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

指标按 **三层 workload**（见 §4）分组采集，每次 run 导出统一 JSON（见 §5）。

### 3.1 通用元数据（每次 run 必采）
GPU 型号、Mesa/RADV/radeonsi 版本、kernel、QEMU / libkrun / virglrenderer / venus 版本、DXVK/VKD3D 版本、guest OS、分辨率、vsync 状态、context type（virgl/venus/native/passthrough）、env_id。

### 3.2 L1 — GPU 算力层（GravityMark，GPU-bound）
衡量"虚拟化后 GPU 纯算力是否还在"。预期各虚拟化方案差异小。

| 指标 | 说明 |
|---|---|
| `score` | GravityMark 总分 |
| `fps_avg / fps_min / fps_max` | 帧率 |
| `frametime_avg_ms / p95 / p99` | 帧时间分布 |
| `fps_1pct_low / fps_0p1pct_low` | 卡顿 |
| `asteroids` | 固定对象数（保证跨 run 一致） |

### 3.3 L2 — 真实负载层（Basemark GPU / vkmark / glmark2，CPU+GPU 混合）
每帧数万 draw call，**包含命令提交路径开销**。是 GPU 算力与 transport 开销的综合体现。

| 指标 | 说明 |
|---|---|
| `score` / `fps_avg` | 综合性能 |
| `frametime_avg_ms / p95 / p99` | 帧时间分布 |
| `fps_1pct_low / fps_0p1pct_low` | 卡顿一致性 |
| `frametime_stddev_ms` | 帧时间抖动 |
| `host_cpu_pct` | host 端解码进程 (virglrenderer/venus/QEMU) CPU 占用 |

### 3.4 L3 — Transport 显微镜层（vkoverhead / drawoverhead，transport-bound）
专门隔离 **VM transport 的 CPU 提交开销**，是区分 passthrough / Venus / VirGL / muvm 的最关键数据。

| 指标 | 说明 |
|---|---|
| `draws_per_second` | 每个 vkoverhead/drawoverhead 用例的吞吐 |
| `submit_noop_dps` | 空 submit 吞吐 → 纯 transport 往返成本 |
| `submit_1cmdbuf_dps` / `submit_50cmdbuf_dps` | command buffer 提交成本 |
| `draw_dps` / `draw_multi_dps` | draw call 提交成本 |
| `descriptor_*_dps` | 资源绑定提交成本 |
| `relative_pct` | 相对各类 base case 的百分比（工具原生输出） |

> vkoverhead 走 Vulkan(→Venus)，drawoverhead 走 GL(→VirGL)，分别量化两条 transport 路径的提交开销。

### 3.5 派生指标（跨环境聚合后计算）
- `overhead_pct = (baseline - measured) / baseline`，基线为对应 native（`native-windows` / `native-linux`）。
- 每个 workload × API 一张"环境对比表"，列出各虚拟化方案相对 native 的 overhead。
- L3 的 `submit_*` overhead 单独成表 —— 这是 transport 方案优劣的核心证据。

> 关键方法论：**所有渲染类 workload（L1/L2）统一用同一帧时间捕获层归一化**（Linux: MangoHud；Windows: PresentMon），避免各 benchmark 自报 FPS 口径不一。L3 工具自带精确计数，直接用其原生 CSV。

---

## 4. Workload 选型（三层结构）

原则：**开源/免费 + CLI/headless + 结构化导出 + 跨 API**。避免 3DMark / Unigine Pro（CLI 与 CSV 导出付费、Linux 无 CLI 路径）。

设计核心：单一 workload 无法同时覆盖"GPU 算力"和"transport 开销"，因此分三层，各司其职。

| 层 | 目的 / bound | 工具 | API | CLI/导出 | 平台 | 状态 |
|---|---|---|---|---|---|---|
| **L1** | 跨 API 标准场景，GPU-bound（比 GPU 纯算力） | **GravityMark** | Vk/D3D12/D3D11/GL | ✅ CLI + 逐帧统计 + 自动退出 | Linux/Win | 先实测 |
| **L2** | 跨 API 真实负载，CPU+GPU（每帧数万 draw call，含提交开销） | **Basemark GPU** | Win:Vk/DX/GL; Linux:Vk/GL | ⚠️ 需实测 CLI/导出 | Linux/Win | 先实测 |
| **L2 补充** | 开源替补 / 轻量综合场景 | **vkmark**(Vk) + **glmark2**(GL) | Vk / GL | ✅ headless；glmark2 原生 CSV | Linux | 补充 |
| **L3** | transport 显微镜，transport-bound（隔离 VM 提交开销） | **vkoverhead**(Vk) + **drawoverhead**(GL,piglit) | Vk / GL | ✅ 原生 CSV，纯 CLI，零依赖 | Linux | 后续 |
| **计算/带宽** | Vulkan 峰值算力 microbench | **vkpeak** | Vk compute | ✅ 纯 CLI | Linux/Win | 可选 |
| **捕获层 (Linux)** | 统一帧时间归一化 | **MangoHud** | Vk/GL/DXVK | ✅ CSV（含 1%/0.1% low） | Linux | — |
| **捕获层 (Windows)** | 统一帧时间归一化 | **PresentMon** | DX/Vk/GL (ETW) | ✅ per-frame CSV | Windows | — |

> 当前阶段：**先实测 L1 (GravityMark) 与 L2 (Basemark GPU)**；L3 (vkoverhead/drawoverhead) 后续加入用于精确归因 transport 开销。

### 为什么要分三层
- **L1 GravityMark 是 GPU-driven**（CPU 几乎空闲），命令提交极少 → 测得出 GPU 算力，但**测不出 transport 开销**。
- **L2 Basemark GPU 是 CPU-driven**（每帧数万 draw call）→ 充分压 virtio/venus 提交路径，体现真实游戏式负载。L1 与 L2 互补。
- **L3 vkoverhead/drawoverhead** 用百万级 draw/submit 把 transport 往返成本放大成可测信号 → 干净隔离 passthrough vs Venus vs VirGL vs muvm 的提交开销差异。这是整个对比里最有信息量的数据。

### 跨 API 转译组件（非 benchmark 本身）
- **DXVK**（D3D9/10/11→Vulkan）、**VKD3D-Proton**（D3D12→Vulkan）：DX workload 在 Linux/虚拟化下的唯一途径，按路由走到 Venus / native ctx。
- 按 §2.1 路由，**不使用 Zink / ANGLE 做交叉转译**（GL 一律走 VirGL，保持路径干净）。

### Basemark GPU 已知坑（来自调研，实测时验证）
1. **Linux 版无原生 DX**（仅 GL+Vulkan）；DX 仅 Windows 版。
2. **强制联网**：free 版每次跑都上传 Power Board，断网无法运行 → 隔离 VM 需保证 guest 联网。
3. **AMD + RADV + 高画质/4K 会崩**（drm fence timeout 锁屏）→ 用 Medium 画质或非 4K，或改用 AMDVLK。
4. **CLI/导出能力待实测**：可能偏 GUI 驱动，需确认能否脚本化与结构化导出；若不行则以 vkmark/glmark2 替补 L2。
5. **License**：仅非商业；禁止把结果发布到带广告网站。内部研究可用。

### 推荐命令（占位，实测后锁定参数）
- L1: `GravityMark --api {vulkan|d3d12|d3d11|opengl} --preset <fixed> --asteroids <N> -benchmark -close`
- L2: `Basemark GPU`（实测 CLI；替补 `vkmark -b <scenes> --winsys headless` / `glmark2 -b <scenes> --off-screen --results-file r.csv`）
- L3: `vkoverhead -duration 5`（CSV）、piglit `drawoverhead`
- 计算: `vkpeak <dev_id>`
- 捕获: Linux `MANGOHUD_CONFIG=output_folder=...,fps_only=0` + `mangohud --dlsym <cmd>`；Windows `PresentMon -process_name <exe> -output_file r.csv`

---

## 5. 统一结果 Schema

每次 run 输出一个 JSON，便于跨矩阵聚合（CSV 也可由此派生）：

```json
{
  "run_id": "2026-06-29T12:00:00Z_venus-linux_L1_gravitymark_vulkan",
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
    "layer": "L1",
    "tool": "gravitymark", "api": "vulkan",
    "scene": "asteroids", "asteroids": 200000,
    "resolution": "1920x1080", "vsync": false, "duration_s": 30
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
  "raw_capture": "captures/venus-linux_L1_gravitymark_vulkan.csv"
}
```

> 字段说明：`env_id` 见 §2 矩阵；`category` ∈ {native,virtualization}；`layer` ∈ {L1,L2,L3}；`transport` ∈ {native,passthrough,virgl,venus,muvm}；L3 run 的 `metrics` 用 `draws_per_second` 系列（submit_noop / submit_1cmdbuf / draw 等按用例名展开），`score`/`fps_*` 留空。

---

## 6. 已知风险 / 待验证

- **`venus-windows` 已从矩阵移除（virtio-gpu 在 Windows guest 上无 3D）**：在 Linux host + Windows guest 组合下，virtio-gpu **没有可用的 3D 客户端驱动**。官方 virtio-win 提供的 Windows GPU 驱动（`viogpudo`）是 *display-only*（仅 2D/framebuffer），不提供 OpenGL/Vulkan/DirectX 硬件路径——这是架构性限制，与 virtio-win 版本无关（最新 0.1.285 仍只有 viogpudo）。后果：Windows guest 里任何 3D workload（DX/GL/Vulkan）都会回退到 **软件渲染**（DirectX→WARP、GL→GDI 1.1），host GPU 完全不参与，测不出真实性能（实测：`dxdiag` 显示 `Direct3D 0/4`，GpuTest/Basemark 直接闪退）。
  - 社区现状（追踪用）：virtio-win issue [#773](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/773)（请求完整 3D 驱动，多年未实现）、[#841](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/841)、PR [#943](https://github.com/virtio-win/kvm-guest-drivers-windows/pull/943)（viogpu3d：virgl+D3D10，黑屏/BSOD、未合并、判为死路）。基于 Venus(Vulkan)+VKD3D 的新驱动（anonymix007）号称"接近发布"但**尚未正式发布**。
  - 结论：**Windows 的虚拟化图形只用 `pt-windows`（passthrough，原生 AMD Windows 驱动 + 原生 DX）**。virtio 路径（VirGL/Venus）只在 Linux guest 上测。若将来 Windows Venus guest 驱动成熟发布，可重新评估加入 `venus-windows`。
- **muvm 仅 Linux guest**：无 Windows 路径（drm native context 是 Linux UAPI）。
- **Basemark GPU**：见 §4 已知坑（Linux 无原生 DX、强制联网、AMD+RADV 高画质崩溃、CLI/导出待实测、非商业 license）。若 CLI/导出不可用，L2 改用 vkmark + glmark2。
- **L1 GravityMark CPU-free**：测不到 transport 提交开销，须靠 L3 (vkoverhead/drawoverhead) 补齐归因。
- **路径干净性**：按 §2.1，GL→VirGL、VK→Venus、DX→DXVK(over Venus)，不做交叉转译，避免混淆开销来源。
- **MangoHud CSV 列格式随版本变化**：需在目标版本上锁定列定义；默认采样可能偏粗，需开启 per-frame frametime 日志。
- **Windows guest 帧捕获**：用 PresentMon（ETW，API 无关），与 Linux 的 MangoHud 口径需做一次校准对齐。仅用于 `native-windows` / `pt-windows`。
- **公平性控制**：固定分辨率、关 vsync、锁 GPU/内存时钟（避免 boost 抖动）、固定 guest vCPU/内存、预热后再采样、每配置多次取中位数。

---

## 7. 建议的执行顺序

阶段一（当前）：跑通 L1 + L2，验证 harness 与基线。
1. `native-linux` — 基线 + harness 验证（L1 GravityMark、L2 Basemark/vkmark/glmark2）。
2. `pt-linux` — 虚拟化上限。
3. `venus-linux` 与 `muvm-linux` — 核心对比（VK + DX via DXVK）。
4. `virgl-linux` — 仅 GL。
5. Windows 侧 `native-windows` / `pt-windows` — 原生 DX 对照（Windows 唯一的虚拟化图形路径是 `pt-windows`；virtio 路径仅 Linux，见 §6）。

阶段二：加入 L3 (vkoverhead/drawoverhead)，对上述每个环境精确量化 transport 提交开销。
