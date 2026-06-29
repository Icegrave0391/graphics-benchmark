# graphics-benchmark

A reproducible benchmark suite for measuring the performance cost of **graphics
APIs** (DirectX, Vulkan, OpenGL) across different **GPU virtualization schemes**
on AMD hardware.

## Background

Running GPU workloads inside a virtual machine is increasingly common — cloud
gaming, CI for graphics drivers, sandboxed desktops, and ML/visualization
backends all rely on some form of GPU virtualization. But "GPU virtualization"
is not one thing. A guest can reach the physical GPU through very different
paths, each with its own performance trade-offs:

- **VFIO passthrough** hands an entire card to one guest (near-native, but not
  shareable).
- **virtio-gpu** paravirtualizes the GPU and multiplexes it, but the guest's
  API calls must be transported across the VM boundary and re-executed on the
  host. The cost of that transport depends on which protocol runs on top of
  virtio-gpu — **VirGL** (OpenGL), **Venus** (Vulkan), or a **drm native
  context** (raw driver UAPI, used by muvm).
- **muvm / libkrun** uses a drm native context to minimize that transport
  overhead.

On top of the transport, the *graphics API* itself matters: OpenGL, Vulkan, and
DirectX have very different driver and command-submission characteristics, and
DirectX on Linux is itself a translation layer (DXVK/VKD3D → Vulkan).

These two axes interact, and there is little apples-to-apples public data on how
they combine — especially on AMD, where the open Mesa stack (RADV / radeonsi)
makes every one of these paths a first-class, license-free option.

## Goal

Produce a clean, reproducible comparison that answers:

- How much performance does each **virtualization scheme** cost relative to bare
  metal? (passthrough vs. VirGL vs. Venus vs. muvm)
- How does that cost differ by **graphics API**? (OpenGL vs. Vulkan vs. DirectX)
- Where does the overhead actually come from — **raw GPU throughput** or the
  **command-submission / transport path**?

To separate those last two, workloads are organized into layers (see
[Workloads](#workloads)): a GPU-bound layer, a real-world draw-call-heavy layer,
and a transport microbenchmark layer.

## Scope

- **Host:** always Linux.
- **GPU:** always AMD (amdgpu / RADV / radeonsi).
- **Guests:** Linux and Windows.
- **APIs:** OpenGL, Vulkan, DirectX (via DXVK/VKD3D under virtualization).

## How the GPU is reached

`virtio-gpu` is only a transport. What it can render depends on the **context
type** layered on top of it:

| Context              | OpenGL | Vulkan | DirectX (via DXVK) | Overhead |
|----------------------|:------:|:------:|:------------------:|----------|
| VirGL                | ✅     | ❌     | ❌                 | high     |
| Venus                | ❌     | ✅     | ✅                 | low      |
| drm native context   | ✅     | ✅     | ✅                 | lowest   |

To keep every measurement attributable to a single transport, each API takes
exactly one path under virtualization (no cross-translation):

| API     | Virtualized path              |
|---------|-------------------------------|
| OpenGL  | virtio-gpu + **VirGL**        |
| Vulkan  | virtio-gpu + **Venus**        |
| DirectX | **DXVK** → Vulkan → **Venus** |

## Environment matrix

Environments are grouped into **Native** (bare metal) and **Virtualization**
(host is always Linux). Each has a self-describing short ID used as its
directory name and in result `run_id`s.

### Native
| ID               | Guest   | GPU path                        |
|------------------|---------|---------------------------------|
| `native-windows` | Windows | native amdgpu (Windows driver)  |
| `native-linux`   | Linux   | native amdgpu + Mesa (baseline) |

### Virtualization
| Scheme                          | ID              | Guest   | GPU path                      |
|---------------------------------|-----------------|---------|-------------------------------|
| Passthrough (VFIO)              | `pt-linux`      | Linux   | full-card passthrough         |
|                                 | `pt-windows`    | Windows | full-card passthrough         |
| VirtIO-GPU + VirGL              | `virgl-linux`   | Linux   | virtio-gpu + VirGL (GL only)  |
| VirtIO-GPU + Venus              | `venus-linux`   | Linux   | virtio-gpu + Venus (Vulkan)   |
|                                 | `venus-windows` | Windows | virtio-gpu + Venus (experimental) |
| muvm (libkrun + drm native ctx) | `muvm-linux`    | Linux   | drm native context (lowest)   |

## Workloads

Workloads are layered so that GPU throughput and transport overhead can be
measured separately:

| Layer | Bound        | Purpose                                   | Tools                              |
|-------|--------------|-------------------------------------------|------------------------------------|
| L1    | GPU          | Cross-API standard scene, raw GPU power   | GravityMark                        |
| L2    | CPU + GPU    | Real-world load (tens of thousands of draw calls/frame) | Basemark GPU, vkmark, glmark2 |
| L3    | Transport    | Isolate VM command-submission overhead    | vkoverhead (Vk), drawoverhead (GL) |

Frame metrics are normalized through a single capture layer per OS
(**MangoHud** on Linux, **PresentMon** on Windows) so FPS/frametime numbers are
comparable regardless of which benchmark produced them.

## Repository layout

```
graphics-benchmark/
├── docs/
│   └── benchmark-design.md      # full design: matrix, metrics, methodology, schema
├── environments/                # one directory per matrix row (setup, not benchmarks)
│   ├── native/{windows,linux}/
│   └── virtualization/{passthrough,virtio-virgl,virtio-venus,muvm}/
├── workloads/                   # benchmark tools, grouped by layer
│   ├── l1-gpu-bound/            # GravityMark
│   ├── l2-real-world/          # Basemark GPU, vkmark, glmark2
│   ├── l3-transport/           # vkoverhead, drawoverhead
│   ├── compute/                # vkpeak
│   └── capture/                # MangoHud, PresentMon
├── harness/                    # CLI to schedule runs, wrap capture, emit results
├── config/                     # matrix / run configuration
└── results/                    # exported per-run JSON + raw captures
```

## Status

Early scaffolding. The design is documented; setup scripts and the run harness
are not yet implemented.

- [x] Benchmark design and methodology — [`docs/benchmark-design.md`](docs/benchmark-design.md)
- [x] Repository structure
- [ ] Environment setup scripts (native + virtualization)
- [ ] Workload integration and CLI harness
- [ ] Result schema implementation and aggregation

## Documentation

See [`docs/benchmark-design.md`](docs/benchmark-design.md) for the full matrix,
metric definitions, the unified result schema, known risks, and the planned
execution order.
