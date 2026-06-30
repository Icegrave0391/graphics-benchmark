# Environments

Each subdirectory corresponds to a row in the benchmark matrix (see
[`docs/benchmark-design.md`](../docs/benchmark-design.md) §2). An environment
defines **how the GPU is exposed to the workload** — bare metal, VFIO
passthrough, or a virtio-gpu transport.

The host is always **Linux**. The GPU is always **AMD**
(amdgpu / RADV / radeonsi).

## Matrix

Environments are grouped into **Native** (bare metal) and **Virtualization**
(host is always Linux). Each has a self-describing short ID used as the
directory name and in `run_id`s.

### Native

| ID               | Directory          | Guest   | GPU path                       |
|------------------|--------------------|---------|--------------------------------|
| `native-windows` | `native/windows/`  | Windows | native amdgpu (Windows driver) |
| `native-linux`   | `native/linux/`    | Linux   | native amdgpu + Mesa (baseline)|

### Virtualization

| Scheme                    | ID              | Directory                                   | Guest   | GPU path                       |
|---------------------------|-----------------|---------------------------------------------|---------|--------------------------------|
| Passthrough (VFIO)        | `pt-linux`      | `virtualization/passthrough/linux-guest/`   | Linux   | full-card passthrough          |
|                           | `pt-windows`    | `virtualization/passthrough/windows-guest/` | Windows | full-card passthrough          |
| VirtIO-GPU + VirGL        | `virgl-linux`   | `virtualization/virtio-virgl/linux-guest/`  | Linux   | virtio-gpu + VirGL (GL only)   |
| VirtIO-GPU + Venus        | `venus-linux`   | `virtualization/virtio-venus/linux-guest/`  | Linux   | virtio-gpu + Venus (Vulkan)    |
| muvm (libkrun + drm native ctx) | `muvm-linux` | `virtualization/muvm/linux-guest/`       | Linux   | libkrun + drm native context   |

> No `venus-windows`: on a Linux host, virtio-gpu has no usable 3D driver for
> Windows guests (`viogpudo` is display-only → DX/GL/Vulkan fall back to software,
> host GPU unused). Windows virtualized graphics is measured via `pt-windows`
> (passthrough) only. The virtio paths are Linux-guest only. See
> `../docs/benchmark-design.md` §6.

## API routing (fixed)

To keep every measurement attributable to a single transport, each API takes
exactly one path under virtualization (no cross-translation):

| API     | Virtualized path              |
|---------|-------------------------------|
| OpenGL  | virtio-gpu + **VirGL**        |
| Vulkan  | virtio-gpu + **Venus**        |
| DirectX | **DXVK** → Vulkan → **Venus** |

## What each environment directory should contain

> Scaffolding only — no real scripts yet.

- `SETUP.md` — host + guest provisioning steps for this configuration.
- `host/` — host-side config (libvirt XML, QEMU args, kernel cmdline, module options).
- `guest/` — guest-side config (driver install, ICD selection, env vars).
- `notes.md` — gotchas, versions pinned, known-good combinations.
