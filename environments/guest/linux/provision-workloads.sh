#!/usr/bin/env bash
#
# provision-workloads.sh — bake the workload TOOLS into the guest qcow2 (host-side).
#
# Instead of cloning the repo into the guest and re-downloading every benchmark
# there, we prepare the self-contained tools ONCE on the host and copy them
# straight into the guest disk image with libguestfs (virt-copy-in) — no chroot,
# no nbd, no mounting, and the guest does not need to be running.
#
# Split of responsibilities:
#   * Self-contained payloads (GravityMark .run extracted, Basemark .tar.gz
#     extracted) — prepared here in WL_DOWNLOAD_ONLY mode (host only downloads +
#     extracts, installs NOTHING system-wide, stays clean) and copied in.
#   * apt/dpkg deps (X libs, libssl1.1) — installed by the guest's cloud-init
#     (see cloud-init/user-data). Build the disk first with create-vmdisk.sh so
#     those are already present.
#   * chrome-sandbox SUID fix for Basemark — applied here via virt-customize.
#
# Scope: GravityMark + Basemark GPU only.
#
# Linux guest only (this repo does not support a Windows guest).
#
# Run as your normal user, with the guest POWERED OFF. Idempotent.

set -euo pipefail
cd "$(dirname "$0")"
source .env

REPO_ROOT="$(cd ../../.. && pwd)"
WORKLOADS_DIR="$REPO_ROOT/workloads"
# Where the tools land inside the guest (owned by the guest user).
GUEST_DEST="/home/$USERNAME/graphics-benchmark"

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
log_info "==> Checking prerequisites"
missing=()
command -v virt-copy-in   >/dev/null || missing+=("virt-copy-in (apt install libguestfs-tools)")
command -v virt-customize >/dev/null || missing+=("virt-customize (apt install libguestfs-tools)")
[[ -f "$VMDISK" ]] || missing+=("guest disk $VMDISK (run ./create-vmdisk.sh first)")
if (( ${#missing[@]} )); then
  log_err "Missing prerequisites:"
  for m in "${missing[@]}"; do log_err "  - $m"; done
  log_err ""
  log_err "Install host bits:  sudo apt-get install -y libguestfs-tools"
  exit 1
fi

# Refuse to touch the disk while the VM is running (would corrupt it).
if pgrep -af "qemu-system.*$(basename "$VMDISK")" >/dev/null 2>&1; then
  log_err "The guest appears to be RUNNING (qemu has $VMDISK open)."
  log_err "Shut it down first; libguestfs must not write to a live disk."
  exit 1
fi

# libguestfs (supermin) needs to READ the host kernel image. On Ubuntu/Debian
# /boot/vmlinuz-* is mode 0600 (root only), which makes supermin fail with
# "/usr/bin/supermin exited with error status 1" when run as a normal user.
# Detect and tell the user exactly how to fix it.
if ! find /boot -maxdepth 1 -name 'vmlinuz-*' -readable 2>/dev/null | grep -q .; then
  log_err "libguestfs can't read the host kernel (/boot/vmlinuz-* is root-only)."
  log_err "supermin will fail. Grant read access (safe, standard libguestfs fix):"
  log_err "    sudo chmod +r /boot/vmlinuz-*"
  log_err "Then re-run this script. (Permanent across kernel updates:"
  log_err "    sudo dpkg-statoverride --add --update root root 0644 /boot/vmlinuz-\$(uname -r))"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Prepare the self-contained tools on the host (download + extract ONLY).
#    WL_DOWNLOAD_ONLY=1 makes the install scripts skip all apt/dpkg/SUID steps,
#    so the host system is not modified.
# ---------------------------------------------------------------------------
log_info "==> Preparing workload tools on the host (download + extract only)"
export WL_DOWNLOAD_ONLY=1
"$WORKLOADS_DIR/gravitymark/install.sh"
"$WORKLOADS_DIR/basemark-gpu/install.sh"

# What to copy in: the extracted tool trees + the runner scripts + lib. We avoid
# copying the big .cache/ (raw installers) since the extracted trees suffice.
GM_DIR="$WORKLOADS_DIR/gravitymark/GravityMark"
BMK_DIR="$WORKLOADS_DIR/basemark-gpu/BasemarkGPU"
[[ -d "$GM_DIR" ]]  || { log_err "GravityMark not extracted: $GM_DIR"; exit 1; }
[[ -d "$BMK_DIR" ]] || { log_err "Basemark not extracted: $BMK_DIR"; exit 1; }

# libguestfs appliance must NOT bring up networking here — we only copy files /
# chown / chmod offline. On libguestfs 1.52 (Ubuntu 24.04) the default passt
# backend can fail to start ("passt exited with status 1"); disabling the
# appliance network avoids it entirely and is harmless for offline edits.
export LIBGUESTFS_BACKEND_SETTINGS="network=0"

# ---------------------------------------------------------------------------
# 2. Stage a copy WITHOUT the big raw-installer cache, then copy into the image.
#    virt-copy-in has no exclude, so we build a clean staging tree first (the
#    extracted tool dirs are what the guest needs; .cache/ raw installers are not).
# ---------------------------------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
log_info "==> Staging workloads (excluding .cache/) for copy-in"
rsync -a --exclude='.cache/' "$WORKLOADS_DIR"/ "$STAGE/workloads/"

log_info "==> Copying workloads into the guest image (virt-copy-in)"
log_info "    dest: ${GUEST_DEST}/workloads  (this can take a while; Basemark is ~2.5 GB)"

# virt-copy-in needs the destination dir to exist in the guest.
virt-customize --no-network -a "$VMDISK" \
  --mkdir "$GUEST_DEST" \
  --run-command "chown $USERNAME:$USERNAME $GUEST_DEST"

# Copy the staged tree (scripts, lib, extracted GravityMark + Basemark).
virt-copy-in -a "$VMDISK" "$STAGE/workloads" "$GUEST_DEST/"

# ---------------------------------------------------------------------------
# 3. Fix ownership + Basemark's Electron chrome-sandbox SUID inside the image.
# ---------------------------------------------------------------------------
log_info "==> Fixing ownership + Basemark chrome-sandbox SUID in the image"
virt-customize --no-network -a "$VMDISK" \
  --run-command "chown -R $USERNAME:$USERNAME $GUEST_DEST/workloads" \
  --run-command "find $GUEST_DEST/workloads -name chrome-sandbox -exec chown root:root {} \; -exec chmod 4755 {} \;"

cat <<EOF

$(log_info "==> Done.")
Workloads baked into: $VMDISK
Inside the guest they live at:
    ${GUEST_DEST}/workloads

apt deps (X libs, libssl1.1) come from cloud-init —
make sure the disk was built with the updated create-vmdisk.sh.

Boot and run (onscreen needs the desktop session / DISPLAY=:0):
    ./start-vm.sh --gui
    ./ssh-vm.sh -- 'DISPLAY=:0 ${GUEST_DEST}/workloads/gravitymark/GravityMark/run_windowed_vk.sh -asteroids 200000 -benchmark 1 -close 1'
    ./ssh-vm.sh -- 'DISPLAY=:0 ${GUEST_DEST}/workloads/basemark-gpu/run.sh --api vulkan'
EOF
