#!/usr/bin/env bash
#
# 30-venus.sh — Build virglrenderer with Venus (Vulkan over virtio-gpu).
#
# Ubuntu 24.04 ships virglrenderer 1.0.0 WITHOUT the venus capset. Venus needs
# virglrenderer built with -Dvenus=true. QEMU is already covered by
# 05-qemu-10.2.sh (Venus also needs QEMU >= 9.2, which 10.2 satisfies).
#
# This builds virglrenderer (venus + drm native context) and installs it to
# /usr/local. After this you should RE-RUN 05-qemu-10.2.sh so QEMU links against
# this venus-enabled virglrenderer.
#
# Run after 00-base-kvm.sh and 05-qemu-10.2.sh. Source build.
set -euo pipefail

VIRGL_REF="${VIRGL_REF:-1.1.0}"   # tag/branch of virglrenderer to build
SRC_DIR="${SRC_DIR:-/usr/local/src}"
PREFIX="${PREFIX:-/usr/local}"
JOBS="$(nproc)"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

echo "==> Installing virglrenderer build dependencies"
apt-get update -y
apt-get install -y --no-install-recommends \
  build-essential meson ninja-build pkg-config git \
  libgbm-dev libdrm-dev libegl-dev libgl-dev libgles-dev \
  libepoxy-dev \
  libvulkan-dev mesa-vulkan-drivers \
  spirv-tools python3-mako

echo "==> Cloning virglrenderer (${VIRGL_REF})"
mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"
if [[ ! -d virglrenderer ]]; then
  git clone https://gitlab.freedesktop.org/virgl/virglrenderer.git
fi
cd virglrenderer
git fetch --all --tags
git checkout "${VIRGL_REF}"

echo "==> Configuring virglrenderer (venus + amdgpu drm native context)"
rm -rf build
meson setup build \
  --prefix="${PREFIX}" \
  -Dvenus=true \
  -Ddrm-renderers=amdgpu-experimental \
  -Dvideo=false

echo "==> Building virglrenderer (-j${JOBS})"
ninja -C build -j"${JOBS}"

echo "==> Installing virglrenderer to ${PREFIX}"
ninja -C build install
ldconfig

cat <<EOF

Done. virglrenderer with Venus is installed at ${PREFIX}.

IMPORTANT: re-run 05-qemu-10.2.sh now so QEMU 10.2 links against THIS
virglrenderer (the venus-enabled one), otherwise venus=on will not work.

Example guest launch fragment (Linux guest, Venus / Vulkan):

    qemu-system-x86_64 \\
      -object memory-backend-memfd,id=mem1,size=8G,share=on \\
      -machine memory-backend=mem1 \\
      -device virtio-gpu-gl,hostmem=8G,blob=true,venus=true \\
      -display egl-headless,gl=on \\
      ... (cpu/mem/disk/net) ...

Guest needs Mesa with the venus Vulkan driver (VK_ICD: virtio-gpu venus).
DirectX workloads run via DXVK/VKD3D on top of this Vulkan path.
EOF
