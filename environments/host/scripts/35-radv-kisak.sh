#!/usr/bin/env bash
#
# 35-radv-kisak.sh — install a known-good host RADV for Venus.
#
# Venus decodes guest Vulkan by calling the HOST Vulkan ICD from inside QEMU /
# virglrenderer. On the Renoir/Cezanne test host, Ubuntu 24.04's stock RADV
# exposed Venus but crashed in the host decoder thread under real workloads:
#
#     vkr-ring-* segfault ... in libvulkan_radeon.so
#
# Updating only the Mesa Vulkan driver stack to kisak-mesa's Mesa 26.1.3 fixed
# vkmark and GravityMark over Venus. This script adds the kisak PPA and upgrades
# the narrow RADV-relevant packages instead of running a broad full-upgrade.
#
# Run after 00-base-kvm.sh. Re-run QEMU/venus VMs after this (reboot not required
# for the package files, but recommended if you want a completely clean state).
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

echo "==> Adding kisak-mesa PPA (Mesa/RADV)"
apt-get update -y
apt-get install -y --no-install-recommends software-properties-common ca-certificates
add-apt-repository -y ppa:kisak/kisak-mesa

echo "==> Upgrading RADV-related packages only (no full-upgrade)"
apt-get update -y
apt-get install -y --only-upgrade \
  mesa-vulkan-drivers \
  libglapi-mesa \
  libegl-mesa0 \
  libglx-mesa0 \
  libgl1-mesa-dri \
  libgbm1

cat <<'EOF'

Done. Host RADV/Mesa packages are upgraded from kisak-mesa.

Verify RADV (and not AMDVLK) with:

    DISABLE_LAYER_AMD_SWITCHABLE_GRAPHICS_1=1 \
    VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
    vulkaninfo --summary | grep -E 'deviceName|driverName|driverInfo'

Start Venus with the default RADV host decoder:

    cd environments/virtualization/virtio-venus/linux-guest
    ./start.sh --gui

If AMDVLK is installed, the Venus start script disables AMDVLK's implicit layer
and explicitly selects /usr/share/vulkan/icd.d/radeon_icd.json by default.
EOF
