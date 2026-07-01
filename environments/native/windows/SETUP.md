# 1.1 — Native Windows (bare metal)

Baseline for native DirectX (D3D11/D3D12), Vulkan, and OpenGL on AMD with the
official Windows driver. No virtualization.

## TODO (scaffolding)

- [ ] `SETUP.md` — Windows install, AMD driver version, capture tooling (PresentMon).
- [ ] Document fixed clocks / power settings for repeatability.
- [ ] List workloads run here: Basemark GPU (Vk/D3D12/D3D11/GL where available).

Reference baseline for `pt-windows` (passthrough Windows). There is no
`venus-windows` (virtio-gpu has no 3D driver for Windows guests — see
`../../../docs/benchmark-design.md` §6).
