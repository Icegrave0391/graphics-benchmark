# Windows guest image

Windows guest used for the native-DirectX baseline and its virtualized
counterparts. The host is always Linux; this is the Windows *guest*.

Frame capture on Windows uses **PresentMon** (ETW, API-agnostic) instead of
MangoHud — see `docs/benchmark-design.md` §3.5 / §4.

Matrix rows that use this guest:

| ID | GPU path | APIs |
|---|---|---|
| `native-windows` | bare metal (out of scope for this VM dir) | native D3D11/D3D12, Vulkan, GL |
| `pt-windows`      | VFIO full-card passthrough | native DX (compare vs `native-windows`) |
| `venus-windows`   | virtio-gpu + Venus (experimental, see §6) | Vulkan + DX via DXVK |

## TODO (scaffolding)

- [ ] Decide build method: unattended install from a Windows ISO (`autounattend.xml`
      on a seed CD) vs. a prebuilt image. Unlike the Linux cloud image there is no
      official cloud qcow2.
- [ ] virtio drivers (virtio-win ISO) for disk/net/GPU in the guest.
- [ ] Default user `user`, RDP/SSH (OpenSSH Server on Windows) for headless control.
- [ ] AMD Windows driver install + fixed clocks for repeatability.
- [ ] PresentMon capture wiring.
- [ ] `venus-windows` is experimental; the Venus ICD on Windows may not work and
      may be skipped (see design §6).

Scripts here should mirror the Linux guest layout where it makes sense
(`.env` / `create-vmdisk.sh` / `start-vm.sh` plus a Windows-specific remoting
helper).
