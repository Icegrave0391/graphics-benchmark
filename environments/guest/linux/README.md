# Linux guest image

Build and run the headless **Ubuntu 24.04** Linux guest used across the
benchmark matrix. (The Windows guest lives in `../windows/`.) The host is always
Linux; this directory produces a reusable `qcow2` with:

- default user **`user`**, **no password** (passwordless `sudo`, passwordless
  console login),
- **SSH key auth** (empty-password SSH is refused by `sshd`, so login is by key
  — see `.ssh/guest-key`),
- the **Mesa/Vulkan graphics userspace** (RADV/radeonsi + virgl/venus client
  drivers) and **MangoHud** preinstalled.

## Why a cloud image, not the desktop ISO

The Ubuntu **desktop** ISO boots a GNOME GUI installer that **cannot run
unattended** (it ignores `autoinstall`/NoCloud — that's a *server* ISO feature),
which is why it asks for a username/password.

Rendering performance does **not** depend on having a desktop. It depends on the
Mesa/Vulkan userspace and the GPU path (passthrough / VirGL / Venus / muvm).
Those are packages, installed here via cloud-init. All benchmarks run
**CLI/headless** (vkmark `--winsys headless`, glmark2 `--off-screen`,
GravityMark `-benchmark`, MangoHud) — see `docs/benchmark-design.md` §4. A
headless cloud image is also cleaner and more reproducible (design §6).

So we use the official **`noble-server-cloudimg-amd64.img`** (a prebuilt qcow2)
and customize it with cloud-init. The local desktop ISO is not used.

## Files

| File | Purpose |
|---|---|
| `.env` | paths, credentials, cloud-image URL, QEMU/memory/port settings |
| `cloud-init/user-data` | cloud-init config (placeholders filled at build time) |
| `cloud-init/meta-data` | cloud-init meta-data (instance id / hostname) |
| `create-vmdisk.sh` | downloads + customizes the cloud image into `vmdisk/ubuntu-vm.qcow2` |
| `start-vm.sh` | boots the guest (`--gui` for a window, default headless) |
| `ssh-vm.sh` | `ssh` into the running guest (key auth) |
| `.ssh/guest-key{,.pub}` | SSH keypair injected into the guest (committed — see note below) |

Generated artifacts (`vmdisk/`, the cached `*.img`, `*.qcow2`, `seed.iso`,
`OVMF_VARS.fd`) are git-ignored.

> The SSH keypair is **committed on purpose**. It only authenticates to
> throwaway benchmark VMs, so a fresh clone can `./ssh-vm.sh` immediately without
> regenerating keys. Do not reuse this key for anything else.

## Prerequisites

Runtime QEMU is the source-built **10.2** in `/usr/local`
(`environments/host/scripts/05-qemu-10.2.sh`). Plus a few host tools:

```sh
sudo apt-get install -y cloud-image-utils xorriso ovmf wget
```

(`cloud-image-utils` gives `cloud-localds`; `xorriso`/`genisoimage` are
fallbacks; `ovmf` provides UEFI firmware — already installed by
`00-base-kvm.sh`.)

## Usage

```sh
cd environments/guest/linux
./create-vmdisk.sh      # download + cloud-init customize -> vmdisk/ubuntu-vm.qcow2
./start-vm.sh           # boot it (headless; serial console)
./ssh-vm.sh             # ssh user@localhost -p 2222, key auth
```

`create-vmdisk.sh` boots the guest once headless, lets cloud-init install the
graphics stack and set up the user, waits for it to finish (polling SSH), then
powers off — no interaction required. First boot needs guest network access
(QEMU user-net provides it).

Run a command in the guest non-interactively:

```sh
./ssh-vm.sh -- vulkaninfo --summary
./ssh-vm.sh -- nproc
```

## Notes

- Host SSH port is `2222` -> guest `22` (change `SSH_HOSTFWD_PORT` in `.env`).
- The base image is cached in `vmdisk/` so re-runs don't re-download.
- `start-vm.sh` uses generic `virtio-vga-gl`. Graphics-path-specific launch
  fragments (VirGL / Venus / passthrough / muvm) live under
  `environments/virtualization/*` and `environments/host/scripts/`.
- Memory/vCPU/disk size and the Ubuntu release are in `.env` (`MEMORY`, `VCPUS`,
  `DISK_SIZE`, `CLOUDIMG_RELEASE`).
- The local `ubuntu-24.04.4-desktop-amd64.iso` is **not** used by these scripts;
  you can delete it to reclaim ~6.6 GB.
