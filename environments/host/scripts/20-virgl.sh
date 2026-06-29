#!/usr/bin/env bash
#
# 20-virgl.sh — virtio-gpu + VirGL (OpenGL) host runtime (Ubuntu 24.04).
#
# VirGL is the OpenGL path over virtio-gpu. Stock virglrenderer 1.0.0 already
# supports it, so this is apt-only. Run after 00-base-kvm.sh and 05-qemu-10.2.sh.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

echo "==> Installing VirGL / OpenGL runtime"
apt-get update -y
apt-get install -y --no-install-recommends \
  libvirglrenderer1 \
  qemu-system-modules-opengl \
  libgl1-mesa-dri \
  libglx-mesa0 \
  libegl-mesa0

cat <<'EOF'

Done. VirGL (OpenGL over virtio-gpu) host runtime is installed.

Example guest launch fragment (Linux guest, headless EGL):

    qemu-system-x86_64 \
      -device virtio-gpu-gl \
      -display egl-headless,gl=on \
      ... (cpu/mem/disk/net) ...

Guest needs Mesa with virtio-gpu (virgl) support; OpenGL apps then run through
virglrenderer -> radeonsi on the host. (Vulkan is NOT available on this path.)
EOF
