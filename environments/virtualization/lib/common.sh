#!/usr/bin/env bash
#
# common.sh — shared helpers for the virtualization launch scripts.
#
# Two orthogonal dimensions are kept separate so the matrix stays comparable and
# the scripts extend to Windows guests cleanly:
#
#   * GUEST  (OS dimension)   — which guest image + its config/remote tooling.
#                               Provided by environments/guest/<os>/.env.
#   * SCHEME (GPU-path dim.)   — VirGL / Venus / passthrough device args.
#                               Provided by each <scheme>/<os>-guest/start.sh.
#
# A scheme start.sh sets GUEST (linux|windows), SSH_HOSTFWD_PORT, VM_RUN_NAME,
# defines a GPU_ARGS array, then calls run_qemu. Every scheme boots the SAME
# per-OS image; only the GPU path differs. muvm (libkrun, no QEMU) does not use
# run_qemu — see muvm/linux-guest/start.sh.

# --- repo paths --------------------------------------------------------------
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
VIRT_DIR="$(cd "$_LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd "$VIRT_DIR/../.." && pwd)"

# --- guest selection ---------------------------------------------------------
# Default to linux; a Windows scheme sets GUEST=windows before sourcing.
GUEST="${GUEST:-linux}"
GUEST_DIR="$REPO_ROOT/environments/guest/$GUEST"
GUEST_ENV="$GUEST_DIR/.env"

if [[ ! -f "$GUEST_ENV" ]]; then
  echo "ERROR: guest config not found: $GUEST_ENV" >&2
  echo "       GUEST='$GUEST' — build that guest first" >&2
  echo "       (e.g. environments/guest/$GUEST/create-vmdisk.sh)." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$GUEST_ENV"

# The guest .env may export GUEST_OS to drive OS-specific behaviour; default to
# the directory name so existing Linux .env (which predates this) still works.
GUEST_OS="${GUEST_OS:-$GUEST}"

# Per-scheme override so multiple schemes can run concurrently on distinct ports.
SSH_HOSTFWD_PORT="${SSH_HOSTFWD_PORT:-2222}"
VM_RUN_NAME="${VM_RUN_NAME:-graphics-benchmark-$GUEST}"

# --- display mode ------------------------------------------------------------
# Default headless (egl-headless) for automated/offscreen runs. Pass --gui for a
# GTK window where the guest displays onscreen through its GNOME/X11 desktop —
# the real render-and-present use case.
DISPLAY_MODE="${DISPLAY_MODE:-headless}"
parse_common_args() {
  for a in "$@"; do
    case "$a" in
      --gui)      DISPLAY_MODE="gui" ;;
      --headless) DISPLAY_MODE="headless" ;;
      *) log_warn "ignoring unknown arg: $a" ;;
    esac
  done
}

# --- preconditions -----------------------------------------------------------
check_qemu_guest() {
  [[ -x "$QEMU" ]]      || { log_err "QEMU not found at $QEMU (build via host/scripts/05-qemu-10.2.sh)"; exit 1; }
  [[ -f "$VMDISK" ]]    || { log_err "Guest disk missing: $VMDISK (run guest/$GUEST/create-vmdisk.sh)"; exit 1; }
  [[ -f "$OVMF_CODE" ]] || { log_err "OVMF firmware missing: $OVMF_CODE (run host/scripts/00-base-kvm.sh)"; exit 1; }
  [[ -f "$OVMF_VARS" ]] || cp "$OVMF_VARS_SRC" "$OVMF_VARS"
}

# Confirm the runtime QEMU actually has virglrenderer (needed by virgl/venus).
warn_if_no_virgl() {
  if ! "$QEMU" -device help 2>/dev/null | grep -q 'virtio-gpu-gl'; then
    log_warn "This QEMU lacks virtio-gpu-gl (virglrenderer). Rebuild via 05-qemu-10.2.sh."
  fi
}

# --- OS-specific bits --------------------------------------------------------
# How to reach the guest, and how to probe the GPU path, differ per OS. Both can
# be overridden by the guest .env; sane defaults are provided here.

# remote_hint: printed after launch so the user knows how to connect.
remote_hint() {
  case "$GUEST_OS" in
    windows)
      echo "RDP: localhost:${RDP_HOSTFWD_PORT:-3389}  (or SSH if OpenSSH Server is enabled in the guest)"
      ;;
    *)
      echo "ssh -p $SSH_HOSTFWD_PORT -i ${SSH_KEY:-<key>} ${USERNAME:-user}@localhost"
      ;;
  esac
}

# gpu_probe_hint: a command the user can run in the guest to confirm the GPU path
# resolved to the real AMD device (vs. llvmpipe / software). A scheme should set
# GPU_PROBE_HINT to the API-correct probe (VirGL = OpenGL, Venus = Vulkan); we
# fall back to an OS-generic hint when it is unset.
gpu_probe_hint() {
  if [[ -n "${GPU_PROBE_HINT:-}" ]]; then
    echo "$GPU_PROBE_HINT"; return
  fi
  case "$GUEST_OS" in
    windows) echo "dxdiag / PresentMon (check adapter is 'AMD Radeon ...', not Basic Render)" ;;
    *)       echo "vulkaninfo --summary | grep deviceName   (and/or eglinfo -B)" ;;
  esac
}

# --- display fragment --------------------------------------------------------
display_args() {
  if [[ "$DISPLAY_MODE" == "gui" ]]; then
    printf '%s\n' -display "gtk,gl=on"
  else
    printf '%s\n' -display "egl-headless,gl=on"
  fi
}

# --- base (non-GPU) QEMU args ------------------------------------------------
# Venus needs a shared memory backend (blob resources), so we always provide a
# memfd backend; it is harmless for VirGL/passthrough too. Per-OS extras (e.g.
# the virtio-win cdrom, RDP forward) are appended via GUEST_EXTRA_ARGS from the
# guest .env if present.
base_qemu_args() {
  local mem_mib="$MEMORY"
  BASE_ARGS=(
    -name "$VM_RUN_NAME"
    -machine q35,accel=kvm,memory-backend=mem0
    -object "memory-backend-memfd,id=mem0,size=${mem_mib}M,share=on"
    -cpu host
    -smp "$VCPUS"
    -m "${mem_mib}M"
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$OVMF_VARS"
    -drive "file=$VMDISK,if=virtio,format=qcow2,cache=writeback"
    -netdev "user,id=net0,hostfwd=tcp::${SSH_HOSTFWD_PORT}-:22"
    -device "virtio-net-pci,netdev=net0"
  )
  # Optional per-OS additions: the guest .env may define an array and set
  # GUEST_EXTRA_ARGS to its name (e.g. a virtio-win cdrom or extra hostfwd).
  if [[ -n "${GUEST_EXTRA_ARGS:-}" ]] && declare -p "$GUEST_EXTRA_ARGS" >/dev/null 2>&1; then
    local -n _extra="$GUEST_EXTRA_ARGS"
    BASE_ARGS+=( "${_extra[@]}" )
  fi
}

# --- launch ------------------------------------------------------------------
# run_qemu <label> -- <GPU_ARGS...>
run_qemu() {
  local label="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  local gpu_args=( "$@" )

  base_qemu_args
  local disp_args=(); mapfile -t disp_args < <(display_args)

  log_info "==> Launching $label  [guest: $GUEST_OS]"
  log_info "    guest disk : $VMDISK"
  log_info "    display    : $DISPLAY_MODE"
  log_info "    connect    : $(remote_hint)"
  log_info "    verify GPU : $(gpu_probe_hint)"

  exec "$QEMU" "${BASE_ARGS[@]}" "${disp_args[@]}" "${gpu_args[@]}"
}
