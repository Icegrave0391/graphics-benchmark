#!/usr/bin/env bash
#
# start-vm.sh — Boot the installed Ubuntu guest qcow2 (no installer ISO).
#
# Forwards host port $SSH_HOSTFWD_PORT -> guest 22 for SSH. Uses the runtime
# QEMU 10.2 from /usr/local. By default boots headless (windowless, serial
# console); pass --gui for a GTK window where the guest autologins into a
# GNOME/X11 desktop and benchmarks render-and-present onscreen.
set -euo pipefail

cd "$(dirname "$0")"
source .env

GUI=0
for a in "$@"; do
  case "$a" in
    --gui)      GUI=1 ;;
    --headless) GUI=0 ;;
    *) log_warn "ignoring unknown arg: $a" ;;
  esac
done

[[ -f "$VMDISK" ]]   || { log_err "No disk at $VMDISK — run ./create-vmdisk.sh first."; exit 1; }
[[ -f "$OVMF_VARS" ]] || cp "$OVMF_VARS_SRC" "$OVMF_VARS"

log_info "==> Booting $VMNAME"
log_info "    SSH: ssh -p $SSH_HOSTFWD_PORT $USERNAME@localhost  (or ./ssh-vm.sh)"

QEMU_ARGS=(
  -name "$VMNAME"
  -machine q35,accel=kvm,memory-backend=mem0
  -object "memory-backend-memfd,id=mem0,size=${MEMORY}M,share=on"
  -cpu host
  -smp "$VCPUS"
  -m "${MEMORY}M"
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
  -drive "if=pflash,format=raw,unit=1,file=$OVMF_VARS"
  -drive "file=$VMDISK,if=virtio,format=qcow2,cache=writeback"
  -netdev "user,id=net0,hostfwd=tcp::${SSH_HOSTFWD_PORT}-:22"
  -device "virtio-net-pci,netdev=net0"
  -device "virtio-gpu-gl,blob=true"
)

if [[ "$GUI" -eq 1 ]]; then
  QEMU_ARGS+=( -display gtk,gl=on )
else
  QEMU_ARGS+=( -display egl-headless,gl=on -nographic )
fi

exec "$QEMU" "${QEMU_ARGS[@]}"
