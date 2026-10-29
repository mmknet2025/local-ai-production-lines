---
type: "navigation"
title: "本机三条生产线总览（单一事实源 · 2026-10-13）"
description: "本机 NInfer 单卡/双卡 + Strata 三条生产线的唯一入口：身份、端口、开关、能力、回滚。细节各自 manifest，本页只放四处都要用的公共事实，避免逐文件重复。"
tags: [local-inference, ninfer, strata, production, single-source-of-truth, okf-v0.2]
timestamp: "2026-10-21"
trust: "agent-generated"
status: "current"
okf_version: "v0.2"
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
| 引擎树（**2026-10-29 20 补丁**） | **`~/src/kvmem-product/repo/backends/ninfer`** = `kvmem/kvmem` 产品线自建树（`versions.json` 钉 `iamwavecut/ninfer-all@63428ac2` + **20 补丁**，末端树 **`d976d3f8b206`** = 官方 `patched_tree`；核心 `repo/kvmem`）。10-28 时的 16 补丁末端 `31eae205` 已作废。旧 qzshch 树 `kvmem-base-20261021`/`kvmem-base-0180-20261022` 与 5258 树留作回滚 | `~/ninfer-build/baiyouqing-tp2` 分支 `so-port-structured-output-recovered` @ **74a2879b** | `~/src/Strata` tag **`v0.2.7.1`** @ **46c152a13**（引擎 **0.1.53**，10-28；此前 v0.2.6/0.1.51 见 §20、v0.2.1.3/0.1.46.2 见 §16–17） |
| 二进制（**2026-10-29**） | sha **a6dffc2d…**（684,392,648 B，`0.12.0-rtx3090+2026-10-25.1-dirty`；20 补丁产物）。升级只走 `~/.local/bin/kvmem-8090-upgrade --check`（只跟 kvmem 仓库 pin，不前滚 iamwavecut master）；回滚 = 同目录 `ninfer-serve.old-c7683001`（16 补丁件）+ 树重打 16 补丁 | sha **e630612d…**（216,109,952 B，**10-29 01:09 重编**，源码 `74a2879b` 对齐；旧件 `45ca6e27` 10-13 已删） | sha **68dfccc3…**（114,432,176 B，**10-28**） |
| 端口 / 单元 | 8090 / `ninfer-prod` | 8091 / `ninfer-tp2` | 8080 / `strata-swift-iq3s` |
| 上下文 | 262144 | 262144 | 262144 |
| 特有能力 | KVMem 环（分页 KV 池 + 长复用）+ 约束解码 | MTP K=3 投机 + 前缀复用 99.9% + **约束解码（10-13 并入）** | 双卡 layer-split 24 |
| 资源 | 单卡；需 MemAvailable ≥40 G | 双卡；`min_mem_gib 0` | 双卡 + RAM ~48–133 G |
| 冷启动 | ≈10 s | ≈8.5 s | 1–2 分钟 |
| 详情 | [[20_Tech_Stack/ninfer_engine_architecture_manifest]] | [[20_Tech_Stack/qwen3.8-27b-coder390-tp2-ninfer_manifest]]（§12 约束解码） | [[20_Tech_Stack/strata_engine_manifest]] + [[20_Tech_Stack/swift-1.5-qwen3.8-flash-next-iq3_s_manifest]] |

> 🔁 **2026-10-29 变更（仅 8090）**：产品线 pin 从 **16 → 20 补丁**（base 仍 `63428ac2`，末端树 `31eae205` → **`d976d3f8b206`**），新增 4 个链式补丁 `dflash2-layer-pipeline → cpu-vision-props → memory-planning → multigpu-resident-vision`（对应上游 **#225 DFlash2 layer-pipeline**、#226 CPU vision props、#228 resident vision）。新二进制 **`a6dffc2d…`**（684,392,648 B），20 环 `after_tree` 逐环校验通过，`--check` 报「无需重建」。**生产仍用 `--spec mtp --draft-tokens 4`**（结论见下）。
>
> 🧪 **MTP vs DFlash2 实测（单卡 5060 Ti 16 GB，同工件 `swift-qwen38-rco-iq3s`，KV 131072，greedy，3 reps）**：该工件 header 实测**同时带** `Qwen3_5MTP` 与 `DFlash2DraftModel`（5 层、head_dim 128、target_layer_ids `[5,19,33,47,61]`、selector_top_k 16），所以 `--spec` 可直接对跑。
> - **草稿接受率：MTP 37.5%（1911/5098）> DFlash2 33.5%（1767/5276）**；decode 短 58.4 vs 55.8 / 长 61.3 vs 57.1 tok/s；prefill 与 TTFT 持平；`--spec none` 同 KV 仅 32.8 tok/s（草稿本身的收益 32.8 → 55–58）。
> - **权重：MTP 11.6 GiB / DFlash2 13.4 GiB**（+1.8）⇒ 16 GB 单卡上 DFlash2 的 `--kv-capacity 262144` 起不来（`runtime 需 3013989632 B，仅 2165112832 B 可用`），只能 131072 ⇒ **上下文腰斩**。
> - **输出等价性已验证**：同 prompt、无冷前缀 nonce、greedy 下 `none / mtp / dflash2` 三者 **79 tokens、文本逐字相同**（注意：`ab-probe.py` 每次请求加唯一 nonce 用于测 TTFT，因此**不能用它的 completion_tokens 判断输出一致性**，那是假信号）。
> - 决策：**单卡保持 MTP**（DFlash2 接受率更低、decode 更慢、上下文只有一半，prefill/TTFT 无补偿）。已把这三条实测报给上游 `kvmem/kvmem#225`（comment `6487316391`）。

> 🔁 **2026-10-28 变更（仅 8090）**：引擎换成 **`kvmem/kvmem` 产品线自建树**（`~/src/kvmem-product/repo`，pin `63428ac2` + 16 补丁 → `31eae205`），二进制 `c7683001…`。单卡 A/B：count **+23.1%**、long **+13.4%**、prefill 等价、散文 +1.5%。**维护约定**：只跟 kvmem 仓库 `versions.json` 的 pin 升级，**不自行前滚 `iamwavecut/ninfer-all` master**（KVMem 与 TP 源码层互斥，前滚要重打 16 补丁、82 文件重叠，无收益证据）。升级入口 `~/.local/bin/kvmem-8090-upgrade --check`（`--apply --yes` 才重建，不重启引擎）；详见 [[20_Tech_Stack/kvmem_product_line_manifest]]。

> 🔁 **2026-10-21 变更（仅 8090）**：引擎基座由 `5258MF` 下游树换成**环上游 `qzshch/ninfer-kvmem` 底座**（`iamwavecut@08fd7019` + 补丁 + 独立 `kvmem/` 模块）。散文 decode **67.2 → 51.0 tok/s**（−24%），前缀复用 91.5% → **98.3%**；`--kvmem-window-pages`/`--kv-capacity`/`--device-state-slots`/`--host-kv-mib` 等旧旗标已换（详见 [[20_Tech_Stack/ninfer_engine_architecture_manifest#§14 换基座|manifest §14]]）。device profile 已用 `ninfer-calibrate` 重跑（schema v2，78 键）。回滚 = 换回 `start-prod.sh.5258-20261021` + 旧二进制 `f6c8b6be…`。

> 🧪 **2026-10-22 8090 上游判定（严格对账 + A/B，结论：不升）**
> - **上游是两层**：基座 `iamwavecut/ninfer-all`（`08fd7019`，由 qzshch `versions.json` 的 `base_commit` 钉定 → **基座不是升级轴**；`origin/master` 落后 79 commit 只是基座自身进展，大头是 `qwen4_exp`/docs，与 qwen3.5 27B 路径无关）；特性环 = `qzshch/ninfer-kvmem`（判版本只看 `VERSION` + `backends/patches/ninfer-kvmem.patch` 的 sha256）。
> - **对账结果**：干净基座 `08fd7019` + 当前补丁（`VERSION 0.18.0`，sha256 `743ef2db…`，253 文件，0 失败块）vs 现役树 → 一致 179 / 内容不同 61 / 我方缺失 13；现役树相对基座的 165 个改动文件 **全部**落在补丁文件集内，**自研独有改动 = 0**，补丁外新增文件除 worktree `.git` 外 43 个全是补丁新增。
> - **A/B（新编 `b555024f…` 650 MB vs 现役 `169716d5…`，同参数同语料）**：冷长文 prefill 63,883 tok → 66,524ms(960 tok/s) vs 66,839ms(956 tok/s)；暖前缀 286 vs 287ms；前缀复用均 99.998%；长文 decode 71.8 vs 71.8；散文 decode 50.3 vs 50.2；ready 6s vs 6s；显存均 14,705 MiB；答案均命中。**性能等价 → 判不升**（功能增量：约束解码/tool-call/reasoning budget 未测）。
> - 产物：新树 `~/workspace/ninfer-0180`（约 1.1 GB，**已删除**：2026-10-22 白天清理）；存活证据 = `~/workspace/ab-0180.log`（A/B 原始输出）、`ab_probe.py`（探针）、`ab-0180.sh`（驱动）、`~/workspace/kvmem-0180`（kvmem 核，与现役核 diff=0）。复现方式：干净基座 `08fd7019` + qzshch 0.18.0 补丁重打后重编（约 40 分钟）。生产未改动。

## 2. 编排（三线共用一条入口）

- Hermes 唯一本地 provider = **`local-engines` → `http://127.0.0.1:8097/v1`**（unit `local-router`，脚本 `~/.local/bin/ninfer-router`，**常驻不占 GPU**）
- 模型 id → 端口：`1card-qwen3.8-27b-swift-iq3s`→8090 ｜ `2card-qwen3.8-27b-coder390`→8091 ｜ `flash-next-swift1.5-iq3s`→8080
- **三引擎互斥**：首请求按需拉起，拉起前先停其它并等其真 inactive；8099（旧直连口）保留应急，8098 已 disable
- 流式冷启动会先注入「⏳ 正在拉起 X…」/「✅ X 就绪（已停 Y）」两条 delta

## 3. 8091 的开关（10-13 起）

- `--structured-output`（**默认关**；但 **router 已对 8091 无条件加上 ⇒ 生产上常开**）：开时接受 JSON / JSON Schema 请求格式（Chat `response_format`、Responses `text.format`、Anthropic `output_config.format`），硬保证输出符合；**不传格式时行为与旧版一致**
- 与之互斥的 `--unconstrained-response-format`：客户端总发格式时降级为不加约束生成
- 回退：树 `pre-so-port-20261013-1914` / `backup/windows-port-20261013-1914`；旧二进制 `~/vault-backup/ninfer-8091-pre-structured-output-20261013-1914/ninfer-serve-pre`；router `~/.local/bin/ninfer-router.orig`（⚠️ **2026-10-21 实测该回退件不存在**，只有本体 `ninfer-router`）
- ⚠️ **源码领先产物**：树 HEAD 已到 `74a2879b`（2026-10-21 01:30，`recover: structured-output work reconstructed from working tree`），而现役二进制仍是 `45ca6e27…`（10-13 19:15）。**这不是功能缺口** —— 约束解码在 10-13 的产物里就有（`--help` 命中 `structured-output` 3 次，router 也一直带着该旗标），10-21 那次只是重建工作树。真要重编属于「跟代码整洁性」，不是修 bug。

## 4. 通用纪律（三线共用）

- **Hermes 侧推理强度会覆盖引擎模板默认**（2026-10-29 实测）：`local-engines` 走 `CustomProfile`，其 `default_reasoning_config()` 主动填 `{enabled:true, effort:'medium'}` 并以**顶层 `reasoning_effort`** 发出 ⇒ 单卡引擎模板默认的 **xhigh 被压成 medium**（同一题思考 957 → 420 字符，实测 medium 实际落在 low 档）。已用 `agent.reasoning_overrides` 对 `1card-qwen3.8-27b-swift-iq3s` / `2card-qwen3.8-27b-coder390` 覆盖为 **xhigh**（`flash-next-swift1.5-iq3s` 未覆盖，Strata 是否认该字段未验）。坑：`hermes config set agent.reasoning_overrides.<model-id>` 会把 model id 里的点当路径分隔符拆错（`1card-qwen3:` / `8-27b-…:`），必须整体传 JSON：`hermes config set agent.reasoning_overrides '{"<model-id>": "xhigh"}'`。

- **按需启动**、用完释放；不常驻占显存
- **升级口径**：不看上游「发版没」，只看「我们这条 fork 线有没有传导过来、且值不值」；收益未证实 ⇒ 不升。**8090 例外**：它只跟 `kvmem/kvmem` 的 pin（`~/.local/bin/kvmem-8090-upgrade --check`），不自行前滚 `iamwavecut/ninfer-all` master
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
| `ninfer-router`（`--profile ninfer`） | 8099 | **disabled + inactive（2026-10-21 实测）** | 旧直连口。⚠️ 当前**不是**常开的回滚口：`ss` 无 :8099 监听，需 `systemctl --user start ninfer-router` 才可用；与 8097 同时使用时注意引擎互斥 |
| `strata-router`（`--profile strata`） | 8098 | **disabled** | 关闭（可 `enable` 复活作回滚口） |
| 引擎单元 `ninfer-prod` / `ninfer-tp2` | 8090 / 8091 | 按需（瞬时单元，`systemd-run --user --collect`） | 由 router 拉起；手工 `--stop` 或 `systemctl --user stop` 均可停 |
| 引擎单元 `strata-swift-iq3s` | 8080 | disabled（按需 start） | 由 router `start_via: unit` 拉起 |

**维护纪律**：手工直起引擎会**绕过互斥**（router 只认端口状态）⇒ 直起前先确认其它引擎已停；收尾把 `local-router` 起回（`systemctl --user start local-router`）。

## 7. 已发布（GitHub，公开，2026-10-13）

| 仓 | 内容 | 快照点 |
|---|---|---|
| `mmknet2025/ninfer-line-8090-single-card` | 8090 引擎源码（**不含**模型/编译产物） | `c7f5a1ba` |
| `mmknet2025/ninfer-line-8091-dual-card-tp2` | 8091 引擎源码（含 vendored XGrammar + 受限解码） | `8c50e4ed` |
| `mmknet2025/strata-line-8080-125b-moe` | Strata 引擎源码 | **`b7c794f0`**（= `v0.1.44`/`ed4773eb` 合并本仓 `PUBLICATION.md` 提交 `320981df`；2026-10-14 推） |
| `mmknet2025/local-ai-production-lines` | **编排层**：`ninfer-router` + 4 个 systemd 单元 + `start-prod-8090.sh` + 本页与 4 份手册 | — |

- 方式：克隆 → 加 `PUBLICATION.md`（溯源 / 生产配置 / 不含什么）→ 以 `main` 推送；**生产树零改动**，发布父提交 sha 与生产树 HEAD **逐位相同**（内容同一性证明）。
- **不含模型**：15–21 GB `.ninfer` 工件、133 GB `Strata-data`、引擎二进制（1.37 G / 209 M / 68 M，未跟踪）均在仓外。
- 发布时踩到的**坑**：Strata 源树当时是**浅克隆**（`.git/shallow`）⇒ 直接推报 `remote: fatal: did not receive expected object … index-pack failed`（本地缺历史对象，而 `git fsck` 因 shallow/promisor 特性**免检不报**＝假安全）；当时解法 = 从上游**全量克隆**后检出 `a0116b2` 再推。
- **2026-10-13 21:20 已补全量**：`git fetch --unshallow origin`（**4 s**，对象 +1137 个，`.git` 42→67 M）；提交数 **341→1892**、`.git/shallow` 消失；HEAD（`a0116b2`）/树 sha（`4c7ff5f7…`）/引用/工作树/分支**全未变**，`fsck` 无错。回滚点 `~/vault-backup/strata-git-shallow-20261013/.git`（42 M）。**三棵树现均非浅克隆**。
- **2026-10-13 21:27 精修**：四仓补 **topics**（`local-inference` / `ninfer` / `qwen3` / `kv-cache` / `tensor-parallel` / `speculative-decoding` / `structured-output` / `moe` / `layer-split` / `systemd` / `llm-serving` 等）；8090/8091 的 `PUBLICATION.md` 把「systemd user 单元」精确为「**由路由器按需拉起的瞬时单元**（`systemd-run --user --collect`，仓内无静态 unit 文件）」，各推一个 docs 提交（新头 `426b1111` / `aba15a6a`）；**内容仍逐位等于生产树**（父提交 `c7f5a1ba` / `8c50e4ed`）。
