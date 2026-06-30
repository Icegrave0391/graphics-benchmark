#!/usr/bin/env bash
#
# create-vmdisk.sh — Build a ready-to-use headless Ubuntu 24.04 qcow2 from the
# official cloud image, customized via cloud-init (NoCloud seed).
#
# Result: vmdisk/ubuntu-vm.qcow2 with user "user" (passwordless, passwordless
# sudo), SSH key auth, and the Mesa/Vulkan graphics userspace + MangoHud
# installed — all headless (no desktop). See docs/benchmark-design.md §4.
#
# Why cloud image (not the desktop ISO): the desktop ISO boots a GNOME GUI
# installer that cannot run unattended. Rendering performance does NOT depend on
# having a desktop — it depends on the Mesa/Vulkan userspace + GPU path, which we
# install below. Benchmarks run CLI/headless.
#
# Run as your normal user. Needs sudo only if the seed tool requires it (it does
# not). Idempotent: caches the base image; rebuilds the working disk each run.
set -euo pipefail

cd "$(dirname "$0")"
source .env

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
log_info "==> Checking prerequisites"
missing=()
[[ -x "$QEMU" ]]      || missing+=("qemu (expected $QEMU — build via 05-qemu-10.2.sh)")
[[ -x "$QEMU_IMG" ]]  || missing+=("qemu-img (expected $QEMU_IMG)")
command -v openssl >/dev/null || missing+=("openssl")
command -v wget >/dev/null || command -v curl >/dev/null || missing+=("wget or curl")
[[ -f "$OVMF_CODE" ]] || missing+=("OVMF firmware ($OVMF_CODE — run 00-base-kvm.sh)")

# seed ISO builder: prefer cloud-localds, fall back to xorriso/genisoimage
SEEDTOOL=""
if command -v cloud-localds >/dev/null; then SEEDTOOL="cloud-localds"
elif command -v xorriso >/dev/null;     then SEEDTOOL="xorriso"
elif command -v genisoimage >/dev/null;  then SEEDTOOL="genisoimage"
else missing+=("a seed-ISO builder: cloud-image-utils (cloud-localds) OR xorriso OR genisoimage"); fi

if (( ${#missing[@]} )); then
  log_err "Missing prerequisites:"
  for m in "${missing[@]}"; do log_err "  - $m"; done
  log_err ""
  log_err "Install the host bits with one command:"
  log_err "  sudo apt-get install -y cloud-image-utils xorriso ovmf wget"
  exit 1
fi
[[ -f "$SSH_PUBKEY" ]] || { log_err "SSH pubkey missing: $SSH_PUBKEY (run ssh-keygen)"; exit 1; }
log_info "    QEMU:      $("$QEMU" --version | head -1)"
log_info "    seed tool: $SEEDTOOL"

mkdir -p "$VMDISKFOLDER"

# ---------------------------------------------------------------------------
# Fetch (and cache) the base cloud image
# ---------------------------------------------------------------------------
if [[ ! -f "$CLOUDIMG_CACHE" ]]; then
  log_info "==> Downloading base cloud image: $CLOUDIMG_NAME"
  log_info "    $CLOUDIMG_URL"
  if command -v wget >/dev/null; then
    wget -O "$CLOUDIMG_CACHE.part" "$CLOUDIMG_URL"
  else
    curl -fL -o "$CLOUDIMG_CACHE.part" "$CLOUDIMG_URL"
  fi
  mv "$CLOUDIMG_CACHE.part" "$CLOUDIMG_CACHE"
else
  log_info "==> Using cached base image: $CLOUDIMG_CACHE"
fi

# ---------------------------------------------------------------------------
# Build the working disk: copy base -> resize to DISK_SIZE
# ---------------------------------------------------------------------------
log_info "==> Creating working qcow2 ($DISK_SIZE) from base image"
rm -f "$VMDISK"
# Make a standalone copy (not a backing-file overlay) so the disk is portable.
"$QEMU_IMG" convert -O qcow2 "$CLOUDIMG_CACHE" "$VMDISK"
"$QEMU_IMG" resize "$VMDISK" "$DISK_SIZE" >/dev/null
cp "$OVMF_VARS_SRC" "$OVMF_VARS"

# ---------------------------------------------------------------------------
# Render cloud-init config and build the NoCloud seed ISO (label: cidata)
# ---------------------------------------------------------------------------
log_info "==> Rendering cloud-init config + seed ISO"
PUBKEY="$(cat "$SSH_PUBKEY")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
sed \
  -e "s/@USERNAME@/$(esc "$USERNAME")/g" \
  -e "s/@HOSTNAME@/$(esc "$HOSTNAME")/g" \
  -e "s/@SSH_PUBKEY@/$(esc "$PUBKEY")/g" \
  cloud-init/user-data > "$WORK/user-data"
sed -e "s/@HOSTNAME@/$(esc "$HOSTNAME")/g" cloud-init/meta-data > "$WORK/meta-data"

case "$SEEDTOOL" in
  cloud-localds)
    cloud-localds -v "$SEEDISO" "$WORK/user-data" "$WORK/meta-data" ;;
  xorriso)
    xorriso -as mkisofs -output "$SEEDISO" -volid cidata -joliet -rock \
      "$WORK/user-data" "$WORK/meta-data" ;;
  genisoimage)
    genisoimage -output "$SEEDISO" -volid cidata -joliet -rock \
      "$WORK/user-data" "$WORK/meta-data" ;;
esac

# ---------------------------------------------------------------------------
# First boot: cloud-init runs once, customizes the guest, then we shut down.
# We poll SSH to know when cloud-init has finished, then power off cleanly.
# ---------------------------------------------------------------------------
log_info "==> First boot: running cloud-init (installs graphics stack, sets up user)"
log_info "    This needs guest network access (QEMU user-net provides it)."

"$QEMU" \
  -name "$VMNAME-firstboot" \
  -machine q35,accel=kvm \
  -cpu host \
  -smp "$VCPUS" \
  -m "$MEMORY" \
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,unit=1,file=$OVMF_VARS" \
  -drive "file=$VMDISK,if=virtio,format=qcow2,cache=writeback" \
  -drive "file=$SEEDISO,media=cdrom,readonly=on" \
  -netdev "user,id=net0,hostfwd=tcp::${SSH_HOSTFWD_PORT}-:22" \
  -device "virtio-net-pci,netdev=net0" \
  -nographic &
QEMU_PID=$!

cleanup_fb() { kill "$QEMU_PID" 2>/dev/null || true; }
trap 'cleanup_fb; rm -rf "$WORK"' EXIT

log_info "==> Waiting for cloud-init to finish (polling SSH on :$SSH_HOSTFWD_PORT)"
SSH_OPTS=(-p "$SSH_HOSTFWD_PORT" -i "$SSH_KEY"
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5 -o LogLevel=ERROR)
deadline=$(( SECONDS + 900 ))   # up to 15 min for first-boot package install
ready=0
while (( SECONDS < deadline )); do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    log_err "    QEMU exited prematurely during first boot."; exit 1
  fi
  if ssh "${SSH_OPTS[@]}" "$USERNAME@localhost" \
       'cloud-init status --wait >/dev/null 2>&1; cloud-init status' 2>/dev/null \
       | grep -q 'status: done'; then
    ready=1; break
  fi
  sleep 10
done

if (( ! ready )); then
  log_err "    Timed out waiting for cloud-init. Check by SSHing in manually."
  exit 1
fi
log_info "    cloud-init finished."

# Quick graphics-stack sanity probe (best-effort).
log_info "==> Graphics stack probe inside guest:"
ssh "${SSH_OPTS[@]}" "$USERNAME@localhost" \
  'echo -n "  vulkan: "; vulkaninfo --summary 2>/dev/null | grep -m1 deviceName || echo "(vulkaninfo not ready)"; \
   echo -n "  gl:     "; glxinfo -B 2>/dev/null | grep -m1 "OpenGL renderer" || echo "(no GL — expected until a GPU path is attached)"' \
  2>/dev/null || true

log_info "==> Shutting down guest cleanly"
ssh "${SSH_OPTS[@]}" "$USERNAME@localhost" 'sudo poweroff' 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 1; done
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
trap 'rm -rf "$WORK"' EXIT

log_info ""
log_info "==> Done. Disk ready: $VMDISK"
log_info "    Boot it with:   ./start-vm.sh        (headless)"
log_info "                    ./start-vm.sh --gui  (window, for GPU-path bringup)"
log_info "    SSH in with:    ./ssh-vm.sh          (user '$USERNAME', key auth, no password)"
