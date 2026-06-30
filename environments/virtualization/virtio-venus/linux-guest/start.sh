#!/usr/bin/env bash
#
# start.sh — venus-linux: boot the Linux guest with virtio-gpu + Venus.
#
# GPU path: guest Vulkan -> virtio-gpu (Venus) -> host venus decoder (in
# virglrenderer) -> RADV -> amdgpu. This is the Vulkan virtualized path; DirectX
# workloads run on top via DXVK/VKD3D -> Vulkan -> Venus. See design §1/§2.1.
#
# Requires QEMU linked against the venus-enabled virglrenderer (build order:
# host/scripts 00 -> 30-venus.sh -> 05-qemu-10.2.sh) and a guest Mesa with the
# venus Vulkan ICD (installed by the guest cloud-init).
#
# Usage: ./start.sh            # headless (egl-headless, GPU-accelerated)
#        ./start.sh --gui      # GTK window, for bring-up
set -euo pipefail

SSH_HOSTFWD_PORT="${SSH_HOSTFWD_PORT:-2224}"
GUEST="linux"
VM_RUN_NAME="graphics-benchmark-venus-linux"
# Venus is the Vulkan path — verify with vulkaninfo (expect a Venus/RADV device).
GPU_PROBE_HINT='vulkaninfo --summary | grep deviceName   (expect "Virtio-GPU Venus (... RADV ...)", not llvmpipe)'

source "$(cd "$(dirname "$0")/../../lib" && pwd)/common.sh"
parse_common_args "$@"
check_qemu_guest
warn_if_no_virgl

if ! "$QEMU" -device virtio-gpu-gl,help 2>&1 | grep -qi 'venus'; then
  log_warn "This QEMU's virtio-gpu-gl does not expose a 'venus' property."
  log_warn "It was likely linked against the apt virglrenderer (no venus)."
  log_warn "Rebuild: host/scripts 30-venus.sh THEN 05-qemu-10.2.sh."
fi

# Venus needs blob resources backed by a shared host memory region. hostmem
# sizes the GPU's blob window; the shared memfd backend lives in base_qemu_args.
GPU_ARGS=(
  -device "virtio-gpu-gl,blob=true,venus=true,hostmem=${MEMORY}M"
)

run_qemu "venus-linux (virtio-gpu + Venus, Vulkan; DX via DXVK)" -- "${GPU_ARGS[@]}"
