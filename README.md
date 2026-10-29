# 本地推理生产线 · 编排层（orchestration）

三条本地推理生产线跑在 **2× RTX 5060 Ti 16GB（Gen5 x8+x8，P2P 可用）+ Ryzen 7 9700X + 60 GB RAM** 上，由**一个按需编排的本地路由器**统一暴露给上层（Hermes 侧只有一条 provider，指向 `127.0.0.1:8097/v1`）。

> 最后同步：**2026-10-29 14:30**（内核 `7.3.0-10-generic`，驱动 615.78.08 + P2P 补丁）。

## 三条线（互斥：同一时刻只有一条占卡）

| | ① 8090 单卡长上下文 | ② 8091 双卡主力 | ③ 8080 125B MoE |
|---|---|---|---|
| 引擎 | NInfer（单卡，内建 **KVMem** 分页 KV 池） | NInfer（**张量并行 TP2**，MTP 投机 + 前缀复用） | **Strata**（双卡 layer-split，125B MoE） |
| 模型 | Qwen3.8-27B Swift-1.5 GSQ-RCO IQ3_S（15.0 GB） | Qwen3.8-27B Coder390 W4A4-W8A8（21.5 GB） | Qwen3.8-Flash-Next 125B/A6B IQ3_S |
| ctx | 262144（显存 KV 池 65536，超出走 host KV） | 262144 | 262144 |
| 投机 | `--spec mtp --draft-tokens 4` | `MTP K=3` | — |
| 冷启动 | ≈4.3 s | ≈8.5 s | 1–2 min |
| 引擎版本 | `a6dffc2d`（kvmem 产品线 20 补丁，树 `d976d3f8`） | `e630612d`（源码 `74a2879b`） | Strata `v0.2.7.1` / engine `0.1.53`（`68dfccc3`） |
| 源码仓 | `ninfer-line-8090-single-card` | `ninfer-line-8091-dual-card-tp2` | `strata-line-8080-125b-moe` |

**模型工件不进任何仓**（15–21 GB 的引擎工件与 134 GB 的 Strata 数据都在仓外）。

## 这个仓里有什么

- `bin/ninfer-router` —— 编排路由器（**唯一事实源**：每个 profile 的启动 argv 都写在脚本的 `ROUTES` 表里）。三引擎互斥：**拉起新人前先停旧的并等其真正 inactive**；Strata 卸载需释放 ~48 GB。
- `units/*.service` —— systemd **user** 单元（`local-router` @8097 常驻不占 GPU；`ninfer-router` @8099、`strata-router` @8098 为应急直连/回滚口；`strata-swift-iq3s` 是 8080 引擎本体）。
- `scripts/start-prod-8090.sh` —— 单卡线的生产启动脚本（KVMem 预算 / host KV / 投机参数都在里面，**改参数只改这一个文件**）。
- `docs/` —— 三线总表与各线手册（引擎架构、模型工件、验证记录）。
- `docs/CURRENT-STATE.md` —— 本机三线**现役状态快照**（版本、参数、实测基线）。

## 启动

```bash
systemctl --user enable --now local-router     # 常驻路由器（不占 GPU）
curl -s localhost:8097/v1/models               # 看三个 model id
# 之后按 model id 发起请求即可，引擎按需自动拉起（拉起前会停掉另一条线）
```

**手工直起某个引擎会绕过互斥** —— 要么走路由器，要么先确认另一条线已停。

## 注意

- 本仓是我们的**编排与文档**，不含任何上游引擎源码（三条线的引擎源码在各自的仓）。
- 脚本/单元里的路径是本机布局（`/home/mmknet/...`），换机需要改路径与卡号。
- 单卡 8090 只跟 `kvmem/kvmem` 的 `backends/versions.json` pin 升级，**不自行前滚 `iamwavecut/ninfer-all` master**（KVMem 与 TP 源码层互斥）。升级入口 `kvmem-8090-upgrade --check`。
