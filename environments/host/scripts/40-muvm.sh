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
# Run after 00-base-kvm.sh and 30-venus.sh. QEMU/05 is NOT needed for muvm.
#
# Run as your normal user (NOT root): it builds as you and uses sudo only for
# the install steps.
#
# VERSION COUPLING (important): libkrun and muvm must match. muvm-0.6.0 ships
# krun-sys 1.10.1 and calls krun_set_passt_fd / krun_set_root /
# krun_set_log_level. libkrun master has REMOVED those symbols, so building both
# from master fails. We pin libkrun to v1.10.1 (still exports them) and muvm to
# tag muvm-0.6.0. Bump both together if you upgrade.
set -euo pipefail

SRC_DIR="${SRC_DIR:-${HOME}/src/graphics-benchmark}"
PREFIX="${PREFIX:-/usr/local}"
LIBKRUN_REF="${LIBKRUN_REF:-v1.10.1}"
MUVM_REF="${MUVM_REF:-muvm-0.6.0}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "ERROR: run this as your normal user, NOT root/sudo." >&2
  exit 1
fi

echo "==> Checking kernel version (muvm needs >= 6.13)"
KREL="$(uname -r)"
KMAJ="${KREL%%.*}"; KMIN="$(echo "${KREL}" | cut -d. -f2)"
if (( KMAJ < 6 || (KMAJ == 6 && KMIN < 13) )); then
  echo "WARNING: running kernel ${KREL}; muvm drm native context needs >= 6.13." >&2
  echo "         Install an HWE / mainline kernel and reboot before benchmarking." >&2
fi

echo "==> Installing build dependencies"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  build-essential pkg-config git curl \
  clang libclang-dev llvm-dev \
  flex bison patchelf \
  libelf-dev libpixman-1-dev passt \
  libudev-dev libdrm-dev libepoxy-dev \
  python3 python3-pip

# libkrun's Rust deps (clang-sys / bindgen) need libclang at build time.
if [[ -z "${LIBCLANG_PATH:-}" ]]; then
  LC="$(find /usr/lib -name 'libclang.so*' 2>/dev/null | head -n1)"
  if [[ -n "${LC}" ]]; then
    export LIBCLANG_PATH="$(dirname "${LC}")"
    echo "==> LIBCLANG_PATH=${LIBCLANG_PATH}"
  fi
fi

if command -v cargo >/dev/null 2>&1 || [[ -x "${HOME}/.cargo/bin/cargo" ]]; then
  echo "==> Rust toolchain already present, skipping rustup"
else
  echo "==> Installing Rust toolchain via rustup"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
export PATH="${HOME}/.cargo/bin:${PATH}"

echo "==> Building libkrun (containers/libkrun)"
mkdir -p "${SRC_DIR}"
if [[ ! -d "${SRC_DIR}/libkrun/.git" ]]; then
  git clone https://github.com/containers/libkrun.git "${SRC_DIR}/libkrun"
fi
cd "${SRC_DIR}/libkrun"
git fetch --tags
git checkout "${LIBKRUN_REF}"
make clean 2>/dev/null || true
make
sudo make install PREFIX="${PREFIX}"
sudo ldconfig

echo "==> Building muvm (AsahiLinux/muvm)"
if [[ ! -d "${SRC_DIR}/muvm/.git" ]]; then
  git clone https://github.com/AsahiLinux/muvm.git "${SRC_DIR}/muvm"
fi
cd "${SRC_DIR}/muvm"
git fetch --tags
git checkout "${MUVM_REF}"
# muvm's krun-sys crate finds libkrun via pkg-config; libkrun installed under
# ${PREFIX} is not on the default pkg-config search path, so add it.
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/lib64/pkgconfig:${PREFIX}/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
cargo build --release
sudo install -m 0755 target/release/muvm "${PREFIX}/bin/muvm"

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
