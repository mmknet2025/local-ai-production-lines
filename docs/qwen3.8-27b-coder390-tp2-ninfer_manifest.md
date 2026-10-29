---
type: manifest
title: "Qwen3.8-27B Coder390 W4A4-W8A8 双卡 TP2 部署手册（NInfer · BaiYouQing fork · 8091 · ✅ 本机生产模型 2026-10-08 起 · 2026-10-11 换用上游件）"
tags: [qwen3.8, coder390, w4a4w8a8, nvfp4, ninfer, tp2, dual-gpu, mtp, prefix-reuse, container-repack, sm120a, rtx50, local-inference, okf-v0.2]
description: "【✅ 本机生产模型（2026-10-08 起；**2026-10-11 起工件换为上游 fork 兼容件**）】Qwen3.8-27B Coder390（社区后训练版）W4A4-W8A8 双卡 TP2 部署手册。上游 2026-10-08 的 .ninfer 包原样装不上本机 fork（四道门全在制品侧，§2）；**2026-10-11 上游发布了 fork 兼容新包** `…NVFP4-W4A4-W8A8-MTP-NInferV2.ninfer`（白名单模板 + 只留 MTP + 含 vision），**实测可直接加载**（§9），遂换用：现役件 = 上游件（21,490,955,393 B / sha `e15f0293…`），本机旧重打包件（21,493,639,424 B / `db0c7df8…`）归档 NAS。实测：加载 6.78/7.08 s、ctx 262,144（2026-10-11 提到上限）、中文正确、工具调用正确、decode 92.4 tok/s（含 prefill+thinking）；旧重打包件口径（前缀复用 A/B、质量 A/B）见 §5/§6，仍有效。"
trust: agent-generated
status: current
okf_version: v0.2
timestamp: "2026-10-10"
sources:
  - 现役件（2026-10-11 起）= **上游 fork 兼容件** https://modelscope.cn/models/Merkyor/Qwen3.8-27B-Coder390-EfficientThink-Opus5.5-GPT6Astra-Grok4.7-DSV4Pro-K3-SFT-RLOO-NVFP4-NInfer 的 `NVFP4-NInfer/W4A4-W8A8/…MTP-NInferV2.ninfer`（sha `e15f0293…`，直接加载实测通过，见 §9）
  - 旧上游工件（同仓 NVFP4-NInfer/W4A4-W8A8 的 v2 包，原样装不上 → 曾作重打包输入）
  - HF 镜像 https://huggingface.co/nerkyor/Qwen3.8-27B-Coder390-…-MTP-DFlash2
  - 供体（对象集顺序 + frontend/vision 资源 + 白名单模板）= 本机旧现役件 neroued v2（已迁 NAS）
  - 引擎 fork BaiYouQing/ninfer-tp2-5060ti-windows（本机自编 `~/ninfer-build/baiyouqing-tp2/build-linux`）
  - 本机会话实测（2026-10-08）
---

[[20_Tech_Stack/index|↩️ 返回技术栈首页]]

> [!note] 引擎选型（2026-10-29）：官方 `--tensor-parallel` 实测不换线 —— NVFP4 要 3 处未上游补丁才能加载、修好仍 prefill −50~69%，零补丁路线要换 GGUF 量化件且同样 −50%。数据与根因见 [[20_Tech_Stack/ninfer_dual_card_engine_eval_20261029]]。

# Qwen3.8-27B Coder390 W4A4-W8A8 · NInfer 双卡 TP2 部署手册

> [!success] ✅ 本机生产模型（2026-10-08 起）
> - 客户端 id **`2card-qwen3.8-27b-coder390`**（Hermes 侧 provider 已是 **`local-engines` @8097**，不再是旧 `local-ninfer`）→ 端口 8091 ｜ 编排与 model id 清单见 [[20_Tech_Stack/local-production-lines|三条生产线总览]] §2/§5
> - 引擎 **`baiyouqing-tp2`** · 端口 **8091** · unit **`ninfer-tp2`** · 引擎 `--model-id` **`qwen3.8-27b-coder390-tp2`**
> - **引擎二进制（2026-10-13 起含约束解码）**：sha256 `45ca6e27…cebdd9`（208,877,736 B，2026-10-13 19:15 重编）；新增开关 **`--structured-output`**（默认关，未传 `response_format`/`text.format`/`output_config.format` 时行为与旧版完全一致）。回退：树 tag `pre-so-port-20261013-1914`／分支 `backup/windows-port-20261013-1914`；旧二进制 `~/vault-backup/ninfer-8091-pre-structured-output-20261013-1914/ninfer-serve-pre`（sha `a640a648…`）；router `~/.local/bin/ninfer-router.orig`。详见 §12
> - 工件 `~/models/qwen3.8-27b-coder390/qwen3_8_27b_coder390_w4a4w8a8.ninfer` · **21,490,955,393 B** · sha256 `e15f02938b69be2b87afb5e89a282772c4663674e703b3f17e099bba92f1b534`（**2026-10-11 起 = 上游件**，见 §9；旧本机重打包件 `db0c7df8…` 已归档 NAS）
> - 取代 [[20_Tech_Stack/qwen3.8-27b-nvfp4-tp2-ninfer_manifest|旧 TP2 手册（neroued v2 件，已存档）]]；**引擎/参数/前缀复用结论全部沿用**，变的是工件与 id

## 0. 一句话结论

上游 2026-10-08 的 Coder390 `.ninfer` 包**原样装不上**本机 fork——卡点**全在制品侧**（四道门，见 §2），本机曾按 fork 约束**重打包**一版跑上生产（2026-10-08 起）。**2026-10-11 上游发布了 fork 兼容新包**（`…NVFP4-W4A4-W8A8-MTP-NInferV2.ninfer`），**实测可直接加载**（§9），遂**换用上游件、旧本机重打包件归档 NAS**。两者**功能等价**（1124 对象名称/大小/编码全同，`chat_template.jinja` 逐字节相同，抽样权重逐字节相同）。

## 1. 工件身份

| 项 | 值 |
|---|---|
| 模型 | Qwen3.8-27B **Coder390**（官方基座 → SFT+SimPO → 多轮 SFT + 2 轮 RLOO 的社区后训练版） |
| 档位 | NVFP4-NInfer **W4A4-W8A8**（混合精度：MLP 走 NVFP4 W4A4，注意力/线性注意力投影走 FP8 W8A8） |
| 容器 | **v2**（`NINFER` + `0x0002`），与 fork 的 v2-only reader 匹配 |
| 生产件（现役 · 2026-10-11 起） | `qwen3_8_27b_coder390_w4a4w8a8.ninfer` · **21,490,955,393 B** · sha `e15f0293…` —— **上游 fork 兼容件**（1124 对象，直接加载实测通过，见 §9） |
| 旧生产件（归档 NAS） | 本机**重打包件** 21,493,639,424 B · sha `db0c7df8…` —— 2026-10-08~10-11 现役；归档 `/mnt/nas/nas/nas/linux/models/qwen3.8-27b-coder390-local-rebuilt/` |
| 上游旧原包（重打包输入） | `qwen3_8_27b_coder390_w4a4w8a8_v2.ninfer` 23,477,696,516 B（**原样装不上**）—— NAS `/mnt/nas/nas/nas/linux/models/qwen3.8-27b-coder390-w4a4w8a8-v2/`（sha `099b2d00…`） |
| 上游旧容器 | 865 对象；**缺** 2 frontend resource + 333 vision 张量；**多** 76 个 `dflash2/*`（2.28 GB 死重） |

**重打包做了什么（相对上游原包）**：剥 `dflash2/*` 76 个 · 补 `frontend/preprocessor_config.json` + `video_preprocessor_config.json` + `vision/*` 333 个 · `chat_template.jinja` 换成白名单版 · `tokenizer_config.json` 内嵌同款模板 · 条目按 neroued 顺序重排、张量 4096 对齐。**文字权重与 MTP 头全部是 Coder390 自己的**；只有 vision 塔与模板资源取自旧件。

## 2. fork 的四道门（全部实测）—— 旧上游件为何装不上 / 2026-10-11 新件如何满足

> 📌 **2026-10-11 更新**：下列四门针对的是**旧上游包**；**新上游件 `…MTP-NInferV2.ninfer` 四门全过**（对象集与重打包件一致 · `chat_template.jinja` = 白名单摘要 `c3cf9e34…` · tokenizer_config 内嵌模板 · 张量 offset 256 对齐），故**不再需要重打包**（取证见 §9）。

1. **对象集双向严格** —— 缺件报 `required artifact object is missing: …`；**多件**报 `artifact object was not consumed by the selected target: …`。⇒ 必须与它期望的集合**完全一致**（以本机旧件的 1124 对象集为准）。
2. **模板按 sha256 白名单**（`src/targets/qwen3_6/impl/frontend/chat_template.cpp:293`）——`CompiledChatTemplate::resolve()` 只认两个摘要：`kThinkingToggleTemplateDigest` / `kReasoningEffortTemplateDigest`（`c3cf9e34…`）。作者自改版 `a497db9e…` 被拒。**引擎不解析模板正文**，`CompiledChatTemplate` 只存一个语义枚举、prompt 由 C++ 自拼 ⇒ 换成白名单版**行为等价**，作者那 4 处模板改进本引擎上也永远不生效。
3. **`tokenizer_config.json` 必须内嵌 `chat_template`** 且与 `.jinja` 一致（作者的包把该键清掉了）。
4. **容器布局**：`[0,16) 头('NINFER'|ver|jlen|4×0)` + `[16,16+jlen) JSON 目录` + 补零到 `align_up(16+jlen,4096)` + 数据段；条目 `offset` **相对数据段起点**；**无校验和**；文件大小 == 数据段起点 + `max(offset+bytes)`；张量 4096 对齐、resource 紧邻。

## 3. 落地配置

```bash
BIN=~/ninfer-build/baiyouqing-tp2/build-linux/apps/ninfer-serve
MODEL=~/models/qwen3.8-27b-coder390/qwen3_8_27b_coder390_w4a4w8a8.ninfer
$BIN $MODEL --tp 2 --devices 0,1 --host 127.0.0.1 --port 8091 \
  --model-id qwen3.8-27b-coder390-tp2 --max-context 262144 --kv-capacity 262144 \
  --prefill-chunk 1024 --kv-dtype int8 --spec mtp --draft-tokens 3 --lm-head-draft \
  --max-concurrency 1 --default-max-tokens 32768
```

- 客户端 id **`2card-qwen3.8-27b-coder390`** → Hermes `local-ninfer.models` + 路由器 `ROUTES`（唯一事实源）
- fish 封装同步改：`ninfer-tp2-serve` / `ninfer-tp2-stop`
- 参数**逐条沿用旧手册**（`--kv-dtype int8` / `--draft-tokens 3` / `--default-max-tokens 32768` 等依据见旧手册 §3）

> 📦 折叠：§4 实测（2026-10-08 旧本机重打包件 · 引擎日志口径）→ 旧版本实录 [[_archive/qwen3.8-27b-coder390-tp2-ninfer_manifest-版本文史-20261014.md|qwen3.8-27b-coder390-tp2-ninfer_manifest-版本文史-20261014.md]]（关键数字：加载 7.9s；冷 prefill 3,033 tok/s；decode 101.5 tok/s；MTP 81.7%；同 prompt 重发 cache 6150/6152、ttft 38ms；现役上游件口径见 §9）

## 5. 质量 A/B（同端口、同参数、只换模型件）

- **工具调用**（5 项 / 2 档 effort）：Coder390 **5/5**（xhigh 生产口径）vs 旧件 4/5（唯一失手 = T2 内容搜索退化成 `terminal`+grep，正好复现旧手册记过的已知退化）。⚠️ n=1/档，**不算结论**。
- **思考量**（10 题可客观判定，greedy）：同 **10/10** 正确率下 gen tokens P50 **74 vs 92**、思考字符 P50 **112 vs 246（−54%）**；总墙钟 12.1 s vs 12.9 s。
- **GPQA-Diamond 子集**（`AI-ModelScope/gpqa_diamond`，作者生成参数，`max_tokens 32768`，前 7 题同题对照）：**7/7 vs 6/7**，生成 token 中位 **780 vs 1,256**，墙钟 **120.5 s vs 516.0 s**。其中**旧件单题生成 28,574 token / 思考 95,438 字符 / 347.6 s 且答错** —— 正是作者说的"停不下来"形态的实机复现。

**统计局限（必须连着读）**：GPQA 只跑了 **7 对**（原计划 24，用户叫停）；`max_tokens` 减半（32,768，作者用 73,728）；题量与判分未复刻 EvalScope 的 rule judge。⇒ 作者宣称的「准确率 +2pp / 94K 截断 4→1」**未验证**（2% vs 0.5% 的差异在 7 题样本上不可测）。

## 6. 已知边界

- **模板正文被引擎丢弃** ⇒ 作者对模板的 4 处改进（developer 角色、final-assistant 续写、tool-result 历史兜底）在本引擎上**不生效**；换白名单版不构成损失。
- **vision 塔在 `--tp 2` 下不执行**（fork 明说 tp2 不支持 `--vision`），它只为过加载器的必需件检查而存在（+296 MB）。
- **`dflash2/*` 已剥**（2.28 GB）；本线只用 MTP。
- **量化是 W4A4-W8A8（FP8 为主）**：作者自报该仓 NVFP4 三档**全不如其静态 FP8**（178/450/90），本档 MMLU 444 vs 同仓 W4A4 的 449。

## 7. 重建步骤

> ⚠️ **两份输入件现在都在 NAS**：上游原包 → `/mnt/nas/nas/nas/linux/models/qwen3.8-27b-coder390-w4a4w8a8-v2/`；供体（neroued v2）→ `…/models/qwen3.8-27b-nvfp4-ninfer-v2/`。本机不再保留这两份。

```bash
cd ~/workspace/coder390-w4a4w8a8-test
# 输入：上游原包 + 旧件（供体）；输出：_rebuilt.ninfer
python3 rebuild_container.py
sha256sum .../qwen3_8_27b_coder390_w4a4w8a8_v2_rebuilt.ninfer    # 期望 db0c7df8…
```

## 8. 回滚

1. 工件：NAS `/mnt/nas/nas/nas/linux/models/qwen3.8-27b-nvfp4-ninfer-v2/qwen3_8_27b_nvfp4.ninfer`（21,492,695,040 B，sha `bb336052…`）拷回 `~/models/qwen3.8-27b-nvfp4-ninfer-v2/`
2. 配置：`~/.local/bin/ninfer-router.bak-20261008_225414`、`~/.hermes/config.yaml.bak.coder390-20261008_225414`、`~/.config/fish/functions/ninfer-tp2-serve.fish.bak-20261008_225414`
3. 停引擎（`systemctl --user stop ninfer-tp2`）→ 还原三处 → `systemctl --user restart ninfer-router` → `ninfer-router --check`

## 9. 上游溯源与版本（2026-10-11 复核实测）

| 项 | 值 |
|---|---|
| 上游仓库 | **`nerkyor/Qwen3.8-27B-Coder390-EfficientThink-Opus5.5-GPT6Astra-Grok4.7-DSV4Pro-K3-SFT-RLOO-NVFP4-NInfer`**（HF；ModelScope 镜像同名 `Merkyor/…`，见 frontmatter `sources`） |
| 上游目录 `NVFP4-NInfer/W4A4-W8A8/`（**2026-10-11 实测 4 件**） | ① 23,773,675,264 B `cccfbf0b…`（…EfficientThink-W4A4-W8A8-MTP-DFlash2）；② **21,490,955,393 B `e15f0293…`（…EfficientThink-NVFP4-W4A4-W8A8-MTP-NInferV2）= 本机现役件**；③ 23,477,696,516 B `099b2d00…`（…MTP-DFlash2-NInferV2-NOT-FOR-V3）；④ 20,752,831,236 B `01a4440f…`（…NInferV2-NOT-FOR-V3）；另有 `SHA256SUMS`、`vision-bf16.safetensors` `d7defc90…` |
| **本机现役件（2026-10-11 起）** | `…MTP-NInferV2.ninfer`（件②）· 21,490,955,393 B · `e15f02938b69be2b87afb5e89a282772c4663674e703b3f17e099bba92f1b534` —— **上游原件，可直接加载**（四门全过） |
| 旧本机件（归档 NAS） | 重打包件 21,493,639,424 B · `db0c7df87a279397c179413c7290b39218b44eab8828f0128ef82f175d98e3a2`（2026-10-08 自建；2026-10-11 被上游件取代） |
| **换件取证（2026-10-11 实测）** | 上游件② vs 旧本机件：**1124 对象、名称/kind/encoding 全同**；仅 `frontend/tokenizer_config.json` 大小差（16383 vs 14286，**逐键无差 = 纯排版**）；`chat_template.jinja` **逐字节相同** = `c3cf9e34…`（= fork 白名单摘要，门②过）；tokenizer_config 内嵌模板 == `.jinja`（门③过）；容器 v2、`payload_start` 4096 对齐、**张量 offset 256 对齐**（fork 常量 `kTensorAlignment`）、顺序无重叠（门④过）；**抽样 6 张量（含 100 MB / 50 MB）逐字节相同** ⇒ 与重打包件**功能等价** |
| 加载实测 | 端口 8092 直接加载：**6.78 s**、20.92 GiB、ctx 253,952（当时口径；2026-10-11 晚提到 **262,144**，见 §3）；中文正确、**工具调用 `get_weather({"city":"北京"})` 正确**、decode 92.4 tok/s（含 prefill+thinking）；经 8099 生产路由端到端通过（加载 7.08 s） |
| 结论 | **上游件② 即现役件**；旧本机重打包件归档 NAS。上游已自行补齐 fork 兼容性（白名单模板 + 只留 MTP + 含 vision），故**本机重打包流程 §7 转为历史** |

> 判读要点：判「有无更新 / 能否替换」**不能**用文件名相似度或版本号，须靠 **容器头 + 逐对象清单 + 抽样 sha256**（本页 §7 的重建回读、§9 的换件取证都遵循此则）。

## 10. 关联

- [[20_Tech_Stack/qwen3.8-27b-nvfp4-tp2-ninfer_manifest|旧 TP2 手册（neroued v2 件 · ⚠️ 已存档 2026-10-08）]] —— 引擎身份、参数依据、v2-only 边界、重建步骤全在那页，**仍然有效**
- [[20_Tech_Stack/ninfer_engine_architecture_manifest|NInfer 引擎架构手册]]
- [[20_Tech_Stack/ornith-1.5-35b-a3b-ninfer_manifest|Ornith NInfer 手册（8093）]]

## 12. 约束解码 / 结构化输出（2026-10-13 并入）

**是什么**：采样阶段的文法掩码（vendored **XGrammar v0.2.7**）保证输出符合 JSON Schema / 正则 / 枚举候选 —— 硬约束，不是提示词软约束。

**请求形态**：Chat `response_format:{type:json_schema,json_schema:{name,strict,schema}}`（也支持 `{type:json_object}`）｜ Responses 扁平式 `text.format:{...}`（**并已回显**）｜ Anthropic `output_config.format:{type:json_schema,schema}`。

**开关**：`--structured-output`（**默认关**；关时对受约束请求回 HTTP 400 `response_format_not_supported`）。`--unconstrained-response-format` 与之互斥（客户端总发格式时降级为不加约束生成）。router 的 8091 argv 已加 `--structured-output`（精确一行差异）。

**与工具调用共存**：受约束请求带 `tools` 时，模型仍可先发原生 tool-call（`finish_reason=tool_calls`），工具结果回填后再产出受约束 JSON（已真机验证）。

**实测（2026-10-13，生产二进制）**：整套 live 一致性 `PROD_LIVE_EXIT=0`（Chat 5 用例 + 流式 + 长度截断 + 取消 + 非法请求 + Responses + Anthropic）；经 8097 provider 端到端通过；n=9 decode 三臂中位 **28.7 tok/s 一致**、prefill 12.919→12.927 s、前缀复用 **99.9% 不变**、工具调用指纹逐字一致；掩码平面 **121 KiB/lane**（不影响 262144 ctx）。

**已知边界**：(a) 贪婪（`temperature=0`）路径已修复并有用例覆盖；(b) DFlash 两条道未验（tp2 上 DFlash 被拒、产线不可达）；(c) 多 lane（`--max-concurrency>1`）掩码隔离未验（产线固定 1）；(d) `tests/targets/qwen3_6/test_frontend.cpp` 目标既有坏（硬编码作者路径 `/home/neroued/…`，本机不可跑）。

**来源**：隔离克隆 `~/workspace/so-port-20261013/repo`（分支 `so-port-structured-output`，已 ff 并入生产树）；移植地图/坑/验收口径见 skill `ninfer-linux-sm120a-build/references/constrained-decoding-port.md`。 （该隔离克隆已清理）
