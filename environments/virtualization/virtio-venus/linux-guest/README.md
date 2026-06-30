# venus-linux

virtio-gpu + **Venus**: guest Vulkan → host venus decoder → RADV → amdgpu.
Vulkan path; DirectX runs on top via DXVK/VKD3D → Vulkan → Venus.

```sh
./start.sh            # headless (egl-headless)
./start.sh --gui      # GTK window
```

SSH port `2224`. Verify inside the guest that Vulkan hits the real GPU:

```sh
vulkaninfo --summary | grep deviceName
# expect: Virtio-GPU Venus (AMD Radeon Graphics (RADV RENOIR))   <-- verified
# (additional llvmpipe entries are software fallbacks, expected)
```

Build order matters: `host/scripts` `00 → 30-venus.sh → 05-qemu-10.2.sh` so QEMU
links the venus-enabled virglrenderer (building QEMU first links the apt 1.0.0
with no venus). The guest needs the venus Vulkan ICD (installed by the guest
cloud-init). See `../../README.md` and `docs/benchmark-design.md` §2.1.
