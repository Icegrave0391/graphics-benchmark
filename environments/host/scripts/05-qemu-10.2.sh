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
# ORDERING (important):
#   * Venus path:           00 -> 30-venus.sh (builds virglrenderer w/ venus) -> 05 (this)
#   * VirGL / passthrough:  00 -> 05, but first install the apt VirGL library
#                           (uncomment libvirglrenderer-dev below).
#
# This script does NOT install the apt virglrenderer; it links QEMU against
# whatever virglrenderer pkg-config finds, preferring /usr/local (the source
# venus build). It verifies and warns if that is not the case — so you cannot
# silently end up with a non-venus QEMU.
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
  libgtk-3-dev libvte-2.91-dev \
  libseccomp-dev libcap-ng-dev \
  flex bison wget xz-utils
# libgtk-3-dev enables the 'gtk' display backend (used by the --gui mode of the
# virtualization launchers for bring-up; benchmarks themselves run headless).
#
# NOTE: we intentionally do NOT install the apt 'libvirglrenderer-dev' (1.0.0,
# no venus). For the Venus path you must build the venus-enabled virglrenderer
# FIRST (30-venus.sh installs it to /usr/local), then run this script so QEMU
# links against it. We force pkg-config to prefer /usr/local below.
#
# If you only need VirGL/passthrough and have NOT built the source virglrenderer,
# uncomment the next line to use the apt VirGL-only library instead:
#   apt-get install -y --no-install-recommends libvirglrenderer-dev

echo "==> Selecting virglrenderer for QEMU to link against"
export PKG_CONFIG_PATH="${PREFIX}/lib/x86_64-linux-gnu/pkgconfig:${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
if pkg-config --exists virglrenderer; then
  VIRGL_PC_VER="$(pkg-config --modversion virglrenderer)"
  VIRGL_PC_PREFIX="$(pkg-config --variable=prefix virglrenderer)"
  echo "    Found virglrenderer ${VIRGL_PC_VER} at prefix ${VIRGL_PC_PREFIX}"
  if [[ "${VIRGL_PC_PREFIX}" != "${PREFIX}" ]]; then
    echo "    WARNING: QEMU will link against ${VIRGL_PC_PREFIX}, NOT your" >&2
    echo "             source build in ${PREFIX}. Venus may be unavailable." >&2
    echo "             Build 30-venus.sh first if you need Venus." >&2
  fi
else
  echo "    ERROR: no virglrenderer found via pkg-config." >&2
  echo "           Run 30-venus.sh first, or install libvirglrenderer-dev for VirGL-only." >&2
  exit 1
fi

echo "==> Fetching QEMU ${QEMU_VERSION}"
mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"
if [[ ! -f "${QEMU_TARBALL}" ]]; then
  wget -O "${QEMU_TARBALL}" "${QEMU_URL}"
else
  echo "    tarball already present, skipping download"
fi
if [[ ! -d "qemu-${QEMU_VERSION}" ]]; then
  tar xf "${QEMU_TARBALL}"
else
  echo "    source tree already extracted, skipping"
fi
cd "qemu-${QEMU_VERSION}"

echo "==> Configuring QEMU (x86_64, KVM, OpenGL, virglrenderer, GTK)"
mkdir -p build && cd build
../configure \
  --prefix="${PREFIX}" \
  --target-list=x86_64-softmmu \
  --enable-kvm \
  --enable-opengl \
  --enable-virglrenderer \
  --enable-gtk \
  --enable-slirp \
  --enable-seccomp

echo "==> Confirming QEMU picked up virglrenderer"
if grep -Eiq 'virglrenderer.*(YES|true|enabled)' config-host.mak meson-logs/meson-log.txt 2>/dev/null; then
  echo "    OK: virglrenderer enabled in QEMU build."
else
  echo "    WARNING: could not confirm virglrenderer in the QEMU config." >&2
  echo "             Check build/meson-logs/meson-log.txt before relying on Venus." >&2
fi

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
