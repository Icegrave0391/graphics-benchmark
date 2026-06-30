# Workloads

The benchmark **tools**, grouped by layer (design [§4](../docs/benchmark-design.md#4-workload-选型三层结构)).
These are the things that render/measure; the *environments* that host them live
under [`../environments/`](../environments/).

Scope of the install scripts: **`native-linux` and `guest-linux`** (both Ubuntu
24.04 on AMD/Mesa). The two targets are the same OS, so **one set of scripts
installs identically on both** — run them on the bare-metal host, or push the
repo into the guest VM and run them there (or via
`environments/guest/linux/ssh-vm.sh -- <cmd>`).

This repo does **not** support a Windows guest on the Linux host. DirectX is
still covered, but on the **Linux** guest only — by running Windows benchmark
`.exe`/`.msi` files through **Proton** (DXVK/VKD3D → Vulkan), see
[DirectX via Proton](#directx-via-proton). The L3/compute layers are not wired
up yet.

## What installs here, and how

Where possible we use **precompiled binaries** (apt or vendor `.deb`/`.run`) —
no source builds.

| Layer | Tool | API(s) | Source | Automatable? |
|---|---|---|---|---|
| **L1** | GravityMark | Vulkan / OpenGL | vendor `.run` (precompiled, extracted) | ✅ full CLI |
| **L2** | vkmark + glmark2 | Vulkan / OpenGL | **apt** (precompiled) | ✅ headless |
| **L2** | Basemark GPU | Vulkan / OpenGL | vendor `.tar.gz` (precompiled, extracted) | ✅ CLI via `run-basemark.sh` |
| **DX** | GravityMark (Windows) | DirectX 11/12 | vendor `.msi` (precompiled, unpacked) → Proton | ✅ full CLI |
| **DX** | Basemark GPU (Windows) | DirectX 12 | vendor `.exe` installer → Proton | ⚠️ GUI only |

Per design [§2.1](../docs/benchmark-design.md#21-api--渲染路径的固定路由规则) routing,
each API stays on one path (no cross-translation): **OpenGL→VirGL**,
**Vulkan→Venus**, **DirectX→DXVK/VKD3D→Venus**. So Vulkan tools (vkmark,
GravityMark `-vulkan`) exercise the Venus path; GL tools (glmark2, GravityMark
`-opengl`) exercise the VirGL path; and **DirectX has no native Linux backend**
— DX workloads are Windows builds run through **Proton** (DXVK for D3D11,
VKD3D-Proton for D3D12) which translate to Vulkan, then onward to RADV / venus /
native ctx. See [the DX section](#directx-via-proton) below.

## Layout

```
workloads/
├── lib/common.sh                 # shared install helpers (logging, download, makeself)
├── l1-gpu-bound/
│   └── install-gravitymark.sh    # L1: GravityMark (GPU-bound)
├── l2-real-world/
│   ├── install-vkmark-glmark2.sh # L2: open-source, scriptable (recommended)
│   ├── install-basemark-gpu.sh   # L2: Basemark GPU (precompiled .tar.gz)
│   └── run-basemark.sh           #     CLI runner (bypasses the GUI launcher)
├── dx/                           # DirectX via Proton (DXVK/VKD3D -> Vulkan)
│   ├── install-dx-runtime.sh     #   umu-launcher + Proton runtime
│   ├── run-dx.sh                 #   wrapper: run a Windows .exe through Proton
│   ├── install-gravitymark-dx.sh #   Windows GravityMark (D3D11/D3D12)
│   └── install-basemark-dx.sh    #   Windows Basemark GPU (D3D12)
├── l3-transport/                 # later: vkoverhead, drawoverhead
├── compute/                      # later: vkpeak
├── capture/                      # MangoHud (frame capture) — guest already has it
└── .cache/                       # downloaded installers (git-ignored)
```

## Install

Run as your normal user (the scripts `sudo` only for apt/dpkg; they refuse to
run as root so extracted trees stay user-owned).

```sh
# L1 — GravityMark (downloads + extracts the vendor .run, ~184 MB)
workloads/l1-gpu-bound/install-gravitymark.sh

# L2 — open-source, fully scriptable (recommended path)
workloads/l2-real-world/install-vkmark-glmark2.sh

# L2 — Basemark GPU (downloads + extracts the vendor tarball, ~1.16 GB)
workloads/l2-real-world/install-basemark-gpu.sh
```

Each script `sudo apt-get`s a few runtime libs first (Vulkan/GL/X loaders) and
will prompt for your sudo password. If those deps are already present and you
just want the download/extract step (e.g. while iterating), skip apt with:

```sh
WL_SKIP_APT=1 workloads/l1-gpu-bound/install-gravitymark.sh
```

In the guest, the same commands work after copying the repo in, e.g.:

```sh
# from environments/guest/linux/, push and install:
rsync -e './ssh-vm.sh --' -a ../../../ user@guest:graphics-benchmark/   # or scp/git clone
./ssh-vm.sh -- 'graphics-benchmark/workloads/l1-gpu-bound/install-gravitymark.sh'
```

## Tool notes

### GravityMark (L1)

- Tellusim ships Linux as a Makeself `.run`. The script extracts it with
  `--noexec --target` to skip the interactive license/browser flow and get a
  plain CLI-usable tree under `l1-gpu-bound/GravityMark/` (git-ignored).
- GPU-bound (CPU nearly idle): measures raw GPU throughput, **not** transport
  overhead. Transport attribution comes from L3 later (design §3.2).
- Example: `run_windowed_vk.sh -asteroids 200000 -benchmark 1 -close 1` (uses
  `-vulkan`/`-opengl`, not `-api`).

### vkmark + glmark2 (L2, recommended)

- Both precompiled in Ubuntu 24.04 `universe`. Ubuntu split glmark2 by window
  system: we install `glmark2-x11` (desktop GL on the guest's GNOME/Xorg) and
  `glmark2-drm` (KMS/DRM, no X/Wayland needed → true headless).
- `vkmark --winsys headless`, `DISPLAY=:0 glmark2 --off-screen`,
  `glmark2-drm --off-screen`.

### Basemark GPU (L2, headline)

The Electron `basemarkgpu` app is a GUI launcher, but the real benchmark is the
native CLI binary it wraps (`resources/binaries/BasemarkGPU_{vk,gl}`). We drive
that directly with **`run-basemark.sh`** so runs are scriptable — no clicking:

```sh
# Vulkan (Venus path), medium quality, 1080p, result JSON under captures/:
l2-real-world/run-basemark.sh --api vulkan --quality medium --res 1920x1080

# OpenGL (VirGL path):
l2-real-world/run-basemark.sh --api gl --quality medium --res 1920x1080

# With MangoHud capture; or headless host via a virtual X server:
l2-real-world/run-basemark.sh --api vulkan --mangohud
USE_XVFB=1 l2-real-world/run-basemark.sh --api vulkan
```

It is an **onscreen** renderer (no offscreen mode): run it in a desktop session
(native), with `DISPLAY=:0` (guest GNOME/Xorg), or `USE_XVFB=1` (virtual X).
Result JSON fields: `result.score`, `result.averageFPS/minFPS/maxFPS`,
`software.api`.

Install caveats / gotchas (design §4/§6), handled by the install script:

1. **GUI launcher** for interactive use; `run-basemark.sh` bypasses it for CLI.
2. **Electron SUID sandbox** — `chrome-sandbox` is set root:root 4755 on install
   (or launch the GUI with `--no-sandbox`).
3. **Legacy `libssl1.1`** — the 2020 render binaries link OpenSSL 1.1, missing on
   Ubuntu 24.04; the installer pulls it from the 20.04 security pocket. (Without
   it the GUI misreports "Benchmark asset file not found".)
4. **AMD+RADV crashes at High/4K** — `run-basemark.sh` defaults to medium @ 1080p.
5. **Power Board upload** — the free GUI forces it; the CLI defaults
   `ResultUpload false` (set `BMK_UPLOAD=1` to match the GUI). Online needed
   either way for the GUI; the guest must have network.
6. **Non-commercial license** — don't publish results on ad-supported sites.

## DirectX via Proton

There is **no native DirectX on Linux** (it's a Windows API). Per design §2.1,
DX is measured by running a **Windows** build of the benchmark through
**Proton**, which bundles Wine + **DXVK** (D3D9/10/11 → Vulkan) +
**VKD3D-Proton** (D3D12 → Vulkan). The translated Vulkan then runs on RADV
(native), venus (venus-linux), or the drm native context (muvm) — one clean
transport, no cross-translation.

We drive Proton with **umu-launcher** (`umu-run`), Valve's Steam Linux Runtime
packaged to run a `.exe` through Proton **without Steam**. It auto-downloads
Proton (UMU-Proton = official Proton) and the runtime on first use.

```sh
# 1. install the DX runtime (umu-launcher debs + prime the Proton download)
workloads/dx/install-dx-runtime.sh

# 2a. GravityMark DX (fully scriptable): unpacks the Windows .msi
workloads/dx/install-gravitymark-dx.sh
workloads/dx/run-dx.sh workloads/dx/GravityMark-win/.../GravityMark.exe \
    -d3d11 -asteroids 200000 -benchmark 1 -close 1          # D3D11 -> DXVK
workloads/dx/run-dx.sh .../GravityMark.exe -d3d12 ...        # D3D12 -> VKD3D-Proton

# 2b. Basemark GPU DX (GUI): installs the Windows installer into the prefix
workloads/dx/install-basemark-dx.sh
workloads/dx/run-dx.sh "<prefix>/drive_c/.../BasemarkGPU.exe"
```

Notes:
- `run-dx.sh --mangohud <exe>` wraps the run in MangoHud so DX frametimes use
  the same capture layer as GL/Vulkan (design §3).
- The DX runtime records the resolved Proton / DXVK / VKD3D versions into
  `workloads/dx/versions.txt` for the result schema (`dxvk_version` /
  `vkd3d_version`, design §3.1).
- First run needs network (Proton/runtime download); the guest's QEMU user-net
  provides it.

## Frame capture

All L1/L2/DX render workloads are normalized through **MangoHud** on Linux for a
single, comparable frametime source (design §3 methodology) instead of each
tool's self-reported FPS. MangoHud is already installed in the guest via
cloud-init; on a native host: `sudo apt-get install -y mangohud`. For DX runs,
use `workloads/dx/run-dx.sh --mangohud <exe>` (MangoHud is forwarded into the
Proton/Steam-Runtime container).
