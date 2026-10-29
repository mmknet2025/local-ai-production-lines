---
type: manifest
title: "Swift 1.5 Qwen3.8-Flash-Next GSQ-RCO IQ3_S 部署手册（Strata 引擎 · 本机双卡 · ✅ 本机生产模型 2026-10-11 起）"
tags: [qwen3.8-flash-next, swift, gguf, gsq, rco, iq3_s, strata, moe, quantization, mtp, okf-v0.2]
description: "【✅ 本机生产模型（2026-10-11 起）】UkisAI Swift 1.5（Qwen3.8-Flash-Next 125B/A6B 的短思考 fine-tune）GSQ-RCO IQ3_S 量化在本机（2×RTX 5060 Ti / 59 GiB）经 Strata 引擎的部署手册：模型身份与文件字节、低 RAM 模式（--resident-experts）与正常模式的内存实测取舍、校准参数、实测速度、MTP、许可。2026-10-11 由 IQ3_XXS 换用本档（IQ3_XXS 手册已存档）"
trust: agent-generated
status: current
okf_version: v0.2
timestamp: "2026-10-11"
sources:
  - HF / ModelScope: ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF
  - 基座: Qwen/Qwen3.8-Flash-Next
  - 本机实测（2026-10-11）
---

# Swift 1.5 Qwen3.8-Flash-Next GSQ-RCO IQ3_S 部署手册

> 🔗 **编排（端口 / 互斥 / 按需拉起 / model id）统一见 [[20_Tech_Stack/local-production-lines|三条生产线总览]] §2–§5。**

> 引擎侧见 [[20_Tech_Stack/strata_engine_manifest|Strata 引擎手册]]。本页只记**模型身份与参数**。
> 上一档（IQ3_XXS）手册见 [[20_Tech_Stack/swift-1.5-qwen3.8-flash-next-iq3_xxs_manifest|Swift IQ3_XXS（已存档 2026-10-11）]]。

## 一、模型身份
| 项 | 值 |
|---|---|
| 量化仓库 | `ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF` |
| 基座 | `Qwen/Qwen3.8-Flash-Next`（125B / 激活 6B） |
| 版本 | **Swift 1.5**（UkisAI 短思考 fine-tune）：官方称 thinking token 少 **63.4%**、出答案快 **1.8×**、精度损失 <1% |
| 量化 | **GSQ**（Gumbel-Softmax 逐张量标量量化）+ **RCO**（预算约束分配）；Swift 专属 refine |
| 本机档位 | **IQ3_S**（83.74 GB，保留全部 512 专家；3.5-bit，官方称「质量最高、匹配全 BF16 基准」） |
| 许可 | Swift Open License 1.0（https://huggingface.co/ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF） |

## 二、文件与字节
| 文件 | 字节 |
|---|---:|
| `Swift-...-IQ3_S-00001-of-00002.gguf` | 44,900,816,736 |
| `Swift-...-IQ3_S-00002-of-00002.gguf` | 38,842,920,384 |
| **合计** | **83,743,737,120（≈83.74 GB）** |

- **下载**：ModelScope 直连（`--source modelscope`，仓内同名同路径）。⚠️ setup.py 对 Swift 仓 pin 的修订 `b22d729`（2026-09-24）**不含** IQ3_S 文件 —— 该档 2026-10-08 才加（上游 #1651），下载走「pin 404 → 回退仓库当前文件」路径并打一条 warning，属正常。
- **落盘**：`~/src/Strata-data/models/swift-IQ3_S/`（两分片+.done）+ `packs/swift-iq3_s/`（~49 G）+ `mtp/{tensors,rt}`。
- **MTP draft 层**：draft 约 1100 MiB VRAM（`--mtp-q4 proj` 后投影转 Q4_0，约 37.3 MiB）。

## 三、本机内存取舍（2026-10-11 实测）
| 模式 | RAM 专家 | GPU 专家缓存 | 系统剩余 | decode |
|---|---:|---|---:|---:|
| **低 RAM（`--resident-experts`，安装器默认）** | 33.14 GiB 锁页 | ~20.5 GiB（CUDA0 6124 槽 11.02 + CUDA1 4735 槽 9.49）| ~17 GiB | ~79 tok/s |
| 正常模式（默认 resident arena，去掉 `--resident-experts`） | 46.84 GiB | ~11 GiB | ~3 GiB | ~87 tok/s |

- **59 GiB 机器两模式都能跑** ⇒ `--resident-experts` **非必需**（安装器「需 ~62 GB」估计偏保守）。正常模式快 ~10% 但仅余 ~3 GiB；低 RAM 模式余量足、更稳，故为默认。
- **校准**（`tools/calibrate.py`，592 s）得 **`--pcie-frac 0.20`**（引擎自探 0.55；**0.1.44 已删该 flag，改自动**）、**`--spec-min-p 0.70`**，受控 3 轮扫描 **+6.7%**。
- 生效 args：`kv k8v4` / `max-context 262144` / `spec 6` / `mtp-max-t 4` / `suffix-draft 3` / `trim-stage-weights` / `pipeline-windows 2` / `layer_split 24` / `--resident-experts`。
- opt-in 实测（`STRATA_EXCHANGE_ROTATE` / `STRATA_DISJOINT_ADAPT` / `--lookup-chain` / `--mtp-q4`）：**均无收益或本机不适用**，未采纳。
- **2026-10-14（v0.1.44）复核**：`--mtp-q4 all` 以 9 轮配对复测（n=8 符号秩）**仍无收益**（decode +2.00，p=0.294），并补到机制证据 —— 草稿头每步读 **212.9 → 146.0 MiB**（−31%）但**显存余量不变**（仍 335/210 MiB），草稿接受率 81.1%→78.7%（−2.4pt）与增益相抵。`--adapt-async 1`（本机有 `--resident-experts` ⇒ 该开关有效）实测 decode +1.40（p=0.53）、prefill −2.50（7/8 更慢，p=0.059）⇒ **也不用**。
- **同步**：`--pcie-frac` 与 `--vram-reserve-mib` 在 **0.1.44 已从二进制删除**；本机协议检测下限 ≈5%（同一配置独立跑两次中位差 −4.60 tok/s）。

## 四、为何从 IQ3_XXS 换到 IQ3_S（2026-10-11）
- IQ3_XXS 手册当年的结论「Strata 的 Swift **无 IQ3_S** 档」**已被推翻**：Swift 1.5 自 2026-10-08 起有 IQ3_S（`ukisai/...` 仓，上游 #1651）。
- IQ3_S 质量更高（官方称匹配全 BF16），且本机 59 GiB 可跑（低 RAM 模式）。
- 切换动作：删 IQ3_XXS 运行时（`models/swift-IQ3_XXS` + `packs/swift-iq3_xxs` + `strata-swift-iq3_xxs.json` + `run-swift-iq3_xxs.sh` + 旧 unit，释放 **~72.5 GB**），IQ3_S 转正为唯一在装档。

## 五、运行
- 引擎侧启动/停止、按需单元、provider 集成见 [[20_Tech_Stack/strata_engine_manifest|Strata 引擎手册]]。
