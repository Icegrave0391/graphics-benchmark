# Workloads

This directory contains the benchmark tools used by the project. Workloads are
no longer grouped into L1/L2/L3 layers. The active set is intentionally small:

- **Basemark GPU** — primary benchmark workload.
- **GravityMark** — retained as a standalone smoke/diagnostic workload for
  Vulkan/OpenGL bring-up.

Both install scripts use precompiled upstream binaries; no workload is built from
source. The same scripts run on `native-linux` and the Linux guest.

## Layout

```
workloads/
├── lib/common.sh            # shared install/download/extract helpers
├── basemark-gpu/
│   ├── install.sh           # downloads/extracts Basemark GPU Linux tarball
│   └── run.sh               # CLI runner for BasemarkGPU_vk / BasemarkGPU_gl
└── gravitymark/
    └── install.sh           # downloads/extracts GravityMark Linux .run
```

Downloaded installers are cached under `workloads/.cache/` and extracted payloads
live under the respective workload directory. Both are git-ignored.

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
