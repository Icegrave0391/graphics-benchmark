# Guest images

Reusable guest VM images used across the benchmark matrix, one subdirectory per
guest OS. The host is always Linux; these are the *guests*.

| Dir | Guest OS | Status | Used by matrix rows |
|---|---|---|---|
| `linux/`   | Ubuntu 24.04 (headless cloud image) | working | `native-linux`, `pt-linux`, `virgl-linux`, `venus-linux`, `muvm-linux` |
| `windows/` | Windows | scaffolding | `native-windows`, `pt-windows`, `venus-windows` |

Each guest image is built once here and then attached to a specific GPU path
(passthrough / VirGL / Venus / muvm) by the launchers under
`environments/virtualization/*` and `environments/host/scripts/`.

See each subdirectory's `README.md` for build/run instructions.
