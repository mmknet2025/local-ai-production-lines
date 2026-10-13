---
title: "本机三条生产线总览（单一事实源 · 2026-10-13）"
description: "本机 NInfer 单卡/双卡 + Strata 三条生产线的唯一入口：身份、端口、开关、能力、回滚。细节各自 manifest，本页只放四处都要用的公共事实，避免逐文件重复。"
tags: [local-inference, ninfer, strata, production, single-source-of-truth]
---

# 本机三条生产线总览（单一事实源，2026-10-13）

> 本页是**唯一入口**：公共事实（端口分配、互斥关系、编排、回滚）只在这里写一份；每条线的细节见各自 manifest（链接在表下）。
> 口径：机器为 2×RTX 5060 Ti 16G（sm_120a）+ Ryzen 7 9700X + 59G RAM；纯 Wayland。

## 1. 总表

| | ① 8090 单卡 | ② 8091 双卡 | ③ Strata 8080 |
|---|---|---|---|
| 角色 | 单卡长上下文（KVMem） | 双卡主力（TP2） | 125B MoE 大模型 |
| 模型 | Qwen3.8-27B **Swift-1.5 GSQ-RCO IQ3_S** | Qwen3.8-27B **Coder390 W4A4-W8A8** | Qwen3.8-**Flash-Next 125B/A6B** IQ3_S |
| 工件 | `swift-qwen38-rco-iq3s.ninfer` 15.0 GB（v3，10-03） | `qwen3_8_27b_coder390_w4a4w8a8.ninfer` 21.5 GB（v2，10-11） | `~/src/Strata-data` 133 G |
| 引擎树 | `~/ninfer-build/src-5258` `upgrade-013-20261005` @ **c7f5a1ba** | `~/ninfer-build/baiyouqing-tp2` `windows-port` @ **8c50e4ed** | `~/src/Strata` `main` @ **a0116b2**（v0.1.43.1） |
| 二进制 | sha **f6c8b6be…**（1.37 GB，10-12） | sha **45ca6e27…**（209 MB，**10-13**） | sha **65e167e9…**（68 MB，10-13） |
| 端口 / 单元 | 8090 / `ninfer-prod` | 8091 / `ninfer-tp2` | 8080 / `strata-swift-iq3s` |
| 上下文 | 262144 | 262144 | 262144 |
| 特有能力 | KVMem 环（分页 KV 池 + 长复用）+ 约束解码 | MTP K=3 投机 + 前缀复用 99.9% + **约束解码（10-13 并入）** | 双卡 layer-split 24 |
| 资源 | 单卡；需 MemAvailable ≥40 G | 双卡；`min_mem_gib 0` | 双卡 + RAM ~48–133 G |
| 冷启动 | ≈10 s | ≈8.5 s | 1–2 分钟 |
| 详情 | [[20_Tech_Stack/ninfer_engine_architecture_manifest]] | [[20_Tech_Stack/qwen3.8-27b-coder390-tp2-ninfer_manifest]]（§12 约束解码） | [[20_Tech_Stack/strata_engine_manifest]] + [[20_Tech_Stack/swift-1.5-qwen3.8-flash-next-iq3_s_manifest]] |

## 2. 编排（三线共用一条入口）

- Hermes 唯一本地 provider = **`local-engines` → `http://127.0.0.1:8097/v1`**（unit `local-router`，脚本 `~/.local/bin/ninfer-router`，**常驻不占 GPU**）
- 模型 id → 端口：`1card-qwen3.8-27b-swift-iq3s`→8090 ｜ `2card-qwen3.8-27b-coder390`→8091 ｜ `flash-next-swift1.5-iq3s`→8080
- **三引擎互斥**：首请求按需拉起，拉起前先停其它并等其真 inactive；8099（旧直连口）保留应急，8098 已 disable
- 流式冷启动会先注入「⏳ 正在拉起 X…」/「✅ X 就绪（已停 Y）」两条 delta

## 3. 8091 的开关（10-13 起）

- `--structured-output`（**默认关**）：开时接受 JSON / JSON Schema 请求格式（Chat `response_format`、Responses `text.format`、Anthropic `output_config.format`），硬保证输出符合；**不传格式时行为与旧版一致**
- 与之互斥的 `--unconstrained-response-format`：客户端总发格式时降级为不加约束生成
- 回退：树 `pre-so-port-20261013-1914` / `backup/windows-port-20261013-1914`；旧二进制 `~/vault-backup/ninfer-8091-pre-structured-output-20261013-1914/ninfer-serve-pre`；router `~/.local/bin/ninfer-router.orig`

## 4. 通用纪律（三线共用）

- **按需启动**、用完释放；不常驻占显存
- **升级口径**：不看上游「发版没」，只看「我们这条 fork 线有没有传导过来、且值不值」；收益未证实 ⇒ 不升
- 换线/换件前先判「它能不能读我们的工件」（容器版本 v2/v3 + 量化格式 + 结构）
- 引擎与工件**必须配对**；模型手册逐个独立，历史模型不删不合并

## 5. provider 可用的 model id（Hermes 侧唯一入口 `local-engines`）

| model id | 端口 | 说明 |
|---|---|---|
| `1card-qwen3.8-27b-swift-iq3s` | 8090 | 单卡 · KVMem · 约束解码 |
| `2card-qwen3.8-27b-coder390` | 8091 | 双卡 TP2 · MTP K=3 · 约束解码（10-13 并入） |
| `flash-next-swift1.5-iq3s` | 8080 | Strata · Qwen3.8-Flash-Next 125B IQ3_S |

> Hermes provider `local-engines` 的 `api` = `http://127.0.0.1:8097/v1`；**没有**引擎直连 provider（旧 `local-ninfer`/`local-strata` 已删除）。

## 6. 入口与单元：谁能停谁

| 入口/单元 | 端口 | 状态 | 关系 |
|---|---|---|---|
| `local-router`（脚本 `ninfer-router --profile all`） | **8097** | enabled + **active** | **Hermes 唯一入口**；按需拉起三引擎并做互斥（`stop_others`） |
| `ninfer-router`（`--profile ninfer`） | 8099 | enabled + **active** | 旧直连口，**保留应急/回滚**；不参与 Hermes 流量，但**它会自己拉起引擎** ⇒ 与 8097 同时使用时注意互斥 |
| `strata-router`（`--profile strata`） | 8098 | **disabled** | 关闭（可 `enable` 复活作回滚口） |
| 引擎单元 `ninfer-prod` / `ninfer-tp2` | 8090 / 8091 | 按需（瞬时单元，`systemd-run --user --collect`） | 由 router 拉起；手工 `--stop` 或 `systemctl --user stop` 均可停 |
| 引擎单元 `strata-swift-iq3s` | 8080 | disabled（按需 start） | 由 router `start_via: unit` 拉起 |

**维护纪律**：手工直起引擎会**绕过互斥**（router 只认端口状态）⇒ 直起前先确认其它引擎已停；收尾把 `local-router` 起回（`systemctl --user start local-router`）。
