---
type: manifest
title: "Strata 推理引擎手册（本机双 RTX 5060 Ti · Qwen3.8-Flash-Next 单模型引擎 · ✅ 本机生产模型 2026-10-11 起）"
tags: [strata, engine, qwen3.8-flash-next, moe, multi-gpu, layer-split, sm120, local-inference, okf-v0.2]
description: "【✅ 本机生产模型（2026-10-11 起，与 NInfer 栈并列为第二条生产引擎线）】Strata（github.com/Niko1221/Strata，MIT）在本机（2×RTX 5060 Ti 16GB sm_120 / 59 GiB / 驱动 615.78.08 / CUDA 13.4）的完整部署手册：引擎身份与本地编译、产物路径、双卡 layer-split、systemd 运行方式、调优参数（生效 args + opt-in 实测 + 踩坑）、实测数字、Hermes provider 集成与工具调用验证"
trust: agent-generated
status: current
okf_version: v0.2
timestamp: "2026-10-29"
sources:
  - 上游仓库 Niko1221/Strata（**已装上游 main `4b9e05a2a`（tag v0.2.6），引擎 0.1.51，2026-10-26**；v0.1.45 为 2026-10-17；v0.1.44.1 为 2026-10-14 / v0.1.44 同日前 / v0.1.43.1 于 2026-10-13；tag v0.1.42 为 2026-10-11；v0.1.41 为 2026-10-08）：INSTALL.md / DETAILS.md / MULTI_GPU.md / MODELS.md / BATCHING.md / docs/release-notes-0.2.0.md
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
| 驱动 / CUDA | **615.78.08** / `/usr/local/cuda-13.4`（本地编译用）|
| CPU | Ryzen 7 9700X（AVX-512）|

## §2 引擎身份与血统
- **仓库**：`github.com/Niko1221/Strata`，**MIT**。只支持 Qwen3.8-Flash-Next（含 Swift / Coder / Unsloth 变体）。
- **版本**：**引擎 0.1.53 / 上游 main `46c152a13`（tag v0.2.7.1）**（2026-10-28 升级，见 §22；0.1.51 / v0.2.6 见 §20；0.1.49.2 / v0.2.4.2 见 §19；0.1.47 / v0.2.2 见 §18；0.1.46.3 见 §17；0.1.46.2 见 §16；v0.1.45 为 2026-10-17 / §13；v0.1.44.1 为 2026-10-14 / §12，v0.1.43.1 为 2026-10-13 / §11，v0.1.42 为 2026-10-11、v0.1.41 为 2026-10-08）。仅 3 周大的项目（首个 release 2026-09-24）。⚠️ 判版本只看 `engine/strata --version` 与 `engine/BUILD.json`：上游 tag 与引擎包版本号长期不同步（v0.2.7.1 = 引擎 0.1.53），大版本增量多在 app/Terminal/打包。
- **本机是本地编译，不是预编译**：`engine/BUILD.json` = `source=local, archs=[120], version 0.1.53, src=7a4844f3…, vision=cpu`（2026-10-28，**169/169** 步；旧 `build/` 与 `build-vision/` 因持有 `/home/ubuntu/...` 陈旧 CMakeCache 已移开并清理），留 `build/`（298M）。需 **nvcc/CUDA 13**。⚠️ 0.2.0 起 ENGINE 侧编译带 `vision: cpu` ⇒ 新增图片识别产物（本机启动参数未开 `--vision`，`/v1/status` 仍报 `vision false`）。
  - ⚠️ 上游 INSTALL 称 Linux 有 sm_120 预编译；**实测本机仍走了源码编译**——不要假设 50 系免编译。
- **多卡 = 按层切分的流水线并行（layer split / pipeline），不是张量并行**；无需 NVLink/P2P；每卡只缓存自己层的专家。

## §3 安装与产物路径
| 项 | 路径 |
|---|---|
| 引擎树 | `~/src/Strata`（`engine/strata` **114,432,176 B**（sha `68dfccc3…`），v0.1.53，mtime 10-28 17:31，见 §22；`serve/server.py`）· **树在 detached HEAD `cbfd5b92`（上游 main，2026-10-21 第二次 ff-only）**；回滚分支 `pre-update-20261020` = `477ac13c` |
| 数据（~133G）| `~/src/Strata-data/`：`models/swift-IQ3_S/`（两分片+.done）、`packs/swift-iq3_s/`、`mtp/{tensors,rt}` |
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
- **启动**：`systemctl --user start strata-swift-iq3s`（持久 user 单元 `~/.config/systemd/user/strata-swift-iq3s.service`，`Restart=on-failure`、**未 enable ⇒ 开机不自启**、按需；等同 `~/workspace/strata-swift-iq3s/bin/start.sh`）。停止：`systemctl --user stop strata-swift-iq3s`。 （该 wrapper 目录已不存在，现用 systemd 单元 + `~/src/Strata` 直跑）
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
（`--pcie-frac` / `--vram-reserve-mib` 在 **0.1.44 已删除** ⇒ 不再写入；见 §12.2 / §12.4b）
--mtp <Strata-data/mtp/rt>
--max-context 262144          # 256K（原生窗口；A/B 实测加载成功、decode −4%）
--kv k8v4                     # K=8bit/V=4bit，比 int8 省 23% KV 显存
--trim-stage-weights          # 每卡只加载自己层的 dense 权重（需显式 layer_split）
--pipeline-windows 2          # 两窗口在飞，双卡重叠（吃首卡 ~272MiB 缓存）
layer_split = 24   (gpu=[0,1])  # 48 层，0-23 / 24-47
env: STRATA_PREFILL_HELP=1
```
**opt-in 参考（官方 0.1.41 实测；本机可按需 A/B）**：
- ✅ 倾向开：`--pipeline-windows 2`（双卡 prefill +28%，2×3090 实测）、`STRATA_PREFILL_HELP=1`（空闲卡帮预取短 prompt +20~70%）。
- ⚠️ 试了测：`STRATA_SPEC_COUPLED=1`+`GUMBEL`（采样请求草稿接受率↑）、`STRATA_ADAPT_LAG=2`（小卡多半中性）。
- ❌ 不要用：`STRATA_GDN_CHUNKED=1`（需 ≥128 SM，小卡更慢）、`STRATA_FS_SLOTS`（所有机型更慢）、`STRATA_STAGE_PIN=1`（只对 mmap 模式有用，且有 IQ3_S 长 prompt 损坏未修）、`--adapt-async 1`（无 `--resident-experts` 时无效；**本机有该模式，2026-10-14 实测：decode +1.40；p=0.53 不显著、prefill −2.50；p=0.059 反向 ⇒ 不用**）。

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
- **〔v0.1.43.1 及更早，**0.1.44 已删该 flag**〕`--vram-reserve-mib` 不可低于 ~700**：设 300 时最后一张卡只剩 105 MiB，**MTP draft head（178 MiB）装不下** → 引擎退出（`mtp: the draft head does not fit`）。
- **`--calibrate` 收尾会启动模型并自动开浏览器**（无 `--no-browser`），且服务挂在它自己的瞬时单元下——想自己管就重挂。
- **重跑 `setup` 会覆盖手改的 `args`**（setup 只保留 sampling/mcp 等你加的键）。
- **RAM 取舍**：59 GiB 对 IQ3_S —— 低 RAM 模式（`--resident-experts`）余 ~17 GiB、更稳；正常模式仅余 ~3 GiB。跑前清内存。
- **sm_120 与 thread-block clusters 存在说法冲突**（官方称 RTX 50 有；4×5060Ti 旧 fork 称无）——以本机为准（未证）。
- **A/B 实测（2026-10-11）**：**256K 可用**——`--max-context 262144` 加载成功，代价 ~decode −4%（专家缓存 8210/5775 → 7719/5292 槽），换 2× 上下文。**`--prefill 32768` 是负优化**——引擎钳到 16384，20K prompt prefill 1829 vs `auto` 2170（−16%）→ 保持 `auto`。**（2026-10-13 于引擎 0.1.43.1 复测 `auto:32768`**：36,487 token 长题 prefill **2054.9 vs `auto` 2392.4 tok/s ＝ −14.1%**；日志显示引擎实际取 **`prompt chunk auto: 20736 tokens`**（不是 16384），请求起始 VRAM 只剩 **313 MiB**（`auto` 臂 337 MiB）⇒ 机制与上一条一致：块越大 → 流式环越浅 + 显存越紧 → 更慢。decode 90.85 → 89.26 tok/s（噪声内）。harness `~/workspace/strata-prefill-ab-20261013/`，两臂各重启一次、同 prompt、只动这一个 knob） （该一次性 A/B 工作目录已清理）
  （固定协议：decode=短 prompt×3 中位；prefill=中文 prompt；基线 ctx128K/prefill auto：decode 96.2、prefill 4.9K 1459、20K 2170）

## §9 P2P 实测（2026-10-11 用户提问触发）

| 证据 | 实测值 |
|---|---|
| 引擎血统 | `~/src/Strata/third_party/llama.cpp`（**本地编译的 llama.cpp 派生树**；`engine/BUILD.json` = `source=local, archs=[120], version 0.1.41→0.1.42→0.1.43.1→0.1.44→0.1.44.1→0.1.45→0.1.45.3→0.1.46.1→**0.1.46.2**, src 62eb4907c92a8cb7→1e0c97588848ea0f→7089bf002d14a0e3→3ef48793b38e2065→7dfd34378bd2d32a→b95137167bd9b751→25c992dfc5c6cb06→c10a555f95866240→**c56870384782…**（逐次升级后；0.1.46.2 = 上游 main `cbfd5b92`，2026-10-21；**再经 0.1.47/0.1.49.2/0.1.51/0.1.52 → 0.1.53 = 上游 main `46c152a13` / tag v0.2.7.1，2026-10-28，见 §22**）`）|
| 二进制里的 peer 符号 | `CanAccessPeer` 2 · `EnablePeerAccess` 2 · `MemcpyPeer` 2 · `P2P` 6 · `pcie_frac` 5（`peer_access`/`nvlink` 字面 0）|
| 服务层模式 | `serve/server.py:2161` —— **`--peer-device`**（第二卡作专家缓存层），且**与 `--layer-split` 互斥**（上游 #665）|
| 引擎自测链路 | `PCIe probe: 28.8 GB/s host->device … -> pcie_frac 0.55`（CUDA0 与 CUDA1 各一次）|
| 跨卡/PCIe 实际占比 | `decode expert cache hit rate` 81.4%→97.7%，其中「read by the GPU over PCIe **or from another GPU**」**10.9%→0.5%**（随缓存变热趋零）|
| 本机 P2P 能力 | `topo -p2p r` = **2 边 OK**（驱动 **615.78.08** + `SharkEzz/615.78.08-p2p` 补丁 DKMS，srcversion 内存==磁盘 `1520AB0911A959E9933C9EF`，hold **25**）|

> **结论**：该引擎**有** P2P 代码路径（含 peer-device 模式），但本机采用的 layer-split 形态下 **P2P 不在关键路径** —— 跨卡流量只占 0.5–11%。28.8 GB/s 与 P2P 实测 ~28.7 GB/s 同量级（host-staged 往返恰为一半 ~14.3）⇒ **该探测值本身不能区分 P2P 与直连 H2D**。因 Strata 不使用 NCCL，缺乏 per-channel `via P2P/...` 证据 ⇒ 「我们的 P2P 补丁对它是否有实际增益」**标 unverified，未宣称**。

> 📦 **已折叠归档 —— 引擎升级 v0.1.41 → v0.1.42（2026-10-11 09:55 完成）**：升级完成，`/v1/status` → `engine 0.1.42`；单请求 decode **102.1 tok/s**（旧区间 100–114，样本小/缓存冷）；`STRATA_ROUTE_TAIL_SKIP=7` 新默认已生效，A/B（7 vs 0 · n=14 配对 · **Wilcoxon p≈0.017**）**decode 中位 +9.0%（112.5 vs 103.2）**、prefill 两臂一致（570/549）。
> 🔧 **沿用坑与解法（原 §10 留档要点，勿丢）**：① **「假绿」坑** —— 旧 `update.sh` 打印 `[ok] engine compiled` 并把 `engine/BUILD.json` 改写成新版本 + 新 src 哈希，而 `cmake --build` 实为 `ninja: no work to do`、二进制逐字节未变 ⇒ 更新器此后比对 BUILD.json 直接秒退；**判据只看 `cmp 二进制` + 运行中引擎自报版本，别信 BUILD.json**（新版 setup 已改为诚实报错，见 §11.1 坑②）。② **裸 `setup.sh --yes` 不指定模型会按默认值换档并下载**（曾拉 Q2_0 37.62 GB）⇒ 只做引擎升级勿裸跑 `--yes`；确需带 `--yes` 则加 `--family swift --model IQ3_S`。③ **重编前置**：先停引擎释放 RAM（常驻 ~48 G）、旧 `build/` 需清空；官方回滚口 `--rollback-engine`（被替换的引擎留 `engine/.previous`）。
> 原文（含 §10.1 升级后实测、§10.2 A/B 完整表与复现脚本）见 [[20_Tech_Stack/_archive/strata_engine_manifest-版本文史-20261014|strata 旧版本实录]]。

## §11 升级记录 v0.1.42 → v0.1.43.1（2026-10-13，**用户选保留**）

**结论：🟢 实测零收益、亦零回归**（四臂 A/B：decode 中位 96.2/93.0/95.4/94.4 tok/s、prefill 2376–2384 逐位一致 ⇒ 广告的两项收益在本机均惰性；机制见 0.1.43 的 adaptive overlap 对 layer-split **按设计关闭** 与 PCIe 跨卡占比仅 0.0–0.4%）。
三个坑全部命中并排掉：**annotated tag 伪造「落后 N」** / **setup 重写 args** / **陈旧 `build/` 让 ninja 报 `no work to do` 而 setup 仍谎报成功**。

> 📦 完整实录（4 小节 + 四臂表 + 定格态）已归档：[[_archive/tech_stack/strata-engine-v0.1.43.1-upgrade-2026-10-13|§11 原文（2026-10-13）]]


## §12 引擎升级 v0.1.43.1 → **v0.1.44**（2026-10-14 08:02–08:22，用户指令「升级 strata」）

**结论：升级完成 ✅ —— 真换件、前缀复用守卫通过、无退化；启动参数经 4 臂 A/B 后维持现状。**

### §12.1 目标与路径（六步，全部按 §11 的已验证序列走）
- **目标**：tag **`v0.1.44`**。⚠️ **annotated tag 陷阱（本轮新踩）**：`git rev-parse v0.1.44` 给的是 **tag 对象** `e95507d2`，而它指向的 commit 是 **`ed4773eb` = 上游 `origin/main` 头** ⇒ 我一度误报"main 更靠前 271 commit"，实际**这一版就含全部 271 个**。判据：比较时用 `git rev-parse v0.1.44^{commit}` 或直接看 checkout 后的 `HEAD`。
- 树：`git -C ~/src/Strata checkout v0.1.44`（`engine/` 被 gitignore ⇒ 二进制不受影响）⇒ 树内 `MIN_ENGINE` 随之由 `(0,1,43,1)` 升到 **`(0,1,44)`**（这就是"版本门在树里"的机制）。
- 旧 `build/` **先移开**：`mv build build.pre-0.1.43.1-20261014`（217M）⇒ 否则 ninja 会 `no work to do` 假绿（§11 踩过）。
- `BUILD.json` 保持**如实**（`0.1.43.1` + `src 7089bf00…`）⇒ 树一换，hash 自然不符 ⇒ 重编触发器成立（无需像 §11 那样手工回写）。
- 重编在 **`systemd-run --user --collect`** 里跑（Hermes 后台 shell 有 4 GiB cgroup 上限）：`./setup.sh --yes --no-start --build --family swift --model IQ3_S`，带代理（FetchContent 要重取 vendored llama.cpp）。⇒ **153/153 步**、单元 `success 0`、耗时约 2 分钟。
- 二进制真值三法：`engine/strata --version` → **`strata 0.1.44`** ✅；`cmp` 与回滚件**不同** ✅；sha256 **`359d65ff94255e0b`**（旧 `65e167e9797f6a1c`）· 75,742,704 B（旧 68,080,136）· mtime 08:04:20。`BUILD.json` = `version 0.1.44, src 3ef48793b38e2065`（与二进制一致）。
- **回滚件**：`~/vault-backup/strata-engine-0.1.43.1-20261014-0802/`（旧二进制 + BUILD.json + 模型配置 + 启动器）。

### §12.2 ⚠️ setup 又一次重写 args（§11 的坑复现），且**新版删掉了两个 flag**
- setup 把 `strata-swift-iq3_s.json` 的 args 换成默认：`--spec 4 --spec-min-p 0.5 --max-context 65536 --kv int8`，并把 `layer_split` 从 `24` 改成 `auto` ⇒ 我们丢掉 10 项手改参数。
- **`0.1.44` 的 `--help` 里已无 `--vram-reserve-mib` 与 `--pcie-frac`**（后者被自动模式取代 —— 与 10-13 实测"该旋钮跨 PCIe 占比仅 0.0–0.4%、无杠杆"吻合）⇒ **还原时按新 `--help` 剔除，绝不照抄旧配置**（照抄会起不来）。
- 其余 16 个 flag 仍在（含 `--kv k8v4`、`--trim-stage-weights`、`--mtp-max-t`、`--spec-min-p`）⇒ 还原后回读：`layer_split=24`、`kv=k8v4`、`ctx=262144`、`spec=6`、`windows=2`、`resident-experts` ✅。`lib_dirs` 被 setup 换成 `/usr/local/cuda/...`，但该路径**解析到 cuda-13.4** ⇒ 等价、不改。
- **`layer_split` 必须是显式 `24`**：`--trim-stage-weights` 只在显式 layer-split 下生效（`auto` 下失效）。

### §12.3 验收（硬判据全过）
| 判据 | 实测 |
|---|---|
| 引擎自报版本 | `/v1/status` → `engine 0.1.44 · loaded true · ctx 262144 · serving 1`；三方言齐全 |
| **前缀复用（技能的硬门）** | 同一题第二次：`prompt 124,032 tokens = **124,027 reused** + 5 read in 37 ms` ⇒ 复用率 **99.996%**、`cache_n=124027` ✅（「99.6%→0.0%」那类回归未出现） |
| prefill 无退化 | 47,510 tok → **2576.9 tok/s**（记录：36,487 tok → 2392.4（0.1.43.1）/ 2379（0.1.42））；124,032 tok → 2802.6 tok/s。**题长不同不可直接比，但更长的题反而更快 ⇒ 记「无退化」** |
| Hermes 真实调用形状 | `tool_choice:auto` → `finish_reason=tool_calls` + `{"city":"Beijing"}`（1.66 s）✅ |
| MTP 草稿头 | 装得下（`draft head does not fit` 报错 0 次）✅ |
| 运行指标 | 专家缓存命中 94.6–96.6% · 跨 PCIe 1.6–2.4% · resident RAM 33.14 GiB · **0 次文件 blob 读** · `route tail skip` 计数持续增长（证明 tail-skip 生效）· RAM 38.7–39.4 GiB · 双卡各 ~15.6/15.8 GiB |

**⚠️ 日志行格式已变（技能里那条判据要更新）**：0.1.44 不再打印 `cache N (P%, private endpoint)`，改为
`prompt <N> tokens = <R> reused + <M> read in <ms> ms (<rate> tok/s), <G> generated in <ms> ms (<rate> tok/s), drafts accepted <a> of <b>`。

### §12.4 启动参数 A/B（4 臂，各重启换臂、同一 harness 3 轮 seed 1234、串行）
| 臂 | 改动 | decode 中位（跨题） | 范围 | prefill 中位 |
|---|---|---|---|---|
| `base` | 现状 | **93.8** | 89.4–96.8 | 458.3 |
| `mtp` | `--mtp-max-t 0`（解开草稿窗口上限） | 90.1 | 89.7–**134.3** | 457.7 |
| `minp` | `--spec-min-p 0.5`（新版默认） | 94.8 | 90.2–95.6 | 458.2 |
| `elas` | `+ --vram-elastic` | 91.7 | 89.5–96.5 | 458.4 |

**判决：三个候选全部不改。** 差异 −4% / +1% / −2% 全部小于本机噪声（同臂内散布 −5%…+48%、两次独立 `base` 中位 97.3 vs 93.8 ⇒ **中位本身有 ~4% 跑间噪声**）；prefill 四臂逐位一致（458）⇒ 这三个旋钮都在 decode 侧、没触到 prefill。
⚠️ `elas` 臂的**日志里没有任何 elastic/segment 字样** ⇒ **无法证明该旋钮生效过**（"启动行会撒谎、要拿证据"）⇒ 不采纳。
**维持的现状组合**：`--prefill auto`（抬高 = −14% 实测）· `--kv k8v4`（比 int8 省 23% 显存）· `STRATA_ROUTE_TAIL_SKIP=7`（vs 0 实测 +9.0%，p≈0.017）· `--pipeline-windows 2`（+28% prefill）· `--spec 6 --mtp-max-t 4 --suffix-draft 3 --spec-min-p 0.70` · `--resident-experts` · `--expert-cache auto`。

### §12.4b 第 2 轮 A/B：`--adapt-async 1` 与 `--mtp-q4 all`（2026-10-14 08:37–08:43，用户指令「那就 12 测」）

**协议**：3 臂各重启换臂、每臂 **9 轮**（同 `seed0=1234` ⇒ **同题**，跨臂天然配对）、剔 rep0、**配对符号秩检验**（不是比中位）。

| 对比 | decode 中位差 | 变好/变差 | p | 判决 |
|---|---|---|---|---|
| `base` vs `--adapt-async 1` | **+1.40** tok/s | 5/3 | **0.529** | 不显著 |
| `base` vs `--mtp-q4 all` | **+2.00** tok/s | 5/3 | **0.294** | 不显著 |
| **噪声底**（同一 base 配置独立跑两次：08:17 vs 08:37） | **−4.60** | 0/2 | — | **本协议检测下限 ≈5%** |

⇒ 两个候选的效应量都**小于噪声底** ⇒ **均不采纳**（准确表述是"本机测不出"，不是"无收益"）。

**生效证据（按 `engine started` 切日志）**
- `--adapt-async 1`：臂的 `engine started:` 命令行含该 flag ✅；**但 prefill 有反向迹象**：中位 −2.50 tok/s、7/8 轮更慢、p=0.059（边缘）。
- `--mtp-q4 all`：`strata mtp: --mtp-q4: draft head over 106299 tokens as Q4_0 (146.0 MiB read per step, was 212.9)` ⇒ 每步读带宽 **−31%** ✅；**但显存余量完全没变**（仍 `335 MiB` 满、CUDA1 `210 MiB LOW`）⇒ 省下的是带宽不是显存。
- `--mtp-q4` 的**真实代价**：草稿接受率 81.1% → **78.7%**（−2.4pt，Q4_0 草稿头略不准），与那点速度增益相抵。
- 反向佐证：`minp` 臂接受率最低（**69.8%**）却 decode 中位最高（**94.8**）⇒ **接受率与速度不单调**，不能当唯一指标。

**三条方法论（避免重踩）**
1. **臂的日志写进生产日志文件**（臂配置沿用生产 JSON 的 `log` 键）⇒ 脚本里 `journalctl` 取证是**无效证据**；必须按 `engine started:` 行（含时间戳与 `--config` 路径）**切片**。
2. 查 flag 存在性要查 **`serve` 侧**：`strata --serve --help`（=138 个 flag），不能只查 `generate --help`。
3. ⚠️ **引擎会建议一个已被删除的 flag**：满载日志说 `add --vram-reserve-mib 957 to the config's ar…`，而 0.1.44 的 138 个 flag 里**没有** `--vram-reserve-mib` ⇒ 上游自相矛盾（值得报 issue）。

**撤回一项**：先前清单第 4 项（`--spec-follow` / `--coupled-draft`）不该列入 —— `--spec-follow` 原文标 `benchmarks … (with --spec; **not --serve**)`，`--coupled-draft` 只对**采样**下的 MTP 有义，而本机 `temperature=0` 是贪心 ⇒ 对我们无效。

### §12.5 遗留观察（未动手，待可证收益）
满载后显存余量很小：`strata serve: 335 MiB of VRAM free with everything loaded`，且 `CUDA1: 210 MiB … - LOW: its window graphs are captured on first use and need room`。草稿头仍装得下（0 报错）⇒ **"紧但可用"**；要动它（降 context / 减专家缓存 / 找 `--vram-reserve-mib` 的替代）先得拿出可证收益。

## §13 引擎升级 v0.1.44.1 → **v0.1.45**（2026-10-17，264 commit）

**结论：已落地 0.1.45 ✅ —— 真换件；A/B 显示性能不可分（+2.7% decode / +0.2% prefill，均在本机 5% 噪声底内）；用户指令「按最新的落地」。**

### §13.1 差距与路径
- 上游 `pushed_at` = **2026-10-17 06:50 UTC（14:50 CST）**（最新 commit 的 committer 时间 04:39 CST）⇒ 当日 00:30 那轮审计报 0/0 是**真值**（当时还没推），非假阴性
- 落后 **264 commit**（`296b59d2` v0.1.44.1 → `477ac13c` v0.1.45），领先 0 ⇒ `git merge --ff-only origin/main` 干净快进
- 主题分布：`Merge perf-PR group {cache, serve, batch-1441, rdna34, rdna2, sm75}` 六组；prefill 18 / setup 14 / serve 14 / docs 14 / generate 8 / tests 7 / metal 7 / hip 5 / cpu 5 / verify 4
- 关注面 diff：`src` 70 文件 +17072/−958、`serve` 19 文件 +1597/−62、`include` 34 文件 +1159/−71；无 breaking / restructure
- 序列照 §12：移开 `build/`（267M → `build.pre-0.1.44.1-20261017`）→ `BUILD.json` 保持如实（0.1.44.1 + src `7dfd34378bd2d32a`）⇒ 树一换 hash 不符即触发重编（无需手工回写）→ `systemd-run --user --collect` 跑 `./setup.sh --yes --no-start --build --family swift --model IQ3_S`（带代理跑 FetchContent）⇒ **153/153 步**
- 二进制真值三法：`engine/strata --version` → **`strata 0.1.45`** ✅；md5 **`1e845f20…`**（旧 `bc1c3edf…`）· **77,921,704 B**（旧 75,746,872）· mtime 10-17 16:38；`BUILD.json` = `version 0.1.45, src b95137167bd9b751`（与二进制一致）
- **回滚件**：`~/vault-backup/strata-engine-0.1.45-20261017-1636/`（旧二进制 + BUILD.json + 模型配置）

### §13.2 setup 又重写了配置 —— §12.2 同款**两处**，无新坑
- `args`：**30 → 23 条**。丢 `--mtp-max-t 4 / --suffix-draft 3 / --trim-stage-weights / --pipeline-windows 2`；且 `--spec 6→4 / --max-context 262144→65536 / --kv k8v4→int8 / --spec-min-p 0.70→0.5`。按备份还原后 **30 条逐字一致**
- `layer_split`：**`24` → `auto`** —— §12.2 已记载的老坑，本次再验；必须改回显式 `24`，否则 `--trim-stage-weights` 静默失效
- **查 flag 存在性只能 `strata --serve --help`**（v0.1.45 = **141** 个）；`strata serve --help` 返回 `unknown argument: serve` + `generate` 用法，`grep -cE '^\s+--'` 得 **0** ⇒ 本次先据此错判 4 个「已删」flag，实为**全在**

### §13.3 A/B（新 vs 旧；同题同 seed 1234、temp 0、restart-per-arm、drop rep0、n=3）
| 指标 | v0.1.44.1（旧） | v0.1.45（新） | 差 |
|---|---|---|---|
| decode 中位 | 92.9 tok/s | 95.4 tok/s | **+2.7%** |
| prefill（28,852 token 长题）| 2313.5 tok/s | 2318.8 tok/s | **+0.2%** |
| 草稿接受率 | 78.8% | 77.7% | −1.1pt |
| 前缀复用 | `prompt_n=5` ✅ | `prompt_n=5` ✅ | 一致 |
| 冷启动 | 35s | 35s | 一致 |

**判决：不可分**（+2.7% < 本机 5% 检测下限 §12.4b；prefill 逐位一致）。机制解释（推断）：本机 `concurrency.serving=1`（单请求）⇒ `batch-1441` 组无杠杆；sm120 不在 `rdna34/rdna2/sm75` 覆盖面内。**下次不必重测这六个 perf 组。**

### §13.4 收尾与清理
- 引擎已停（按需）、8080 释放、GPU 回 27/16 MiB、内存可用 52G
- 清理 **953M**：3 个陈旧 `build.pre-*`（751M）+ 3 个旧二进制副本（`0.1.41.bak` / `0.1.43.1` / `0.1.45-keep`，202M）；**保留当前 `build/`**（274M，供同版本增量重编）
- A/B 证据：`~/workspace/strata-ab-0145/`（`measure.py` + `new-0145.txt` / `old-01441.txt`）

## §14 引擎升级 v0.1.45 → **tag v0.2.0-beta（引擎 0.1.45.3）**（2026-10-20 02:14–02:30，用户指令「升」）

**结论：已落地 ✅ —— 真换件（`strata 0.1.45.3`）；硬判据全过（前缀复用 99.98%、MTP 无报错、三方言）；性能不可分（decode 95.0 vs 95.4、prefill +0.3%）。**

### §14.1 差距判定（先查知识库再动手）
- 落后 **789 commit**（`477ac13c` v0.1.45 → `origin/main` `e88ee39d`），领先 0、**可纯快进**；但主体是 `apps/` **740 文件 +121,308 行**（桌面 UI）、`strata_control` +17,632；引擎核心 `src/` 55 文件 +7,860/−544、`include/` +1,628/−7
- 上游 tag 尾部已出现 **`v0.2.0-beta`**（`3d1fb480`，10-19 15:29）→ 已并入 main，main 再领先 **12 个提交（全是 docs/CI/README/portable bundle，无引擎改动）**
- 关键判据：发布说明原文「**Engine package version 0.1.45.3**」⇒ **引擎只涨了 3 个补丁号**，0.2.0 的大版本增量在 app/Terminal/签名更新订阅
- 0.2.0 的性能项逐条对照本机形态：零拷贝 page-cached 专家（1.16–2.88×）**不适用**（本机 `--resident-experts` + `packs/experts`，原文「Packs in `experts.bin` keep the old behaviour」）；prompt chunk 文件层（2.46×）**多半惰性**（专家常驻 RAM、file set 已进 page cache 时无变化）；CPU worker 按物理核 = **噪声级**；sm_86/sm_60 表、AMD gfx12、Intel XMX **不适用**（本机 sm_120）；图片识别默认开 = **新能力非提速**

### §14.2 升级序列（照 §12/§13）
- 回滚件：`~/vault-backup/strata-engine-0.1.45-pre-0.2.0-20261020-0214/`（`strata.0.1.45` + `BUILD.json.0.1.45` + `strata-swift-iq3_s.json.0.1.45` + `run-swift-iq3_s.sh`）；git 分支 `pre-update-20261020` = `477ac13c`
- `git checkout v0.2.0-beta`（`3d1fb480`）；`mv build build.pre-0.1.45-20261020`（274M）；`BUILD.json` 保持如实（0.1.45 + src `b95137167bd9b751`）⇒ 树一换 hash 不符即触发重编
- `systemd-run --user --collect --wait --unit=strata-build-020` + `http_proxy/https_proxy=127.0.0.1:7890` + `no_proxy=127.0.0.1,localhost` 跑 `./setup.sh --yes --no-start --build --family swift --model IQ3_S`
- 编译 **131/131** 步、3min 8s wall / 14min 40s CPU、**内存峰值 3.5G**（贴近 Hermes 后台 4 GiB cgroup 上限 ⇒ 必须 systemd-run）

### §14.3 本次唯一新坑：setup 后置 HF 预检在代理下失败（exit=1，但编译已完成）
```
=== Step 5: downloading Swift 1.5 IQ3_S ===
  [ok] … already downloaded / model files present
  [X]  cannot reach huggingface.co (<urlopen error [SSL: UNEXPECTED_EOF_WHILE_READING] …>)
```
- 官方提示改用 `--source modelscope`；本质是**编译后**的连通性预检，模型已在本地 ⇒ 不影响产物
- **副作用是好的**：setup 在写配置那步之前就退出，所以 `args` **逐字未变**、`layer_split` 仍 `24` —— 与前两轮（30→23 条、`24→auto`）不同，这次**无需还原**

### §14.4 二进制真值三法
`engine/strata --version` → **`strata 0.1.45.3`** ✅；`cmp` 与回滚件**不同** ✅；**84,822,920 B**（旧 77,921,704）· sha256 **`4c64f06ade4f3798d30f2fe4…`** · mtime 10-20 02:16；`BUILD.json` = `version 0.1.45.3 / src 25c992dfc5c6cb06 / vision cpu / vision_src 074945ccc2991e60`（与二进制一致）

### §14.5 验收（硬判据）
| 判据 | 实测 |
|---|---|
| `/v1/status` | `engine 0.1.45.3 · loaded true · ctx 262144 · serving 1 · vision false`；冷启动 ~50 s |
| **前缀复用** | 同一 28,852 token 题第二次：**`= 28,847 reused + 5 read in 34 ms`** ⇒ 复用率 **99.98%**，两次均如此 ✅ |
| prefill 无退化 | 28,852 tok → **2326.5 tok/s**（旧 0.1.45：2318.8） |
| MTP 草稿头 | `draft head does not fit` 报错 **0 次**；接受率 80.9%（旧 77.7%） |
| 专家缓存 / 跨 PCIe | 命中 **97.2–99.2%**；跨卡 **0.2–0.9%** |
| 显存 | 15687 / 15818 MiB（各卡 16311）—— 仍「紧但可用」 |

### §14.6 A/B（同协议：同题同 seed 1234、temp 0、drop rep0、n=3–4）
| 指标 | 0.1.44.1 | 0.1.45 | **0.1.45.3** |
|---|---|---|---|
| decode 中位 | 92.9 | 95.4 | **95.0（全 4 次）；98.0（drop rep0）** |
| prefill（28,852 tok） | 2313.5 | 2318.8 | **2326.5（+0.3%）** |
| 草稿接受率 | 78.8% | 77.7% | **80.9%** |

**判决：不可分**（decode −0.4% / prefill +0.3%，均远小于本机 5% 噪声底）⇒ 与 §13 判定一致：这一代增量对本机形态**无可测收益**，升的价值是「跟上 tag + 拿到 vision CPU 产物」。

### §14.7 收尾
- 引擎已停（按需）、8080 释放、GPU 回 **41/30 MiB**、内存可用 53G
- 清理 `build.pre-0.1.45-20261020`（274M）；保留当前 `build/`（298M）
- 留存未跟踪文件：`strata-swift-iq3_s.json.bak`、`strata-swift-iq3_s.json.setup-wrote-20261017`（历史遗留，未动）
- A/B 证据：`~/workspace/strata-ab-0145/`（同 harness，本轮标签 `new-020-beta`）
- ⚠️ 判据补充：换 tag 后 `strata --serve --help` 仍是 **141** 个 flag；`--mtp` **不在 help 列表里但被引擎接受**（服务正常加载）⇒ **flag 存在性不能只看 help**

## §15 引擎升级 v0.1.45.3 → **v0.1.46.1**（2026-10-21 01:36–01:45，114 commit，用户指令「升」）

**结论：已落地 0.1.46.1 ✅ 真换件；配置未被 setup 触碰（`args` 30 条 + `layer_split 24` 逐字保留）；experts.bin 预取特性在本机已生效（日志实证）；短题 decode 95.4 与 0.1.45.3 的 95.0/98.0 不可分。**

### §15.1 过程
- `git merge --ff-only origin/main`：`3d1fb480` → **`dea6920b`**（114 commit，detached HEAD，无冲突）
- 回滚件 `~/vault-backup/strata-engine-0.1.45.3-20261021/`（旧二进制 84,822,920 B + BUILD.json + 生产 JSON + unit）

### §15.2 新坑之一：陈旧 CMakeCache 记着**旧机器的绝对路径**（两处，连挂两次）
```
CMakeCache.txt directory /home/mmknet/src/Strata/build ... differs from /home/ubuntu/src/Strata/build
CMake Error: The source ... does not match the source "/home/ubuntu/src/Strata/CMakeLists.txt"
```
- 第 1 次：`build/` 的 cache 指向 `/home/ubuntu/src/Strata` ⇒ **7 秒失败**
- 第 2 次（移开 `build/` 后）：**`build-vision/` 也带 `/home/ubuntu/src/Strata/tools/vision`** ⇒ 引擎已编好（1min49s / 11min CPU / 3.4G 峰值）但 setup 在 vision 步骤 exit 1
- 判据（**一次列全，别逐个试**）：`find . -name CMakeCache.txt | while read f; do echo "$f -> $(grep -m1 CMAKE_HOME_DIRECTORY "$f")"; done`
- 本次移作 `build.pre-0.1.46-20261021` / `build-vision.pre-0.1.46-20261021`，均已清理
- 根因：home 从旧机（`ubuntu` 用户）备份恢复，构建目录里的绝对路径没跟着变 ⇒ **重装/迁移后第一次 `--build` 必查这条**

### §15.3 新坑之二：setup 的 Step 5 会**往 `~/src/Strata-data` 重新下载 83G 模型**
- 我们的模型在 **`~/Strata-data/`**（`--pack`/`--native` 显式指过去），setup 期望的位置却是 `~/src/Strata-data/models/swift-IQ3_S`
- 实测 ~1 分钟已写出 **5.4G `.part`** ⇒ 见到 `=== Step 5: downloading` **立即停单元**，`rm -f *.part*` 清掉；不要让它跑完（白下 83G，且下一步会重写 `strata-swift-iq3_s.json`）
- 正确顺序：**先停 → 验配置 → 再收尾**。本次停在写配置之前，`args` 30 条与 `layer_split 24` 原样保留（`--spec 6` / `--kv k8v4` / `--max-context 262144` 全对）

### §15.4 二进制真值
`engine/strata --version` → **`strata 0.1.46.1`** ✅；**84,833,016 B**（旧 84,822,920）· sha256 **`679c7ec1f9f88e7b…`**（旧 `4c64f06a…`）· mtime 10-21 01:43；`cmp` 与回滚件**不同** ✅；`BUILD.json` = `version 0.1.46.1 / src c10a555f95866240 / vision_src 41b0903f5d532e38`（与二进制一致；第 2 次失败后它一度仍是 0.1.45.3 的假戳，第 3 次跑通才写对）；`engine/strata-vision` = 8,253,128 B

### §15.5 验收（硬判据）
| 判据 | 实测 |
|---|---|
| `/v1/status` | `engine 0.1.46.1 · loaded true · ctx 262144 · serving 1 · vision false`；冷启动 **~110 s**（§14 为 50 s，原因未定，见 §15.6） |
| 层切分 | `layers 0-23 (CUDA0), 24-47 (CUDA1)`；expert cache 6105 slots / 10.98 GiB；CUDA1 4717 slots |
| **新特性生效（关键）** | 日志 `file tier io prefetch with whole-blob preads on 8 I/O threads, the decode's read-ahead only while the page cache has room for it and it pays (STRATA_IO_PF_GATE=1)`；`routing-aware prefetch on (the next layer's router, file tier)` |
| decode（drop rep0, n=3） | **95.4 tok/s**（all: 85.0 / 92.9 / 97.9）；对照 0.1.45.3 的 95.0（all 4）/ 98.0（drop rep0）⇒ **不可分** |
| 显存 | 15681 / 15810 MiB（各 16311）；CUDA1 `209 MiB free … LOW` 警告仍在（老现象，非本轮回归） |

### §15.6 未做与待办
- **未做** experts 预取的对照 A/B：开关 `STRATA_IO_PREFETCH` / `STRATA_IO_PF_GATE` / `STRATA_COLD_OVERLAP`（同一二进制、每臂一次重启）；短题证明不了它对 decode 的贡献，要做需长上下文双臂多重启
- 冷启动 110 s 原因未定（疑首次触盘新 vision/mmq 产物）；下次重启若仍 >100 s 再查
- 测速脚本重建于 `~/workspace/strata-ab-0146/measure.py`（**已不存在**：该目录随 2026-10-22/23 workspace 清理删除，需重建；旧 `strata-ab-0145/` 更早随重装丢失）

## §16 引擎升级 v0.1.46.1 → **v0.1.46.2**（2026-10-21 02:05–02:12，48 commit，用户指令「strata也升了」）

**结论：已落地 0.1.46.2 ✅；配置零改动；`serve/server.py` 的新代码随下次启动生效。重要修正在 §16.5 —— 0.1.46 的 decode 预取在本机被门控关闭。**

### §16.1 这 48 commit 是什么
- 主体是 **Control / Terminal / app / launch / setup + 测试**；`src/`、`include/` 对 `dea6920b` 的差异为 **0 行** ⇒ 引擎源码没动，只有 CMake 版本戳 0.1.46.1 → **0.1.46.2**（上游 commit 原话：`engine packages unchanged`）
- 唯一进入生产运行路径的是 **`serve/server.py`（+103/−23）** 与 `serve/runconfig.py`（+3）：`reasoning_budget_tokens`/`thinking_budget_tokens` 字段、Anthropic 风格 `cache_creation_input_tokens`/`cache_read_input_tokens`/`input_tokens` 记账、无 API key 与公网暴露的安全告警、vision workdir
- 因为我们的 unit 直接从树里跑 `serve/server.py`，**合并即生效、不必重编**；但为消除「树 0.1.46.2 / 二进制 0.1.46.1」的错配，仍重编了一次（163 步，约 2 min）

### §16.2 流程与两次复用到的坑
1. 回滚件 `~/vault-backup/strata-engine-0.1.46.1-20261021/`（0.1.46.1 二进制 + BUILD.json + 生产 JSON）
2. `git merge --ff-only origin/main`：`dea6920b` → **`cbfd5b92`**
3. `setup.sh --yes --no-start --build`（systemd-run，代理 env）→ 引擎 163/163 编完
4. **Step 5 再次触发下载**（`~/src/Strata-data`，已写 6.5G `.part`）⇒ 按 §15.3 立即停单元并清 `.part*`，回到 12K
5. 配置校验：`args` 30 条与备份**逐字相同**、`layer_split 24`（setup 死在写配置之前，再次幸免）

### §16.3 二进制真值
`engine/strata --version` → **`strata 0.1.46.2`**；**84,833,016 B**（与 0.1.46.1 同尺寸）· sha256 **`8d2bb23907ffd3c0…`**（旧 `679c7ec1…`，`cmp` 不同）· mtime 10-21 02:07；`BUILD.json` = `0.1.46.2 / src c56870384782…`（与二进制一致）

### §16.4 验收
| 判据 | 实测 |
|---|---|
| `/v1/status` | `engine 0.1.46.2 · loaded true · ctx 262144 · serving 1` |
| 冷启动 | **~30 s**（上一轮 110 s 的慢启动没复现 ⇒ 那是首编后冷页，不是回归） |
| 经路由器 8097 实请求 | HTTP 200，`model swift-1.5-iq3_s`，正常返回（`prompt_tokens 58 / cached 53`） |
| 层切分 | `layers 0-23 (CUDA0), 24-47 (CUDA1), one hand-off per window` |

### §16.5 **修正 §15.5 的预取判读（重要）**
0.1.46.2 新增的每请求 I/O 遥测把这台机器的真实情况打了出来：

```
decode gate: cache room 0.34 of the experts, ... closed, closed in 483 windows so far, 1 flips
io prefetch: 0 read ahead (297.4 MB by pread), 0 used ...; page cache held 35367.6 MB at the read
```

- **decode 侧 read-ahead 在本机是「关闭」状态**：`cache room 0.34` < 门限 0.55 ⇒ 作者在 32 GB 机器上测到的 1.21–1.38× **拿不到**
- prefill 侧的 io prefetch 开着，但实测 `0 read ahead`：OS 已从盘读了 61 GB、页缓存持 35 GB，预取无事可做
- 因此 §15.5 里「新特性生效」要限定为 **代码路径生效、收益未发生**；不要对用户报「拿到 1.2–1.38×」
- 强开（`STRATA_IO_PREFETCH=1`）不建议：作者自己实测 16 GB 机器上 4K 冷 prompt **慢 4–6%**，而我们 49 GB 专家包 / 60 GB 内存下的 0.34 比例正落在「页缓存不够」那一侧

### §16.6 回滚
`~/vault-backup/strata-engine-0.1.46.1-20261021/strata-0.1.46.1`（cp 回 `engine/strata` 即可）；旧锁 `.git` 树 HEAD 可用 `git reset --hard dea6920b` 回到上一棵树。引擎已按需停止（8080 空）。

## §17 引擎重编 v0.1.46.2 → **v0.1.46.3**（2026-10-21 17:35–17:45，Control-only 更新）

- **上游 4 个提交全在 `strata_control/` + 测试**（下载完整性逐块校验、AMD gfx 选择、进度文案），**`src/` `include/` 引擎源码零改动**；CMakeLists 仅版本号 0.1.46.2 → 0.1.46.3。
- **重编**：`setup.sh --yes --no-start --build --models-dir ~/Strata-data/models --family swift --model IQ3_S`，经 `systemd-run --user --collect --property=MemoryMax=infinity` 跑（绕 hermes-worker 4 GiB cgroup）。产物 `engine/strata` 84,833,016 B / sha256 `cae66a0e67f30040…` / `BUILD.json` = version 0.1.46.3, src `c87773ed5df25479`。
- ⚠️ **setup.sh 会把数据目录算成 `~/src/Strata-data`（非生产 `~/Strata-data`）并开始下 83G 模型**：已把 `~/src/Strata-data` 改为**软链** → `~/Strata-data`，重跑即跳过下载。误下的 1.5G `packs/` 已删。
- ⚠️ **setup.sh 同时改写了 `strata-swift-iq3_s.json` 的生产参数**：`--spec 6→4`、`--spec-min-p 0.70→0.5`、`--max-context 262144→65536`、`--kv k8v4→int8`，删掉 `--pipeline-windows 2` / `--resident-experts`，加 `--vision`，`gpu [0,1]→0`，`layer_split 24` 键被移除。**已按升级前备份逐字恢复**（`~/workspace/strata-swift-iq3_s.json.pre-01463（2026-10-28 已清理）`），并补新版新增的 `vision`/`user_args`/`args_written` 键。
- **验收**：`strata --version` = 0.1.46.3；单元启动 `/v1/status` 200、`context.native = 262144`（证明生产参数生效、没被改成 65536）；真推理一次返回通顺中文（prompt 56 / completion 62 tokens）；验完即停（回到按需启动）。

## §18 引擎升级 v0.1.46.3 → **v0.1.47 / tag v0.2.2**（2026-10-22 02:34–02:47，238 commit，用户指令「升一下 strata」）

**结论：已落地 0.1.47 ✅ 真换件（85,627,608 B，sha `a536b6a9…`）；配置按备份逐字恢复（args 31 条 + `layer_split 24`）；性能不可分（decode 83.8→87.3、prefill −0.2%）；工具调用/前缀复用/路由器路径全通；**首次没有被 Step 5 下载威胁**（`~/src/Strata-data` 软链生效）。**

### §18.1 这一版有什么（238 commit，v0.2.1.4 → v0.2.2）
- tag `v0.2.2` 解引用 = `011c9e60` = `origin/main` 头（无 annotated-tag 假落后）
- **引擎源码真动了**：`src include serve` **42 文件 +3654/−127**（0.2.1.x 的几轮里唯一一次）
  - `serve/`：tool-call 信封修复（#3441 drifted opener / #3075 未声明工具归为文本）、`serve/test_tool_call_envelope.py` 新增
  - `src/core/expert_source.cpp` +295（专家流式）、`src/kernels/cpu/pool.cpp` +492（NUMA/线程池）、`src/prefill/gemm.cu` +43、`src/program/generate.cpp` +152（spec 循环起点、`STRATA_SPEC_WATCH` 看门狗）、`src/core/verify.cpp` +40（#3465 NaN 重试整段读 prompt）
  - 其余大头是别的后端/别的卡：Gyro trellis（`tq_pascal_bench`，8-lane 行）、HIP/RDNA、Strix Halo UMA、Metal、RX 6000 包
- CMake：`project(strata VERSION 0.1.46.3 → 0.1.47)` + 两个新测试目标

### §18.2 流程（沿用 §17 路由，全部一次通过）
1. 回滚件 `~/vault-backup/strata-engine-0.1.46.3-20261022/`（旧二进制 + BUILD.json + 生产 JSON + unit）
2. `git merge --ff-only origin/main`：`9de04cd4` → **`011c9e60`**（238 commit，无冲突；merge 未碰生产 JSON）
3. `setup.sh --yes --no-start --build --models-dir ~/Strata-data/models --family swift --model IQ3_S`，经 `systemd-run --user --collect --property=MemoryMax=infinity`（163 步，约 2 min，**复用现有 `build/`、未重配** —— 本次 CMakeCache 路径正确，无需移走）
4. **Step 5 只打印「already downloaded」**，无 `.part`、无 83G 重下 ⇒ §17 的软链治本生效
5. 配置恢复见 §18.3

### §18.3 setup 又一次改写配置 —— 恢复清单（第 4 次复现，模式不变）
| 键/参数 | setup 写成 | 生产值（已恢复） |
|---|---|---|
| `args --spec` | 4 | **6** |
| `args --spec-min-p` | 0.5 | **0.70** |
| `args --kv` | int8 | **k8v4** |
| `args --max-context` | 65536 | **262144** |
| `args --pipeline-windows` / `--resident-experts` | 删除 | **2 / 保留** |
| `args --vision` | 新增 | 保留（见 §18.4） |
| `layer_split` | `auto` | **`24`**（`--trim-stage-weights` 只在显式值下生效） |
| `tokenizer` | `/home/mmknet/src/Strata-data/…` | **`/home/mmknet/Strata-data/…`** |
| `gpu_roles` / `gpu_order` | **0.2.2 新增键**：`{'0':'helper','1':'main'}` / `as_given` | 保留（与旧 `gpu [0,1]` 等价，日志实证） |

- 恢复做法：从备份 `dict(bak)` 整体恢复 → 覆盖 `gpu_order`/`gpu_roles`/`vision`（新键）→ `args_written = args`；断言 `args == bak['args']`、`layer_split=='24'`、`gpu==[0,1]`
- setup 写的版本留档 `strata-swift-iq3_s.json.setup-wrote-20261022`

### §18.4 新行为：`serve` 会自动补 `--vision`
`serve/server.py:2974` —— 配置里有 `vision` 段而 `args` 里没有 `--vision` 时，**引擎启动自动追加 `--vision`**（并打一行提示）。所以「我恢复的 args 没 --vision」并不等于视像关闭，日志会明说 `images on`。
本次把 `--vision` **写成显式**（args 31 条）以免未来静默漂移。副作用：专家槽 6105 → **6101**（视觉编码器占一点），其余不变。

### §18.5 二进制真值
`engine/strata --version` → **`strata 0.1.47`** ✅ · **85,627,608 B**（旧 84,833,016）· sha256 **`a536b6a9cedbba31…`**（旧 `cae66a0e…`）· mtime 10-22 02:37 · `cmp` 与回滚件不同 ✅ · `BUILD.json` = `version 0.1.47 / src ba8a2d3595085632`（与二进制一致）· 树 `011c9e60` = tag v0.2.2 ⇒ **树/二进制配对**

### §18.6 验收
| 判据 | 实测 |
|---|---|
| `/v1/status` | `engine 0.1.47 · loaded true · native 262144 · serving 1`（证明生产参数没被改成 65536） |
| 冷启动 | **35–36 s**（连续两次） |
| 层切分 / 角色 | `layer split across GPUs [0, 1] (24)`；新日志 `card roles: Main GPU 1, Helper GPU 0` |
| 专家缓存 | `filling the GPU's expert cache (6101 experts, 10.98 GiB of VRAM)` |
| 前缀复用 | 同 prompt 二次 `cached_tokens=59/64`，wall 0.59 s |
| 工具调用 | `finish_reason=tool_calls`，`get_time{"tz":"Asia/Shanghai"}` ✅（本版 `serve/` 正是修信封的那批） |
| 路由器真实路径 | `curl 8097` → `model swift-1.5-iq3_s`，答「北京」✅ |

### §18.7 A/B（旧 0.1.46.3 vs 新 0.1.47，同配置重启换件，温度 0）
- decode 同题 4 轮丢 r0 取中位：**83.8 → 87.3 tok/s（+4.2%）**，落在本机 ~5% 噪声底内 ⇒ **不可分**（未见回归）
- prefill 54,628 token：**2666 → 2661 tok/s（−0.2%）** ⇒ 一致
- 判定：这一版对本机的价值在 **serve 层修复（tool-call 信封）**，不在吞吐；吞吐照旧「测不出」

### §18.8 回滚
- 引擎件：`cp ~/vault-backup/strata-engine-0.1.46.3-20261022/strata-0.1.46.3 ~/src/Strata/engine/strata`（新版另存 `engine/strata.0.1.47-keep`）
- 树：`git -C ~/src/Strata reset --hard 9de04cd4`
- 配置：`cp ~/vault-backup/strata-engine-0.1.46.3-20261022/strata-swift-iq3_s.json ~/src/Strata/`
- 引擎已按需停止（8080 空，双卡 44/33 MiB，MemAvailable 55 GiB）

### §18.9 本轮唯一的探针新坑
`grep -cE '^\s+--'` **在 GNU grep 里不匹配**（`\s` 不是 ERE 字符类）⇒ 选项数读成 **0**，极易误判「所有 flag 都被删了」（本轮先中了一次）。正确写法 `grep -cP '^\s+--'`（本次 143 个）或 `grep -cE '^[[:space:]]+--'`。这与 §12 记的「选项数为 0 是探针坏了」是同一条，但**触发方式不同**，记在这里。

## §19 引擎升级 v0.1.47 / v0.2.2 → **v0.1.49.2 / tag v0.2.4.2**（2026-10-25 09:28–09:45，用户指令「直接升到最新版」）

**结论：已落地 0.1.49.2 ✅；`args` 首次未被 setup 改写（31 条与升级前逐行一致）；性能与 0.1.47 等价（同场 A/B 中位 84.1 → 81.9 tok/s，−2%，落在噪声内）；功能面（问答/前缀复用/tool-calls）全通；**这一版对本机没有可测收益**，价值仅为「跟上游 + 避开 0.2.3 的 setup 崩溃」。**

### §19.1 这一版有什么（跨 0.2.3 / 0.2.3.1 / 0.2.4 / 0.2.4.2）
- **0.2.3**：Strix Halo 提速（gfx1151 实测 +6~19%）、Intel Arc 成为正式引擎包、**DFlash2 起草器（Terminal 专用，opt-in）**、agent chat 满上下文裁剪（64K 窗口峰值 83%→61%）、HTTPS 用系统证书、Work 档默认值（5 CPU worker / 留 1536 MiB 显存，RTX 5070 12G 31→45 tok/s）、会话缓存按空闲内存定容、引擎包 0.1.47→0.1.48
- **0.2.3.1**：修 setup 逐字符读「图形卡代次列表」崩溃（Windows NVIDIA 包崩，**Linux 包同款列表** ⇒ 必须 ≥0.2.3.1）
- **0.2.4 / 0.2.4.2**：全部 DeepSeek 相关（Zen2 系 CPU 快 3×、picture-file 误判、已有文件识别、多安装选引擎、GitHub 不可达提示、会话落盘缓存、引擎自更新、不再顺带下载 Qwen 引擎），**app 仍 0.2.3，Qwen 引擎包不变**（实际本机编译出 0.1.49.2）
- **对本机的相关性：唯一可能相关的是 DFlash2，但引擎二进制没有 `--drafting`** —— 实测 `engine/strata --help` 只有 `--mtp / --mtp-max-t / --spec / --suffix-draft / --batch-mtp`；`--drafting` 属 Terminal。源码安装 + 自建 unit 的用户**拿不到** DFlash2，除非改装官方 Terminal。

### §19.2 流程（与 §18 不同：用 `update.sh` 而非 `setup.sh --build`）
1. 备份 `~/workspace/strata-pre-0242/`（生产 JSON + `BUILD-0.1.47.json` + `HEAD.txt` + 本手册改前副本）—— **该目录已于 2026-10-28 清理**，历史记录保留，回滚请用 `~/vault-backup/strata-pre-5e8a4cc-20261028/`
2. `git merge --ff-only origin/main`：`011c9e60`（v0.2.2）→ **`7dd5cf18e`**（tag v0.2.4.2，无冲突）
3. `./update.sh --yes --no-start`（= git pull + setup 的预启动步骤）：**源码编译 165/165 步 + vision 6 步**（约 2 min），产出 `engine/strata` = 0.1.49.2
4. 该脚本自带 `--no-start` ⇒ 不会拉起模型；模型文件未动（日志 `swift-1.5-iq3_s: up to date`）

### §19.3 setup/update 改写配置 —— 本次**没有**发生（第 5 次记录，首个反例）
`args` 31 条与升级前**逐行 diff 一致**（`--spec 6`、`--spec-min-p 0.70`、`--kv k8v4`、`--max-context 262144`、`--pipeline-windows 2`、`--resident-experts`、`--vision` 全在），`layer_split` 未动。
⇒ 判定：`update.sh` 走「模型设置 up to date」分支时不重写 JSON；只有 `setup.sh` 重跑模型配置（§18.3 的 4 次复现都属后者）。**仍建议每次升级前备份 JSON 并 diff 复核**，不要据此假设安全。

### §19.4 二进制真值
`engine/strata --version` → **`strata 0.1.49.2`** ✅ · **87,350,960 B**（旧 85,627,608）· sha256 **`21e0d6a0f8843666…`**（旧 `a536b6a9…`）· mtime 10-25 09:30 · `BUILD.json` = `version 0.1.49.2 / src b9993e25b7e78735 / archs [120] / source local / vision cpu`（与二进制一致）· 树 `7dd5cf18e`

### §19.5 验收
| 判据 | 实测 |
|---|---|
| `/v1/status` | `loaded true · max_context 262144 · model swift-1.5-iq3_s · images true` |
| 冷启动 | **39 s** |
| 显存 | 双卡 15,603 / 15,730 MiB（与 0.1.47 同量级） |
| 基础问答 | 「13 的平方」→ `169` ✅ |
| 前缀复用 | `cached_tokens=59/64`，wall **0.54 s** ✅ |
| 工具调用 | `finish_reason=tool_calls`，`get_time{"tz":"Asia/Shanghai"}` ✅ |
| 长 prompt | 17,175 tok → prefill **1,997 tok/s**（冷态首次） |

### §19.6 A/B（旧 0.1.47 vs 新 0.1.49.2，同会话交替换件、同 args、同 prompt、温度 0，各 5 轮）
| 引擎 | 5 轮 decode（tok/s） | 中位 |
|---|---|---|
| 0.1.47 | 72.1 / 82.8 / 84.1 / 86.0 / 89.0 | **84.1** |
| 0.1.49.2 | 71.1 / 81.9 / 80.6 / 86.4 / 86.0 | **81.9** |

- 差 **−2%**（轮内波动 71→89，±10%）⇒ **等价，不构成回归**。注意：单轮首跑必偏低（GPU 时钟爬升），任何 A/B 都要丢首轮。
- 判定：这一版对本机**无可测收益**；不采用 DFlash2 的前提下不值得单独升级，本次属「用户指令直接升到最新」。
- **2026-10-25 决定：继续用 MTP，不启用 DFlash2**（引擎 0.1.49.2 已支持 `--draft mtp|dflash2` + `--draft-cap` + `--draft-conf`，但需 1.2 GB 起草器 + 0.76 GB pack，且额外占 ~1.2 GB 显存——两卡现满载 15.6/15.7 GB，只能从专家槽扣，官方亦未证明 DFlash2 全面更快）。配置保持 `--mtp --spec 6 --mtp-max-t 4 --suffix-draft 3`。

### §19.7 回滚
- 引擎件：`cp ~/src/Strata/engine/strata.0.1.47-keep ~/src/Strata/engine/strata`（新版另存 `engine/strata.0.1.49.2-keep`）
- 树：`git -C ~/src/Strata reset --hard 011c9e60`
- 配置：`cp ~/workspace/strata-pre-0242/run-config.json ~/src/Strata/strata-swift-iq3_s.json`（**该备份已于 2026-10-28 清理**，现存最老可用备份见 §21.4）
- 手册：`cp ~/workspace/strata-pre-0242/manifest-before.md` 覆盖本文件（**该副本已清理**）
- 引擎已按需停止（8080 空、双卡 41/30 MiB）

### §19.8 `--expert-cache-per-layer` A/B（2026-10-25 10:05–10:12，同 args、同 prompt、各 6 轮）

| 臂 | 专家槽 | 冷启动 decode | 稳态 5 轮（tok/s） | 中位 | 自报命中率 | PCIe 溢出 |
|---|---|---|---|---|---|---|
| A 默认（共享计数器） | 6101 / 10.98 GiB | 67.7 | 82.3 / 87.1 / 83.7 / 82.2 / 85.6 | **83.7** | 98.8→99.6% | +0.1% |
| B `--expert-cache-per-layer` | 5712 / 10.89 GiB | 62.9 | 76.7 / 78.4 / 78.7 / 78.2 / 78.0 | **78.3** | 95.0→96.3% | +1.8~2.6% |

**结论：本机不采用（−6.5% decode）。** 机制解释：每层独立分槽后总槽位利用变差（专家 6101→5712），热点被打散 ⇒ 命中率从 99.5% 掉到 96%，多出来的 PCIe 回退把 decode 拉低。
官方那个「2.97% → 21.4%（8 槽/层）」的前提是**静态 profile、按到达顺序填满的小缓存**场景；本机是 `--expert-cache auto` + `--expert-profile` 的自适应 + 预热，命中率本来就在 99%+，per-layer 只起反作用。
已回滚：`args` 恢复 31 条，与 `~/workspace/strata-pre-0242/run-config.json` 逐条一致（该备份已于 2026-10-28 清理）；引擎验证后停回按需态。

## §20 引擎升级 v0.1.49.2 / v0.2.4.2 → **v0.1.51 / tag v0.2.6**（2026-10-26 10:21–10:40，用户「升」）

**结论：已落地 0.1.51 ✅；`args` 31 条逐行未变；同场 A/B 与 0.1.49.2 **等价（−0.3%，噪声内）**；这一版对本机唯一相关改动是 IQ3_S 的 AVX-512 CPU 专家行，实测未见收益。**

### §20.1 版本关系（易混淆，先记死）
- 上游 `v0.2.5`（10-25）把**所有引擎包（Qwen + DeepSeek）+ Control 都重编为 0.1.50**；`v0.2.6`（10-25）只再动 DeepSeek 与 Control → **0.1.51**，release notes 明写「Qwen engines stay at 0.1.50: nothing in them changed」。
- **但本机是源码编译**：CMake 项目版本在 0.2.6 已跳到 0.1.51，所以 `engine/strata --version` 报 **0.1.51**，而 Qwen C++ 内容等同官方 0.1.50 包。审计/对账时不要因此判「版本不一致」。

### §20.2 这一版有什么（163 commit，0.2.4.2 → 4b9e05a2a）
- **与本机相关（唯一一条）**：`16c4da944 CPU expert rows: 512-bit grid lookups by gather where a gather is cheap; one IQ3 token on the exact 512-bit rows` —— 改 `src/kernels/cpu/native_expert.cpp`（+53 行），带一个**逐类型一次性校验**：只有本机 ggml-cpu 的 dot 在合成块上逐位一致时才启用 512 位精确行。直接对应 IQ3_S 专家行的 AVX-512 路径（9700X 有 AVX-512）。
- **无关项（占绝大多数）**：DeepSeek Speed 档（6 专家取 5）、RAM store 不再卡 48 GB、prompt chunk 默认规则、单文件安装器（引擎改为首次启动下载）、Windows 卸载器收尾、图形小核在监控里剔除、8K 上下文显示、文档/七语言 README。
- `--spec-split` 在 0.2.4.2 就已存在，非新增。

### §20.3 流程（与 §19 相同的源码路径，脚本未变）
1. 备份 `~/workspace/strata-pre-026/`（run-config、BUILD-0.1.49.2.json、HEAD、旧引擎件另存 `engine/strata.0.1.49.2-keep`）—— **已于 2026-10-28 清理**，历史记录保留
2. `git fetch --tags` → `git merge --ff-only origin/main`：`7dd5cf18e` → **`4b9e05a2a`**（`origin/main` 与 tag v0.2.6 同一提交）
3. `./update.sh --yes --no-start` → **165/165 步编译 + vision 6 步**，日志 `~/workspace/strata-update-026.log`（**已清理**），`EXIT=0`，末行 `[ok] Strata is updated (engine 0.1.51)`
4. `update.sh`/`setup.sh` 在 0.2.4.2→0.2.6 之间**没有 diff**，0.2.5 的安装器改动只影响官方安装包，不影响源码路径。

### §20.4 验收
| 判据 | 实测 |
|---|---|
| `/v1/status` | loaded true（冷启动 36 s） |
| `engine/strata --version` | **0.1.51** · 87,421,464 B · `BUILD.json: 0.1.51 / [120] / src a88a598cd60d6ee1` |
| 配置 | `args` 31 条与升级前**逐行一致**（`update.sh` 仍走「模型设置 up to date」，第 6 次复现） |
| 专家缓存 | 填 6101 个 / 10.98 GiB（与 0.1.49.2 同量级） |
| 结束时状态 | 停回按需态，显存 41 / 30 MiB |

### §20.5 A/B（0.1.49.2 vs 0.1.51，同 args、同 prompt、温度 0，两轮交替，丢弃每次冷启动首轮）
| 引擎 | 样本 | 均值 | 中位 | 区间 | 标准差 |
|---|---|---|---|---|---|
| 0.1.49.2 | 9 | **85.4** | 85.8 | 80.1–89.5 | 3.0 |
| 0.1.51 | 10 | **85.1** | 84.7 | 80.2–91.3 | 3.0 |

- 差 **−0.3%**，标准差 3.0 ⇒ **等价**。专家命中率两臂均 98.8–99.5%、PCIe 溢出 +0.1~0.3%。
- 判读要点：单臂样本量 <8 时噪声可达 ±5%（本轮第一遍看起来像 −3%，第二轮反转），**任何 A/B 至少要两轮交替**。

### §20.6 回滚
- 引擎件：`cp ~/src/Strata/engine/strata.0.1.49.2-keep ~/src/Strata/engine/strata`（更早 0.1.47 亦留盘）
- 树：`git -C ~/src/Strata reset --hard 7dd5cf18e`
- 配置：`cp ~/workspace/strata-pre-026/run-config.json ~/src/Strata/strata-swift-iq3_s.json`（**该备份已于 2026-10-28 清理**）

## §21 引擎升级 v0.1.51 → **v0.1.52 / 上游 main `5e8a4cca7`**（2026-10-28 08:59–09:25，用户「升」）

**结论：已落地 0.1.52 并保留 ✅（用户 2026-10-28 10:03「落地最新的引擎吧」确认保留；114,431,872 B，sha `c2f3c1f2…`）；生产配置 31 条 args 已按备份逐字恢复；A/B 判无收益 —— decode 与 0.1.51 等价（+0.2%），冷 prefill TTFT 反而 +3.2%（1.462 → 1.510 s）。保留理由：与上游 main `5e8a4cca7`（release notes 0.2.7）对齐、无功能/精度损失、decode 不变，只有 prefill 慢 3%（在 1.46–1.55 s 抖动带内）。**

### §21.1 这一版有什么（367 commit，4b9e05a2a → 5e8a4cca7）
- **关注面实质改动**：`src/prefill/` 新增一组 MoE weight-stationary 内核 —— `moe_ws.cu`(+165) `moe_ws_down.cu`(+645) `moe_ws_gu_iq2.cu`(+736) `moe_ws_gu_iq3.cu`(+370)，`prefill.cpp` **+2034**、`generate.cpp` **+1986**、`moe_mmq.cu`(±88)；`src/include` 面 **128 文件 +20,926 / −651**，全部为上游新增（本地移植 0）。
- 判读：这是继 §20「只动 CPU 专家行」之后**第一次真正改 prefill 内核**的版本，所以本轮专门补了冷 prefill 测量（见 §21.3）。

### §21.2 流程（update.sh 的 pull 被代理打断 ⇒ 走 setup.sh 重编）
1. 回滚点：`~/vault-backup/strata-pre-5e8a4cc-20261028/`（`strata-0.1.51` 84M + `BUILD.json-0.1.51` + `HEAD.txt`）；生产配置备份 `~/workspace/strata-pre-5e8a/run-config.json`；新件另存 `~/workspace/strata-0.1.52-keep`。
2. `git merge --ff-only origin/main`：`4b9e05a2a` → **`5e8a4cca7`**（fetch 首次因代理 TLS 抖动失败，但 origin/main 已被审计轮 fetch 过，merge 直接成功）。
3. **`update.sh --yes --no-start` 失败**：它第一步 `git pull --ff-only` 再撞代理 TLS（`GnuTLS, handshake failed`）后 `EXIT=1` 中止，**没有跳过 pull 的开关**。改用 `setup.sh --yes --no-start --build --models-dir ~/Strata-data/models --family swift --model IQ3_S`，经 `systemd-run --user --collect --unit=strata-build-5e8a --property=MemoryMax=infinity` 跑，**150 个编译单元 / EXIT=0**，日志 `~/workspace/strata-build-5e8a.log`。
4. 二进制身份：`strata 0.1.52` · 114,431,872 B（旧 87,421,464）· sha `c2f3c1f2227a0013d23dd756…`（旧 `6b2b8802f90cc0cf…`）· mtime 10-28 09:03 · `BUILD.json` = `0.1.52 / [120] / src b7ff2efbe0819d6b / cuda 13.4`。
5. **setup.sh 又改写生产配置（第 7 次复现）**：args 31 → 28，且把 ctx `262144→65536`、`k8v4→int8`、丢掉 `--pipeline-windows 2` 与 `--resident-experts 0.70`、`layer_split 24→auto`、模型路径改成 `~/src/Strata-data/…`。已 `cp run-config.json` 覆盖恢复 ⇒ argv 31 条逐字回到升级前。

### §21.3 A/B（同 args、温度 0、两轮交替；**冷 prefill 用每次唯一 prompt 规避前缀缓存**）
| 指标 | 0.1.51 | 0.1.52 | 差 |
|---|---|---|---|
decode（散文 220 tok） | 84.5 tok/s（85.5 / 83.5） | 84.7 tok/s（84.4 / 85.0） | **+0.2%**（等价） |
冷 prefill TTFT（~2.5k 字，唯一 prompt，中位×2 轮） | **1.462 s**（1.464 / 1.461） | **1.510 s**（1.553 / 1.467） | **+3.2%（略差）** |

**两个量测坑（本轮踩到，写下来）**：
- **同一个 prompt 反复发，TTFT 会命中前缀缓存**（实测 0.10 s）⇒ 测 prefill 必须**每次换唯一 prompt**，否则量的是缓存命中。
- **换二进制必须先停 unit**：`cp` 到正在运行的可执行文件会 `Text file busy` 且**静默失败**（我的 harness 一开始没查 `cp` 返回码，结果两臂跑的都是同一颗二进制、sha 相同）。判据：每臂打印 `sha256sum engine/strata` 并与预期对比。

### §21.4 终态与回滚
- 终态：unit `strata-swift-iq3s` **active**、`/v1/status` → `engine 0.1.52 / loaded true / ctx 262144 / model swift-1.5-iq3_s`；专家缓存 6089 个 / 10.95 GiB；两卡显存 15.7 / 15.8 GiB。
- 回滚（一条）：`cp ~/vault-backup/strata-pre-5e8a4cc-20261028/strata-0.1.51 ~/src/Strata/engine/strata && cp ~/vault-backup/strata-pre-5e8a4cc-20261028/BUILD.json-0.1.51 ~/src/Strata/engine/BUILD.json && systemctl --user restart strata-swift-iq3s`；树回滚 `git reset --hard 4b9e05a2a`。

## §22 0.2.7.1（engine 0.1.53）· 2026-10-28 落地

**结论：已升并保留（用户「升一下」）。这一版对 Qwen + sm_120 + CUDA + layer-split 路径零代码改动，价值只在跟上游。**

| 项 | 升级前 | 升级后 |
|---|---|---|
树 | `v0.2.7` = `5e8a4cca7`（10-27） | **`v0.2.7.1` = `46c152a13`（10-28，+127 commit）** |
引擎 | 0.1.52 · 114,431,872 B · sha `c2f3c1f2…` | **0.1.53 · 114,432,176 B · sha `68dfccc3…`** |
BUILD.json | src `a88a598cd60d6ee1` | src **`7a4844f3e4e4f80a`**、archs `[120]` |
配置 | 31 args / layer_split 24 | **逐条完全一致**（args 相等、layer_split 24、gpu [0,1]、gpu_roles、vision 全同，无键增减） |
编译 | — | `./update.sh --yes --no-start` **169/169 步，EXIT=0**，内存峰值 3.67 GiB |
运行 | — | 冷启动 **39 s**、`engine 0.1.53 / loaded true / ctx 262144 / vision true / concurrency 1`、专家缓存 6089 个 10.95 GiB、显存 15,607+15,732 MiB |
冒烟 | — | `391+409=800` 正确、reasoning 168 字分离、finish stop、decode 85.6 tok/s、命中 89.8% |

### 改动归属（判「有没有收益」的判据，逐目录）
| 目录 | 内容 | 本机杠杆 |
|---|---|---|
`src/dsv41/`（24 文件） | DeepSeek V4.1 引擎（exl3/gguf/attn_split/vision/sampler） | 零（不跑 DeepSeek） |
`src/prefill/moe_fused_iq.cu` | 新增 `s121` 早退分支（GB10 ≥65,536 routed rows 用 128 行 tile，实测 +3.4~4.3%） | 零（本机 cc 12.0 走 `s120`，该分支进不去） |
`src/core/nv_defaults.cpp` | 新增 **sm_121 默认开关表**（`STRATA_PF_FUSED` / `PREFILL_NVFP4=w4a4` / `HC_UPMIX` / `SPEC_COST`）+ `STRATA_DEFAULTS=026` 总闸 | 零（`else if (mj==12 && mn==1)`） |
`src/kernels/cpu/portable.cpp` | 删 tq_cpu 行、补 iq256x 空实现（x86 CPU 核） | 零（走 GPU） |
`metal/` 35 · `tools/` 18 · `tests/` 15 · `packaging/` 13 · `strata_control/` 5 · `strata_cli/` 4 · `docs/` 5 | Mac Metal 移植、DGX Spark arm64、打包与 CLI | 零 |
`CMakeLists.txt` | 只改 `project(strata VERSION 0.1.52 → 0.1.53)` + arm64 下默认不编 tests | 只有版本号 |

**上游自带的反证**：commit `232fa357f`「SetArgs: the Metal fields go last, so the CUDA/HIP kernels' parameter layout (and SASS) is exactly v0.2.7's」⇒ CUDA 侧二进制级等价，不必跑 A/B。

### 从这一版学到的新判据
- **`nv_defaults` 新增 sm_XXX 表 ≠ 本机默认值变了**：新版只加 `) else if (mj == 12 && mn == 1) { … }` 一整块给 GB10（DGX Spark）；本机 12.0 命中它上面的既有分支，逐字节没动。审「默认值有没有变」要 `git diff … | grep -E '^[+-]' | grep -vi <新卡代号>` 打出剩余行，空 = 与己无关。
- **`update.sh` 第三次连任「不改 args」**（0.1.49.2 / 0.1.52 / 0.1.53 三连未改写）；但仍按纪律逐条断言，不因前两次未改就跳过核对。
- 构建内存峰值 **3.67 GiB** ⇒ 在 Hermes 后台 4 GiB cgroup 里会撞线，`systemd-run --property=MemoryMax=infinity` 是本机重编的必备动作。

**回滚件**：`engine/strata.0.1.52-keep`（sha `c2f3c1f2…`）+ `~/workspace/strata-pre-0271-20261028/{BUILD.json-0.1.52,run-config.json,HEAD.txt}` + `~/workspace/strata-0.1.52-keep`。回滚：拷回 `engine/strata` + `BUILD.json`，`systemctl --user restart strata-swift-iq3s`。

### §21.5 KV 档位实测（int8 vs k8v4，2026-10-28，同引擎 0.1.52 / 262144）
| 指标 | `--kv int8` | `--kv k8v4`（生产） |
|---|---|---|
每 cell | 1,056 B | **816 B（−23%）** |
专家缓存 | 5892 个 / 10.60 GiB（命中 87.3%） | **6089 个 / 10.95 GiB（命中 87.5–93.5%）** |
decode（散文 220 tok，两轮） | 75.5 tok/s（73.9 / 77.1） | **77.0 tok/s（77.7 / 76.3）** → +2.0%（噪声内） |
冷 prefill TTFT（2.5k 字） | 2.230 s | 2.231 s → **0.0%** |
12k token needle（事实埋 ~70% 深度） | ✅ 哈尔滨 7.54 s | ✅ 哈尔滨 7.84 s |

结论：**本机维持 k8v4** —— 省下的 23% KV 显存换来多 197 个常驻专家（99.8% 覆盖），decode 略快、prefill 无差、12k 长文未见精度损失。
官方文档称 k8v4「prompts 慢 2-5%」，本机在 2.5k prompt 上未复现（该代价应出现在 100K+ 上下文）。
另记一个**测试坑**：本模型默认开 thinking，答案在 `content`、思考在 `reasoning_content`；`max_tokens` 给小（如 64）会被思考吃光导致 `content` 空串，needle 测试会误判为失败（给到 400 即正确）。
