#!/usr/bin/env bash
#
# create-vmdisk.sh — Build a Windows guest qcow2 via unattended install.
#
# There is no Windows cloud image, so we install from a Windows ISO you provide
# (WINDOWS_ISO) using autounattend.xml on a seed CD, with the virtio-win driver
# CD attached so the virtio system disk + NIC work. Result:
# vmdisk/windows-vm.qcow2 with user "user" (password "user"), RDP + OpenSSH
# Server enabled, virtio drivers + QEMU guest agent installed.
#
# Targets Windows 10: UEFI but Secure Boot OFF, no TPM (simplest, and avoids
# Secure-Boot conflicts on the passthrough path).
#
# Run as your normal user. Idempotent: caches virtio-win; rebuilds the disk.
set -euo pipefail

cd "$(dirname "$0")"
source .env

# --- preconditions -----------------------------------------------------------
log_info "==> Checking prerequisites"
missing=()
[[ -x "$QEMU" ]]     || missing+=("qemu ($QEMU — build via host/scripts/05-qemu-10.2.sh)")
[[ -x "$QEMU_IMG" ]] || missing+=("qemu-img ($QEMU_IMG)")
[[ -f "$OVMF_CODE" ]]     || missing+=("OVMF firmware ($OVMF_CODE — run host/scripts/00-base-kvm.sh)")
[[ -f "$OVMF_VARS_SRC" ]] || missing+=("OVMF vars ($OVMF_VARS_SRC)")
command -v wget >/dev/null || command -v curl >/dev/null || missing+=("wget or curl")
SEEDTOOL=""
if command -v xorriso >/dev/null;       then SEEDTOOL="xorriso"
elif command -v genisoimage >/dev/null;  then SEEDTOOL="genisoimage"
else missing+=("xorriso or genisoimage (seed ISO builder)"); fi

if (( ${#missing[@]} )); then
  log_err "Missing prerequisites:"
  for m in "${missing[@]}"; do log_err "  - $m"; done
  log_err ""
  log_err "Install host bits with:  sudo apt-get install -y xorriso ovmf wget"
  exit 1
fi
[[ -f "$SSH_PUBKEY" ]] || { log_err "SSH pubkey missing: $SSH_PUBKEY"; exit 1; }

# Windows ISO: auto-download (idempotent) if not provided/found.
if [[ ! -f "$WINDOWS_ISO" ]]; then
  log_info "==> Windows ISO not found — fetching it (get-windows-iso.sh)"
  ./get-windows-iso.sh
fi
[[ -f "$WINDOWS_ISO" ]] || { log_err "Still no Windows ISO at $WINDOWS_ISO; aborting."; exit 1; }

log_info "    QEMU:        $("$QEMU" --version | head -1)"
log_info "    Windows ISO: $WINDOWS_ISO"
log_info "    seed tool:   $SEEDTOOL"

mkdir -p "$VMDISKFOLDER"

# --- fetch virtio-win driver ISO (cached) ------------------------------------
if [[ ! -f "$VIRTIO_WIN_ISO" ]]; then
  log_info "==> Downloading virtio-win driver ISO"
  log_info "    $VIRTIO_WIN_URL"
  if command -v wget >/dev/null; then
    wget -O "$VIRTIO_WIN_ISO.part" "$VIRTIO_WIN_URL"
  else
    curl -fL -o "$VIRTIO_WIN_ISO.part" "$VIRTIO_WIN_URL"
  fi
  mv "$VIRTIO_WIN_ISO.part" "$VIRTIO_WIN_ISO"
else
  log_info "==> Using cached virtio-win ISO: $VIRTIO_WIN_ISO"
fi

# --- render autounattend.xml + build seed ISO --------------------------------
log_info "==> Rendering autounattend.xml + seed ISO"
PUBKEY="$(cat "$SSH_PUBKEY")"
# Edition name embedded in the ISO (WIM). Common: "Windows 10 Pro",
# "Windows 11 Pro". Override with WIN_EDITION if your ISO differs.
WIN_EDITION="${WIN_EDITION:-Windows 10 Pro}"

# Build the base64 (-EncodedCommand) PowerShell that writes the admin
# authorized_keys with the correct restrictive ACL. Encoding it avoids the
# nested-quote escaping that previously made the key-write silently fail in the
# XML. (Same approach as fix-ssh-key.sh.)
read -r -d '' _SSH_PS <<PSEOF || true
\$ErrorActionPreference='SilentlyContinue'
\$key='${PUBKEY}'
\$f="\$env:ProgramData\\ssh\\administrators_authorized_keys"
New-Item -Force -ItemType Directory (Split-Path \$f) | Out-Null
Set-Content -Path \$f -Value \$key -Encoding ascii
icacls \$f /inheritance:r
icacls \$f /grant "Administrators:F" "SYSTEM:F"
PSEOF
SSH_SETUP_ENCODED="$(printf '%s' "$_SSH_PS" | iconv -t UTF-16LE | base64 -w0)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
sed \
  -e "s/@USERNAME@/$(esc "$USERNAME")/g" \
  -e "s/@PASSWORD@/$(esc "$PASSWORD")/g" \
  -e "s/@HOSTNAME@/$(esc "$HOSTNAME")/g" \
  -e "s/@WIN_EDITION@/$(esc "$WIN_EDITION")/g" \
  -e "s/@SSH_PUBKEY@/$(esc "$PUBKEY")/g" \
  -e "s/@SSH_SETUP_ENCODED@/$(esc "$SSH_SETUP_ENCODED")/g" \
  autounattend/autounattend.xml > "$WORK/autounattend.xml"

# The seed CD must have the file at its root named autounattend.xml; Windows
# Setup scans attached media for it automatically.
case "$SEEDTOOL" in
  xorriso)     xorriso -as mkisofs -output "$SEEDISO" -volid AUTOINST -joliet -rock "$WORK/autounattend.xml" ;;
  genisoimage) genisoimage -output "$SEEDISO" -volid AUTOINST -joliet -rock "$WORK/autounattend.xml" ;;
esac

# --- blank disk + UEFI vars --------------------------------------------------
log_info "==> Creating blank qcow2 ($DISK_SIZE) + UEFI vars"
rm -f "$VMDISK"
"$QEMU_IMG" create -f qcow2 "$VMDISK" "$DISK_SIZE" >/dev/null
cp "$OVMF_VARS_SRC" "$OVMF_VARS"

# --- run the unattended installer --------------------------------------------
# CD order matters for drive letters Windows assigns: installer first, then the
# virtio-win CD lands on E: (matching the autounattend driver paths), then seed.
log_info "==> Launching unattended Windows install (no interaction needed)"
log_warn "    This takes a while and reboots itself a few times."
log_info "    Watch progress in the QEMU window."

"$QEMU" \
  -name "$VMNAME-install" \
  -machine q35,accel=kvm \
  -cpu host \
  -smp "$VCPUS" \
  -m "$MEMORY" \
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,unit=1,file=$OVMF_VARS" \
  -device ahci,id=sata \
  -drive "file=$VMDISK,if=none,id=disk0,format=qcow2,cache=writeback" \
  -device "virtio-blk-pci,drive=disk0,bootindex=1" \
  -drive "file=$WINDOWS_ISO,if=none,id=cd-win,media=cdrom,readonly=on" \
  -device "ide-cd,bus=sata.0,drive=cd-win,bootindex=0" \
  -drive "file=$VIRTIO_WIN_ISO,if=none,id=cd-virtio,media=cdrom,readonly=on" \
  -device "ide-cd,bus=sata.1,drive=cd-virtio" \
  -drive "file=$SEEDISO,if=none,id=cd-seed,media=cdrom,readonly=on" \
  -device "ide-cd,bus=sata.2,drive=cd-seed" \
  -netdev "user,id=net0,hostfwd=tcp::${SSH_HOSTFWD_PORT}-:22,hostfwd=tcp::${RDP_HOSTFWD_PORT}-:3389" \
  -device "virtio-net-pci,netdev=net0" \
  -device "virtio-gpu-gl,blob=true" \
  -device "qemu-xhci,id=usb" \
  -device "usb-tablet,bus=usb.0" \
  -device "usb-kbd,bus=usb.0" \
  -display gtk,gl=on

log_info ""
log_info "==> Installer window closed."
if [[ -f "$VMDISK" ]]; then
  log_info "    Disk: $VMDISK"
  log_info "    Boot:  ./start-vm.sh"
  log_info "    SSH:   ./ssh-vm.sh        (user '$USERNAME', key or password '$PASSWORD')"
  log_info "    RDP:   localhost:${RDP_HOSTFWD_PORT}"
else
  log_err "    Disk not created — check the installer."
  exit 1
fi
