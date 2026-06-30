# Guest images

Reusable guest VM images used across the benchmark matrix, one subdirectory per
guest OS. The host is always Linux; these are the *guests*.

| Dir | Guest OS | Status | Used by matrix rows |
|---|---|---|---|
| `linux/`   | Ubuntu 24.04 (GNOME desktop, onscreen) | working | `native-linux`, `pt-linux`, `virgl-linux`, `venus-linux`, `muvm-linux` |
| `windows/` | Windows 10 | working (install) | `native-windows`, `pt-windows` |

Each guest image is built once here and then attached to a specific GPU path
(passthrough / VirGL / Venus / muvm) by the launchers under
`environments/virtualization/*` and `environments/host/scripts/`.

> The Windows guest is used **only for passthrough** (`pt-windows`) and the
> bare-metal `native-windows` baseline. There is **no virtio path for Windows**:
> on a Linux host, virtio-gpu has no usable 3D driver for Windows guests
> (`viogpudo` is display-only → DX/GL/Vulkan fall back to software, the host GPU
> is never used), so a Windows virtio-gpu VM cannot produce real graphics
> numbers. The virtio paths (VirGL/Venus) are Linux-guest only. See
> `../../docs/benchmark-design.md` §6.

See each subdirectory's `README.md` for build/run instructions.
