#!/usr/bin/env bash
#
# 00-base-kvm.sh — Base QEMU/KVM host dependencies (Ubuntu 24.04 LTS, AMD).
#
# Installs everything needed to boot KVM-accelerated Linux/Windows guests with
# bare qemu-system-x86_64, plus the AMD Mesa/Vulkan userspace. Run this first.
#
# apt-only. Idempotent.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Re-running with sudo..." >&2
  exec sudo -E "$0" "$@"
fi

echo "==> Checking CPU virtualization / KVM support"
if ! grep -Eq 'svm' /proc/cpuinfo; then
  echo "WARNING: AMD-V (svm) flag not found in /proc/cpuinfo." >&2
  echo "         Enable SVM/virtualization in BIOS, or KVM will not work." >&2
fi
if [[ ! -e /dev/kvm ]]; then
  echo "WARNING: /dev/kvm not present. Is the kvm_amd module loaded?" >&2
fi

echo "==> Installing base KVM + QEMU tooling + firmware + networking"
echo "    (stock qemu-system-x86 8.2.2 is installed for OVMF/tooling deps;"
echo "     actual runtime QEMU is 10.2 built by 05-qemu-10.2.sh)"
apt_need \
  qemu-system-x86 \
  qemu-utils \
  qemu-system-gui \
  qemu-system-modules-opengl \
  ovmf \
  swtpm swtpm-tools \
  passt \
  bridge-utils \
  dnsmasq-base

echo "==> Installing AMD Mesa / Vulkan userspace (RADV, radeonsi, tools)"
apt_need \
  mesa-vulkan-drivers \
  mesa-utils \
  vulkan-tools \
  libvulkan1 \
  libgl1-mesa-dri \
  libglx-mesa0 \
  libegl-mesa0

echo "==> Adding invoking user to kvm group (if applicable)"
TARGET_USER="${SUDO_USER:-}"
if [[ -n "${TARGET_USER}" ]]; then
  usermod -aG kvm "${TARGET_USER}" || true
  echo "    Added '${TARGET_USER}' to 'kvm'. Log out/in for it to take effect."
fi

echo
echo "==> Versions"
qemu-system-x86_64 --version | head -n1 || true
vulkaninfo --summary 2>/dev/null | grep -E 'driverName|GPU id|deviceName' | head || true

echo
echo "Done. Base KVM host dependencies are installed."
echo "Next: run 05-qemu-10.2.sh to build the runtime QEMU 10.2,"
echo "      then the script(s) for the scheme(s) you want to benchmark."
