# Virtualization environments

Launchers that boot a **guest image** through a specific **GPU path**. These two
dimensions are kept separate so the matrix stays comparable:

- **guest (OS)** — the image + its config/remote tooling, built under
  `environments/guest/<os>/` (`linux/` and `windows/`).
- **scheme (GPU path)** — VirGL / Venus / passthrough / muvm, one directory each.

Every scheme boots the **same per-OS image**; only the GPU device differs. That
isolation is what lets us attribute performance differences to the transport
(design §2.1/§2.2).

```
virtualization/
├── lib/common.sh                 # shared QEMU launcher (sources guest/<os>/.env via GUEST=)
├── virtio-virgl/linux-guest/     # virtio-gpu + VirGL  (OpenGL)        — Linux only
├── virtio-venus/linux-guest/     # virtio-gpu + Venus  (Vulkan, DX via DXVK) — Linux only
├── passthrough/{linux,windows}-guest/    # VFIO full-card passthrough
└── muvm/linux-guest/             # libkrun + drm native context (Linux only)
```

> **The virtio paths (VirGL/Venus) are Linux-guest only.** On a Linux host,
> virtio-gpu has no usable 3D driver for Windows guests (`viogpudo` is
> display-only → DX/GL/Vulkan fall back to software, the host GPU is never used),
> so there is no `virtio-*/windows-guest`. Windows virtualized graphics is done
> only via **passthrough** (`pt-windows`). See `../../docs/benchmark-design.md` §6
> and `../guest/windows/README.md`.

## How a scheme launcher works

A `start.sh` sets `GUEST=linux|windows`, a per-scheme `SSH_HOSTFWD_PORT` and
`VM_RUN_NAME`, then sources `lib/common.sh`, defines a `GPU_ARGS` array (the
virtio-gpu/passthrough device) and calls `run_qemu`. `common.sh` pulls the disk,
firmware, credentials and runtime QEMU from `environments/guest/$GUEST/.env`.
(`GUEST` is parameterized so the passthrough launcher works for both Linux and
Windows guests.)

Ports are distinct so schemes can run concurrently: virgl `2223`, venus `2224`
(base guest uses `2222`). Override with `SSH_HOSTFWD_PORT=... ./start.sh`.

## Status

| Scheme | linux-guest | windows-guest |
|---|---|---|
| VirGL  | ✅ `start.sh` | n/a (virtio-gpu has no Windows 3D) |
| Venus  | ✅ `start.sh` (verified: Venus → RADV RENOIR) | n/a (virtio-gpu has no Windows 3D) |
| muvm   | ✅ `start.sh` | n/a (Linux UAPI only) |
| Passthrough | scaffold | scaffold |

Prerequisites for the QEMU-based schemes: QEMU 10.2 + venus virglrenderer from
`environments/host/scripts/` (order `00 → 30-venus → 05`), and a built guest
(`environments/guest/linux/create-vmdisk.sh`).
