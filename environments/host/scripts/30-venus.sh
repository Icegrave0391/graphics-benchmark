#!/usr/bin/env bash
#
# 30-venus.sh — Build virglrenderer with Venus (Vulkan over virtio-gpu).
#
# Ubuntu 24.04 ships virglrenderer 1.0.0 WITHOUT the venus capset. Venus needs
# virglrenderer built with -Dvenus=true. QEMU is already covered by
# 05-qemu-10.2.sh (Venus also needs QEMU >= 9.2, which 10.2 satisfies).
#
# This builds virglrenderer (venus + amdgpu drm native context) and installs it
# to /usr/local.
#
# ORDER: run this BEFORE 05-qemu-10.2.sh. QEMU must be compiled AFTER this so it
# links against this venus-enabled virglrenderer (05 prefers /usr/local via
# PKG_CONFIG_PATH and verifies the link). Recommended sequence:
#     00-base-kvm.sh  ->  30-venus.sh  ->  05-qemu-10.2.sh
#
# Run after 00-base-kvm.sh. Source build.
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

echo "==> Fetching virglrenderer (${VIRGL_REF})"
mkdir -p "${SRC_DIR}"
if [[ ! -d "${SRC_DIR}/virglrenderer/.git" ]]; then
  git clone https://gitlab.freedesktop.org/virgl/virglrenderer.git \
    "${SRC_DIR}/virglrenderer"
fi
cd "${SRC_DIR}/virglrenderer"
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

NEXT: run 05-qemu-10.2.sh now. It will build QEMU 10.2 linked against THIS
venus-enabled virglrenderer (it prefers ${PREFIX} via PKG_CONFIG_PATH and warns
if it would pick a different one). If you ran 05 earlier against the apt
virglrenderer, just run it again now.

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
