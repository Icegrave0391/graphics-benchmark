#!/usr/bin/env bash
#
# start-vm.sh — Boot the installed Windows guest qcow2.
#
# UEFI (Secure Boot OFF, no TPM) to match the install. Forwards host ports for
# SSH ($SSH_HOSTFWD_PORT->22) and RDP ($RDP_HOSTFWD_PORT->3389). Default is a
# GTK window (onscreen); pass --headless for a windowless run.
#
# NOTE: virtio-gpu 3D on Windows is basic (2D/framebuffer). Real graphics
# benchmarking on Windows uses VFIO passthrough (pt-windows) with the native AMD
# Windows driver — see ../../README and environments/virtualization/passthrough.
set -euo pipefail

cd "$(dirname "$0")"
source .env

GUI=1
for a in "$@"; do
  case "$a" in
    --gui)      GUI=1 ;;
    --headless) GUI=0 ;;
    *) log_warn "ignoring unknown arg: $a" ;;
  esac
done

[[ -f "$VMDISK" ]]    || { log_err "No disk at $VMDISK — run ./create-vmdisk.sh first."; exit 1; }
[[ -f "$OVMF_VARS" ]] || { log_err "UEFI vars missing: $OVMF_VARS (rebuild)"; exit 1; }

log_info "==> Booting $VMNAME"
log_info "    SSH: ssh -p $SSH_HOSTFWD_PORT $USERNAME@localhost   (password '$PASSWORD' or key)"
log_info "    RDP: localhost:$RDP_HOSTFWD_PORT"

QEMU_ARGS=(
  -name "$VMNAME"
  -machine q35,accel=kvm
  -cpu host
  -smp "$VCPUS"
  -m "$MEMORY"
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
  -drive "if=pflash,format=raw,unit=1,file=$OVMF_VARS"
  -drive "file=$VMDISK,if=virtio,format=qcow2,cache=writeback"
  -netdev "user,id=net0,hostfwd=tcp::${SSH_HOSTFWD_PORT}-:22,hostfwd=tcp::${RDP_HOSTFWD_PORT}-:3389"
  -device "virtio-net-pci,netdev=net0"
  -device "virtio-gpu-gl,blob=true"
  -device "qemu-xhci,id=usb"
  -device "usb-tablet,bus=usb.0"
  -device "usb-kbd,bus=usb.0"
)

if [[ "$GUI" -eq 1 ]]; then
  QEMU_ARGS+=( -display gtk,gl=on )
else
  QEMU_ARGS+=( -display egl-headless,gl=on )
fi

exec "$QEMU" "${QEMU_ARGS[@]}"
