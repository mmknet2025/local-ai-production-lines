---
type: manifest
title: "Strata 推理引擎手册（本机双 RTX 5060 Ti · Qwen3.8-Flash-Next 单模型引擎 · ✅ 本机生产模型 2026-10-11 起）"
tags: [strata, engine, qwen3.8-flash-next, moe, multi-gpu, layer-split, sm120, local-inference, okf-v0.2]
description: "【✅ 本机生产模型（2026-10-11 起，与 NInfer 栈并列为第二条生产引擎线）】Strata（github.com/Niko1221/Strata，MIT）在本机（2×RTX 5060 Ti 16GB sm_120 / 59 GiB / 驱动 615.71.09 / CUDA 13.4）的完整部署手册：引擎身份与本地编译、产物路径、双卡 layer-split、systemd 运行方式、调优参数（生效 args + opt-in 实测 + 踩坑）、实测数字、Hermes provider 集成与工具调用验证"
trust: agent-generated
status: current
okf_version: v0.2
timestamp: "2026-10-13"
sources:
  - 上游仓库 Niko1221/Strata（**已装 v0.1.43.1，2026-10-13**；tag v0.1.42 为 2026-10-11；v0.1.41 为 2026-10-08）：INSTALL.md / DETAILS.md / MULTI_GPU.md / MODELS.md / BATCHING.md
  - 本机实测会话（2026-10-10 ~ 10-11）
  - 社区配方：Tlyer233/strata-dual-3080-qwen-flash（双3080 sm_86）、eddoursul/Strata fork、johnmosesventura06/strata-4gpu（4×5060Ti）
---

> 📌 **生产线公共事实（端口/互斥/编排/回滚）以 [[20_Tech_Stack/local-production-lines|三条生产线总览]] 为单一事实源**；本文只保留本线/本主题细节。

# Strata 推理引擎手册

> 🔗 **编排（端口 / 互斥 / 按需拉起 / model id）统一见 [[20_Tech_Stack/local-production-lines|三条生产线总览]] §2–§5。**

> [!info] 一句话定位
> **Strata**（MIT）是**只跑 Qwen3.8-Flash-Next 一个模型**的消费级推理引擎：把 125B MoE 拆到
> **VRAM（热门专家缓存）+ 系统 RAM（全部专家）+ SSD（PLE/n-gram 查表）** 三档，在单张 12–24GB 消费卡上跑，
> 起 OpenAI / Anthropic 兼容 API（`http://127.0.0.1:8080`）。与本机 NInfer 栈（[[20_Tech_Stack/ninfer_engine_architecture_manifest]]）**并列的另一条本地引擎线**。
> 模型侧：现役 **Swift 1.5 IQ3_S** —— 见 [[20_Tech_Stack/swift-1.5-qwen3.8-flash-next-iq3_s_manifest|Swift IQ3_S 模型手册]]（上一档 [[20_Tech_Stack/swift-1.5-qwen3.8-flash-next-iq3_xxs_manifest|IQ3_XXS]] 已于 2026-10-11 存档）。

## §1 本机硬件与环境（本页数字的基准）
| 部件 | 实测值 |
|---|---|
| GPU | 2 × RTX 5060 Ti 16GB（compute capability **12.0 / sm_120**，各 16,311 MiB）|
| 双卡链路 | PCIe **Gen5 x8 + x8**；引擎自探测 **28.8 GB/s**（单向，每卡各测一次）→ `pcie_frac 0.55`。**「不用 P2P」≠「不支持 P2P」**（2026-10-11 实测引擎二进制）：`cudaDeviceCanAccessPeer`/`EnablePeerAccess`/`MemcpyPeer*` 各 **2 处**、`P2P` 6 处、`pcie_frac` 5 处，且 serve 层有 **`--peer-device`** 模式（第二卡当专家缓存层，**与 `--layer-split` 互斥**，上游 #665）；但本机用的 layer-split **不把 P2P 放在关键路径** —— 引擎日志实测跨卡/PCIe 仅占 **0.5–10.9%**（专家缓存命中 81.4%→97.7%）。**Strata 不用 NCCL** ⇒ 无 per-channel 证据，其跨卡读是否落成 peer DMA **unverified** |
| 显示输出 | **AMD 核显（Granite Ridge）**——两张 N 卡连接器全 disconnected，**显存 100% 给计算**，故无需给 N 卡留显示显存 |
| 内存 | 59 GiB（IQ3_S：低 RAM 模式 `--resident-experts` 下 ~33 GiB 专家驻 RAM、系统余 ~17 GiB；正常模式 ~47 GiB、仅余 ~3 GiB。**两模式均可跑**）|
| 驱动 / CUDA | 615.71.09 / `/usr/local/cuda-13.4`（本地编译用）|
| CPU | Ryzen 7 9700X（AVX-512）|

## §2 引擎身份与血统
- **仓库**：`github.com/Niko1221/Strata`，**MIT**。只支持 Qwen3.8-Flash-Next（含 Swift / Coder / Unsloth 变体）。
- **版本**：**v0.1.43.1**（2026-10-13 升级，见 §11；v0.1.42 为 2026-10-11、v0.1.41 为 2026-10-08）。仅 3 周大的项目（首个 release 2026-09-24）。
- **本机是本地编译，不是预编译**：`engine/BUILD.json` = `source=local, archs=[120], src=7089bf002d14a0e3`（v0.1.43.1），节 **138/138** `Linking CXX executable strata`，留 `build/`。需 **nvcc/CUDA 13**。
  - ⚠️ 上游 INSTALL 称 Linux 有 sm_120 预编译；**实测本机仍走了源码编译**——不要假设 50 系免编译。
- **多卡 = 按层切分的流水线并行（layer split / pipeline），不是张量并行**；无需 NVLink/P2P；每卡只缓存自己层的专家。

## §3 安装与产物路径
| 项 | 路径 |
|---|---|
| 引擎树 | `~/src/Strata`（`engine/strata` **68,080,136 B**，v0.1.43.1，mtime 10-13 14:07，见 §11；`serve/server.py`）|
| 数据（~127G）| `~/src/Strata-data/`：`models/swift-IQ3_S/`（两分片+.done）、`packs/swift-iq3_s/`、`mtp/{tensors,rt}` |
| 模型配置 | `~/src/Strata/strata-swift-iq3_s.json`（+ `run-swift-iq3_s.sh`）|
| 引擎日志 | `~/src/Strata/strata-swift-iq3_s.log` |
| 解析项目/脚本 | `~/workspace/strata-swift-iq3s/bin/{start,stop}.sh`（systemd 单元 `strata-swift-iq3s` 的薄封装）|

安装命令（已执行）：
```bash
git clone --depth 1 https://github.com/Niko1221/Strata.git ~/src/Strata
cd ~/src/Strata
./setup.sh --setup --family swift --model IQ3_S --source modelscope --no-start --yes
./setup.sh --calibrate   # 逐机调优
```

## §4 运行（按需、非常驻、不开机自启）
- **启动**：`systemctl --user start strata-swift-iq3s`（持久 user 单元 `~/.config/systemd/user/strata-swift-iq3s.service`，`Restart=on-failure`、**未 enable ⇒ 开机不自启**、按需；等同 `~/workspace/strata-swift-iq3s/bin/start.sh`）。停止：`systemctl --user stop strata-swift-iq3s`。
  - 必须走 `systemd-run`：Hermes 的后台 shell 有 **4GiB cgroup 上限**，直接后台跑会被 OOM 杀掉。
  - 加载约 40GB 进 RAM + page-lock，首次启动 1–3 分钟。
- **停止**：`bin/stop.sh`（释放显存与 page-locked 内存）。
- **API**：`http://127.0.0.1:8080/v1`（OpenAI `/v1/chat/completions`、Anthropic `/v1/messages`、`/v1/responses`；任意 model 名）。
- `/v1/status`：`dialects` 三方言、`structured_output`（json_object/json_schema，prompt+validate）、`concurrency.serving=1`、`context.native=262144`（2026-10-11 实测；此前记 131072 为 v0.1.41 时点值，v0.1.42 起现值 262144）、`vision.enabled=false`。

## §5 生效的引擎参数（`strata-swift-iq3_s.json`）
```
--pack <Strata-data/packs/swift-iq3_s>
--native / --ple-gguf  .../Swift-...-IQ3_S-00001-of-00002.gguf   (都指 shard1)
--expert-profile ./data/expert-profile.bin
--expert-cache auto   --prefill auto
--spec 6 --mtp-max-t 4 --suffix-draft 3 --spec-min-p 0.70   (校准)
--resident-experts            # 低 RAM 模式（安装器默认：~33 GiB 专家驻 RAM）
--pcie-frac 0.20              # 校准值（引擎自探 0.55）
--mtp <Strata-data/mtp/rt>
--max-context 262144          # 256K（原生窗口；A/B 实测加载成功、decode −4%）
--kv k8v4                     # K=8bit/V=4bit，比 int8 省 23% KV 显存
--trim-stage-weights          # 每卡只加载自己层的 dense 权重（需显式 layer_split）
--vram-reserve-mib 700        # 见踩坑：300 会让 MTP draft head 装不下
--pipeline-windows 2          # 两窗口在飞，双卡重叠（吃首卡 ~272MiB 缓存）
layer_split = 24   (gpu=[0,1])  # 48 层，0-23 / 24-47
env: STRATA_PREFILL_HELP=1
```
**opt-in 参考（官方 0.1.41 实测；本机可按需 A/B）**：
- ✅ 倾向开：`--pipeline-windows 2`（双卡 prefill +28%，2×3090 实测）、`STRATA_PREFILL_HELP=1`（空闲卡帮预取短 prompt +20~70%）。
- ⚠️ 试了测：`STRATA_SPEC_COUPLED=1`+`GUMBEL`（采样请求草稿接受率↑）、`STRATA_ADAPT_LAG=2`（小卡多半中性）。
- ❌ 不要用：`STRATA_GDN_CHUNKED=1`（需 ≥128 SM，小卡更慢）、`STRATA_FS_SLOTS`（所有机型更慢）、`STRATA_STAGE_PIN=1`（只对 mmap 模式有用，且有 IQ3_S 长 prompt 损坏未修）、`--adapt-async 1`（无 `--resident-experts` 时**无效**，引擎自报 off）。

## §6 实测数字（本机，2026-10-11）
| 项 | 值 |
|---|---|
| decode | **100–114 tok/s**（draft 接受 ~65–70%）|
| prefill | 2K prompt **~990 tok/s**；短 prompt ~150 tok/s（冷）|
| calibrate 基准 | 93.9 tok/s（"默认已最优"，未改动任何设置）|
| 专家缓存 | CUDA0 8210 槽（11.89 GiB）/ CUDA1 5775 槽（10.45 GiB）|
| 显存 | 两卡各 ~15.3/16.3 GiB，加载后剩 325–414 MiB |
| 内存 | used ~50 GiB / available ~8.6 GiB |

## §7 接入 Hermes（**2026-10-12 起：统一 provider `local-engines`**）
**现状**：`local-strata` 条目**已从 `providers:` 删除**，Strata 并入统一编排 provider `local-engines`（`ninfer-router --profile all` @8097，unit `local-router`；拉起 Strata 前路由器先停 NInfer 引擎并等其真 inactive，Strata 卸载需释放 ~48 G）。**下方 yaml 为已退役的直连接入法**（2026-10-11 快照，留作应急直连/回滚参考）：
```yaml
  local-strata:
    api: http://127.0.0.1:8080/v1
    name: Local-Strata
    api_key: local
    models:
      flash-next-swift1.5-iq3s:
        context_length: 262144
    default_model: flash-next-swift1.5-iq3s
    transport: chat_completions
```
- **工具调用已实测通过**：发 OpenAI 标准 `tools` → 返回 `finish_reason: tool_calls`，参数正确（`get_weather{city:北京}`）。
- 切成 driver（**旧直连法，10-12 后勿照做**——会把已删 provider 加回去）：现走 `model.provider local-engines` + `model.default flash-next-swift1.5-iq3s`，路由器按需自动拉起。
- 坑：① 全局 `reasoning_effort` 对本地 URL **无效**，要写条目的 `extra_body.chat_template_kwargs.reasoning_effort`；② `concurrency=1`，子代理并行会排队；③ driver 期间 Strata 必须在线（别 `bin/stop.sh`）；④ 3-bit 量化偶发畸形工具调用可开 `tool_call_recovery: true`。

## §8 踩坑 / 边界 / 待办
- **`--vram-reserve-mib` 不可低于 ~700**：设 300 时最后一张卡只剩 105 MiB，**MTP draft head（178 MiB）装不下** → 引擎退出（`mtp: the draft head does not fit`）。
- **`--calibrate` 收尾会启动模型并自动开浏览器**（无 `--no-browser`），且服务挂在它自己的瞬时单元下——想自己管就重挂。
- **重跑 `setup` 会覆盖手改的 `args`**（setup 只保留 sampling/mcp 等你加的键）。
- **RAM 取舍**：59 GiB 对 IQ3_S —— 低 RAM 模式（`--resident-experts`）余 ~17 GiB、更稳；正常模式仅余 ~3 GiB。跑前清内存。
- **sm_120 与 thread-block clusters 存在说法冲突**（官方称 RTX 50 有；4×5060Ti 旧 fork 称无）——以本机为准（未证）。
- **A/B 实测（2026-10-11）**：**256K 可用**——`--max-context 262144` 加载成功，代价 ~decode −4%（专家缓存 8210/5775 → 7719/5292 槽），换 2× 上下文。**`--prefill 32768` 是负优化**——引擎钳到 16384，20K prompt prefill 1829 vs `auto` 2170（−16%）→ 保持 `auto`。
  （固定协议：decode=短 prompt×3 中位；prefill=中文 prompt；基线 ctx128K/prefill auto：decode 96.2、prefill 4.9K 1459、20K 2170）

## §9 P2P 实测（2026-10-11 用户提问触发）

| 证据 | 实测值 |
|---|---|
| 引擎血统 | `~/src/Strata/third_party/llama.cpp`（**本地编译的 llama.cpp 派生树**；`engine/BUILD.json` = `source=local, archs=[120], version 0.1.41→0.1.42→**0.1.43.1**, src 62eb4907c92a8cb7→1e0c97588848ea0f→**7089bf002d14a0e3**（逐次升级后）`）|
| 二进制里的 peer 符号 | `CanAccessPeer` 2 · `EnablePeerAccess` 2 · `MemcpyPeer` 2 · `P2P` 6 · `pcie_frac` 5（`peer_access`/`nvlink` 字面 0）|
| 服务层模式 | `serve/server.py:2161` —— **`--peer-device`**（第二卡作专家缓存层），且**与 `--layer-split` 互斥**（上游 #665）|
| 引擎自测链路 | `PCIe probe: 28.8 GB/s host->device … -> pcie_frac 0.55`（CUDA0 与 CUDA1 各一次）|
| 跨卡/PCIe 实际占比 | `decode expert cache hit rate` 81.4%→97.7%，其中「read by the GPU over PCIe **or from another GPU**」**10.9%→0.5%**（随缓存变热趋零）|
| 本机 P2P 能力 | `topo -p2p r` = **2 边 OK**（驱动 615.71.09 + aikitoria 补丁 DKMS，srcversion 内存==磁盘 `DCB98E66E94742CC334C0E5`，hold 19）|

> **结论**：该引擎**有** P2P 代码路径（含 peer-device 模式），但本机采用的 layer-split 形态下 **P2P 不在关键路径** —— 跨卡流量只占 0.5–11%。28.8 GB/s 与 P2P 实测 ~28.7 GB/s 同量级（host-staged 往返恰为一半 ~14.3）⇒ **该探测值本身不能区分 P2P 与直连 H2D**。因 Strata 不使用 NCCL，缺乏 per-channel `via P2P/...` 证据 ⇒ 「我们的 P2P 补丁对它是否有实际增益」**标 unverified，未宣称**。

## §10 升级记录 v0.1.41 → v0.1.42（2026-10-11 09:55 完成）

**✅ 已完成（2026-10-11 09:40 编译 / 09:5x 起服务）**：引擎二进制 66,709,088 B（旧 66,256,120）、mtime 10-11 09:40、`cmp` 与旧件不同；`/v1/status` → **`engine: 0.1.42`**；启动日志 `session is up (engine 0.1.42)`。**下方表格是 09:28 的半升级态留档。**

### 升级过程中的两个真坑（都已复现并解决）

**坑 1 ——「假绿」元数据会让升级自我维持地跳过。** `update.sh`（=`setup.sh --update`）第一次跑时打印 `The engine's source changed: compiling it again`，但 `cmake --build` 回了 **`ninja: no work to do`**，然后仍打印 `[ok] engine compiled` 并把 `engine/BUILD.json` 改写成 **version 0.1.42 + 新 src 哈希** —— 而二进制 `cmp` 与旧件**完全相同**。此后更新器拿 BUILD.json 的 `src` 哈希比对，得出「已是最新」⇒ 再跑直接秒退（20 秒、无 configure）。**判据：永远用 `cmp 二进制` + 运行中引擎自报版本，不要信 BUILD.json。**

**坑 2 ——`setup.sh --yes` 不指定模型会按默认值换档并下载。** 裸 `--yes` 触发了 **Q2_0（37.62 GB）**下载到 `Strata-data/models/Q2_0`（已停并删除，释放 15.1 GB）。**只做引擎升级时不要单独用 `--yes` 裸跑 setup**；确需带 `--yes` 就走 `--family swift --model IQ3_XXS`。另注下载在长连接下会周期性报 `SSL: UNEXPECTED_EOF_WHILE_READING`，它自带重试可跨过。

**有效解法（官方路径）**：① 把 `engine/BUILD.json` **还原成与当前二进制相符**的真实注册（version 0.1.41 + 旧 src 哈希，即「让官方判据自己识别出源码已变」）→ ② `./setup.sh --yes --no-start --build`（`--build` 官方语义 = *compile the engine instead of using the ready-made one*；`--setup` 路径才会真的走 configure+编译）→ ③ 清空过的 `build/` 从零 configure（约 100 s，含 FetchContent 重取 vendored llama.cpp）+ 编译 138 步。官方另有 `--rollback-engine`（被替换的引擎保留在 `engine/.previous`）。

| 层 | 版本 | 证据 |
|---|---|---|
| 源码树 | **v0.1.42** | tag `v0.1.42` · HEAD `61b3fb5`（"Merge f-142-pciefrac"，10-10 14:49 +0200）· reflog `HEAD@{2026-10-11 09:15:23}: merge origin/main: Fast-forward` |
| 引擎二进制 | **0.1.41** | `engine/BUILD.json` `version=0.1.41`、`src 62eb4907c92a8cb7`、mtime 10-10 23:34 |
| 运行中服务 | **0.1.41** | `/v1/status` → `engine 0.1.41` · 单元起于 2026-10-11 01:23:05(BUILD 早于源码拉取) |
| 手改 args | **完好** | `strata-swift-iq3_xxs.json` 31 条未被子 setup 覆盖 |

**⚠️ 版本门槛**：`setup.py:195` = `MIN_ENGINE = (0, 1, 42)`（注释：*v0.1.42: STRATA_ROUTE_TAIL_SKIP=7 default on CUDA*）⇒ **只重启不重编会造成 serve 0.1.42 + 引擎 0.1.41 的混版，被 setup 拒**。单元 `ExecStart` 直接跑源码树的 `serve/server.py` ⇒ 重启即取新版 serve。

**重编前置**：引擎常驻 **RAM 48G（可用仅 10G）**、双卡各 15.6G 显存 ⇒ 必须**先停引擎**释放资源再编（16 核并行 nvcc 会吃穿 10G）。参考耗时：10-10 23:28 clone → 23:34 引擎二进制 ⇒ **约 6 分钟**。

**本次升级的改动量**（`fb58e0d..61b3fb5`，661 文件 +162449/−1041）：`src/` 47 文件 +4551/−457（`src/program/generate.cpp` 单文件 +1510）、`include/` 31 文件 +1209、`serve/` 29 文件 +3130 ⇒ **引擎必须重编**。

**关于 v0.1.42 对本机是否有收益（更正早前判断）**：`b4e3407` 明确 `STRATA_ROUTE_TAIL_SKIP=7` 默认对 **single GPU 与 layer split** 开，**排除**项 =「专家全常驻 VRAM / `--batch` 槽 / peer 或 helper 卡 / HIP」。本机 layer split、专家**未**全常驻（命中率 81→98%，有 PCIe/RAM 溢出）、无 peer/helper、不用 batch ⇒ **不在排除名单** ⇒ 早就前「本机大概率吃不到」的结论**不成立**（那条依据的 2×A4000「99.7% 常驻 ⇒ −0.2%」数据点恰属被新默认排除的场景）。**幅度未测**，升完可 `STRATA_ROUTE_TAIL_SKIP=0` vs 默认做 A/B。另注 `aa7b0cb` 的 `--pcie-frac` 自适应**仅单卡**，与本机无关。

### §10.1 升级后实测（2026-10-11 09:55）

| 项 | 实测值 |
|---|---|
| 引擎自报 | `/v1/status` → `engine: 0.1.42`；日志 `session is up (engine 0.1.42)` |
| 二进制 | 66,709,088 B（旧 66,256,120）、mtime 10-11 09:40、`cmp` ≠ 旧件；`build/` 138 步真编译 |
| 冒烟请求 | `finish_reason: stop`，中文答对（"我是通义千问（Qwen）…"），墙钟 1.0 s |
| 吞吐（单请求） | prompt 59 tok / 375 ms = **157.2 tok/s**；decode 67 tok / 656 ms = **102.1 tok/s**；draft 接受 39/49 |
| **v0.1.42 新默认已生效** | `STRATA_ROUTE_TAIL_SKIP=7 is ON (default): … (+10..20% decode on 12-16 GB cards)`；运行统计 `route tail skip: 3148 missed experts skipped (3461 entries)` |
| 手改 args | ✅ 31 条逐条一致（`strata-swift-iq3_xxs.json` 未被 setup 改写） |
| 专家缓存 | 命中 89.9%；跨卡/PCIe 仅 6.0%（与 §9 的 layer-split 形态一致） |
| 资源 | 引擎常驻 RAM ~48G（可用 10G）、双卡各 ~15.5 GiB |

> **收益判断（更正后）**：`b4e3407`/启动行都为「12–16 GB 卡」声明 **+10~20% decode** ⇒ 本机 16 GB 卡**在受益面内**，
> 且新默认已实测生效。单次短请求 102.1 tok/s 落在旧版 100–114 tok/s 同区间（样本太小、缓存冷），
> **要坐实幅度需 `STRATA_ROUTE_TAIL_SKIP=0` vs 默认的 A/B**。另注该默认**会轻微改变输出**（跳过尾部 rank≥7 的漏专家），可按需关。

### §10.2 A/B 实测：`STRATA_ROUTE_TAIL_SKIP` 7（默认）vs 0（关）

**协议**：同一引擎 0.1.42 / 同 args；**每臂重启后再测**（避开自适应专家缓存带偏）；prompt = 从语料随机取
1200 字窗口（实测 `cache_n` 全 0 ⇒ 无前缀复用）；`temperature=0`、`max_tokens=256`；**同 seed 配对**
（两臂跑同一组题面）；GPU 无降频（2610–2752 MHz / 58–62℃）。

| 臂 | n | decode 中位 | 极值 | prefill 中位 |
|---|---|---|---|---|
| `=7`（默认 ON） | 14 | **112.5 tok/s** | 101.2–151.4 | 570.2 |
| `=0`（OFF） | 14 | **103.2 tok/s** | 93.3–132.8 | 548.7 |

- **中位 +9.0%**；同题配对中 ON 更快 **11/14** 题，配对差中位 **+7.0 tok/s**
- **Wilcoxon 符号秩检验：W+=90.5 / W−=14.5，z=2.39，p≈0.017 ⇒ 显著**
- prefill 两臂一致（570/549）⇒ 差异**纯在 decode**；与官方"decode +10~20%（12-16 GB 卡）"吻合，实测落在其**下限**
- 内部一致性：A1 113.0 / A2 112.0、B1 103.4 / B2 102.3（A2 在 B1 **之后**跑仍同值 ⇒ 排除时间漂移）
- ⚠️ **逐题差异极大（−5% ~ +48%）** ⇒ 单轮/单题完全不可判，必须**配对 + 取中位 + 重启换臂**
- 复现：`python3 ~/workspace/strata_ab.py <臂名> <轮数> <seed0>`（产物 `~/workspace/strata_ab_*.json`，内置 Wilcoxon 由独立脚本汇总）

**⚠️ 坑：启动行 `strata serve: STRATA_ROUTE_TAIL_SKIP=7 is ON (default)` 是 serve 层在描述默认值，不看引擎 env。**
判断某臂是否真生效，只能看 **`/proc/<engine pid>/environ`**（引擎是 `serve/server.py` 的子进程，继承单元 env，drop-in `Environment=` 有效）
或"`route tail skip:` 计数器是否增长"，**不要信那行**。

## §11 升级记录 v0.1.42 → v0.1.43.1（2026-10-13 14:07 完成，**用户选保留**）

**结论：升级完成 —— 🟢 实测零收益、亦零回归**（故「不升」与「保留」在本机等价；用户 2026-10-13 14:18 选**保留**）。

### §11.1 升级路径（三个坑全部命中，逐一排掉）
| # | 现象 | 根因 / 处置 |
|---|---|---|
| ① | `./setup.sh --update` 打印 `[ok] Strata is updated (engine 0.1.42)`，**二进制逐字节未变**（`cmp` identical） | **版本门在树里**：`MIN_ENGINE` 由**本机树自己的 `setup.py`** 提供（`61b3fb5` 那版 = `(0,1,42)`，已满足）⇒ 上游抬门只在树前进后生效。必须 `git merge --ff-only origin/main`（`61b3fb5` → **`a0116b2`**，105 提交 ⇒ `MIN_ENGINE=(0,1,43,1)`） |
| ② | `--build` 报 **`ninja: no work to do`** | 旧 `build/` 被复用。**现代 setup 会明确拒绝谎报**：`[X] the engine build finished without a new engine (strata is version 0.1.42, this source is 0.1.43.1): the installed engine and its stamp are left as they were` + `delete it and run this again` ⇒ 把 `build/` 挪成 `build.pre-0143-20261013-1405` 再跑（**注意：旧版 setup 是「假报成功并改写 BUILD.json」，新版改为诚实报错**）|
| ③ | 重编 | 138/138 步、`Linking CXX executable strata` ⇒ `engine 0.1.43.1` |

**验真三法**（BUILD.json 只是声明）：`engine/strata --version` → **`strata 0.1.43.1`**（最省事）；`cmp` ≠ 回滚件；`/v1/status` → `engine`。
**回滚件**：`~/vault-backup/strata-engine-0.1.42-20261013/`（旧件 sha `071c4c01…` + BUILD.json + 模型配置 + 启动器）。

### §11.2 ⚠️ setup 会重写模型配置、丢掉手改 args
重编后 `strata-swift-iq3_s.json` 的 `args` **被换成默认**（`--spec 6 --kv k8v4 --pcie-frac 0.20 --spec-min-p 0.70 --max-context 262144 --vram-reserve-mib 700 --pipeline-windows 2` → `--spec 4 --spec-min-p 0.5 --max-context 65536 --kv int8`）⇒ **先备份、后 `diff`、再恢复**（本次已恢复，与备份逐字节一致）。

### §11.3 四臂 A/B（2026-10-13）：**零收益**
协议：新默认 / 新 PcieAuto（去 `--pcie-frac`）/ 新 `STRATA_ADAPT_OVERLAP=0` / 旧 0.1.42；同 args、**每臂重启**、`seed 1234`、`temperature 0`；decode = 3 题 × 3 rep、prefill = 36,487 tok 长题；harness `~/workspace/strata-ab/`。

| 臂 | decode 中位（剔 rep0 暖机） | 全 9 行中位 | prefill | 引擎自报 |
|---|---|---|---|---|
| 新 默认 | **96.21** tok/s | 86.99 | 2379 tok/s | 0.1.43.1 |
| 新 PcieAuto | 93.00 | 79.16 | 2384 | 0.1.43.1 |
| 新 `ADAPT_OVERLAP=0` | 95.40 | 74.40 | 2379 | 0.1.43.1 |
| **旧 0.1.42** | **94.41** | 92.56 | 2376 | 0.1.42 |

- 成对中位差 **+0.06…+3.66 tok/s**、单点幅度 −34.8…+6.0 ⇒ **不可分**；prefill **逐位一致**（2376–2384）⇒ 未证收益、亦未证回归。
- **两条候选收益对本机形态先天不适用（硬证据，非推断）**：
  1. **adaptive overlap 不在我们路径上** —— 引擎自报 `strata serve: adaptive overlap: off: not on a layer split`（三个新件臂各打一次、旧件臂不打）⇒ 0.1.43 的新默认**对 layer-split 按设计关闭**，故 0.1.43 的 pinned-host decode 回归（#1964/#1975）在本机不可能发生。
  2. **`--pcie-frac` 无杠杆** —— 日志中专家路由跨 PCIe **仅 0.0–0.4%**（decode 专家缓存命中 90.6–99.3%、33.14 GiB 专家驻 page-locked RAM）⇒ 手钉 `0.20` 与 PcieAuto 细化测不出差别。
- 📌 **方法论坑（新）**：decode **首 rep 是暖机**（48–52 → 94–99 tok/s，单臂内 ~2× 跨幅）⇒ n=3 不剔 rep0 会读成假「新件慢 17%」；**臂态以引擎自报日志为准**（`pgrep -f 'engine/strata '` 会自匹配探测 shell ⇒ `/proc/<pid>/environ` 读空，像是「env 未生效」）。

### §11.4 定格态（2026-10-13 14:18）
| 项 | 值 |
|---|---|
| 源码树 | `a0116b2`（`main`，落后 `origin/main` **0**）|
| 引擎件 | 68,080,136 B · sha `65e167e9797f6a1c…` · `--version` = `strata 0.1.43.1` · mtime 10-13 14:07 |
| BUILD.json | `0.1.43.1 / src 7089bf002d14a0e3 / archs[120] / cuda /usr/local/cuda` |
| 生产配置 | 34 项 args（已从备份恢复，逐字节一致）|
| 引擎 | `strata-swift-iq3s` **inactive**（按需；8080 无监听）|
| 残留 | ~~`build.pre-0143-20261013-1405`~~ —— **已于 2026-10-13 14:24 删除**（753.1 MiB，df 实释 ~1 GiB）· `~/workspace/strata-ab/`（208 K，A/B 证据，保留）|
