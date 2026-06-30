# AGENTS.md

Benchmark suite comparing graphics APIs (DirectX/Vulkan/OpenGL) across GPU
virtualization schemes on **AMD** GPUs, host always **Linux (Ubuntu 24.04 LTS)**.
Currently scaffolding only: design docs + host setup scripts. No application
code, no build/test/lint/CI yet.

## Layout
- `docs/benchmark-design.md` — authoritative design (matrix, metrics, workload layers, result schema). Read this before changing matrix/metrics.
- `environments/host/scripts/` — host dependency install + source builds.
- `environments/{native,virtualization}/`, `workloads/` — mostly empty placeholders described in READMEs.

## Environment IDs (use these verbatim)
Short self-describing IDs are the convention, not numbers: `native-windows`,
`native-linux`, `pt-linux`, `pt-windows`, `virgl-linux`, `venus-linux`,
`muvm-linux`. Used as dir names and result `run_id`s.

There is **no `venus-windows`** (dropped): on a Linux host, virtio-gpu has no 3D
driver for Windows guests (`viogpudo` is display-only), so Windows virtualized
graphics is only done via `pt-windows` (passthrough). virtio paths are Linux-only.
See `docs/benchmark-design.md` §6.

## Host script rules (hard-won, easy to get wrong)
- `00-base-kvm.sh`, `05-qemu-10.2.sh`, `10/20/30` **self-elevate** (`exec sudo`). Run them as a normal user; do not prefix `sudo`.
- `40-muvm.sh` is the exception: it **must run as the normal user, not root**. It builds with the user's rustup `cargo` and `sudo`s only for install steps. Running it with sudo errors out by design.
- **Run order for Venus matters**: `00 -> 30-venus.sh -> 05-qemu-10.2.sh`. QEMU links virglrenderer at build time; `05` must come *after* `30` so QEMU links the venus-enabled `/usr/local` build (it sets `PKG_CONFIG_PATH` to prefer `/usr/local` and warns otherwise). Building QEMU first links the apt virglrenderer 1.0.0 which has **no venus**.
- muvm path: `00 -> 30 -> 40`. QEMU/`05` is NOT used by muvm (it uses libkrun).

## Toolchain facts (verified, non-obvious)
- Ubuntu 24.04 ships QEMU 8.2.2 (too old for Venus) and virglrenderer 1.0.0 (no venus). So QEMU 10.2 and virglrenderer 1.1.0 are **built from source** to `/usr/local`.
- virglrenderer meson opts: `-Dvenus=true -Ddrm-renderers=amdgpu-experimental` (note: `amdgpu-experimental`, NOT a `drm-msm-experimental` flag — that does not exist in 1.1.0).
- muvm needs kernel **>= 6.13** (24.04 default 6.8 is too old) and Mesa >= 24.2.
- **libkrun/muvm version coupling**: libkrun master has *removed* `krun_set_passt_fd`/`krun_set_root`/`krun_set_log_level` that muvm still uses. Do not build both from master. libkrun must be pinned to a tag that still exports them (v1.9.0–v1.10.0 do).
- After any accidental `sudo cargo`, `~/.cargo/registry` gets root-owned files that break later user builds — fix with `sudo chown -R "$USER:$USER" ~/.cargo`.

## API routing (do not cross-translate)
OpenGL -> VirGL, Vulkan -> Venus, DirectX -> DXVK over Venus. One API per
virtualized path, no Zink/ANGLE substitution. See design doc §2.1.

## Git
SSH remote (`git@github.com:Icegrave0391/graphics-benchmark`); HTTPS tends to
time out from this network. `main` branch. Validate scripts with `bash -n`
before committing.
