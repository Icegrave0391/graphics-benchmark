#!/usr/bin/env bash
#
# 05-qemu-10.2.sh — Build and install QEMU 10.2 from source (Ubuntu 24.04).
#
# Ubuntu 24.04 ships QEMU 8.2.2, which is too old for Venus (needs >= 9.2) and
# lacks newer virtio-gpu features. This builds QEMU 10.2 with OpenGL +
# virglrenderer support and installs it to /usr/local.
#
# Run AFTER 00-base-kvm.sh. The stock qemu-system-x86 from base is kept only for
# its OVMF/tooling dependencies; at runtime use /usr/local/bin/qemu-system-x86_64.
#
# NOTE on ordering vs. Venus: for the Venus path you want QEMU linked against the
# venus-enabled virglrenderer. If you plan to run Venus, build virglrenderer
# first (30-venus.sh builds it) OR re-run this script after it so QEMU links the
# right library. For VirGL/passthrough this stock-virglrenderer build is fine.
set -euo pipefail

QEMU_VERSION="10.2.0"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TARBALL}"
SRC_DIR="${SRC_DIR:-/usr/local/src}"
PREFIX="${PREFIX:-/usr/local}"
JOBS="$(nproc)"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

echo "==> Installing QEMU build dependencies"
apt-get update -y
apt-get install -y --no-install-recommends \
  build-essential ninja-build meson pkg-config python3 python3-venv \
  libglib2.0-dev libpixman-1-dev zlib1g-dev libfdt-dev \
  libslirp-dev libusb-1.0-0-dev libaio-dev \
  libepoxy-dev libgbm-dev libdrm-dev libegl-dev libgl-dev \
  libvirglrenderer-dev \
  libseccomp-dev libcap-ng-dev \
  flex bison wget xz-utils

echo "==> Fetching QEMU ${QEMU_VERSION}"
mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"
if [[ ! -f "${QEMU_TARBALL}" ]]; then
  wget -O "${QEMU_TARBALL}" "${QEMU_URL}"
fi
rm -rf "qemu-${QEMU_VERSION}"
tar xf "${QEMU_TARBALL}"
cd "qemu-${QEMU_VERSION}"

echo "==> Configuring QEMU (x86_64, KVM, OpenGL, virglrenderer)"
mkdir -p build && cd build
../configure \
  --prefix="${PREFIX}" \
  --target-list=x86_64-softmmu \
  --enable-kvm \
  --enable-opengl \
  --enable-virglrenderer \
  --enable-slirp \
  --enable-seccomp

echo "==> Building QEMU (-j${JOBS})"
ninja -j"${JOBS}"

echo "==> Installing QEMU to ${PREFIX}"
ninja install
ldconfig

echo
echo "==> Installed version"
"${PREFIX}/bin/qemu-system-x86_64" --version | head -n1

cat <<EOF

Done. QEMU ${QEMU_VERSION} installed at ${PREFIX}/bin/qemu-system-x86_64.

Make sure ${PREFIX}/bin precedes /usr/bin in PATH, or call it by full path in
your guest launch scripts. Verify:

    which qemu-system-x86_64
    qemu-system-x86_64 --version
EOF
