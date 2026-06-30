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
# venus Vulkan ICD (installed by the guest cloud-init). On Renoir/Cezanne we
# found host RADV from Ubuntu 24.04's stock Mesa can crash in the venus decoder
# thread (vkr-ring-* segfault in libvulkan_radeon.so). Use a fixed RADV (known
# good: Mesa 26.1.3 from kisak-mesa). This script defaults to RADV and disables
# AMDVLK's implicit switchable-graphics layer so installing AMDVLK for A/B tests
# cannot silently steal the Venus backend.
#
# Usage: ./start.sh                          # RADV host decoder (default)
#        ./start.sh --gui                    # RADV + GTK window, for bring-up
#        HOST_VK_ICD=amdvlk ./start.sh --gui # AMDVLK workaround/A-B check
#        HOST_VK_ICD=auto ./start.sh --gui   # system Vulkan default (debug only)
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

HOST_VK_ICD="${HOST_VK_ICD:-radv}"
case "$HOST_VK_ICD" in
  radv)
    export VK_ICD_FILENAMES="${RADV_ICD:-/usr/share/vulkan/icd.d/radeon_icd.json}"
    # AMDVLK installs an implicit switchable-graphics layer that can steal the
    # default ICD even when RADV is installed. Disable it when explicitly testing
    # RADV so host decoder results are attributable to RADV.
    export DISABLE_LAYER_AMD_SWITCHABLE_GRAPHICS_1=1
    log_info "==> Host Vulkan ICD: RADV (${VK_ICD_FILENAMES})"
    ;;
  amdvlk)
    export VK_ICD_FILENAMES="${AMDVLK_ICD:-/etc/vulkan/icd.d/amd_icd64.json}"
    log_info "==> Host Vulkan ICD: AMDVLK (${VK_ICD_FILENAMES})"
    ;;
  auto)
    log_warn "HOST_VK_ICD=auto: using the system Vulkan default."
    log_warn "If AMDVLK is installed, its implicit layer may override RADV."
    ;;
  *)
    log_err "HOST_VK_ICD must be 'radv', 'amdvlk', or 'auto' (got: ${HOST_VK_ICD})"
    exit 1
    ;;
esac

if ! "$QEMU" -device virtio-vga-gl,help 2>&1 | grep -qi 'venus'; then
  log_warn "This QEMU's virtio-vga-gl does not expose a 'venus' property."
  log_warn "It was likely linked against the apt virglrenderer (no venus)."
  log_warn "Rebuild: host/scripts 30-venus.sh THEN 05-qemu-10.2.sh."
fi

# Venus needs blob resources backed by a shared host memory region. hostmem
# sizes the GPU's blob window; the shared memfd backend lives in base_qemu_args.
#
# We use virtio-VGA-gl (not virtio-gpu-gl) so the device doubles as the
# VGA-compatible primary display from firmware time. Otherwise OVMF brings up an
# EFI framebuffer that the guest exposes as simpledrm (card0), Xorg picks that as
# primary, and onscreen Vulkan (swapchain) goes through the software path / fails
# — even though Venus works on the render node. virtio-vga-gl is the boot display
# from the start, so the desktop's WSI binds the accelerated virtio-gpu. No guest
# cmdline changes are needed.
GPU_ARGS=(
  -device "virtio-vga-gl,blob=true,venus=true,hostmem=${MEMORY}M"
)

run_qemu "venus-linux (virtio-gpu + Venus, Vulkan; DX via DXVK)" -- "${GPU_ARGS[@]}"
