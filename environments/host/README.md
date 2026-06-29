# Host dependencies (Ubuntu 24.04 LTS)

Everything the **host** needs to run QEMU/KVM and bring up Linux/Windows guests
for every scheme in the matrix. The host is Ubuntu 24.04 LTS on AMD.

> Run order: start with `00-base-kvm.sh`, then `05-qemu-10.2.sh` (everyone uses
> QEMU 10.2), then the script(s) for the schemes you intend to benchmark.
> Scripts are idempotent and safe to re-run.

## What can be installed from apt vs. what must be built

| Scheme | apt only? | Notes |
|---|---|---|
| Base KVM | ✅ | OVMF, swtpm, passt, Mesa/Vulkan |
| **QEMU 10.2** | ❌ **build required** | 24.04 ships 8.2.2; we build 10.2 (covers Venus's ≥ 9.2 requirement) |
| Passthrough (VFIO) | ✅ (+ kernel cmdline) | vfio-pci is in-kernel; needs IOMMU cmdline |
| VirGL (OpenGL) | ✅ | stock `libvirglrenderer1` 1.0.0 has VirGL |
| **Venus (Vulkan)** | ❌ **build required** | stock virglrenderer has no `venus` (QEMU already covered by `05`) |
| **muvm (libkrun)** | ❌ **build required** | no apt package; needs virglrenderer w/ drm native context + kernel ≥ 6.13 |
| AMD / Mesa / Vulkan | ✅ | Mesa 25.2.8 on 24.04 amd64, RADV is new enough |

One source build of virglrenderer (with both `-Dvenus=true` and drm native
context) serves **both** Venus and muvm. QEMU 10.2 is built once by `05` and
shared by all schemes.

## Scripts

| Script | Purpose | Method |
|---|---|---|
| `scripts/00-base-kvm.sh`        | KVM, OVMF, swtpm, networking, Mesa/Vulkan       | apt |
| `scripts/05-qemu-10.2.sh`       | build & install QEMU 10.2 to /usr/local         | **source build** |
| `scripts/10-passthrough.sh`     | VFIO modules, IOMMU cmdline guidance, driverctl | apt + kernel cmdline |
| `scripts/20-virgl.sh`           | virtio-gpu VirGL (OpenGL) runtime               | apt |
| `scripts/30-venus.sh`           | build virglrenderer (`venus`); relink QEMU      | **source build** |
| `scripts/40-muvm.sh`            | build libkrun + muvm (+ drm native context)     | **source build** |

> These are scaffolding: they encode the correct package/build steps but should
> be reviewed before running. They do **not** modify your bootloader
> automatically — IOMMU/kernel cmdline changes are printed for you to apply.

## Kernel note

Ubuntu 24.04 ships kernel 6.8. **muvm needs kernel ≥ 6.13** for the
`virtio-gpu` drm-native-context params. Install the HWE / mainline kernel before
running `40-muvm.sh` (the script checks and warns).
