#!/bin/bash
# NInfer 生产启动器 —— 8090（单卡 27B / Swift 1.5 IQ3_S / KVMem 长上下文）
# 2026-10-22 换引擎件：kvmem-base-20261021 → kvmem-base-0180-20261022（qzshch KVMem 补丁更新版）
#   BIN = ~/ninfer-build/kvmem-base-0180-20261022/build/apps/ninfer-serve
#         sha256 b555024f24469377… 650796448 B  VERSION 0.12.0-rtx3090
#   旗标与采样全未改动（A/B 实测性能等价：prefill 956 vs 960 tok/s、decode 71.8 vs 71.8）
# 回滚（上一版 = 08fd7019+qzshch 拼装，sha 169716d5…）：
#   cp start-prod.sh.bak-pre0180-20261022 start-prod.sh
# 更早回滚（5258 下游树）：cp start-prod.sh.5258-20261021 start-prod.sh（旧 sha f6c8b6be… 在 ~/vault-backup/ninfer-8090-pre-rebuild-20261021/）
set -u

# 2026-10-28 换引擎件：qzshch 线(kvmem-base-0180-20261022) → KVMem 产品线自建树
#   理由：单卡口径实测 count +23.1% / long +13.4%，prefill 与冷启动等价（见 Vault
#   20_Tech_Stack/kvmem_product_line_manifest.md）。回滚：把下面 BIN 换回注释里那行。
BIN=/home/mmknet/src/kvmem-product/repo/backends/ninfer/build/apps/ninfer-serve
# 回滚件（旧引擎 0.12.0-rtx3090+unknown，sha b555024f…，650796448 B）：
# BIN=/home/mmknet/ninfer-build/kvmem-base-0180-20261022/build/apps/ninfer-serve
MODEL=/home/mmknet/models/qwen3.8-27b-swift/swift-qwen38-rco-iq3s.ninfer

HOST=127.0.0.1
PORT="${PORT:-8090}"
MODEL_ID=qwen3.8-27b

# ── 上下文与 KV ──
# 设备池 B(61440) + 生成预留 R(4096) = 65,536 token 窗口；超出部分按需从主机 16 GiB 池召回。
# ⚠️ 不要传 --kv-capacity：auto/explicit 都会被 KVMem 的「B+R ≤ capacity」闸门拒绝。
MAX_CONTEXT="${MAX_CONTEXT:-262144}"
KV_DTYPE="${KV_DTYPE:-int8}"
KV_BUDGET="${KV_BUDGET:-61440}"
KV_GEN_RESERVE="${KV_GEN_RESERVE:-4096}"
KV_HOST_MIB="${KV_HOST_MIB:-16384}"
KV_SINK_TOKENS="${KV_SINK_TOKENS:-128}"

PREFILL_CHUNK="${PREFILL_CHUNK:-1024}"

SPEC="${SPEC:-mtp}"
DRAFT_TOKENS="${DRAFT_TOKENS:-4}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"

# ── 输出与采样（沿用 5258 版验证值，勿改）──
DEFAULT_MAX_TOKENS=32768
PRESENCE_PENALTY=0
TEMPERATURE=0.7
TOP_P=0.9
TOP_K=20
CUDA_GRAPH_ALLOWANCE_MIB=144
LOG_LEVEL=info
VISION="${VISION:-}"

[ -x "$BIN" ]   || { echo "REFUSE: 引擎不存在 $BIN"; exit 3; }
[ -f "$MODEL" ] || { echo "REFUSE: 模型不存在 $MODEL"; exit 4; }

exec "$BIN" "$MODEL" \
  --host "$HOST" --port "$PORT" --model-id "$MODEL_ID" \
  --max-context "$MAX_CONTEXT" \
  --kv-dtype "$KV_DTYPE" \
  --kvmem \
  --kvmem-budget "$KV_BUDGET" \
  --kvmem-gen-reserve "$KV_GEN_RESERVE" \
  --kvmem-host-mib "$KV_HOST_MIB" \
  --kvmem-sink-tokens "$KV_SINK_TOKENS" \
  --derive-session-keys \
  --prefill-chunk "$PREFILL_CHUNK" \
  --spec "$SPEC" --draft-tokens "$DRAFT_TOKENS" \
  --lm-head-draft \
  --max-concurrency "$MAX_CONCURRENCY" \
  --default-max-tokens "$DEFAULT_MAX_TOKENS" \
  --presence-penalty "$PRESENCE_PENALTY" --temperature "$TEMPERATURE" \
  --top-p "$TOP_P" --top-k "$TOP_K" \
  $VISION \
  --gdn-state-fp16 \
  --structured-output \
  --cuda-graph-allowance-mib "$CUDA_GRAPH_ALLOWANCE_MIB" \
  --log-level "$LOG_LEVEL"

# ── 与 5258 版启动器的差异（回滚时对照）──
# 去掉 --kvmem-window-pages 1000 → --kvmem-budget 61440 + --kvmem-gen-reserve 4096
# 去掉 --kv-capacity auto（有 KVMem 时被拒）
# 去掉 --host-kv-mib 16384（上下文缓存归 KVMem 独占）
# 去掉 --embedding-host / --lm-head-q6（新基座无此旗标）
# 去掉 4 个 NINFER_KVMEM_* 环境变量（新基座改用 --kvmem-* 旗标）
# 保留 --derive-session-keys（前缀复用必要条件）/ --gdn-state-fp16 / 采样四件套 / --default-max-tokens 32768
