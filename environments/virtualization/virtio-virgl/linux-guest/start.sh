#!/usr/bin/env bash
#
# start.sh — virgl-linux: boot the Linux guest with virtio-gpu + VirGL.
#
# GPU path: guest OpenGL -> virtio-gpu -> host virglrenderer (VirGL) -> radeonsi
# -> amdgpu. This is the OpenGL-only virtualized path (no Vulkan here; that's
# venus-linux). See docs/benchmark-design.md §1/§2.1.
#
# Requires QEMU built with virglrenderer (host/scripts/05-qemu-10.2.sh) and a
# guest Mesa with virtio-gpu (virgl) support (installed by the guest cloud-init).
#
# Usage: ./start.sh            # headless (egl-headless, GPU-accelerated)
#        ./start.sh --gui      # GTK window, for bring-up
set -euo pipefail

# Own SSH port so this scheme can run alongside others.
GUEST="linux"
SSH_HOSTFWD_PORT="${SSH_HOSTFWD_PORT:-2223}"
VM_RUN_NAME="graphics-benchmark-virgl-linux"
# VirGL is OpenGL-only — verify with a GL probe, NOT vulkaninfo (Vulkan has no
# hardware path here and will show llvmpipe, which is expected).
GPU_PROBE_HINT='eglinfo -B 2>/dev/null | grep -i renderer   (expect virgl/AMD, not llvmpipe; glmark2 --off-screen to benchmark)'

source "$(cd "$(dirname "$0")/../../lib" && pwd)/common.sh"
parse_common_args "$@"
check_qemu_guest
warn_if_no_virgl

# VirGL: virtio-gpu-gl WITHOUT venus. blob=true enables blob resources (shared
# memory) which VirGL also benefits from; the memfd backend is in base_qemu_args.
GPU_ARGS=(
  -device "virtio-gpu-gl,blob=true"
)

run_qemu "virgl-linux (virtio-gpu + VirGL, OpenGL)" -- "${GPU_ARGS[@]}"
