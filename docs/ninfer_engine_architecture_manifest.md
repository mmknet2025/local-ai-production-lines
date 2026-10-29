---
type: manifest
title: "NInfer 引擎架构全流程手册（本机 RTX 5060 Ti ×2 · sm_120a · 从源码到生产）"
tags: [ninfer, engine, architecture, sm120a, rtx50, gpu, cuda, kvmem, mtp, speculative-decoding, local-inference, okf-v0.2]
description: "NInfer 自研推理引擎在本机（MAXSUN B850 / Ryzen 7 9700X / 2×RTX 5060 Ti 16GB / CUDA 13.4）上的完整架构拆解：源码模块地图、启动链路、请求链路、KVMem 页级检索链路、按卡路线校准、投机解码、GGUF 量化内核借用关系、全流程参数与实测数字、调优与负结果（decode +7.0%、int8 KV、视觉屏蔽、cublas/深草稿为何被撤）、已知边界"
trust: agent-generated
status: current
okf_version: v0.2
timestamp: "2026-10-21"
sources:
  - 源码 ~/ninfer-build/src-5258/swift15/engine（commit 组合版 3c26089 = 基线 927e19e + 摘入 209c75b 的 serve 层；历史 c9fd230）
  - 本机会话实测（2026-10-03 ~ 10-04）
  - 厂商引擎包 /mnt/nas/nas/nas/linux/50/infer-engine-sm120a-20261002（README-pack.md + 教程）
  - 调优对照实测（2026-10-04，逐档真重启 69s；产物 20_Tech_Stack/_evidence/ninfer-2026-10-04/tune-sweep/，含 QUAL/LADDER JSON、完整日志与前缀复用 A/B）
---

> 📌 **生产线公共事实（端口/互斥/编排/回滚）以 [[20_Tech_Stack/local-production-lines|三条生产线总览]] 为单一事实源**；本文只保留本线/本主题细节。

# NInfer 引擎架构全流程手册

> 本页记录 **NInfer** 这一自研推理引擎的完整架构与工作流，全部按**本机实际配置**（见 §1）取证。
> 与 [[20_Tech_Stack/kvmem_llamacpp_manifest|KVMem+llama.cpp 手册]]（**已归档**）的关系：那是被本引擎**替换掉的旧栈**。

> 🔗 **编排（端口 / 互斥 / 按需拉起 / model id）统一见 [[20_Tech_Stack/local-production-lines|三条生产线总览]] §2–§5。**

> 🔗 **编排（端口 / 互斥 / 按需拉起 / model id）统一见 [[20_Tech_Stack/local-production-lines|三条生产线总览]] §2–§5。**

> [!info] 一句话定位
> NInfer 是**为 Qwen3.5 单一模型家族从零写的推理引擎**（22 万行、629 个自研 CUDA 内核），
> **不是 llama.cpp 的封装**；但它**直接复制 llama.cpp 的量化内核**（MIT）来处理 GGUF 块格式权重。

---

## §1 本机硬件与环境（本页所有数字的基准）

| 部件 | 实测值 |
|---|---|
| 主板 / CPU | MAXSUN B850 AIGA · Ryzen 7 9700X |
| GPU | **2 × RTX 5060 Ti 16GB**（sm_120a · 各 16,311 MiB · 各 36 SM） |
| 双卡链路 | PCIe **Gen5 x8 + x8**（P2P 已实测可用，`~/scripts/p2p/`） |
| 显示输出 | **AMD 核显**（`1002:13C0`）—— 两张 N 卡连接器全 `disconnected`，**显存 100% 给计算** |
| 内存 / 交换 | 59 GiB / 40 GiB swap |
| CUDA | 系统 13.4.2（给 llama.cpp/vLLM）；**引擎本机自编用 `/usr/local/cuda`** |
| 驱动 | 615.71.09 + aikitoria P2P 补丁（hold，只能随补丁 DKMS 一起升） |
| 内核 | **`7.3.0-9-generic`**（apt HWE，**2026-10-21 实测唯一在跑内核**；DKMS 也只对这一项 installed —— 自编 vanilla 7.3.0 随 2026-10-20 重装消失） |

> [!warning] 关键前提
> 引擎源码**原生只支持 RTX 30/40**（作者 README 原文：「只支持 RTX 30 / 40 系：引擎按 sm_86 编译。
> **RTX 50 系请用 Ryan-gsq 分支的官方预编译包**」）。本机跑的是**自编 sm_120a 版**（见 §2.3）。

---

## §2 引擎身份与血统

### 2.1 三条 fork 线（同一份代码的不同分支）

| 线 | 仓库 | 定位 |
|---|---|---|
| **本机现役（2026-10-21 换基座，见 §14）** | ~~`5258MF/ninfer-rtx3060-27b` → `swift15/engine/`~~ → 现为 `iamwavecut/ninfer-all@08fd7019` + `qzshch/ninfer-kvmem` 环（树 `~/ninfer-build/kvmem-base-20261021`） | **完整源码** + **KVMem 已合入（现以独立 `kvmem/` 模块接入）** + 架构门接受 `120a`，Apache-2.0 |
| 上游汇总 | `iamwavecut/ninfer-all` | 多派系整合（3090/4090/5090/Blackwell），`master` = 0.12.0 |
| RTX50 官方 | `Ryan-gsq/ninfer-16g-5070ti-5080-5090-…` | Windows / 16GB / RTX 50；**无 KVMem 环**（只有上游前缀缓存） |
| 原始引擎 | `Neroued/ninfer` | 上游源头（Linux、sm_120a、无多卡、无环） |

> [!important] 命名陷阱：三个东西都叫「50 线」
> ① 厂商 Windows 包 `infer-engine-sm120a-20261002` —— **变体 A**（`NINFER_KV_*` + 内容打分 `kvmem_score: SELECT`），**仅 Windows .exe**
> ② `Ryan-gsq` GitHub 仓 —— 上游 master + Windows 托盘管理器，**无环**
> ③ 本机自编二进制 —— **变体 B**（`--kvmem-window-pages` + `NINFER_KVMEM_*`）
> **两者的 KVMem 是两套独立实现，标志不通用。**

### 2.1.1 选型记录：为什么「单卡长上下文」只有这条线（2026-10-12 实测复核）

> 回答「当初为何选 `5258MF` 这条 fork、是不是还有别的选择」。**结论：候选面不宽，是「要环」这一条把所有其它选项筛掉了。**

**候选面 = 本机 `~/ninfer-build/` 下现存的 8 棵树**（即当初试过的全部），逐树实测 `kvmem` 命中：

| 树 | 来源 | 源码命中 | 文件名含 kvmem | 结论 |
|---|---|---|---|---|
| **`src-5258`** | `5258MF/ninfer-rtx3060-27b` | **101** | **41** | ✅ **唯一带环** → 曾是唯一选择；**2026-10-21 起改跟环上游 `qzshch`（见 §14）**，本树保留作回滚 |
| ~~`src`~~（**已删除** 2026-10-13） / `src-master` | `iamwavecut/ninfer-all`（2 个 checkout；`src` 为 09-23 旧 checkout，已删除、公开仓可重克隆） | 0 | 0 | 无环（仅上游前缀缓存） |
| `src-tp2` | `wamansou/ninfer-tp2-1m` | 0 | 0 | 无环 ＋ 硬编码禁用前缀复用（不适合 agent 多轮） |
| `baiyouqing-tp2` | `BaiYouQing/ninfer-tp2-5060ti-windows` | 0 | 0 | 无环 ＋ Windows 端 |
| `patch-mirror` | （无 origin，本地） | 16 | 0 | 旧 KVMem 补丁镜像，非 fork 候选 |
| `disk-kv-tier` / `runtime.orig-153116` | （无 origin，本地） | 0 | 0 | 实验 / 备份树 |

**推理链**：要「单卡 256K」⇒ 必须把 KV 搬出显存并按需召回 ⇒ 必须**有环**；环不在上游汇总线、不在原始引擎（`Neroued/ninfer`）、不在 Windows 官方线（`Ryan-gsq`，§2.1 表已注「无环」）⇒ **只剩 5258**。（**2026-10-21 更新**：环的上游 `qzshch/ninfer-kvmem` 已把环做成独立 `kvmem/` 模块并持续更新，现役基座直接取自它 —— 见 §14；5258 自 10-13 停更。）

**这条 fork 自己的定位正好对口**（`README.md` 原文）：标题「**ninfer：在 RTX 3060 上本地运行 27B 模型**」；「支持对话和图片输入，也支持工具调用与 **KVMem 长上下文**」；「Swift 1.5 默认总上下文为 **200K，最多可配置 256K**；**KVMem 会从历史中选取部分内容放入显存**」。环是它作者在持续开发的主线：`d161410` Allocate KVMem windows from rendered request prefixes / `f7090b9` perf(bonsai): move KVMem retrieval to CPU and allocate full resident windows / `c03e301`·`2d4f48e`·`274d060` 12GB 档 KVMem 容量调优。

**许可证一并核实**：`swift15/LICENSE` 与 `swift15/engine/LICENSE` 均为 **Apache License 2.0**；根目录无 LICENSE 属正常——这是多版本仓（`bonsai2/` + `swift15/`）⇒ §2.1 表里「Apache-2.0」的记载**无误**。

**结论**：不是「在多个选择里挑了一个」，而是**本机可得的生态里只有这一条实现了环**——别的那几条是「**没有**」，不是「没选」。唯一能改变该结论的前提是「**环从别处来**」：即 ActKV 一类**外挂**方案（别人的 Windows 线），在本机产线源码 **0 命中**（2026-10-12 实测）。

### 2.2 血统：借了 llama.cpp 的量化内核（官方原文）

`third_party/ggml-quants/README.ninfer.md`：

> These files are copied **unmodified from llama.cpp**（追溯至上游 vendored 源，`ggml/include/` + `ggml/src/`，
> **非本机 llama.cpp 现役构建**）, commit `a25c9865fe03c954c93fd755b5d79ae86ba99750`, under the MIT license.
> NInfer compiles ggml's integer tensor-core matrix multiplication (`ggml-cuda/mmq.cuh`) and its
> dequantizers through the bridge in `src/ops/linear/gguf/` … **Products of up to eight tokens use
> NInfer's own kernel** (`ggml_bridge_vec.cuh`)

**实测边界**：

```
llama_ 符号（整棵 src 树）     0 种
#include llama.h               0 个文件
动态库依赖                     154 个，无 llama / ggml 共享库
third_party/ggml-quants        28 文件（仅量化：ggml-common.h / mmq.cuh / 14 个反量化器 / mma.cuh）
```

→ **借量化块格式与张量核矩阵乘，其余全部自研。** 这正是 `.ninfer` 里 `gguf_blocks_v1` 布局的来由。

### 2.3 本机构建身份

| 项 | 值 |
|---|---|
| 源树（**旧，2026-10-21 起生产改用 `~/ninfer-build/kvmem-base-20261021`，见 §14**） | `~/ninfer-build/src-5258/swift15/engine/`（**2026-10-12 实测**：生产分支 `upgrade-013-20261005` @ **`c7f5a1b`** = `origin/main`（`7fdbbb7`）**+ 2 条本地移植的上游修复**（本机 fork 的本地提交，非来自 origin）；工作区干净。实验分支保留：`endpoint-anchor-20261012`（`e88e2b5`，端点锚移植，未采用）、`upstream-cache-fixes-20261012`（`c0bb9ae`））。**⚠️ 永不对 `origin/main` 做 `merge --ff`**（2026-10-13 实测：上游 `78b2544e` 虽名为懒人包发布，但在引擎子树上把上面两处修复**逐字回退** —— `git diff c0bb9ae^ 78b2544e` 在这 2 个文件上为空；`rev-list origin/main..HEAD -- swift15/engine` = **1**，正是这处移植） |
| 构建配置 | `CMAKE_CUDA_ARCHITECTURES=UNINITIALIZED=120a` · `CMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc` · Release |
| 二进制 | `build/apps/ninfer-serve`（**2026-10-12 23:13 重编换件**：源 = 生产分支 `upgrade-013-20261005` @ **`c7f5a1b`**（= `7fdbbb7` **+ 2 条本地移植的上游 context-cache 修复**：`e4cbf1e2` 抛错→优雅阻塞 + 满池 retain、`7649ce34` 独占锚额度守卫），sha256 **`f6c8b6bea627e76356eb16f87b9326af03c7f467`**，启动横幅 `build bonsai2-v0.1.5-2-gc7f5a1b`。**换件验收（实测）**：启动参数行（`KVMem allocation` / `context cache`）与产线日志**逐字相同**；复用回归**逐项与旧件相同**（工具 6,752/6,803、同文重发 6,649、冷启动 0）⇒ §9/§10 性能与容量档案不受影响（改动只在错误路径/保留决策/额度计数）。**上一代**（2026-10-10 登记、2026-10-12 23:13 退役）：编自 `5bb1516`，mtime `2026-10-05 22:47`，sha256 `d468690125ede9736e38beebc3805a83d3b97e63c5220e1420b923203d0bcfd7`，横幅 `build bonsai2-12g-v0.1.4`（该件的回滚副本 = `~/vault-backup/ninfer-binary-pre-upstream-fixes-20261012/ninfer-serve`）。**旧登记值「组合版 sha256 `8d793703103a38a4…`」已被取代** —— 10-04 组合版原物已迁 NAS 留档、本地已删除） |
| 架构实证 | `cuobjdump --list-elf` → `device_calibration.sm_120a.cubin` 等；`strings` 701 处 `sm_120a` |
| 源码规模 | **1,273 文件 / 221,272 行 / 629 个 `.cu`** |

---

## §3 源码模块地图（10 大模块）

```
src/
  ops/           930 文件  112,443 行   ← 算子层（最大）
  models/        141 文件   57,028 行   ← Qwen3.5 模型实现
  runtime/        41 文件   16,417 行   ← 引擎核心 / 调度 / 准入
  serve/          53 文件   15,578 行   ← HTTP 服务与协议翻译
  core/           56 文件   11,858 行   ← 显存/张量/KV 池/解码图基础设施
  artifact/       21 文件    2,592 行   ← .ninfer 容器读取
  product/        18 文件    2,598 行   ← 日志/诊断
  media/           4 文件    1,111 行   ← 图像视频预处理
  calibration/     2 文件      967 行   ← 按卡路线校准
  text/            7 文件      680 行   ← 分词
```

### 3.1 `ops/` —— 算子层（29 个子目录）

```
attn_input_proj  candidate_selector  context_kv_materialize  dynamic_grouped_conv
gdn_gating_proj  gdn_input_proj      kernel/  launcher/      linear/  linear_add
linear_attention linear_pair         linear_swiglu            linear_topk
rmsnorm_rope     softmax_attention   span_accumulate          sparse_moe
kv_cache         common/  wrapper/
fp8_sm86_stubs.cpp  nvfp4_sm86_stubs.cpp     ← 按架构裁剪的桩
```
`kernel/` 下有 31 个 `.cuh` 专用于本模型：`gdn_gating` / `hadamard_transform` / `mtp_pack` /
`paged_kv_window` / `speculative_round` / `target_logprobs` / `vision_pos_embed` …

### 3.2 `models/qwen3_5/` —— 模型实现主线

```
frontend/    execution/    load/    state/    program/     ← 五层
program/
  program.cpp/.h        总装
  prefill.cpp           预填
  decode.cpp            解码
  graphs.cpp            计算图装配
  context_work.cpp      上下文工作
  prefix/               前缀复用（hybrid 缓存）
  planning/             规划层 ★
  retrieval/            内容检索 ★
  transactions/         页事务 ★
  speculative/          投机解码 ★
  storage/              KV 存储
  vision_control.cpp    视觉控制
  round_buffers.cpp     轮次缓冲
```

**四个关键子层**：

| 子层 | 文件 | 职责 |
|---|---|---|
| `planning/` | `startup.cpp`·`request_plan.cpp`·`pressure.cpp`·`pressure_planner.cpp`·`graph_profiles.cpp` | **参数校验 + 容量规划 + 压力决策** |
| `retrieval/` | `block_retrieval.cpp`·`kv9_score.h`·`kv9_plan.h`·`query_span.h`·`media_window.h` | **内容检索（打分 → 选块）** |
| `transactions/` | `capture.cpp`·`commit.cpp`·`materialization.cpp` | **设备/主机页事务** |
| `speculative/` | `mtp.cpp`·`mtp_adaptive.h`·`mtp_alignment.h`·`target_verification.cpp`·`lookup_draft.h` | **投机解码** |

### 3.3 `core/` —— 基础设施（关键文件）

```
paged_kv_cache.cpp/.h      分页 KV 缓存
cyclic_kv_cache.cpp/.h     环形 KV（窗口复用）
host_kv_arena.cpp/.h       主机侧 KV 池（pin 住的）
paged_kv_gather.cu         页批量搬运（gather）
evictable_kv_pool.cu       可驱逐 KV 池
evictable_weight_pool.cu   可驱逐权重池
disk_kv_store.cpp/.h       磁盘 KV 层
decode_graph.cpp/.h        解码期 CUDA graph
linear_attention_state.cpp 线性注意力状态（GDN）
resident_memory.cpp        常驻内存管理
stage_link.cu / stage_plan.h  多卡流水级
arena.cu                   显存分配器
```

### 3.4 `artifact/` —— `.ninfer` 容器

支持的权重布局（`formats.cpp`）：

| layout | 用途 |
|---|---|
| `gguf_blocks_v1` | **保留 GGUF 块格式**（IQ3_S 主体，386 张） |
| `row_split_k128_v1` | 按 K=128 切行（旋转/分组量化，132 张） |
| `row_split_panel4_v1` | 4 面板行切 |
| `row_scale_v1` / `block_scale_k16_m128x4_v1` | 行/块缩放（NVFP4 系） |
| `contiguous_le_v1` | 连续小端（小张量，725 张） |

管线：`reader.cpp` → `schema.cpp`（校验）→ `layouts.cpp` → `materializer.cpp` → `binder.cpp`（绑到语义名）

---

## §4 全流程 A：启动链路

```
① 解析 argv              serve/serve_options.cpp  parse_serve_options()
② 语义校验               models/qwen3_5/program/planning/startup.cpp  validate()
      · max_context ≤ 4 × 原生窗口（否则 FATAL）
      · kv_capacity 在 [window_pages×64, 并发×逻辑页] 内
      · spec 后端与模型 draft 组件必须匹配
      · compute_capability ∈ {80, 86, 89, 120}
③ 读容器                 artifact/  reader → schema → layouts → materializer → binder
④ 装载权重               10.9–11.2 GiB（本机 Swift）
⑤ 校准路线               calibration/  →  ~/.cache/ninfer/device-profiles.json
⑥ 规划 KV                planning/  →  host_kv_arena  pin 主机池（本机 16 GiB / 2.1 s）
⑦ 起 HTTP                serve/http_server.cpp  +  generation_service
⑧ ready                  "capacity | KV …" + "engine ready"
```

### 4.1 步骤 ⑤ 是本引擎最大的差异点：**按卡现场校准**

本机校准产物 `~/.cache/ninfer/device-profiles.json`：

```json
{
  "schema": "ninfer.device-route-profiles", "schema_version": 2,
  "devices": [{
    "hardware_class": "nvidia-geforce-rtx-5060-ti-sm120",
    "multiprocessors": 36,
    "origin": "calibration",
    "calibration": { "route_catalog": "ac2d7b3e311831b0",
                     "ninfer_build": "e1eb49e", "cuda_driver": 13040,
                     "date": "2026-10-03T12:28:45Z" },
    "routes": { "attn_i8_small/h24/int8/w1": [[1048576, ""]], … }   ← 46 条
  }]
}
```

即：**首次启动在本机跑一遍测速，为每类算子选内核与 split-k 宽度**。
源码 `route_table.h` 注释：「unified 模板表是在 **RTX 5090** 上量的；legacy 表是本线在自己的内核上调出来的」。
→ 与 llama.cpp 的**编译期启发式**形成对比。

### 4.2 步骤 ② 的关键硬约束（源码实测）

| 约束 | 源码位置 | 行为 |
|---|---|---|
| 位置容量 | `startup.cpp:951-960` | `kPositionExtension = 4`；`max_context > 4×原生` → `FATAL max_context exceeds the configured position capacity` |
| draft 位置 | 同上 | 选中 draft 时另按 `4×draft.max_position_embeddings` 检查 |
| KV 容量下限 | `startup.cpp:998-1007` | 有环时下限 = `window_pages × 64`；上限 = `并发 × 逻辑页` |
| 规格匹配 | `startup.cpp:1030-1045` | `--spec dflash` **被 KVMem 拒绝**：`KVMem requires one or two lanes with none, MTP or DFlash2 speculation` |
| 架构门 | `startup.cpp` | `{80, 86, 89, 120}`，注释自认「**能正确跑，不是为它调优**」（occupancy/split-k 仍是 sm_86 那套） |

---

## §5 全流程 B：请求链路

```
HTTP 请求
  ↓  serve/http_server.cpp
  ↓  协议翻译层
      openai_chat_request.cpp       /v1/chat/completions
      openai_responses_request.cpp  /v1/responses（含 responses_store 会话态）
      anthropic_messages_request.cpp /v1/messages
  ↓  request_validation.cpp   校验
  ↓  structured_output.cpp    xgrammar 约束解码（若要求 JSON）
  ↓  generation_service
  ↓  runtime/engine/engine.cpp
      · admission_policy.cpp   准入
      · scheduler.h            调度（单槽 / 多并发）
      · context_cache/         上下文缓存复用
  ↓  models/qwen3_5/program/
      ① planning/request_plan.cpp    本次请求计划
      ② prefill.cpp                  预填（分段 128 对齐）
      ③ retrieval/                   内容检索（见 §6）
      ④ speculative/mtp.cpp          投机轮
      ⑤ target_verification.cpp      目标验证
      ⑥ decode.cpp + core/decode_graph.cpp   CUDA graph 解码
      ⑦ sampling_device.cuh          设备侧采样
  ↓  响应装配（openai_chat_response.cpp / …）
  ↓  统计行   req#N done | … | mtp accepted a/b
```

### 5.1 实测统计行（本机）

```
req#1 done | openai-chat | stop token | prompt 1,133 | output 800 | cache 0 (0.0%) |
  TTFT 1.2s | total 8.5s | prefill 918.9 tok/s | decode 109.9 tok/s | mtp accepted 639/640 (99.8%)
req#2 done | openai-chat | tool calls 1 | prompt 276 | output 26 |
  TTFT 436 ms | total 662 ms | prefill 644.2 tok/s | decode 110.5 tok/s | mtp accepted 20/20 (100.0%)
```

> [!info] 以上为**厂商参数基线**（2026-10-04 调优前）。当前生产（调优后 + `int8` + 无视觉）：
> `prompt 1,133 | output 800 | TTFT 1.2s | total 8.0s | prefill 921.5 tok/s | decode 117.6 tok/s | mtp accepted 638/639`
> 即 **decode +7.0%**，prefill 持平。详见 §10.2。

---

## §6 全流程 C：KVMem 页级检索链路（本引擎的核心创新）

### 6.1 三个池

| 池 | 参数 | 本机值 | 性质 |
|---|---|---|---|
| **设备池** | `--kv-capacity N\|auto` | `auto` → 66,176 token | 显存里放多少 token 的 KV（64 token = 1 页） |
| **逻辑上下文** | `--max-context N` | 262,144 | 单请求上限 |
| **主机池** | `--host-kv-mib N` | 16,384（16 GiB） | **真实 pin 住的 RAM** |
| **工作集窗口** | `--kvmem-window-pages N` | **1,000 页 ≈ 64K token** | 稀疏工作集（0 = 稠密语义） |

### 6.2 启动期

```
KVMem kv9 | Eq.10 query rows 192.0 MiB pinned (lane 0)
KVMem allocation | window 1000 pages | sink 2 | prompt share 1000 | output reserve 0 | long reuse off
host KV pinned | 16.0 GiB | 2.1s
capacity | KV 66,176 tokens, int8, explicit | pages 1,034/4,096 | runtime 3.71 GiB | free 487.6 MiB
```

### 6.3 请求期（检索证据）

```
KVMem kv9 | segs 2 (stash 0, eq10 2, 157 ms) | protect 6103/6096 tok, 3 ranges, 49 blocks |
  budget 94 blocks, recent 66 pages | replay yes | merge split |
  [3,515) top 78976,79104,79232; [157938,157951) top 78976,79104,79232;
                            ↑ 按相关性选出来的块
```

### 6.4 机制（源码 `implementation.md` §5 原文）

```
· 注意力跳过不在显存的空洞页
· 页面从内存搬上显卡时批量拷贝（gather），按碎片程度自动选用
· 精简 MTP 输出头做成可选项（+10.5%）
```

### 6.5 多轮复用（§3 原文）

```
· 单次输出整段预留在显存里，不会被挤出去；开头（系统提示）固定保留
· 历史超出窗口以后，多轮对话只重算新内容
· 6 万 token 的对话，接着问每轮从约 140 秒降到 2–4 秒
```

**本机实测**：8K 连发 3 次 → `#1 cache_n=0 / 3.77s` → `#2 cache_n=4211 / 0.13s` → `#3 cache_n=4211 / 0.13s`

> [!warning] ⚠️ 2026-10-12 更正：上面这组（以及 pitfall #14 的 `99.6%/133ms`）**出自 10-05 22:47 重建之前**的构建。
> 现役件（`5bb1516`，即「基线 + 摘入 `209c75b` 的 serve 层」）**不带 `--derive-session-keys` 时跨请求复用恒为 0**
> （实测：同一 4,436-token prompt 连发两次 `cache_n = 0 → 0`、`prompt_ms 3991 → 3910`，即每次全量重算）。
> **根因（源码+运行时双证）**：KVMem 窗口模式（`--kvmem-window-pages != 0`）下引擎的结构性闸门
> （`request_plan.cpp:770-785`）**只拒「共享前缀」路**，放行「私有会话续写」路；而会话键只在
> **`--derive-session-keys`** 打开时派生（`serve_options.h:107` 默认 false；来源 = `hash(system 全文 + 第一条 user)`
> 见 `translate.cpp:376-400`）⇒ 未开 = 匿名请求只能走被拒的共享路。**客户端无任何字段能设会话键**
> （`x-conversation-id` / `user` / `prompt_cache_key` 均被忽略，实测四种形态全 0）。
> **修法**：启动加 `--derive-session-keys`（2026-10-12 已落地到 `start-prod.sh`）。加后实测（同 prompt 连发两次）：
> 4.6k `4.2s→0.3s`／72k `75.4s→0.33s`（230×）／134k `149.8s→0.31s`（**478×**）；日志路径标签变为
> `cache 17004 (100.0%, turn closure)`；显存不变（15,424 vs 15,358–15,492 MiB）。
> **代价**：复用令 `temperature=0` 采样不可复现 ⇒ 质量/参数 A/B 必须带 nonce 或临时关复用。
> ⚠️ 归属**推断**（无法复跑旧件）：10-05 重建摘入的 `209c75b`（`request_plan.cpp` 窗口分支跳过 endpoint 候选）
> 很可能就是打断那次生效的那一刀 —— 与 pitfall #14 指向同一 commit。
>
> 🚨 **2026-10-12 定位结论（更正同日早先的错误归属）**：限制的**真正触发条件不是"工具调用"**，而是
> **「中间有一个请求把会话端点前移，之后从旧端点分叉」**（⚠️ 只对应**同处换问法**的**兄弟分叉**——即"重新生成 / 改最后一条消息"这类；**真实工具往返的下一轮本身正常复用**，见下方收尾块）。决定性对照（同一实例，唯一变量=中间请求动不动端点）：
>
> | 序列 | 第 3 步：从旧端点分叉 | 结果 |
> |---|---|---|
> | X：中间插一个"探测"（**端点被前移**） | 12,930 token | **`cache_n=0` → 全量重算 11.7 s** ❌ |
> | Y：中间只做"同文重发"（端点不动） | 6,340 token | **`cache_n=6590` → 复用，5.9 s** ✅ |
>
> `NINFER_MAT_DEBUG=1` trace 佐证：序列 Y 里第 3 步打印
> `[candgen] priv SKIP slot=0 DIGEST-MISMATCH frontier=6927` → `priv BUILD slot=0 reuse_tok=6891`；
> 序列 X 里没有任何 `priv BUILD`，只有被拒的共享候选（`KVMem reuse refused | shared source`）。
> （早先那条"工具调用后不复用"的结论由此**作废**：工具历史本身不阻断复用，同文重发含工具也能命中。）
>
> ✅ **别人已经修过，诊断文字逐字相同**：上游 `iamwavecut/ninfer-all` 提交 **`ca0c2afd`（2026-10-06）
> "feat(context-cache): resume a sibling branch from the turn it diverges at"** —— 原文：
> *"A request that resumes a retained conversation at its endpoint moves the endpoint with the conversation…
> a later request that diverges right at the old endpoint found no checkpoint between root and the new turn
> and **re-prefilled the whole conversation**: 5.5 s for a branch of a 24K-token conversation on an RTX 5090."*
> 修法 = **`endpoint_anchors`**（默认开启，`--no-endpoint-anchors` 关）：恢复端点并延伸时，把该端点保留为
> **private long anchor**（在 suffix prefill 之前从被恢复的状态取得，不增加 prefill split），
> 之后在旧端点分叉的请求从该 anchor 恢复而不是从 root 重算。上游实测：30.7K 对话分叉首字
> **9.4–9.5 s → 108–110 ms**；24K 对话分叉 **5.52 s → 0.12 s**（复用 24,067 token）。
> 该提交明写**就是为 C=1/H=1 这种缓存规模设计的**（本机生产正是 C=1、H=1）。
>
> **我们这条线的缺口**：`endpoint_anchors` **0 命中**（只有 `automatic_long_anchors`，7 文件；`long_anchor` 25 文件、
> `PrivateLongAnchor` 10 文件 ⇒ 锚机制本身**存在**，缺的是"端点锚"这一层）。改动规模参照上游该提交：
> **20 文件 +501/−43**（核心约 **131 行 / 7 文件**：`resource_manager.h` +70、`materialization.cpp` +22、
> `engine_core.h` +21、`serve_options.cpp` +9、`model_instance.cpp` +6、`program_impl.h` +2、`request_log.cpp` +1；
> 其余 262 行为测试）。**我们线上的真实改动面未测**（要试打才知道），且必须先让闸门放行 anchor 路径
> （`request_plan.cpp:781-782` 目前只放行 `PrivateEndpoint || rewrite`，anchor 落进 `refuse` 分支）。
> 验收代价：重编（单文件 3.9 s 实测；链接未测）＋ 引擎锁定件一变 ⇒ 手册 §9/§10 全部实测档案需重测、250K 召回需重跑。
>
> ### 🧪 2026-10-12 收尾：上游端点锚**已移植并实测** ⇒ 在本 fork 上**惰性**，**未上产线**
>
> **做了什么**：把上游 `ca0c2afd` 移植进本 fork（分支 `endpoint-anchor-20261012`，提交 `e88e2b5`；19 文件 +686/−35；编译通过、单测 11/12，唯一失败项经回滚复核为**移植前既有**）。**未推送、未上产线。**
>
> **实测（侧端口 8092，产线同参数）**：
>
> | 场景 | 结果 |
> |---|---|
> | **真实工具调用往返 + 下一轮**（= Hermes 主形态；产线参数、**未加任何新开关**） | ✅ **99.2% / 99.7% 复用**（路径标签 `turn closure` / `response replay`） |
> | 纯文本多轮增长 / 同文重发 | ✅ 99%+ |
> | **兄弟分叉**（同一处换问法） | ❌ **0**（移植前后**都是 0**） |
> | `--preserve-thinking` / `--auto-long-anchors` / `--max-private-continuations` / `--device-state-slots` | ❌ 同脚本 A/B **逐项相同**，均无收益 |
>
> **为何这枚补丁在这里失效**（`NINFER_ANCHOR_DEBUG=1` 插桩实测）：锚的闸门是
> `program.matched_prefix_tokens(*entry.handle, prompt) < endpoint`，而 `endpoint` 记的是**整段已执行续写的 frontier**——**含模型生成的隐藏推理 token**；客户端回传的历史**不带推理块** ⇒ `matched` 永远停在 prompt 末尾。
> 定量：`endpoint 6715 − matched 6652 = 63`，**正好等于被剥掉的推理长度（62 token）**。
> ⇒ 该特性的前置假设是"**客户端复现了生成的 token**"（= 无思考，或回传推理）；上游自己的实测也是无推理场景（8 输出 token）。
>
> **行业依据（2026-10-12 查证）**：① **Anthropic 官方**：开 thinking 时**推理块必须逐字回传**，否则前缀失效（*"thinking blocks … must be passed back verbatim"*），并给出按轮保留的 `clear_thinking` 配额控制；② **vLLM issue #39321**：*"Reasoning model thinking tokens pollute prefix cache with unreachable entries"* —— 承认是已知问题，方向是**把推理 token 排除出缓存**；③ 主流引擎（vLLM APC / SGLang / llama.cpp）把缓存建在**输入前缀**上，故天然免疫。
>
> **⚠️ 本页早先两处表述已作废**：① 「工具调用后不复用」——**错**（真实工具调用正常复用；该结论出自**手工编造的工具历史**，且其中一轮**混用了思考开关**——而换思考配置本身就会使前缀失效）；② 「Hermes 每一轮的真实形态都触发该限制」——**错**，只剩兄弟分叉。
>
> **产线最终状态**：**二进制已复原**（sha `d468690125ede973…` 逐字符一致），本 fork **不含**该补丁；生产保留 `--derive-session-keys`（有效）。**是否为"兄弟分叉"这唯一窄场景做原创引擎语义改动 —— 已判：不做。**
>
> ⚠️ **后续（2026-10-12 23:13）**：产线件已换为**另一组上游修复**的重编件（`e4cbf1e2`：`throw` → 优雅 `TemporarilyBlocked` + 满池 retain；`7649ce34`：独占锚额度守卫）——见 §2「二进制」行。**端点锚补丁仍未上产线。**

> [!danger] 窗口大小决定一切（本机踩过的坑）
> 同一模型、同一题：`--kvmem-window-pages 256`（≈16K 工作集）时 158K 中段针**答残缺**（`BLUEBIRD-42` → 只吐 `ORANGE-7`）；
> 换成生产值 **1000 页（≈64K）**后，**同一档 + 200K + 250K 全部命中**。
> **结论**：在窄窗口下得出的「长文不稳」是窗口假象，不是引擎缺陷。

---

## §7 关键机制汇总

| 机制 | 实现位置 | 本机实测效果 |
|---|---|---|
| **按卡路线校准** | `calibration/` + `route_table.cpp` | 46 条路线，首启自动测速 |
| **页级稀疏注意力** | `ops/softmax_attention/` + `paged_kv_window.cuh` | 长文 prefill 不掉速：250K 仍 811 tok/s |
| **解码期 CUDA graph** | `core/decode_graph.cpp` | 整步捕获，一次 launch |
| **prefill 分段对齐 SM** | `planning/startup.cpp`（`NINFER_PREFILL_ALIGN`） | 避免最后一批空转 |
| **投机解码 MTP** | `speculative/mtp.cpp` | 接受率 81.8–100%（本机） |
| **投机解码 DFlash2** | `speculative/` + 5 层 draft 组件 | 本机实测**比 MTP 慢**（见 §9） |
| **主机侧 KV pin** | `core/host_kv_arena.cpp` | 16 GiB / 2.1 s |
| **词嵌入放主机** | `--embedding-host` | 省 ~360 MiB（实测 388.4 MiB zero-copy） |
| **可驱逐权重池** | `core/evictable_weight_pool.cu` | 视觉塔 overlay |
| **磁盘 KV 层** | `core/disk_kv_store.cpp` | 未启用（本机） |
| **多卡流水** | `core/stage_link.cu` + `--devices` | **Linux-only**；**拒绝 DFlash2 与 vision** |
| **结构化输出** | `serve/structured_output.cpp`（xgrammar） | 未启用（本机） |

---

## §8 模型侧架构（本机在役的 Swift 模型）

> 详表见 `~/models/qwen3.8-27b-swift/MODEL-INFO.md`；此处只留与引擎相关的部分。

```
主干   Qwen3_5ForCausalLM · 64 层（48 线性注意力 + 16 全注意力，模式 LLLF×16）
       hidden 5,120 · vocab 248,320 · max_pos 262,144 · 24 heads / 4 KV heads
组件   text 10.948 GiB · dflash2 2.074 · proposal 0.352 · mtp 0.324 · vision 0.275
容器   1,249 对象（weight 1,242）· 1,513 bindings · 布局 gguf_blocks_v1 386 张
```

**引擎与模型的耦合点**：引擎的 `--spec mtp|dflash2` 直接对应容器里的 `mtp` / `dflash2` 组件；
`--lm-head-draft` 对应 `proposal` 组件（`domain: indexed`, `rows: 131072`）；
`--vision` 对应 `vision` 组件。**换 spec 就是换组件，不是换参数。**

---

## §9 本机实测数据（全部 verified）

> [!info] 9.1–9.3 为**厂商参数基线**（2026-10-04 调优前）。调优后的对照见 §10.2；差异仅 decode（+7.0%），
> prefill 与 KV 容量实测不变，故阶梯/资源表仍适用。

### 9.1 速度

| 场景 | prefill | decode | 备注 |
|---|---|---|---|
| 数数字 1000 出 | 918.9 tok/s | **109.9 tok/s** | MTP 接受 639/640；调优后 **117.6** |
| 散文 8K | 1,137.6 | 65.0 | |
| 散文 64K | 956.5 | 59.3 | |
| 散文 250K | 811.1 | 56.2 | |

> [!warning] 上面「数数字」与「散文」两行的 decode 差近一倍（109.9 vs 65.0）**不是配置差异，是语料差异** ——
> 数数字续写高度可预测，草稿命中率极高。**判 decode 好不好必须看语料**；做参数对照必须固定语料。

### 9.2 长上下文阶梯（中段针，全命中）

| 档 | 8K | 32K | 64K | 126K | 158K | 200K | 250K |
|---|---|---|---|---|---|---|---|
| prompt | 8,439 | 33,639 | 63,879 | 124,359 | 157,959 | 195,759 | 247,839 |
| prefill | 1,137.6 | 1,051.7 | 956.5 | 824.9 | 820.0 | 816.3 | 811.1 |
| wall | 7.5s | 32.1s | 66.9s | 150.9s | 192.7s | 240.0s | 305.8s |

### 9.3 资源

| 项 | 值 |
|---|---|
| 显存（当前生产：`int8`、无视觉） | **15,454** MiB 刚启动 → **~15,520** 跑过请求后（进程 15,458 + 驱动 ~66） |
| 显存（调优前：`rk8v4` + 视觉） | 15,382 MiB（余 1,001.6 MiB） |
| 主机 pin | 16.0 GiB |
| 启动到就绪 | 64–70 s |
| 词嵌入 | host RAM 388.4 MiB (zero-copy) |

### 9.4 与旧栈（llama.cpp + KVMem）同题对照

| 档 | 本地 prefill | NInfer | 本地 decode | NInfer | 倍数 |
|---|---|---|---|---|---|
| 8K | 874.0 | **1,137.6** | 44.9 | **65.0** | 1.45× |
| 126K | 637.7 | **824.9** | 36.8 | **57.0** | 1.55× |
| 250K | 616.3 | **811.1** | 36.2 | **56.2** | 1.55× |

> [!warning] 可比性的诚实声明
> 两边**参数不同**（KV `q8_0` vs `rk8v4`、draft 3 vs 4），**不是同参对照**；
> 且模型不同（GSQ 原版 vs Swift 微调版）。**倍数只能当量级参考。**

### 9.5 质量评测（26 题 × 3 次，程序化判分）

| 档 | 思考 | 满分 |
|---|---|---|
| 基础 12 题 | 关 | 11/12 |
| 难度 8 题 | 关 | 7/8 |
| 宣称强项 6 题 | 开 | 6/6 |
| **合计** | | **24/26** |

---

## §10 生产配置与运维

### 10.1 本机生产启动参数

```bash
# ~/models/qwen3.8-27b-swift/start-prod.sh（2026-10-04 调优后，实测生效）
--host 127.0.0.1 --port 8090 --model-id qwen3.8-27b
--max-context 262144 --kv-capacity auto --kv-dtype int8 --host-kv-mib 16384
--kvmem-window-pages 1000 --device-state-slots 1 --derive-session-keys --prefill-chunk 1024
--spec mtp --draft-tokens 4 --max-concurrency 1
--fast-prefill-kernel --mlp-a8-decode --lm-head-draft --adaptive-mtp
--default-max-tokens 32768 --default-reasoning-effort none
--presence-penalty 0 --temperature 0.7 --top-p 0.9 --top-k 20
--gdn-state-fp16 --embedding-host --cuda-graph-allowance-mib 144
# 注意：无 --vision（2026-10-04 起默认屏蔽）、无 --max-shared-prefixes 0（已改回引擎默认）
# ★ --derive-session-keys：2026-10-12 加入（跨请求前缀复用的必要条件，见 §6.5 更正块）
```

**启动就绪读数**（可据此判断配置一致）：
```
KVMem allocation | window 1000 pages | sink 2 | prompt share 1000
pinning host KV | 16.0 GiB
capacity | KV 66,176 tokens, int8, explicit | pages 1,034/4,096 | runtime 3.71 GiB | free 487.6 MiB
```
显存：刚启动 **15,454 MiB** / 跑过请求后 **~15,520 MiB**（其中引擎进程 ~15,458、其余 ~66 MiB
为驱动/framebuffer 不归属进程；`nvidia-smi --query-compute-apps` 可分开核对）。总容量 16,311 MiB。

### 10.2 2026-10-04 调优：改了什么、为什么

五项启用（逐档真重启 69s 实测，非默认值推导）：

| 开关 | 依据 | 实测 |
|---|---|---|
| `--lm-head-draft` | 5258 分支 benchmarks「输出头精简 → +10.5%」；上游全部发布测量均用它。**厂商 MTP 启动器漏掉** | 组合后 decode **+7.0%** |
| `--adaptive-mtp` | help 明示 `greedy output is unchanged` | 无质量代价 |
| `--fast-prefill-kernel` | `int8`/`rk*` KV 走快速 prompt-attention 内核 | 本机 dtype 符合 |
| `--mlp-a8-decode` | 解码/校验期 MLP gate_up 走整数激活 | 质量题无退化 |
| ~~恢复共享前缀默认~~ | 厂商 `--max-shared-prefixes 0` 关掉了共享前缀目录 | ⚠️ **2026-10-12 更正：此条与「多轮复用生效」无因果**（详见 §6.5 更正块） |
| **`--derive-session-keys`** | 跨请求前缀复用的**必要条件**：KVMem 窗口模式下闸门只拒共享路、放行私有续写路，而会话键只在本 flag 打开时派生 | **实测 4.6k→478× 加速（见 §6.5）**；2026-10-12 已加入 `start-prod.sh` |

`--kv-dtype`：`rk8v4` → **`int8`**。KVMem 只接受 `int8`/`rk8v4`/`rk4v4` 三档，**`int8` 是其中精度最高**（键 8-bit / 值 8-bit；`rk8v4`/`rk4v4` 的值只有 4-bit）。实测速度为噪声内持平（数数字 117.6 vs 117.1；散文 49.6 vs 48.6 tok/s）。代价：runtime 3.20 → 3.71 GiB，显存余量 1,001.6 → 487.6 MiB。

视觉：`--vision` **默认屏蔽**（2026-10-04）。省 442 MiB（15,382 → 14,940 MiB），KV 容量/decode/prefill 全不变 —— 视觉塔不在文本路径上。需要时 `VISION=--vision ./start-prod.sh`。

**质量验收（当前 int8 生产配置，12 题 × 3 次）**：**11/12 满分**，唯一失分题 `I2_十字句`（汉字数 8 / 期望 10）**与厂商参数基线同一题** → 调优与 `int8` 均未引入新的质量退化。工具调用 `finish=tool_calls` 正常。

### 10.3 试过并【撤掉/否决】的（负结果，勿重复踩）

| 尝试 | 结果 | 数据 |
|---|---|---|
| `--prefill-cublas` | ❌ **无收益，有代价** | prefill 8K/32K/64K/126K：1138→1141 / 1052→1055 / 957→958 / 825→831，全在噪声内（+0.2~0.7%）；fork 自述代价 `+0.156% perplexity`。原因是它要求配套大 `--prefill-chunk`（fork 推荐 4096），本机连 2048 都放不下。**⚠️ 结论仅限本 27B 单卡线** —— 2026-10-06 在**双卡 Ornith-35B-A3B pipeline** 上重测（那里 chunk 2048 起得来），符号翻正：prefill **+2.8~9.1%**（越深越小），见 [[20_Tech_Stack/ornith-1.5-35b-a3b-ninfer_manifest\|Ornith NInfer 手册]] §4。**约束会随拓扑变，勿跨机器搬负结果。** |
| `--prefill-chunk 2048` | ❌ 起不来（**不带 cublas 也一样**） | `FATAL runtime reservation requires 4413001985 bytes, but only 4143579136 available`；KV 池从 66,176 涨到 66,944 tokens 吃掉了余量 |
| `--kvmem-window-pages 1600` | ❌ 起不来 | 需 4,505,870,592 B，仅 4,439,277,568 可用（**差 66 MB**） |
| `--draft-tokens 6/8/12` | ❌ **数数字语料说好，散文反转** | 数数字：draft6 **127.7** vs draft4 117.1（+9%）；散文：draft4 **48.6** / draft6 **46.2**（−5%）/ draft8 40.4（−17%）。接受率虽升（31%→33.4%）但验证开销更大 |

> [!warning] 深草稿的收益是任务相关的 —— 别用可预测语料定 draft 宽度
> 「数数字」这类续写高度可预测，会系统性偏袒深草稿。**判 draft 宽度必须用不可预测的负载（自由创作）**，否则会得出反向结论。

### 10.4 与厂商标准的被迫差异

| 项 | 厂商 | 本机 | 原因 |
|---|---|---|---|
| `--kv-dtype` | `k8v4` | **`int8`** | 本引擎 KVMem 硬拒 `k8v4`：`FATAL: KVMem requires --kv-dtype int8, rk8v4 or rk4v4`；三档里取精度最高的 `int8` |
| `--kv-capacity` | `17920`（显式） | **`auto`** | 厂商按其 9.55 GiB 模型算；本模型 13.98 GiB |
| `--kvmem-window-pages` | 不存在 | **`1000`** | 变体 A/B 机制不同，不可混用 |
| env 变量 | 5 个 `NINFER_KV_*` | **0 个** | 同上 |
| `--vision` | MTP 档不带 | **不带**（2026-10-04 起） | 省 442 MiB；旧 GSQ KVMem 对等期曾开 |
| `--prefill-cublas` | 部分档带 | **不带** | 实测无收益（见 §10.3） |

### 10.5 运维命令

```bash
ninfer-serve [GPU=0] [PORT=8090]   # 启动（独立 systemd unit）
ninfer-stop                        # 停止
journalctl --user-unit=ninfer-prod --since "-10min"   # 日志
```

> [!danger] 必须用独立 systemd unit
> Hermes 的 `terminal(background=true)` 会把进程包进 `hermes-worker-*.scope`，
> 其 `MemoryMax = min(4 GiB, 物理内存/2)`（硬编码）。
> ninfer 需 43 GiB 虚拟地址空间 → **撞 4 GiB 上限被内核 cgroup OOM 杀**，而 `free` 仍显示 50 GiB 可用。
> 诊断：`dmesg -T | grep -A1 oom-kill` → `constraint=CONSTRAINT_MEMCG` + `oom_memcg=.../hermes-worker-*.scope`。
> **`TERMINAL_LOCAL_MEMORY_MAX_MB` 只能调更小，不能放宽。**

### 10.6 Hermes 接入

```yaml
local-ninfer:                       # 经 ninfer-router(8099) 聚合，见 Ornith NInfer 手册 §6
  api: http://127.0.0.1:8099/v1
  name: Local-NInfer
  models:
    1card-qwen3.8-27b-swift-iq3s: { context_length: 262144 }   # -> 8090（本页模型）
    2card-qwen3.8-27b-coder390:      { context_length: 262144 }   # -> 8091（另一条引擎线）
  default_model: 1card-qwen3.8-27b-swift-iq3s
```

阈值提醒：Hermes 的 provider 配置**不设 `tool_choice`**（走默认 `auto`），因此 §11 坑 13
那类「强制工具」限制**在本机不触发**。

### 10.7 ~~双卡路线：三条都试过，结论是走 vLLM（2026-10-04）~~ —— ⚠️ 已两次被推翻（见本节末更新块）

本机两条 16GB 卡能同时用，但**NInfer 自家的双卡都不如 vLLM W4A4**。三条路线实测后
全部放弃，对应 45 GiB 产物已删（见 `log.md` 2026-10-04 12:20）。

| 路线 | 怎么跑 | 实测 | 为何放弃 |
|---|---|---|---|
| **流水线**（`--devices 0,1`） | v3 系 nvfp4 工件 | prefill 2.22×(1K) → **0.86×(126K) 反输**；decode **0.71×** | 层间走 `StagedHost`（卡0→主机内存→卡1）；`src/core/stage_link.h` 只有 `enum { StagedHost, Local }`，**无 P2P 传输** |
| **TP2**（`--tp 2`） | `wamansou/ninfer-tp2-1m` + **v2** 工件 | prefill **2–2.92×**（8K 3,324 / 126K 1,645）；decode ~113；P2P 26.7 GiB/s | ~~`--tp 2 + --spec mtp` 无前缀复用~~ → **2026-10-06 已被 BaiYouQing fork 推翻，见下** |
| **vLLM W4A4** | `nerkyor-nvfp4-w4a4-fast`，TP=2 | prefill 2,207(8K)；decode 63–153 | ✅ **保留** |

**决定性的一条 —— 前缀复用 A/B**（同脚本同 prompt≈4,820 token，各跑两次）：

```
vLLM W4A4   第1次 10.28s → 第2次 1.21s  =  12%（8.5× 提速）
NInfer TP2  第1次 11.35s → 第2次 11.35s = 100%（完全无复用）
```

TP2 的 `--tp 2 + --spec mtp` **文档明示禁用前缀复用**（MTP bridge 依赖只有主卡持有的
target hidden）。对 Hermes 这种「长 system prompt + 每轮追加」的负载，这**抵消了它的全部
prefill 优势**：每轮都要全量重算（32K 就要 11.35s），而 W4A4 只要 1.21s。

**当时的结论（⚠️ 已被推翻，保留作历史）**：TP2 只适合**单次长文档灌入**（离线批处理），不适合 agent 多轮。
NInfer 的价值在**单卡 KVMem 环**（§10.1），不在双卡配置。

> ### ✅ 2026-10-06 更新：上面这条结论**只对 `wamansou` fork 成立**
> `BaiYouQing/ninfer-tp2-5060ti-windows` **删掉了** `request_plan_impl.h` 里那句硬编码降级
> `if (tp != 1 && spec == Mtp) reuse = FullReset`，并让 MTP bridge 在两卡上都驱动 MTP 头
> （rank 1 用一次 UVA `cudaMemcpyAsync` D2D 拿到 retained frontier hidden）。
> **复测（同 prompt 重发）**：5.86 s → **0.08 s**（`cached_tokens: 18903`）；10 轮增长前缀**逐轮命中**
> （`cached = 上轮 prompt − 2`）；prefill **3,226 tok/s**（18.9K 冷启动）、decode **108.6**（MTP3）、
> ctx **262,144**（2026-10-11 起提到原生上限；此前 253,952）、启动 **~10 s**。
> **→ 该线 2026-10-06 已落地为生产模型 `2card-qwen3.8-27b-coder390`（端口 8091，unit `ninfer-tp2`）**，
> 经 `ninfer-router` 聚合；起停参数与重建步骤见 `~/ninfer-build/TP2-PRODUCTION.md`。
> **判据**：判一条线「不能做 agent 多轮」前，先确认**跑的是哪个 fork** —— 这次就是 fork 差异。

> ### 📊 2026-10-06 跨线开关复核（单卡 8090 vs 双卡 8093，一次一轴，全部真重启）
> 口径：固定语料（**真实变化文本**，15.9K tok）+ 定宽 nonce + 3 rep + 数值全部取自引擎日志。
> ⚠️ **语料不能用重复填充** —— 首版用「同段重复 260 次」恰好触发引擎的 `--lookup-ngram` 上下文查表草稿（日志出现 `mixed speculation accepted`），decode 被加成污染。
>
> | 开关 | 单卡 8090 | 双卡 8093(Ornith) | 处置 |
> |---|---|---|---|
> | `--lm-head-draft` | 已在用 | **+17~20%**（早前实测） | ✅ 两线保留 |
> | `--adaptive-mtp` | **关掉 +7.6%（67.3→72.4，3/3 同向）** | no-op | ❌ 两线移除 |
> | `--mlp-a8-decode` | **纯 no-op（逐位相同）** | 长上下文 **−7%** | ❌ 两线移除 |
> | `--fast-prefill-kernel` | **纯 no-op（prefill 1120.0×4 档全等）** | no-op | ❌ 两线移除 |
> | `--draft-tokens` | 4（接受率 ~57%） | **2 > 3 > 4**（181.2/170.4/161.6） | ⚠️ **保留差异**：单卡深、双卡浅 |
> | thinking | **模板默认档（= 开）** —— 2026-10-06 由 `none` 改 | **on**（关掉 −8.5% decode） | ✅ 三线现状一致（都开） |
> | `--draft-tokens` 逐值（第二轮补测） | 3≈4 > 5（3: 68.1/62.4/61.0、4: 67.1/62.1/59.2、5: 58.4/54.7/61.1） | **3 ≈ 4 > 2**（3: 87.2/85.2/85.2、4: 89.2/95.1/**66.7** 抖、2: 78.0/78.7/79.5） | 两线都**维持现状** |
>
> **第二轮补测（2026-10-06，同口径 + 「写长」指令使 out 全 256）三点**：
> ① **8091 的「浅草稿更快」不成立** —— draft 2 接受率反而最高（71~74% vs draft3 的 63~65%），但 decode 只有 **78.7** vs draft3 **85.2**：每轮草稿少 ⇒ 每轮产出的 token 少，接受率高也补不回来。**结论不可跨线搬。**
> ② **8090 `--draft-tokens` 3 ≈ 4**（3 略优 ~0.5~1.8%，三 rep 同向但量级在噪声内）；**5 明显更差（−6%）** ⇒ 维持 4。
> ③ **8090 的 thinking**：三态实测（同语料同长度）—— **off** 62.1 / **模板默认档** **95.2** / **`--default-reasoning-effort medium`** 66.3（med，tok/s）；接受率 **off 41~48% → 模板默认 47~68%**。即**开关 thinking 默认档能把 8090 的 decode 拉高约 53%**，而**显式 `medium` 没有这个收益**（66 ≈ 62）—— 收益来自「模板默认档」本身，不是「thinking 开着」这个布尔量，机制待查。
> **落地与复验（2026-10-06 23:50）**：8090 的 `--default-reasoning-effort none` **已删** → 改走模板默认档。复验（经路由器走生产路径）：
> `reasoning_content` 101 字符、`reasoning_tokens: 36`（thinking 确已开）；进程 argv 无该旗；`started` 行 4/4 = `thinking template default`；
> 同口径长请求 decode **79.2 / 59.3 / 78.0（中位 78.0 vs 改前 62.1，+25.6%）**。
> ⚠️ **收益机制修正**：增益**集中在「混合投机（ngram）介入的那几个 rep」**（78~99 vs 改前 62~67，接受率 57~68% vs 42~48%），
> **纯 mtp 的 rep 基本不变**（59.3 vs 59.2）。即「thinking 开」并不直接提速，而是让**推理文本更自相似 → ngram 草稿命中更多**。
> 所以上一轮报的「+53%」是单次 run 的中位，跨 run 保守读数是 **+25%**，且**没有 rep 变慢**。
> 回退：`~/.hermes/cache/scratch/` 无需动，改回 `~/models/qwen3.8-27b-swift/start-prod.sh`（备份 `.bak-20261006-2346`，即含 `REASONING_EFFORT=none`）。
>
> ④ 附带发现：**`mixed speculation`（含 ngram 上下文草稿）在真实文本 + 「写长」指令下也会自发介入**（8090 15 个长 rep 里 5 个是 mixed，8093 亦有），并非只由重复语料触发 —— 判读 decode 时必须把 `spec` 类型一并列出，否则会把 ngram 的加成记到被测开关头上。
> | `--default-max-tokens` | 32768 | 原 8192 → **改 32768** | ✅ 统一（Hermes 不发 max_tokens） |
>
> **结论**：三条线的**唯一跨线收益项是 `--lm-head-draft`**；其余开关要么单线专属、要么 no-op/负项。
> 「互相优化」的实际产出 = **两线合并删掉 3 个无效开关 + 统一输出上限 + 双卡线 draft 3→2**。
> 复现脚本（**已删除**，scratch 24h 自动清理）：`~/.hermes/cache/scratch/ab_params_v4.py`（含 v1~v3 的失败原因注释：忘了日志重定向 / 引擎 stdout 块缓冲 / 固定正则被换单位与 `queue` 字段打爆）。

**其他留档**：
- P2P 实测可用（`0->1 canAccess=1 / 1->0 canAccess=1`，26.68/26.71 GiB/s），
  但**旧流水线引擎没用它**；TP2 fork 用 UVA `cudaMemcpyAsync` D2D 才吃到。
- **20.58 GiB 的 nvfp4 工件单张 16GB 卡装不下**（需 19.4 GiB，仅 15.4 可用）→ TP2 是运行
  该工件的**唯一方式**；也正因如此它只能跑 v2 工件。
- W4A4 的自身代价：它是该仓**质量最低的一档**（GPQA 79.80%）；且 175K 窗口 < NInfer 的 262K。

---

## §11 已知边界与坑（实测）

| # | 边界 | 证据 |
|---|---|---|
| 1 | **只吃 `.ninfer`** —— 不能加载 GGUF | 转换器 `ninfer-v3` 仅厂商持有 |
| 2 | **`--spec dflash` 被 KVMem 拒绝** | `FATAL … none, MTP or DFlash2` |
| 3 | **DFlash2 比 MTP 慢** | decode 32K: 78.8 vs 89.3；250K: 53.0 vs 76.8（dflash2 用 12 宽时**更慢**，见坑 4） |
| 4 | **draft 宽度是任务相关的** | 厂商：窗口 4→12 在**数数字**上 278→600 tok/s，在**随机输出**上反而更慢。**本机复现（2026-10-04）**：数数字 draft6 **127.7** vs draft4 117.1（+9%）；散文 draft4 **48.6** / draft6 **46.2**（−5%）/ draft8 40.4（−17%）→ **结论反转** |
| 5 | **跨页缝截断（厂商文档化，未修）** | 针跨页边界时尾巴可能被切 |
| 6 | **小池下限未测** | 厂商测过最小 63 页；更小「未测」，不是「更好」 |
| 7 | **sm_120 未调优** | 源码自认 occupancy/split-k 仍是 sm_86 那套 |
| 8 | **多卡拒绝 DFlash2 与 vision** | `split_execution()` 里 `unsupported(...)` |
| 9 | **decode 是瓶颈** | 250K 时 prefill 811 vs decode 56 |
| 10 | **参数扫描必须证明「真重启」** | 停错 unit 名 → 新实例静默起不来，此后每档都在测同一个进程（表现为「就绪 3s」+ 数字逐位相同）。**判据**：加载必 >30s（本机 ~69s）+ 每档打印 `MainPID` |
| 11 | **调显存前先关视觉** | `--vision` 占 442 MiB（15,382→14,940 MiB）且完全不影响 KV 容量与文本速度。想加窗口/加池被 `runtime reservation` 拒时，先关它（本机据此救活 chunk2048 与 int8 两档） |
| 12 | **上游引擎读不了本机工件** | 实测 `weight/…: unknown tensor layout: gguf_blocks_v1`。上游只认 `bf16/fp32/int32/q4_g64/q5_g64/q6_g64/q8_g32/nvfp4/fp8_e4m3fn`，无任何 `gguf_*`；且上游是单卡（`--device N` 单选），双卡 `--devices` 是 fork 功能 |
| 13 | **旧引擎对「强制工具」直接 400** | 旧版（`c9fd230`）实测：多工具 + `tool_choice:"required"` → `400 tool_choice_not_supported`；强制/具名工具 + 思考开启 → `400`（"cannot be combined with reasoning"）。**组合版已修**（降级 Auto / 静默关思考）。**本机 Hermes 不设 `tool_choice` → 不触发** |
| 14 | **升级 fork 会打断前缀复用** | `origin/main`（`c863e02`）实测：`cache 4,820 (99.6%) → 0 (0.0%)`、TTFT `133ms → 4.3s`（32×），2/2 复现。根因 `209c75b` 在 `request_plan.cpp` 的 `kvmem_window_pages != 0` 分支跳过 endpoint 候选 → **window 模式正是它破坏的配置**。**禁直接升 `origin/main`**；生产用组合版（见文末「引擎版本锁定」块） |
| 15 | **`git log --stat \| head -N` 会少报 commit 数** | 实测：`git log --oneline --stat <range> \| head -40` 只显示 3 个 commit，实际 **5 个**（每 commit 的多行 stat 吃掉了名额）。被藏的两个含 `device.cu`/`prefill.cpp` 一整套改动 → 整段分析错位。**数 commit 用裸 `git log --oneline <range>`，过 `head` 只用于看内容** |
| 16 | **组合构建只编 `--target ninfer-serve`** | 整树 `all` 目标会挂在 `tools/ninfer-multi-gpu-probe`（`undefined reference to ninfer::core::current_resident_memory()`）——上游 CMake 缺陷，与 server 无关 |
| 17 | **跨请求前缀复用需要会话键；不带 `--derive-session-keys` 时恒为 0** | 2026-10-12 实测：现役件不带该 flag → 同一 prompt 连发两次 `cache_n = 0 → 0`（每次全量重算，4.4k prompt `prompt_ms 3991→3910`）；带该 flag → `cache_n = 4431 (99.9%)`、`prompt_ms 74`。**别把 `NINFER_KVMEM_LONG_REUSE=1` 当作这一层**（那是 KVMem 窗口层，管不了 context-cache 的 history 读写）。KVMem 窗口模式的闸门（`request_plan.cpp:770-785`）只拒共享路、放行私有续写路；会话键只在本 flag 下派生（`serve_options.h:107` 默认 false）。判据：引擎日志的 `cache N (P%, path)` 会给出路径标签（修复后为 `turn closure`）；`journalctl -u ninfer-prod` **没有逐请求行**，真日志在 `~/models/qwen3.8-27b-swift/prod.log` |

---

## §12 相关笔记

- [[20_Tech_Stack/kvmem_llamacpp_manifest|KVMem + llama.cpp 手册]] —— **已归档**，本引擎替换掉的旧栈
- [[20_Tech_Stack/qwen3.8-27b-gsq-rco-gguf_manifest|GSQ-RCO GGUF 手册]] —— 旧栈权重（已删）
- [[20_Tech_Stack/gpu_hybrid_rendering_manifest|双卡混跑独显无头智算手册]] —— 核显渲染 + 独显计算
- [[10_AI_Models/llama_cpp_compilation_manifest|llama.cpp 编译手册]]

> 构建/移植陷阱另见 skill `ninfer-linux-sm120a-build`（含 `references/kvmem-variants-and-forks.md`、
> `references/pack-deployment-acceptance.md`）—— 属 Hermes skill，非本 Vault 笔记。

### 产物位置

```
引擎源码   ~/ninfer-build/kvmem-base-20261021/        (iamwavecut@08fd7019 + qzshch 补丁 + kvmem/ 模块；2026-10-21 起)
旧树       ~/ninfer-build/src-5258/swift15/engine/     (upgrade-013-20261005 @ c7f5a1b，保留回滚)
二进制     …/build/apps/ninfer-serve                   sha256 f6c8b6bea627e76356eb16f8… (生产分支 c7f5a1b = 7fdbbb7 + 2 条上游修复, 10-12 23:13)
权重       ~/models/qwen3.8-27b-swift/swift-qwen38-rco-iq3s.ninfer   13.98 GiB
启动       ~/models/qwen3.8-27b-swift/start-prod.sh
回退脚本   ~/models/qwen3.8-27b-swift/start-prod.sh.bak-vendor-params-20261004-083906
验收       ~/models/qwen3.8-27b-swift/{accept.py, accept-composed.py}
说明       ~/models/qwen3.8-27b-swift/{PRODUCTION.md, MODEL-INFO.md}
校准       ~/.cache/ninfer/device-profiles.json
厂商包     /mnt/nas/nas/nas/linux/50/infer-engine-sm120a-20261002/   (Windows .exe)
```

**引擎二进制归档（三方，可回滚）**

```
~/ninfer-build/_rollback-c9fd230-20261004-123651/ninfer-serve   29252e13…  原生产（无修复）
~/ninfer-build/_composed-agcompat-20261004-130522/ninfer-serve  8d793703…  现生产（+RECIPE.txt）
~/ninfer-build/_new-c863e02-20261004-124036/ninfer-serve         425233d2…  有回归，弃
```

**git 分支**：`main`=`c863e02` · `prod-c9fd230`=`c9fd230` · **`agcompat-serve`=`3c26089`（现用）**

**实测证据**：`20_Tech_Stack/_evidence/ninfer-2026-10-04/`（`tune-sweep/` 65 文件含
QUAL/LADDER JSON 与前缀复用 A/B；`ninfer-eval/` 引擎改动记录）。

---

*本页由 agent 于 2026-10-04 生成，全部数字来自本机实测与源码直读；生产引擎为**组合版**（分支 `agcompat-serve` @ `3c26089`）。
行为随上游推进而变 —— 引用前先核 `strings`/源码，不要只依赖本页。*

> [!warning] 引擎版本锁定（2026-10-04 实测）—— 不要直接升 `origin/main`
> **fork 的 `origin/main`（`c863e02`）实测有前缀复用回归**：`cache 4,820 (99.6%) → 0 (0.0%)`、TTFT `133 ms → 4.3 s`（32×），2/2 复现。根因是 `209c75b` 在 `models/qwen3_5/program/planning/request_plan.cpp` 的 `kvmem_window_pages != 0` 分支下跳过 endpoint 候选 —— 本机的 `--kvmem-window-pages 1000` 正是它破坏的配置。引擎日志表现为 `KVMem reuse refused | needs fork/retain or anchor`（旧版 0 次 / 新版 4 次）。
> **生产 = 组合版**：基线 `927e19e`（实测干净）+ 摘入 `209c75b` 的 `serve/*.cpp`×4 与 `runtime/engine/engine_core.h`，**排除 `request_plan.cpp`**。拿到：三项 `tool_choice` 400 消除、客户端 `max_tokens` 封顶到 `default_max_tokens`、显存预算日志。
> **残余风险（未消除）**：排除的那段是厂商的 KVMem 截断/分叉保护；本地泄漏测试（植入唯一事实 → 截断/分叉 → 追问）未复现泄漏，但仅为「所测场景通过」，不等于证明安全。
> **四方留档**（⚠️ 以下目录**已迁移**至 NAS `/mnt/nas/nas/nas/linux/offload-20261007/`，本地已删除）：`~/ninfer-build/_rollback-c9fd230-*/`（原生产 `29252e13…`）· `~/ninfer-build/_composed-agcompat-*/`（**现生产** `8d793703…`，含 RECIPE.txt）· `~/ninfer-build/_new-c863e02-*/`（有回归，弃）· git 分支 `main`=`c863e02` / `prod-c9fd230`=`c9fd230` / `agcompat-serve`=`3c26089`（现用）。
> 验收工具：`~/models/qwen3.8-27b-swift/accept.py`（速度）+ `accept-composed.py`（兼容/复用/泄漏/检索）。


> [!warning] 引擎版本锁定 —— **2026-10-10 状态更新：生产件已换代（10-04 决策记录保留在上方）**
> **现役生产件（实测）**：2026-10-05 **22:46:42** checkout 由 `agcompat-serve` 移到 `upgrade-013-20261005`（= `5bb1516`），**22:47 重编** ⇒ 8090/8093 现役二进制 = **`5bb1516` 构建**（mtime `2026-10-05 22:47`，sha256 `d468690125ede9736e38beebc3805a83d3b97e63c5220e1420b923203d0bcfd7`；两条线的启动日志横幅均为 `build bonsai2-12g-v0.1.4`）。`~/models/qwen3.8-27b-swift/start-prod.sh` 已实际使用 `NINFER_KVMEM_LONG_REUSE=1`（脚本注释自述「0.1.3 新增」）⇒ **与「现役 = 0.1.2 组合版」的旧登记不一致，旧值已过期**（判定依据：reflog + 二进制 mtime + 运行日志横幅，三者互证）。
> **引擎子树等价性（决定「要不要重编」）**：`5bb1516..7fdbbb7` 对 `swift15/engine/` 的改动 = **0 个 commit** ⇒ 现役二进制与当前 `origin/main`(`7fdbbb7`) 的**引擎源码等价**，重编得等价产物 ⇒ **无重编收益**。
> **上游推进与锁定是否仍成立**：fork `origin/main` 相对构建基线 `5bb1516` 多 **29 个 commit**（引擎子树 18 文件 +470/−92），其中含 `209c75b`（已知前缀复用回归源）与 KVMem 相关改动（`d161410 Allocate KVMem windows from rendered request prefixes`、`f7090b9 perf(bonsai): move KVMem retrieval to CPU`）⇒ **锁定规则照旧成立，仍禁直接升**。
> **上游 `Neroued/ninfer`（非生产线）**：master/dev 引用自 `68c5435` 推进至 **`81c8ce0`（2026-10-07）**；⚠️ **增量不可采信** —— 本地 clone 与该线**无共同祖先**（`git merge-base` 为空，shallow/grafted），`rev-list` 报的 144/48 是结构性假数。新增主题为 constrained decoding（gbnf / json mode / tool calling / tuple schemas）与 bf16·q8 算子调优；**生产线不使用该线**，要真判需先 `git fetch --unshallow`。

---

## §13 生产线件上游溯源与更新状态（2026-10-10 实测）

**两条引擎线**
| 线 | 上游仓 | 本地 | 上游当前 | 判定 |
|---|---|---|---|---|
| ~~5258（8090 Swift）~~ | ~~`5258MF/ninfer-rtx3060-27b`~~ | checkout `7fdbbb7` | 停更 **2026-10-13** | **2026-10-21 起不再跟（改跟 qzshch，见 §14）** |
| TP2（8091 Coder390） | `BaiYouQing/ninfer-tp2-5060ti-windows` | `windows-port` `c50ccc91` | `c50ccc91`（2026-09-24，无其它远端分支） | **无更新** |

**两个在役生产模型件**（Ornith 件 2026-10-11 迁 NAS 退役）
| 件 | 本地大小 / sha256 | 上游 | 更新判定 |
|---|---|---|---|
| `swift-qwen38-rco-iq3s.ninfer` | 15,017,456,128 B / `1c4ceed8c3600bebbf35e3b6df89197b277a8f81153bbf7f473b3e94d62a363b` | 源 = **`jonathan-golden/swift15-gsq-rco-iq3s-mtp`**（`Swift-1.5-Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf` 12,120,016,896 B + `mmproj-Swift-1.5-Qwen3.8-27B-F16.gguf` 927,606,976 B，与包内 provenance 记录一一对应） | **无更新**（源仓最后修改 2026-09-25） |
| ~~`Ornith-1.5-35B-A3B-MTP-...v3.ninfer`~~ | 22,791,106,048 B / `e56ef1ec6ca085a48fe5076941b73177f65308c70e8cc311c4033b940ff5669e` | `knoopx/Ornith-1.5-35B-A3B-NInfer` | **2026-10-11 退役（迁 NAS）** |
| `qwen3_8_27b_coder390_w4a4w8a8.ninfer` | 21,490,955,393 B / `e15f02938b69be2b87afb5e89a282772c4663674e703b3f17e099bba92f1b534` | 见 [[20_Tech_Stack/qwen3.8-27b-coder390-tp2-ninfer_manifest\|Coder390 手册 §9]]（`nerkyor/…-NVFP4-NInfer` 的 `…MTP-NInferV2.ninfer`） | **2026-10-11 换用上游件**（旧本机重打包件 `db0c7df8…` 归档 NAS） |

> 📦 **折叠留档（2026-10-14）**：本页原「## 📅 2026-10-12 单卡线（8090 · NInfer 5258 KVMem）当日工作记录」（39 行过程流水）已整块逐字移入 [[20_Tech_Stack/_archive/ninfer_engine_architecture_manifest-版本文史-20261014|旧版本实录]]。关键数字：真实工具调用往返复用 **99.2% / 99.7%**（`turn closure` / `response replay`）、同文重发与纯文本多轮增长 **99%+**、兄弟分叉 **0**（唯一缺口，已判不做）；`--derive-session-keys` 上产后同 prompt 连发 4.6k `4.2s→0.3s`、72k `75.4s→0.33s`、134k `149.8s→0.31s`（**478×**）；2 条上游 context-cache 修复 2 文件 +24/−4（**无实测收益、无回归**，价值在健壮性）；负结果：上游端点锚移植后**惰性**、`--auto-long-anchors`/`--max-private-continuations`/`--device-state-slots`/`--preserve-thinking` 四开关无收益、`f928d888` 本机早有、「关思考以换复用」被用户否决。**why 不受影响**：选型定案见 §2.1.1，复用机制/根因/行业依据见 §6.5，生产参数见 §10.1–10.2，坑见 §11 #17。

> **本机 Swift 件的性质（§13 补注，不属上面当日记录）**：目录内**无 HF 下载缓存**，且包内 provenance 记录为「`converter: ninfer-v3` + `base`/`gguf`/`vision`/`dflash2` 四路输入（B 机 `E:\infer-build\…` 路径）」⇒ 它是**从源 GGUF+mmproj 转换出的 v3 件，不是 HF 直下件**。HF 上名称最接近的两件尺寸都对不上（`fyb1214/…-IQ3_S-mtp` 12,790,639,360 B；`WaveCut/Qwen3.8-27B-GSQ-RCO-IQ3_S-NInfer-v3` 15,017,456,**896** B，比本机件多 **768 B**）。
> **溯源方法（可复用）**：HF 直下件的来源可从 `~/models/<pkg>/.cache/huggingface/download/*.metadata` 读出三行 = **revision / LFS sha256 / 下载时间戳**；仓名从 `~/.cache/huggingface/hub/models--<org>--<name>/refs/main` 反查（其内容 ≡ 同一 revision）。**判「有无更新」一律比对 sha256 与 revision，不信文件名相似度。**

## §14 换基座：8090 从「5258 下游移植树」切到「qzshch 环上游」（2026-10-21，用户决定）

**为什么切**：5258 自 2026-10-13 停更，而环的真实上游 `qzshch/ninfer-kvmem` 仍在动（10-20 前仍有 RAM KV 预取、bounded recall transfer、DFlash2 八通道等提交）。决策口径见 §2.1.1 谱系：`Neroued`（基座）→ `qzshch`（环）→ `5258`（移植进新引擎结构）。选择「直接以上游为底座」，接受性能代价，不再在老树上打补丁。

**怎么搭的（可复现）**：
1. 基座 = `iamwavecut/ninfer-all` **`08fd7019`**（worktree：`~/ninfer-build/kvmem-base-20261021`）
2. 补丁 = `qzshch/ninfer-kvmem` 的 `backends/patches/ninfer-kvmem.patch`（1.2 MB / 208 文件 / 740 hunk，sha256 `d1b64eb…` 与仓内 `versions.json` 声明一致）→ **在真基座上 208 文件全部干净应用（0 reject）**
3. 外部模块 = 同仓 `kvmem/`（56 文件 / 443 KB）→ `cmake -DNINFER_KVMEM_SOURCE_DIR=<path>/kvmem`
4. 编译：`-DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=120a -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc`（**nvcc 不在 PATH，必须显式给编译器**，否则 configure 失败）；819 目标全绿
5. 生产二进制 sha `169716d5…`（643,752,688 B）；启动器 `~/models/qwen3.8-27b-swift/start-prod.sh` 已重写，旧版 `start-prod.sh.5258-20261021`

**参数映射（旧 → 新）**：
| 旧（5258） | 新（qzshch 基座） |
|---|---|
| `--kvmem-window-pages 1000` | `--kvmem-budget 61440` + `--kvmem-gen-reserve 4096`（窗口 = B+R = 65,536） |
| `--host-kv-mib 16384` | `--kvmem-host-mib 16384`（上下文缓存归 KVMem 独占，旧键不再生效） |
| sink 2 页（env `NINFER_KVMEM_SINK_PAGES=2`） | `--kvmem-sink-tokens 128` |
| `NINFER_KVMEM_AUTO_ALLOCATION/_LONG_REUSE` 等 4 个 env | 无对应（新基座用 `--kvmem-*` 旗标） |
| `--kv-capacity auto` | **删掉**（有 KVMem 时被「B+R ≤ capacity」闸门拒） |
| `--device-state-slots 1` | **删掉**（会触发「exclusive ownership of history caching」拒绝） |
| `--embedding-host`、`--lm-head-q6` | 新基座无此旗标 |

**性能对照（同题、temp 0、seed 7、同工件、单卡）**：
| 场景 | 5258（旧） | qzshch 基座（新） |
|---|---|---|
| 短题 decode | **67.2 tok/s**（草稿 39/84=46.4%） | 51.0（37/108=34.3%） |
| 散文 512 / 1024 tok | 60.5 / 64.1 | 51.0 / 51.0 |
| 7,457 tok 长文 | prefill 1.13k / decode 66.8 | prefill 1.10k / decode 64.5 |
| 工具调用 | prefill 756 / decode 71.2 | prefill 547 / decode 73.9 |
| 前缀复用 | 91.5%（TTFT 75.7 ms） | **98.3%（TTFT 64.5 ms）** |
| 关掉 KVMem 的裸引擎 | — | 54.0 ⇒ **慢在引擎核心而非 KVMem** |

- 参数扫描无法弥补：`draft 3` 51.8、`--adaptive-mtp`(d4) 50.2、(d8) 42.8、`d6` 42.3、`d8` 35.9、`--full-draft-head` 47.7、`--kvmem-budget 32768` 51.0；`--draft-min-p` 与 `--expert-cache-adaptive` 直接启动失败。
- **差距定位**：`execution/mtp.cpp|mtp.h`、`ops/mtp_round.h`、`ops/mtp_pack.h` 两树**逐字相同（0 行差异）**；差异在草稿宽度策略层（5258 独有 `program/speculative/mtp_adaptive.h` 406 行，被 `program_impl.h` include）与验证器（qzshch 反而已升级为 `speculative_accept_coupled_drafts`，5258 仍是 greedy）。**未移植**（用户决定「不调试了」）。

**校准（2026-10-21 13:12 已完成）**：新基座要求 `schema_version: 2` 的 device profile（旧文件是 5258 系 v1 ⇒ 被跳过）。用 `ninfer-calibrate --device 0` 重跑：**78 keys / 63.3 s / 其中 50 个键改走非编译路径**，写入 `~/.cache/ninfer/device-profiles.json`（`origin: ninfer-calibrate on NVIDIA GeForce RTX 5060 Ti`，route catalog `5893cf72e3d60377`）；旧 v1 文件备份在 `~/vault-backup/ninfer-8090-pre-rebuild-20261021/device-profiles.v1-5258.json`。引擎启动告警消失，日志改为 `device profile … 78 routed keys`。**校准后 decode：短题 51.0 → 53.0、散文 512 tok 51.0 → 51.2**（+2 / +0.4），仍比旧线 67.2 低 —— 校准只补回 2 tok/s，主差距仍是草稿宽度策略。GPU1 未校准（KVMem 单卡线只用卡 0；如 8091 也换新基座再校准）。

**已知遗留**：decode 比旧线低 24%（散文），如将来要追，切入点是把 `mtp_adaptive.h` 接到新验证器上，先看能否把接受率从 34.3% 拉回 46.4%。

**回滚**：`cp ~/models/qwen3.8-27b-swift/start-prod.sh.5258-20261021 ~/models/qwen3.8-27b-swift/start-prod.sh`，二进制用 `~/vault-backup/ninfer-8090-pre-rebuild-20261021/ninfer-serve.pre`（sha `f6c8b6be…`）。旧树 `~/ninfer-build/src-5258` 与 `git bundle`（`~/vault-backup/ninfer-8090-pre-rebuild-20261021/tree-514803c8.bundle`）都在。

