# 本地推理生产线 · 编排层（orchestration）

三条本地推理生产线跑在 **2× RTX 5060 Ti 16GB（Gen5 x8+x8，P2P 可用）+ Ryzen 7 9700X** 上，由**一个按需编排的本地路由器**统一暴露给上层（Hermes 侧只有一条 provider，指向 `127.0.0.1:8097/v1`）。

## 三条线（互斥：同一时刻只有一条占卡）

| | ① 8090 单卡长上下文 | ② 8091 双卡主力 | ③ 8080 125B MoE |
|---|---|---|---|
| 引擎 | NInfer（单卡，引擎内建 **KVMem** 分页 KV 池） | NInfer（**张量并行 TP2**，MTP 投机 K=3 + 前缀复用） | **Strata**（双卡 layer-split，125B MoE） |
| 模型 | Qwen3.8-27B Swift-1.5 GSQ-RCO IQ3_S（15.0 GB） | Qwen3.8-27B Coder390 W4A4-W8A8（21.5 GB） | Qwen3.8-Flash-Next 125B/A6B IQ3_S |
| ctx | 262144 | 262144 | 262144 |
| 冷启动 | ≈10 s | ≈8.5 s | 1–2 min |
| 起法 | `--profile all` 首请求自动拉起 | 同上 | 同上 |
| 源码仓 | `ninfer-line-8090-single-card` | `ninfer-line-8091-dual-card-tp2` | `strata-line-8080-125b-moe` |

**模型工件不进任何仓**（15–21 GB 的引擎工件与 133 GB 的 Strata 数据都在仓外）。

## 这个仓里有什么

- `bin/ninfer-router` —— 编排路由器（**唯一事实源**：每个 profile 的启动 argv 都写在脚本的 `ROUTES` 表里）。三引擎互斥：**拉起新人前先停旧的并等其真正 inactive**；Strata 卸载需释放 ~48 GB。
- `units/*.service` —— systemd **user** 单元（`local-router` @8097 常驻不占 GPU；`ninfer-router` @8099、`strata-router` @8098 为应急直连/回滚口；`strata-swift-iq3s` 是 8080 引擎本体）。
- `scripts/start-prod-8090.sh` —— 单卡线的手工启动脚本（含 4 个 `NINFER_KVMEM_*` 与 `HOST_KV_MIB`）。
- `docs/` —— 三线总表与各线手册（引擎架构、模型工件、验证记录）。

## 启动

```bash
systemctl --user enable --now local-router     # 常驻路由器（不占 GPU）
curl -s localhost:8097/v1/models               # 看三个 model id
# 之后按 model id 发起请求即可，引擎按需自动拉起（拉起前会停掉另一条线）
```

**手工直起某个引擎会绕过互斥** —— 要么走路由器，要么先确认另一条线已停。

## 注意

- 本仓是我们的**编排与文档**，不含任何上游引擎源码（三条线的引擎源码在各自的仓）。
- 脚本/单元里的路径是本机布局（`/home/ubuntu/...`），换机需要改路径与卡号。
