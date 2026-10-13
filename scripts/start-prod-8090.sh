#!/bin/bash
# NInfer 生产启动器 —— Swift 模型 / 本机 5258 线引擎（KVMem 变体 B）
#
# 【调优版】不再照抄厂商 start-pq2（那套是给 9.5GB 模型调的）。按引擎实际能力启用
# 已验证的低代价优化开关。逐项依据见文件末尾。
# 回退：同目录 start-prod.sh.bak-vendor-params-20261004-083906
set -u

BIN=/home/ubuntu/ninfer-build/src-5258/swift15/engine/build/apps/ninfer-serve
MODEL=/home/ubuntu/models/qwen3.8-27b-swift/swift-qwen38-rco-iq3s.ninfer

# ── 端口与身份 ──
HOST=127.0.0.1
PORT="${PORT:-8090}"
MODEL_ID=qwen3.8-27b

# ── 上下文与 KV ──
# KVMem 硬约束（src/runtime/engine/model_instance.cpp）：
#   单卡 only / dtype ∈ {int8, rk8v4, rk4v4} / spec ∈ {none, MTP, DFlash2} / 须开 Host KV
MAX_CONTEXT="${MAX_CONTEXT:-262144}"
KV_CAPACITY="${KV_CAPACITY:-auto}"
KV_DTYPE="${KV_DTYPE:-int8}"   # int8 = KVMem 三档里精度最高（键8/值8位）；
                               #   rk8v4/rk4v4 的值只有 4 位。2026-10-04 实测速度持平，
                               #   代价：runtime 3.20→3.71 GiB（显存余量 1.00→0.49 GB）
HOST_KV_MIB="${HOST_KV_MIB:-16384}"
WINDOW_PAGES="${WINDOW_PAGES:-1000}"   # 变体 B 专有；作者推荐窗口≈63K token ÷ 64 token/页
DEVICE_STATE_SLOTS="${DEVICE_STATE_SLOTS:-1}"

# ── 预填充：调优 ──
PREFILL_CHUNK="${PREFILL_CHUNK:-1024}"   # 2048 使 cuBLAS 工作区翻倍 → runtime 超 269MB 起不来（实测）
                                         #   当 chunk=2048 + cublas 时 FATAL：runtime 需 4.11 GiB 仅余 3.86 GiB

# ── 推测解码：调优 ──
SPEC="${SPEC:-mtp}"
DRAFT_TOKENS="${DRAFT_TOKENS:-4}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"
# 不再显式设 --max-shared-prefixes 0（厂商的关闭动作），改用引擎默认 max(并发,7)

# ── 输出与思考 ──
DEFAULT_MAX_TOKENS=32768
# ⚠️ 2026-10-06 实测：**不再设 --default-reasoning-effort**（回到「模板默认档」）。
#    同口径 16K 真实语料 × 3 rep、out 对齐 256：thinking off = 62.1 tok/s / 接受率 41~48%
#    → 模板默认档 = **95.2 tok/s / 接受率 47~68%（+53%）**；而显式 --default-reasoning-effort medium
#    只有 66.3（≈ off，白开）—— 收益来自「模板默认档」本身，不是 thinking 布尔量。
#    代价：短问答会带上思考 token（参照双卡线：trivia 40 vs 6 tok）。回退见 .bak-20261006-2346

# ── 采样默认 ──
PRESENCE_PENALTY=0
TEMPERATURE=0.7
TOP_P=0.9
TOP_K=20

# ── 本机必需 ──
CUDA_GRAPH_ALLOWANCE_MIB=144
LOG_LEVEL=info

# ── 0.1.3 起必需：KVMem 自动分配 + 长复用（逐字取自上游 Swift 启动器 launch.ps1）──
# 缺这几个 env 时 --kv-capacity auto 会按「全上下文」算设备池 → FATAL:
#   minimum Engine runtime reservation requires 10.9 GiB, but only 4.1 GiB available after weights
# 补上后：KVMem allocation | window 1000 pages | ... | long reuse on
#         capacity | KV 66,176 tokens, int8 | runtime 3.71 GiB   （与本机 0.1.2 组合版一致）
# NINFER_KVMEM_LONG_REUSE=1 是 0.1.3 新增的「长复用」开关，直接决定跨请求前缀复用。
export NINFER_KVMEM_AUTO_ALLOCATION=1
export NINFER_KVMEM_SINK_PAGES=2
export NINFER_KVMEM_GEN_RESERVE_PAGES=0
export NINFER_KVMEM_LONG_REUSE=1

# ── 视觉（2026-10-04 按用户要求默认屏蔽；需要时 VISION=--vision 开） ──
#   存档依据：旧 GSQ KVMem 有视觉，为对等曾开启（实测 +440 MiB）
#   关闭收益：省 440 MiB → 让 chunk2048 / win1600 / kvint8 等档起得来
VISION="${VISION:-}"

[ -x "$BIN" ]   || { echo "REFUSE: 引擎不存在 $BIN"; exit 3; }
[ -f "$MODEL" ] || { echo "REFUSE: 模型不存在 $MODEL"; exit 4; }

exec "$BIN" "$MODEL" \
  --host "$HOST" --port "$PORT" --model-id "$MODEL_ID" \
  --max-context "$MAX_CONTEXT" --kv-capacity "$KV_CAPACITY" \
  --kv-dtype "$KV_DTYPE" --host-kv-mib "$HOST_KV_MIB" \
  --kvmem-window-pages "$WINDOW_PAGES" \
  --device-state-slots "$DEVICE_STATE_SLOTS" \
  --derive-session-keys \
  --prefill-chunk "$PREFILL_CHUNK" \
  --spec "$SPEC" --draft-tokens "$DRAFT_TOKENS" \
  --lm-head-draft \
  --max-concurrency "$MAX_CONCURRENCY" \
  --default-max-tokens "$DEFAULT_MAX_TOKENS" \
  --presence-penalty "$PRESENCE_PENALTY" --temperature "$TEMPERATURE" \
  --top-p "$TOP_P" --top-k "$TOP_K" \
  $VISION \
  --gdn-state-fp16 --embedding-host \
  --cuda-graph-allowance-mib "$CUDA_GRAPH_ALLOWANCE_MIB" \
  --log-level "$LOG_LEVEL"

# ── 调优项与依据（取自引擎 --help 原文 / 上游发布数据 / 分支自测 / 本机实测） ──
# 1. --lm-head-draft   精简提议头。5258 分支 benchmarks：「MTP 输出头选精简 → 约 47 tok/s
#                      （+10.5%）」；上游全部官方发布测量均注明用优化提议头。
#                      厂商 dflash 启动器带、mtp 启动器漏掉（旧脚本第 75 行自述）。
#                      本机实测（组合后）decode 109.9 → 117.3 tok/s = +7.0%。
# 2. ~~--adaptive-mtp~~    ❌ **2026-10-06 A/B 实测移除**（本机 15.9K 真实语料，3 rep 同向）：
#                      关掉后 decode 67.3 → **72.4 tok/s（+7.6%，rep 极值 76.9）**，接受率略降
#                      （56.5→54.4%）但每轮更便宜 → 净加速。开它反而慢 7.6~14%。
# 3. ~~--fast-prefill-kernel~~ ❌ **实测纯 no-op**：与关闭态逐位相同（prefill 1120.0 ×4 档全等）。
# 4. ~~--mlp-a8-decode~~   ❌ **实测纯 no-op**：与关闭态逐位相同（out 71/55/55、decode 54.7/67.3/67.2 全等）。
#                      （同一开关在 8093 Ornith 线上实测长上下文 −7%，两线皆为负/无效。）
#   依据：`~/.hermes/cache/scratch/ab_params_v4.py`（口径见其 docstring：固定语料 + nonce + 3 rep +
#   全部数值取自引擎日志；注意语料必须用**真实变化文本**，重复填充会触发 ngram 草稿污染 decode）。
# 5. 恢复共享前缀默认   厂商显式 --max-shared-prefixes 0 关掉了共享前缀目录 → 多轮场景纯损失。
#    ⚠️ 2026-10-12 更正：这一条**原以为是复用生效的原因，实为误记**（10-04 那个"第2次 1.21s/12%"
#    是 vLLM 线的成绩；同份日志里 NInfer 线写着 100%（无复用））。真正原因是下面第 6 条。
# 6. --derive-session-keys   ★ 2026-10-12 实测新增，跨请求前缀复用的**必要条件**。
#    机制：KVMem 窗口模式（--kvmem-window-pages != 0）下引擎的结构性闸门只拒"共享前缀"路
#    （request_plan.cpp:770-785，日志 `KVMem reuse refused | shared source | path 5`），放行
#    "私有会话续写"路；而会话键只在开本 flag 时派生（serve_options.h:107 默认 false），
#    来源 = hash(system 全部文本 + 第一条 user 消息)（translate.cpp:376-400）。
#    客户端无任何字段能设会话键（x-conversation-id / user / prompt_cache_key 均被忽略）。
#    实测（同一 prompt 连发两次，冷 → 热）：
#      prompt 4.6k  : 4.0s → 0.3s   cache 全命中
#      prompt 72k   : 75.4s → 0.33s  (230×)
#      prompt 134k  : 149.8s → 0.31s (478×)
#    多轮增长式对话：cache 逐轮累积（16k→32k→48k），每轮只 prefill 新增内容 ⇒ TTFT 恒定。
#    代价：显存不变（15,424 vs 15,358–15,492 MiB）；复用令 temperature=0 采样不可复现
#    ⇒ 做质量/参数 A/B 时必须带 nonce 或临时关复用。
#
# ── 试过并【撤掉】的（别重复踩） ──
# · --prefill-cublas   ❌ 实测无用且有害。本机对账（同题同语料）：
#                       8K 1138→1141 / 32K 1052→1055 / 64K 957→958 / 126K 825→831 tok/s
#                       → 全在噪声内（+0.2~0.7%）；而 fork 自述代价是 +0.156% 困惑度。
#                       原因是它要求配套大 --prefill-chunk（fork 推荐 4096），本机连 2048
#                       都放不下（见下），1024 下开不出收益。故撤掉。
# · --prefill-chunk 2048  ❌ 起不来。FATAL：runtime 需 4,413,001,985 B 仅余 4,143,579,136 B
#                       （cuBLAS/内核工作区随分块放大，auto 的 KV 池又把余量吃满）。
#                       1024 时 runtime 3.36 GiB / free 559.6 MiB，正常。
#
# ── 本版【未】启用（各有原因，勿误判为遗漏） ──
# · --spec dflash2      官方要多占 ~1.6 GiB 权重显存（MTP3 16.672 → DFlash2 18.326 GiB）；
#                       本机 16GB 卡生产态 15,382/16,311 → 余量不足，需单独评估。
# · --kv-dtype rk4v4    KV 减半可翻倍窗口，但改变 KV 表示 → 影响 KVMem 检索质量，需单独 A/B。
# · --lm-head-q6        仅省显存（+0.01% 困惑度），本机无显存缺口 → 收益不明确，不加。
# · --rope-yarn         仅在需要 >262144 上下文时才有意义；本机 ctx 已 262144。
# · 双卡 --devices      引擎有 2..8 卡流水线开关，但 KVMem 硬限单卡
#                       （model_instance.cpp: "KVMem supports a single device only"）。
