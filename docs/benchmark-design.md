# Graphics API & GPU Virtualization Benchmark — Design

测量不同 **图形 API**（DirectX / Vulkan / OpenGL）在不同 **GPU 虚拟化方案** 下的渲染性能。
Host 固定为 Linux，GPU 为 **AMD**（RADV / radeonsi / amdgpu）。

---

## 1. 关键背景：virtio-gpu 的分层关系

`virtio-gpu` 是 guest↔host 之间的 **paravirtualized GPU 传输层（virtio 设备）**，它本身不渲染、不决定 API。真正决定 API 语义的是跑在其上的 **context type (capset)**：

```
Guest 应用 (Vulkan / OpenGL / DirectX)
        │
   guest Mesa 驱动 (venus / virgl / amdgpu-native / DXVK+VKD3D)
        │
   virtio-gpu 设备 (virtqueue 传输)                 ← 共享传输层
        │  ===== VM 边界 =====
   host 解码器 (virglrenderer / venus / muvm)
        │
   host Mesa 驱动 (RADV / radeonsi)
        │
   amdgpu 内核驱动 → 物理 AMD GPU                    ← 真实硬件加速
```

| context | guest API | host 执行 | 开销 | OpenGL | Vulkan | DirectX (via DXVK) |
|---|---|---|---|:---:|:---:|:---:|
| **VirGL** | OpenGL/GLES | host OpenGL (radeonsi) | 高（GL 状态机翻译） | ✅ | ❌ | ❌ |
| **Venus** | Vulkan | host Vulkan (RADV) | 低（薄转发） | ❌ | ✅ | ✅ |
| **drm native context** | 原生 amdgpu UAPI | host 原生 Mesa | 最低 | ✅ | ✅ | ✅ |

要点：
- **VirGL 只能跑 OpenGL**；要在 VirGL 路径测 Vulkan/DX 是不可能的。
- 虚拟化下测 **DirectX 必须有 Vulkan**（DXVK/VKD3D 把 DX→Vulkan），因此只能走 Venus 或 native context。
- VirGL 与 Venus 都是 **真实硬件加速**（host 端走 RADV/radeonsi+amdgpu），不是软件渲染。

---

## 2. Benchmark Matrix（环境维度）

Host 永远是 Linux，GPU 永远是 AMD。每个环境用一个**自解释的短名 ID**
（可直接作目录名 / run_id），按 **Native** 与 **Virtualization** 两级分类。

### Native（裸机，非虚拟化）

| ID | Guest | GPU 路径 | 备注 |
|---|---|---|---|
| `native-windows` | Windows | 原生 amdgpu (Windows 驱动) | DX/Vulkan/GL 全原生 |
| `native-linux` | Linux | 原生 amdgpu + Mesa | DX 经 DXVK/VKD3D；总基线 |

### Virtualization（host 恒为 Linux）

| 方案 | ID | Guest | GPU 路径 | 备注 |
|---|---|---|---|---|
| **Passthrough** (VFIO) | `pt-linux` | Linux | 整卡直通 | 虚拟化上限基线 |
| | `pt-windows` | Windows | 整卡直通 | 原生 DX，可比 `native-windows` |
| **VirtIO-GPU + VirGL** | `virgl-linux` | Linux | virglrenderer → radeonsi | **仅 OpenGL** |
| **VirtIO-GPU + Venus** | `venus-linux` | Linux | venus → RADV | Vulkan + DX(DXVK) |
| **muvm** (libkrun + drm native ctx) | `muvm-linux` | Linux | amdgpu-native → RADV/radeonsi | 最低开销，仅 Linux |

> **不做 `venus-windows`（已移除）**：Linux host + Windows guest 下，virtio-gpu **没有可用的 3D 客户端驱动**——官方 virtio-win 的 GPU 驱动（viogpudo）只有 2D/显示，没有 OpenGL/Vulkan/DirectX 硬件路径。任何 3D workload 在 Windows virtio-gpu 下只能落到软件渲染（WARP），测不出真实 GPU 性能。社区的 Venus-on-Windows 驱动仍是 WIP、未正式发布（见 §6）。因此 **Windows 的虚拟化图形只走 `pt-windows`（passthrough，原生 AMD Windows 驱动 + 原生 DX）**；virtio 路径仅在 Linux guest 上测。

### 2.1 API → 渲染路径的固定路由规则

**重要决策**：为保证每条路径"干净"、可归因，每个 API 在虚拟化环境下只走一条固定路径，**不做交叉转译对比**（不测 Zink、不在 VirGL 下测 Vulkan 等）：

| 被测 API | 虚拟化下走的路径 | host 解码 → 驱动 |
|---|---|---|
| **OpenGL** | VirtIO-GPU + **VirGL** | virglrenderer → radeonsi |
| **Vulkan** | VirtIO-GPU + **Venus** | venus → RADV |
| **DirectX** | **DXVK** → Vulkan → VirtIO-GPU + **Venus** | venus → RADV |

native / passthrough 环境下 API 走原生路径（Windows 原生 DX；Linux DX 经 DXVK）。muvm 下所有 API 走 drm native context。

### 2.2 环境 × API 子矩阵（按上面路由）

| 环境 ID | OpenGL | Vulkan | DirectX |
|---|---|---|---|
| `native-windows` | 原生 GL | 原生 Vk | 原生 D3D11/12 |
| `native-linux` | 原生 GL | 原生 Vk | DXVK→Vk |
| `pt-linux` | 原生 GL | 原生 Vk | DXVK→Vk |
| `pt-windows` | 原生 GL | 原生 Vk | 原生 DX |
| `virgl-linux` | VirGL | — | — |
| `venus-linux` | — | Venus | DXVK→Venus |
| `muvm-linux` | native ctx | native ctx | DXVK→native ctx |

"—" 表示该环境不负责该 API（由对应的专用环境测）。这样每个数字都唯一对应一条 transport 路径，便于横向比较"同一 workload 在不同 transport 下的开销"。

---

## 3. 测量指标

当前只保留一个 workload：**Basemark GPU**。不再按 L1/L2/L3 分层组织。
每次 run 导出统一 JSON（见 §5）。

### 3.1 通用元数据（每次 run 必采）

GPU 型号、Mesa/RADV/radeonsi 版本、kernel、QEMU / libkrun / virglrenderer / venus
版本、DXVK/VKD3D/Proton 版本、guest OS、分辨率、vsync 状态、context type
（virgl/venus/native/passthrough/muvm）、env_id。

对 Venus 必须额外记录 host Vulkan ICD：`host_vulkan_driver`（例如 `radv` 或
`amdvlk`）和 `host_vulkan_driver_version`。本项目默认 Venus 走 RADV；在
Renoir/Cezanne host 上，Ubuntu stock Mesa 的 RADV 会让 host venus decoder
线程崩溃（`vkr-ring-*` segfault in `libvulkan_radeon.so`），已验证 Mesa
`26.1.3 - kisak-mesa PPA` 可修复。

### 3.2 Basemark GPU 指标

Basemark GPU 是当前唯一的图形 workload。它覆盖真实游戏式负载（CPU+GPU
混合、较多 draw call），比纯微基准更接近实际应用。

| 指标 | 说明 |
|---|---|
| `score` | Basemark 总分 |
| `fps_avg / fps_min / fps_max` | 帧率 |
| `frametime_avg_ms / p95 / p99` | 由统一捕获层计算 |
| `fps_1pct_low / fps_0p1pct_low` | 卡顿指标 |
| `frametime_stddev_ms` | 帧时间抖动 |
| `host_cpu_pct` | host 端解码进程 (QEMU/virglrenderer/venus) CPU 占用 |

### 3.3 派生指标

- `overhead_pct = (baseline - measured) / baseline`，基线为对应 native
  （`native-windows` / `native-linux`）。
- 每个 Basemark API × 环境一张对比表，列出各虚拟化方案相对 native 的
  overhead。
- 注意 Venus 的 host ICD 必须一致才可做纯 overhead 对比；例如
  `native-linux-radv` 应对比 `venus-linux-radv`。若使用 `venus-linux-amdvlk`，
  需要单独建立 `native-linux-amdvlk` 基线。

> 关键方法论：所有渲染类 run 统一用 **MangoHud**（Linux）或
> **PresentMon**（Windows）采集帧时间，避免 Basemark 自报 FPS 与其他环境
> 口径不一致。

---

## 4. Workload 选型

保留 **Basemark GPU**（正式 benchmark）与 **GravityMark**（诊断/对照），二者各含
一个经 Proton 的 DirectX 变体。移除 vkmark/glmark2、vkoverhead、drawoverhead、
vkpeak 等分层/补充 workload。原因：当前阶段重点是先用少量真实负载跑通环境矩阵和
结果采集，避免多 workload 带来的脚本和口径复杂度。

| 工具 | API | CLI/导出 | 平台 | 状态 |
|---|---|---|---|---|
| **Basemark GPU** | Linux: Vulkan/OpenGL；Windows build: D3D12（经 Proton） | Linux 原生 binary 可由 `run.sh` 直接驱动；DX 变体经 Proton | Linux（native/guest） | 正式 workload |
| **GravityMark** | Linux: Vulkan/OpenGL；Windows build: D3D11/D3D12（经 Proton） | 原生 `run_*.sh`；DX 变体经 Proton | Linux（native/guest） | 诊断/对照 workload |

### DirectX 变体（经 Proton，venus-linux）

DirectX 在 Linux 下没有原生后端。两个 workload 各自带一个 DX 变体，跑各自的
**Windows** 版并通过 **Proton** 翻译：D3D11 → DXVK → Vulkan，D3D12 →
VKD3D-Proton → Vulkan。在 `venus-linux` 上，翻译后的 Vulkan 在 host 端经 Venus
执行，因此 DX 与原生 Vulkan 走同一 transport，可直接对比。

- 共享运行时：`workloads/proton/`（umu-launcher + Proton；首次运行需联网下载
  Proton 与 Steam Runtime）。
- GravityMark DX：`workloads/gravitymark/dx/`（Windows `.msi`，`msiextract`
  离线解包，`run.sh --d3d11|--d3d12`）。
- Basemark GPU DX：`workloads/basemark-gpu/dx/`（Windows 安装器，装入 Proton
  prefix，`run.sh`）。
- `workloads/proton/versions.txt` 记录 Proton/DXVK/VKD3D 版本用于 run 元数据。

### Basemark GPU 已知坑

1. **Linux 版无原生 DX**（仅 GL+Vulkan）。DirectX 通过 Windows 版 Basemark +
   Proton（VKD3D-Proton）跑，见上面 DX 变体。
2. **强制联网/Power Board**：GUI free 版会上传结果；CLI runner 默认关闭
   `ResultUpload`，如需与 GUI 行为一致可显式打开。
3. **AMD + RADV + 高画质/4K 可能崩**：默认使用 Medium / 非 4K。
4. **旧 Linux binary 依赖 OpenSSL 1.1**：Ubuntu 24.04 没有 `libssl1.1`，安装脚本
   从 Ubuntu 20.04 security pocket 安装该兼容库。
5. **Electron SUID sandbox**：安装脚本修复 `chrome-sandbox` 的 `root:root 4755`。
6. **License**：仅非商业；禁止把结果发布到带广告网站。内部研究可用。

### 推荐命令

```sh
# 安装（host 或 Linux guest）
workloads/basemark-gpu/install.sh

# Vulkan（Venus / native Vulkan）
DISPLAY=:0 workloads/basemark-gpu/run.sh --api vulkan --quality medium --res 1280x720

# OpenGL（VirGL / native GL）
DISPLAY=:0 workloads/basemark-gpu/run.sh --api gl --quality medium --res 1280x720
```

---

## 5. 统一结果 Schema

每次 run 输出一个 JSON，便于跨矩阵聚合（CSV 也可由此派生）：

```json
{
  "run_id": "2026-06-29T12:00:00Z_venus-linux_basemark_gpu_vulkan",
  "env": {
    "env_id": "venus-linux",
    "category": "virtualization",
    "host_os": "Linux 6.x",
    "guest_os": "Linux 6.x",
    "virt": "virtio-gpu",
    "context_type": "venus",
    "transport": "venus",
    "gpu": "AMD Radeon ...",
    "mesa_version": "...", "radv_version": "...", "radeonsi_version": null,
    "virglrenderer_version": null, "venus_version": "...",
    "qemu_version": "...", "libkrun_version": null,
    "dxvk_version": null, "vkd3d_version": null
  },
  "workload": {
    "tool": "basemark-gpu", "api": "vulkan",
    "scene": "official", "quality": "medium",
    "resolution": "1280x720", "vsync": false, "duration_s": 90
  },
  "metrics": {
    "score": 0,
    "fps_avg": 0, "fps_min": 0, "fps_max": 0,
    "fps_1pct_low": 0, "fps_0p1pct_low": 0,
    "frametime_avg_ms": 0, "frametime_p95_ms": 0, "frametime_p99_ms": 0,
    "frametime_stddev_ms": 0,
    "host_cpu_pct": null,
    "draws_per_second": null,
    "gflops_fp32": null, "bandwidth_gbps": null
  },
  "derived": { "baseline_id": "native-linux", "overhead_pct": null },
  "capture_layer": "mangohud",
  "raw_capture": "captures/venus-linux_basemark_gpu_vulkan.csv"
}
```

> 字段说明：`env_id` 见 §2 矩阵；`category` ∈ {native,virtualization}；`transport` ∈ {native,passthrough,virgl,venus,muvm}。当前 schema 不再包含 workload layer。

---

## 6. 已知风险 / 待验证

- **`venus-windows` 已从矩阵移除（virtio-gpu 在 Windows guest 上无 3D）**：在 Linux host + Windows guest 组合下，virtio-gpu **没有可用的 3D 客户端驱动**。官方 virtio-win 提供的 Windows GPU 驱动（`viogpudo`）是 *display-only*（仅 2D/framebuffer），不提供 OpenGL/Vulkan/DirectX 硬件路径。
- **Basemark GPU Linux 版**：Linux 无原生 DX；旧 native renderer 依赖 OpenSSL 1.1；GUI free 版会上传 Power Board；高画质/4K 在 AMD/RADV 上可能不稳定，因此默认 Medium / 非 4K。
- **VirGL OpenGL 版本限制**：当前 Linux guest 的 VirGL 暴露 OpenGL 4.3；Basemark GPU 的部分 GL 路径可能要求 OpenGL 4.5，不应假设所有 GL workload 都能在 VirGL 上运行。
- **Venus host RADV 版本敏感**：Ubuntu stock Mesa 在 Renoir/Cezanne host 上可导致 `vkr-ring-*` 在 `libvulkan_radeon.so` 中崩溃。已验证 kisak Mesa 26.1.3 的 RADV 可跑通 Venus Vulkan workload。
- **公平性控制**：固定分辨率、关 vsync、锁 GPU/内存时钟（避免 boost 抖动）、固定 guest vCPU/内存、预热后再采样、每配置多次取中位数。

---

## 7. 建议的执行顺序

当前阶段只围绕 Basemark GPU 建立基线和虚拟化对比：

1. `native-linux` — Basemark GPU Vulkan/OpenGL 基线。
2. `venus-linux` — Basemark GPU Vulkan（必要时通过 host RADV/kisak Mesa 修复）。
3. `virgl-linux` — Basemark GPU OpenGL（受 VirGL GL 4.3 能力限制，若不可运行需标注跳过）。
4. `muvm-linux` / `pt-linux` — Basemark GPU Vulkan/OpenGL 对比。
5. Windows 侧仅保留 `native-windows` / `pt-windows`，用于原生 DX 对照；本 repo 不支持 Windows guest 上的 virtio 图形路径。
