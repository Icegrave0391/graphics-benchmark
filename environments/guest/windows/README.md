# Windows guest image

Windows guest used for the DirectX/Vulkan/OpenGL baselines and their
virtualized counterparts. The host is always Linux; this is the Windows *guest*,
built into a reusable `qcow2` by an unattended install. Mirrors the Linux guest
layout (`.env` / `create-vmdisk.sh` / `start-vm.sh` / `ssh-vm.sh`, plus
`get-windows-iso.sh` for the ISO download).

Result of a build: `vmdisk/windows-vm.qcow2` with

- local admin user **`user`**, password **`user`**,
- **RDP** enabled and **OpenSSH Server** enabled (host's public key authorized),
- **virtio** drivers (disk/net) + **QEMU guest agent** installed,
- **UEFI, Secure Boot OFF, no TPM** — targets **Windows 10** (simplest, and
  avoids Secure-Boot conflicts on the passthrough path).

## Why a from-ISO unattended install (not a cloud image)

There is no official Windows cloud image, so we install from a Windows ISO you
provide, driven by `autounattend/autounattend.xml` on a small seed CD. The
virtio-win driver CD is attached during install so the virtio system disk and
NIC are usable; `FirstLogonCommands` then enables RDP + OpenSSH and finishes the
virtio/guest-agent install.

## Graphics paths for Windows (important)

| Matrix row | GPU path | Status |
|---|---|---|
| `native-windows` | bare metal (not this VM dir) | native DX/Vulkan/GL |
| `pt-windows` | **VFIO full-card passthrough** → native AMD Windows driver | **primary** real-graphics path |
| `venus-windows` | virtio-gpu + Venus | **experimental** (Windows Venus ICD immature — design §6) |

`virtio-gpu` 3D on Windows is only basic 2D/framebuffer, so **real graphics
benchmarking on Windows uses passthrough** (`pt-windows`): the guest runs the
native AMD Windows driver and native DirectX. This build produces the base image;
the passthrough launcher lives under
`environments/virtualization/passthrough/windows-guest/`.

> Passthrough needs a second, discrete, vfio-bindable GPU (you cannot pass
> through the host's only/APU GPU). See `environments/host/scripts/10-passthrough.sh`.

## Getting a Windows ISO

`create-vmdisk.sh` fetches a Windows 10 x64 ISO **automatically** when one isn't
present (idempotent — skips if it already exists). It uses
[`get-windows-iso.sh`](get-windows-iso.sh), which drives **mido** to pull the
**official** image straight from Microsoft (Microsoft's download page only mints
short-lived JS URLs, so a plain `wget` cannot). mido is fetched on demand and
cached in `vmdisk/`.

```sh
./get-windows-iso.sh                 # just download the ISO
MIDO_EDITION=win10x64 ./get-windows-iso.sh
```

To use your own ISO instead, point `WINDOWS_ISO` at it (auto-download is then
skipped):

```sh
WINDOWS_ISO=~/Win10_x64.iso ./create-vmdisk.sh
```

Set `WIN_EDITION` if your ISO's edition name isn't `Windows 10 Pro` (e.g.
`WIN_EDITION="Windows 10 Home"`). Official manual download (fallback):
https://www.microsoft.com/software-download/windows10

## Prerequisites

Runtime QEMU 10.2 (`host/scripts/05-qemu-10.2.sh`, built `--enable-gtk`), plus:

```sh
sudo apt-get install -y xorriso ovmf wget
```

(virtio-win ISO is downloaded automatically and cached in `vmdisk/`.)

## Usage

```sh
cd environments/guest/windows
./create-vmdisk.sh                               # auto-downloads ISO, unattended install
./start-vm.sh                                    # boot (GTK window; --headless to hide)
./ssh-vm.sh -- "ver"                             # SSH in (key or password 'user')
# RDP: connect a client to localhost:3389
```

The installer runs in the QEMU GTK window and reboots itself a few times; it
needs no interaction. First boot finishes driver/SSH setup via FirstLogonCommands.

## Notes

- Ports (in `.env`): SSH host `2322`→guest 22, RDP host `3389`→guest 3389.
- `autounattend.xml` loads the virtio storage driver from the virtio-win CD
  (expected as drive `E:`); if Windows assigns a different letter, adjust the
  `DriverPaths` / `FirstLogonCommands` paths.
- For Windows 11 you would additionally need TPM 2.0 (swtpm) and Secure Boot (or
  a setup bypass) — intentionally out of scope here.
