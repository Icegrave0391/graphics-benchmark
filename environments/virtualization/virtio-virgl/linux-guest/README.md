# virgl-linux

virtio-gpu + **VirGL**: guest OpenGL → host virglrenderer → radeonsi → amdgpu.
OpenGL-only path (no Vulkan — that's venus-linux).

```sh
./start.sh            # headless (egl-headless)
./start.sh --gui      # GTK window
```

SSH port `2223`. Verify inside the guest that GL hits the real GPU:

```sh
eglinfo -B | grep -i renderer      # expect AMD / virgl, not llvmpipe
DISPLAY=:0 /home/user/graphics-benchmark/workloads/basemark-gpu/run.sh --api gl
```

Needs QEMU with virglrenderer (`host/scripts/05-qemu-10.2.sh`) and a guest Mesa
with virtio-gpu (virgl) support (installed by the guest cloud-init). See
`../../README.md` and `docs/benchmark-design.md` §2.1.
