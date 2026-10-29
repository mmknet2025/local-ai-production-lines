# 本机三线现役状态快照 · 2026-10-29

> 全部为本机实测值（`uname -r` / `nvidia-smi` / `--check` / 请求日志），非文档推断。
> 采集时间：2026-10-29 12:10–14:30 CST。机器：2× RTX 5060 Ti 16 GB（sm_120a）+ Ryzen 7 9700X + 60 GB RAM。

## 0. 底座

| 项 | 值 |
|---|---|
| 内核 | **`7.3.0-10-generic`**（10-29 由 `apt dist-upgrade` 升 ABI 9→10；旧 `7.3.0-9` 保留在 GRUB 可回退） |
| 驱动 | **615.78.08**（open kernel modules + aikitoria P2P 补丁，DKMS 名 `nvidia-open-p2p`） |
| P2P | `nvidia-smi topo -p2p r/w` → GPU0↔GPU1 **双向 OK** |
| DKMS | `nvidia-open-p2p/615.78.08` 已为 `7.3.0-10-generic` 与 `7.3.0-9-generic` 双内核 installed |
| 系统包 | `apt-get -s dist-upgrade` = **0 可升级**；snap / pip / flatpak / fwupd 均无更新 |

## 1. 8090 · 单卡长上下文（kvmem 产品线）

| 项 | 值 |
|---|---|
| 模型 / 工件 | Qwen3.8-27B Swift-1.5 GSQ-RCO IQ3_S · `swift-qwen38-rco-iq3s.ninfer` 15,017,456,128 B |
| 引擎源码树 | `~/src/kvmem-product/repo/backends/ninfer`，HEAD `63428ac2`，**20 补丁**，`write-tree` = `d976d3f8b2069f1c6255b803a70466360a107288`（= 官方 `patched_tree`） |
| 二进制 | **`a6dffc2d`**，684,392,648 B |
| 回滚件 | `build/apps/ninfer-serve.old-c7683001`（旧 16 补丁件） |
| 升级判据 | `kvmem-8090-upgrade --check` → 「pin 与现役产物都与钉定一致，无需重建」 |
| 生产参数 | `--spec mtp --draft-tokens 4`、`--max-context 262144`、`--kv-dtype int8`、`--kvmem-budget 61440`、`--kvmem-gen-reserve 4096`、`--kvmem-host-mib 16384`、`--prefill-chunk 1024`、`--structured-output` |
| 资源 | 冷启 4.2–4.3 s；weights 11.6 GiB；显存 14,885 MiB；进程 RSS 3.6 GB |

**实测能力（12:10–12:35，20 补丁引擎）**

| 能力 | 结果 |
|---|---|
| 基础生成 | 89 tok / 1.81 s |
| thinking | 709 字符 reasoning 块 |
| `json_schema` strict | 合法 JSON |
| 工具调用 | `tool_calls` → `get_weather{"city":"北京"}` |
| **长上下文** | **259,149 tokens 成功**（333 s）；首次 prefill：28.8k→27.3 s(1.06k tok/s)、86.4k→100.2 s(863)、259k→333 s(778) |
| **KVMem 复用** | **100% 命中**：28,846 tok 二次请求 409 ms（`response replay`）、86,429 tok 518 ms（`turn closure`） |
| MTP 接受率 | 43.9%–86.8%（长 prompt 更高） |
| 视觉 | 工件带权重但**生产默认关闭**（`VISION` 空 ⇒ `vision_disabled`）。开启后 weights 11.9 GiB / KV runtime 3.43 GiB / 显存 15,761 MiB / **free 仅 184.8 MiB** ⇒ 决策：保持关闭，需要时 `VISION=--vision` 单次拉起 |
| 并发 | `--max-concurrency 1`，第二请求串行排队 |

**为什么用 MTP 不用 DFlash2**（同工件、KV 131072、greedy，3 reps）：接受率 **37.5% vs 33.5%**，decode 58.4/55.8（短）· 61.3/57.1（长）tok/s，权重 11.6 vs **13.4 GiB**（后者使 KV 只能 131072 ⇒ 上下文腰斩）；三者输出经无-nonce 复测逐字一致。

## 2. 8091 · 双卡 TP2 主力

| 项 | 值 |
|---|---|
| 模型 / 工件 | Qwen3.8-27B Coder390 W4A4-W8A8 · `qwen3_8_27b_coder390_w4a4w8a8.ninfer` 21,490,955,393 B（sha256 `e15f02938b69…` = HF 上游 lfs 一致） |
| 引擎源码 | `~/ninfer-build/baiyouqing-tp2` @ `74a2879b`（分支 `so-port-structured-output-recovered`，领先上游 1、落后 0） |
| 二进制 | **`e630612d`**，216,109,952 B（10-29 01:09 重编，CUDA 13.4.92 / `120a` / Ninja Release） |
| 上游 | `BaiYouQing/ninfer-tp2-5060ti-windows` 最后推送 **2026-09-24**（已停更） |
| 生产参数 | `--tp 2 --devices 0,1`、`--max-context 262144 --kv-capacity 262144`、`--kv-dtype int8`、`--spec mtp --draft-tokens 3 --lm-head-draft`、`--structured-output`、`--max-concurrency 1` |
| 参考性能 | 短 prefill 2,862 / decode 79.1 / TTFT 264 ms；6.2k prefill 3,564 / 74.4 / 1,759 ms（冷前缀，3 rep 中位） |

## 3. 8080 · 125B MoE（Strata）

| 项 | 值 |
|---|---|
| 引擎 | Strata 树 `v0.2.7.1`（`46c152a1`，与 origin 0/0）· engine **0.1.53** · 二进制 `68dfccc3` 114,432,176 B |
| 模型数据 | `~/Strata-data` 134 GB（models 79 G / packs 49 G / mtp 6.5 G，含 vision `mmproj` + `mtp-q2_0.gguf`） |
| 上游 | `Niko1221/Strata` 最新 commit `46c152a1`（与本地同版） |
| 参数 | 双卡 layer-split 24 层，`ctx 262144` |
| 资源 | 双卡各 ~15.6 GB 显存 + RAM ~48 GB，冷启 1–2 分钟 |

## 4. 编排

- `local-router`（@8097）常驻，不占 GPU；首请求按 model id 拉起对应引擎，**拉起前停其它引擎并等真 inactive**。
- 三条线互斥：同一时刻只有一条占卡（8090 单卡 / 8091 双卡 / 8080 双卡）。
- 8090 需要 `MemAvailable ≥ 40 GB` 才会被拉起。

## 5. 回滚面

| 线 | 回滚方式 |
|---|---|
| 8090 | `build/apps/ninfer-serve.old-c7683001`（16 补丁件）+ 树重打 16 补丁；或 `kvmem-8090-upgrade --check` 确认 pin |
| 8091 | 从 `74a2879b` 重编（约 3 分钟） |
| 8080 | Strata 自身 `setup.sh` 重建 |
| 系统 | GRUB 选 `Advanced options → 7.3.0-9-generic`（两个内核条目都在） |
