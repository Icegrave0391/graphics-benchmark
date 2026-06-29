#!/usr/bin/env bash
#
# 10-passthrough.sh — VFIO GPU passthrough host setup (Ubuntu 24.04, AMD).
#
# vfio-pci and vfio_iommu_type1 are in-kernel (no apt package). The real work is
# kernel cmdline (IOMMU) + binding the GPU to vfio-pci. This script installs the
# helper 'driverctl', loads modules, and PRINTS the cmdline changes for you to
# apply — it does NOT edit your bootloader automatically.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

echo "==> Installing optional helper (driverctl) for vfio-pci binding"
apt-get update -y
apt-get install -y --no-install-recommends driverctl

echo "==> Checking IOMMU status"
if ! dmesg | grep -qiE 'AMD-Vi|IOMMU enabled'; then
  echo "WARNING: IOMMU does not look enabled in dmesg." >&2
fi

echo "==> Loading VFIO modules (in-kernel, no install needed)"
modprobe vfio-pci || true
modprobe vfio_iommu_type1 || true

cat <<'EOF'

============================================================================
 MANUAL STEPS (apply these yourself, then reboot)
============================================================================
1) Enable IOMMU on the kernel cmdline. Edit /etc/default/grub:

     GRUB_CMDLINE_LINUX_DEFAULT="... amd_iommu=on iommu=pt"

   Then:  sudo update-grub  && reboot

2) Find your GPU + its audio function and their vendor:device IDs:

     lspci -nnk | grep -A3 -iE 'VGA|Audio'

3) Bind the GPU to vfio-pci early (so amdgpu does not grab it). Add to cmdline:

     vfio-pci.ids=<gpu_vendor:device>,<audio_vendor:device>

   OR use driverctl at runtime:

     sudo driverctl set-override 0000:<bus:dev.fn> vfio-pci

4) Verify the GPU sits in a clean IOMMU group:

     for d in /sys/kernel/iommu_groups/*/devices/*; do \
       echo "group ${d%/*/*} -> $(basename "$d")"; done | sort

----------------------------------------------------------------------------
 AMD-SPECIFIC CAVEATS
----------------------------------------------------------------------------
 * AMD reset bug: many consumer Radeon cards cannot soft-reset after
   passthrough; guest reboot may hang the GPU. Fix with the vendor-reset DKMS
   module (source: https://github.com/gnif/vendor-reset — NOT in apt).
 * The passed-through GPU must NOT be in use by the host amdgpu driver.
 * If the IOMMU group is not isolated, you may need ACS override (not
   recommended for anything but testing).
============================================================================
EOF
