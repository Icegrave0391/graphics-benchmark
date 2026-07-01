# Workloads

This directory contains the benchmark tools used by the project. Workloads are
no longer grouped into L1/L2/L3 layers. The active set is intentionally small:

- **Basemark GPU** — primary benchmark workload.
- **GravityMark** — retained as a standalone smoke/diagnostic workload for
  Vulkan/OpenGL bring-up.

Each of the two also has a **DirectX variant** that runs the vendor's *Windows*
build through **Proton** (DXVK for D3D11, VKD3D-Proton for D3D12). On
`venus-linux` this DX → Vulkan output runs on the host through Venus, so DX can
be measured on the same transport as native Vulkan. The Proton runtime is shared
between both DX variants.

Both install scripts use precompiled upstream binaries; no workload is built from
source. The same scripts run on `native-linux` and the Linux guest.

## Layout

```
workloads/
├── lib/common.sh            # shared install/download/extract helpers
├── proton/                  # shared DirectX-via-Proton runtime (umu-launcher + Proton)
│   ├── install.sh           # installs umu-launcher, primes Proton, records versions
│   └── run.sh               # runs a Windows .exe through Proton (DXVK/VKD3D)
├── basemark-gpu/
│   ├── install.sh           # Linux Basemark GPU (Vulkan/OpenGL)
│   ├── run.sh               # CLI runner for BasemarkGPU_vk / BasemarkGPU_gl
│   └── dx/                  # Windows Basemark GPU (DirectX 12) via Proton
│       ├── install.sh
│       └── run.sh
└── gravitymark/
    ├── install.sh           # Linux GravityMark (Vulkan/OpenGL)
    └── dx/                  # Windows GravityMark (D3D11/D3D12) via Proton
        ├── install.sh
        └── run.sh
```

Downloaded installers are cached under `workloads/.cache/` and extracted payloads
live under the respective workload directory. The Proton wine prefix lives under
`workloads/proton/prefix/`. All are git-ignored.

## Install

Run as a normal user, not root. The scripts use `sudo` only for system packages
or permissions that must be set system-wide.

```sh
# Primary workload
workloads/basemark-gpu/install.sh

# Standalone diagnostic workload
workloads/gravitymark/install.sh
```

For host-side provisioning into the Linux guest qcow2, use:

```sh
cd environments/guest/linux
./provision-workloads.sh
```

That script prepares the extracted payloads on the host in `WL_DOWNLOAD_ONLY=1`
mode, then copies them into the offline qcow2 with `virt-copy-in`.

## Basemark GPU

Basemark GPU is the primary benchmark. The Electron GUI launcher is available,
but `run.sh` drives the native renderer binary directly so runs can be scripted.

```sh
# Vulkan (native Vulkan / Venus path)
DISPLAY=:0 workloads/basemark-gpu/run.sh --api vulkan --quality medium --res 1280x720

# OpenGL (native GL / VirGL path)
DISPLAY=:0 workloads/basemark-gpu/run.sh --api gl --quality medium --res 1280x720
```

Important caveats:

- The Linux build is old and links OpenSSL 1.1; `install.sh` installs `libssl1.1`
  from the Ubuntu 20.04 security pocket on Ubuntu 24.04.
- The Electron GUI needs `chrome-sandbox` to be `root:root` with mode `4755`;
  `install.sh` fixes that automatically.
- Prefer Medium quality and non-4K resolutions on AMD/RADV.
- The GUI free build uploads to Basemark Power Board; `run.sh` defaults
  `ResultUpload=false` for local scripted runs.
- Basemark licensing is non-commercial; do not publish results on ad-supported
  sites.

Result JSONs are written under `workloads/basemark-gpu/captures/basemark/` by
default. Useful fields include `result.score`, `result.averageFPS`,
`result.minFPS`, `result.maxFPS`, and `software.api`.

## GravityMark

GravityMark is retained for bring-up and diagnostics, especially for confirming
that Venus can run a real Vulkan workload after host RADV/QEMU fixes.

```sh
GM=workloads/gravitymark/GravityMark
DISPLAY=:0 "$GM/run_windowed_vk.sh" -width 1280 -height 720 -asteroids 10000 -benchmark 1 -close 1
```

The OpenGL backend requires OpenGL 4.5 and is not expected to run on VirGL, which
currently exposes OpenGL 4.3 in the Linux guest.

## DirectX via Proton (venus-linux)

DirectX has no native Linux backend. To measure DX under virtualization we run
the vendor's **Windows** build through **Proton** (DXVK → Vulkan for D3D11,
VKD3D-Proton → Vulkan for D3D12). On `venus-linux` that Vulkan runs on the host
through Venus, so DX shares the Venus transport with native Vulkan.

First install the shared Proton runtime (umu-launcher + Proton). The installer
downloads the umu-launcher `.deb`s and a fixed UMU-Proton tarball into
`workloads/.cache/`, extracts UMU-Proton to `~/.local/share/umu/compatibilitytools`,
then primes the prefix. First run can still need network for Steam Runtime data,
but the large Proton download is cached by this script:

```sh
workloads/proton/install.sh
```

Then install and run each DX workload:

```sh
# GravityMark DX (fully scriptable): unpacks the Windows .msi with msitools
workloads/gravitymark/dx/install.sh
DISPLAY=:0 workloads/gravitymark/dx/run.sh --d3d11            # DXVK
DISPLAY=:0 workloads/gravitymark/dx/run.sh --d3d12            # VKD3D-Proton
DISPLAY=:0 workloads/gravitymark/dx/run.sh --d3d11 --mangohud

# Basemark GPU DX (GUI installer/launcher): installs into the Proton prefix
workloads/basemark-gpu/dx/install.sh
DISPLAY=:0 workloads/basemark-gpu/dx/run.sh                   # pick DirectX 12 in the launcher
```

Notes:

- Start the venus VM with the default RADV host ICD (see
  `environments/virtualization/virtio-venus/linux-guest/start.sh`); Venus over
  RADV was verified working after the host RADV/kisak Mesa fix.
- `workloads/proton/versions.txt` records the resolved Proton / DXVK / VKD3D
  versions for run metadata.
- `--mangohud` wraps the run in MangoHud (forwarded into the Steam Runtime
  container) for a consistent frametime source.
