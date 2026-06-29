#!/usr/bin/env bash
#
# 40-muvm.sh — Build libkrun + muvm (drm native context path).
#
# muvm (Asahi Linux) runs a lightweight VM via libkrun and reaches the GPU
# through a drm NATIVE CONTEXT (not Venus). There is no apt package for either
# libkrun or muvm on Ubuntu, so both are built from source. The drm native
# context also requires a virglrenderer built with that feature
# (30-venus.sh builds virglrenderer with native context enabled).
#
# Requirements: Mesa >= 24.2 (24.04 amd64 = 25.2.8 OK) and kernel >= 6.13.
# Linux guest only (drm native context is a Linux UAPI).
#
# Run after 00-base-kvm.sh and 30-venus.sh (for the virglrenderer with amdgpu
# drm native context). QEMU/05 is NOT needed for muvm. Source build.
set -euo pipefail

SRC_DIR="${SRC_DIR:-/usr/local/src}"
PREFIX="${PREFIX:-/usr/local}"
JOBS="$(nproc)"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

echo "==> Checking kernel version (muvm needs >= 6.13)"
KREL="$(uname -r)"
KMAJ="${KREL%%.*}"; KMIN="$(echo "${KREL}" | cut -d. -f2)"
if (( KMAJ < 6 || (KMAJ == 6 && KMIN < 13) )); then
  echo "WARNING: running kernel ${KREL}; muvm drm native context needs >= 6.13." >&2
  echo "         Install an HWE / mainline kernel and reboot before benchmarking." >&2
fi

echo "==> Installing build toolchain (Rust via rustup if missing, build deps)"
apt-get update -y
apt-get install -y --no-install-recommends \
  build-essential pkg-config git curl \
  clang libclang-dev llvm-dev \
  flex bison patchelf \
  libelf-dev libpixman-1-dev passt \
  python3 python3-pip

# libkrun's Rust deps (clang-sys / bindgen) need libclang at build time.
# Help them locate it even if llvm-config is not on PATH.
if [[ -z "${LIBCLANG_PATH:-}" ]]; then
  LC_DIR="$(dirname "$(find /usr/lib -name 'libclang.so*' 2>/dev/null | head -n1)")"
  if [[ -n "${LC_DIR}" ]]; then
    export LIBCLANG_PATH="${LC_DIR}"
    echo "==> LIBCLANG_PATH=${LIBCLANG_PATH}"
  fi
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "==> Installing Rust toolchain via rustup (stock rustc 1.75 may be too old)"
  TARGET_USER="${SUDO_USER:-root}"
  sudo -u "${TARGET_USER}" sh -c \
    'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
  export PATH="/home/${TARGET_USER}/.cargo/bin:${PATH}"
fi

echo "==> Building libkrun (containers/libkrun)"
mkdir -p "${SRC_DIR}"; cd "${SRC_DIR}"
if [[ ! -d libkrun ]]; then
  git clone https://github.com/containers/libkrun.git
fi
cd libkrun
git pull --ff-only || true
make PREFIX="${PREFIX}"
make install PREFIX="${PREFIX}"
ldconfig

echo "==> Building muvm (AsahiLinux/muvm)"
cd "${SRC_DIR}"
if [[ ! -d muvm ]]; then
  git clone https://github.com/AsahiLinux/muvm.git
fi
cd muvm
git pull --ff-only || true
cargo build --release
install -m 0755 target/release/muvm "${PREFIX}/bin/muvm"

cat <<EOF

Done. libkrun + muvm installed at ${PREFIX}.

Reminders:
 * Requires virglrenderer with drm native context (built by 30-venus.sh).
 * Requires kernel >= 6.13 (current: ${KREL}).
 * Linux guest only.

Run a GPU workload inside a muvm microVM, e.g.:

    muvm -- <your-benchmark-command>

The guest reaches the host AMD GPU via drm native context (lowest overhead).
EOF
