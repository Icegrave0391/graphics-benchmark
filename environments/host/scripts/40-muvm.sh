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
. "$(dirname "$0")/lib/common.sh"

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

echo "==> Ensuring build dependencies"
apt_need \
  build-essential pkg-config git curl \
  clang libclang-dev llvm-dev \
  flex bison patchelf \
  libelf-dev libpixman-1-dev passt \
  libudev-dev libdrm-dev libepoxy-dev \
  python3 python3-pip

# libkrun's Rust deps (clang-sys / bindgen) need libclang at build time.
if [[ -z "${LIBCLANG_PATH:-}" ]] && have_lib 'libclang.so*'; then
  LIBCLANG_PATH="$(dirname "$(find /usr/lib -name 'libclang.so*' 2>/dev/null | head -n1)")"
  export LIBCLANG_PATH
  echo "==> LIBCLANG_PATH=${LIBCLANG_PATH}"
fi

if user_has_cargo; then
  echo "==> Rust toolchain already present for $(target_user), skipping rustup"
else
  echo "==> Installing Rust toolchain via rustup for $(target_user)"
  sudo -u "$(target_user)" sh -c \
    'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
fi
CARGO_RUN="$(cargo_env_for)"

echo "==> Building libkrun (containers/libkrun)"
mkdir -p "${SRC_DIR}"
git_sync https://github.com/containers/libkrun.git "${SRC_DIR}/libkrun"
cd "${SRC_DIR}/libkrun"
make PREFIX="${PREFIX}"
make install PREFIX="${PREFIX}"
ldconfig

echo "==> Building muvm (AsahiLinux/muvm)"
git_sync https://github.com/AsahiLinux/muvm.git "${SRC_DIR}/muvm"
cd "${SRC_DIR}/muvm"
${CARGO_RUN} cargo build --release
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
