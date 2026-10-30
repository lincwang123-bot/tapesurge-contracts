#!/usr/bin/env bash
# TapeSurge 测试网分阶段执行脚本（快速参数：默认 1 天 = 2 分钟，TIME_DIVISOR 可改；随机数用 MockRandomSource）
#
# 用法：bash script/testnet.sh <阶段>
#   prep：只做准备——deploy → fund → mint → genesis（部署、给 PLAYERS 个玩家打 tBNB、铸通行证、开局），之后的开奖、
#         发放交给运营机器人（bot/）。MockPoD 按时间自动产出（不需要定期调用；主板开奖时自己领取产出）。
#   按顺序执行（all = 全部按顺序跑完，中间自动等待链上时间）：
#     deploy          先按主网规则检查合约大小，再部署 mock 环境和 TapeSurge（TESTNET_FAST=1，mock 费用为主网的 1/100），
#                     地址写到 deployments/<链 ID>.json
#     fund            部署者给 50 个玩家各转一笔 tBNB
#     mint            玩家各铸 5 颗创世 NAND、流片通行证，领 100 MockBEM
#     genesis         等到部署后 14 分钟，开局（同时开出标准局 #1 和月局 #1）
#     join-month      玩家 25–49 加入月局 #1（招满即开局，进入 6 分钟的准备期）
#     machines-month  部署者卖 4 台矿机给月局 #1（必须在准备期内）
#     join-std        玩家 0–24 加入标准局 #1
#     machines-std    部署者卖 6 台矿机给标准局 #1
#     reward          领取首批回馈第 1、2 名（两种局合计的开局顺序）
#     month-yield     等月局 #1 准备期结束，进入挖矿，注入 10 BEM 产出
#     pulse-half      运营地址推进标准局开奖 12 次（每次补产出、请求并交付随机数）
#     fallback-std    等运营宽限期（6 分钟）过去，由一位参与者代替运营地址推进一次开奖
#     pulse-rest      运营地址继续开奖，直到选出硅王、进入终局拍卖
#     settle-std      部署者买走标准局终局拍卖中的全部矿机
#     distribute-std  运营地址分批打款、退还通行证
#     join-month2     等到月局 #1 挖矿结束前 2 分钟，关掉过期的招募，玩家 0–24（标准局退回的通行证）开出月局 #2
#     draw-m1         月局 #1 开奖（drawPrizes → 交付随机数 → finalizePrizes）
#     settle-m1       月局 #1 第 0 台交接给月局 #2，第 1 台挂成本价 120% 并成交
#     settle-m1-auto  等 autoListDelay（2 分钟），其余矿机自动按成本价挂单并成交
#     fallback-month  等运营宽限期过去，由一位参与者代替运营地址给月局 #1 打款
#     join-month3     玩家 25–49 开出下一块月局，确认月局 #1 的回馈资本滚了过去
#     sweep           玩家把剩下的 tBNB 退回部署者
#     report          打印部署者花费和各主板状态
#   status：随时查看各主板状态
#   markets：模拟 tapeout.market 的两个来源（不在 all 的顺序里，firsto 之后单独跑一次）：玩家 MARKET_FROM 起的 MARKET_PLAYERS 个人
#           （默认 4 起 4 人）各持两台模拟矿机（官方合集 / 模拟 Behemoth 交替），一台挂 MockOfficialMarket、一台在 MockSeaport 链上挂单，
#           另挂一台不合格的（算力 5）；部署者用 MockWBNB 建两张合集出价。输出（格式同 tapeout.market）：
#           deployments/<名字>-tape-feed.json（GET /api/v1/circuit-market/feed）、<名字>-tape-listings.json（GET /api/v1/listings/<orderHash>，
#           以 orderHash 为键）、<名字>-seaport-offers.json（WBNB 出价）
#   firsto：模拟 Firsto 市场（不在 all 的顺序里，prep 之后单独跑一次）：玩家 FIRSTO_FROM 起的 FIRSTO_PLAYERS 个人（默认 0 起 4 人）
#           各持 2–3 台模拟矿机并对 MockFirstoAskExchange 授权，卖单按主网 API 格式写到 deployments/<名字>-firsto-asks.json；
#           部署者在 MockFirstoBidExchange 建 3 张统一买单（列表写到 deployments/<名字>-firsto-bids.json），
#           MockFirstoSwapper 的 tBNB 补到 FIRSTO_SWAPPER_TARGET（默认 0.015）。报价无效时部署者先按标准局 #1 收购价上限报一次价
#
# 环境变量：
#   KEY_SOURCE=env-file（默认）：读取 .env.testnet（TESTNET_DEPLOYER_ADDRESS / TESTNET_DEPLOYER_PK / TESTNET_PLAYER_SEED /
#                               BSC_TESTNET_RPC_URL），链 ID 必须是 97
#   KEY_SOURCE=anvil：本地 anvil 演练。部署者是 anvil 默认的 0 号账户（由 anvil 公开的开发助记词在本地派生），RPC 默认
#                    http://127.0.0.1:8545，链 ID 必须是 31337；等待时直接推进链上时间，不真的等
#   RPC_URL / EXPECT_CHAIN_ID / PLAYER_SEED：覆盖上面的默认值；GAS_PRICE_WEI：默认 100000000（0.1 gwei）
#   TIME_DIVISOR：时间缩短比例（默认 720；48 = 1 天 → 30 分钟），写进 deployments/<链 ID>.json 的 timeDivisor
#   GENESIS_DELAY：开局等待秒数（默认 7 天 ÷ 比例）；PLAYERS：fund / mint 的玩家人数（默认 50）
#   DEPLOY_NAME：部署记录名（默认链 ID）：deployments/<名字>.json、<名字>-run.log、<名字>-start-balance
#   FOUNDATION：默认是玩家助记词派生的第 99 个地址（不能等于 FEE_SAFE）；FEE_SAFE：默认部署者
#
# 安全：只接受链 ID 97（测试网）或 31337（本地）。私钥和种子只放在本进程的环境变量里，不打印；
#      forge 的输出会把私钥、种子和 RPC 地址遮掉。
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"

KEY_SOURCE="${KEY_SOURCE:-env-file}"
if [ "$KEY_SOURCE" = "anvil" ]; then
  RPC="${RPC_URL:-http://127.0.0.1:8545}"
  CHAIN="${EXPECT_CHAIN_ID:-31337}"
  DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # anvil 默认 0 号账户（公开的开发账户）
  ANVIL_MNEMONIC="test test test test test test test test test test test junk" # anvil / Foundry 公开的开发助记词
  # 玩家用 BIP-39 公开测试向量派生，和 anvil 预充值的账户不重叠，花费从 0 开始算
  export TEST_MNEMONIC="${PLAYER_SEED:-abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about}"
  WALLET=(--mnemonics "$ANVIL_MNEMONIC" --mnemonic-indexes 0)
elif [ "$KEY_SOURCE" = "env-file" ]; then
  set -a
  . ./.env.testnet
  set +a
  RPC="${RPC_URL:-$BSC_TESTNET_RPC_URL}"
  CHAIN="${EXPECT_CHAIN_ID:-97}"
  DEPLOYER="$TESTNET_DEPLOYER_ADDRESS"
  export TEST_MNEMONIC="${PLAYER_SEED:-$TESTNET_PLAYER_SEED}"
  WALLET=(--private-key "$TESTNET_DEPLOYER_PK")
else
  echo "unknown KEY_SOURCE: $KEY_SOURCE" >&2
  exit 1
fi
case "$CHAIN" in 97 | 31337) ;; *)
  echo "refusing: only chain 97 (BSC testnet) or 31337 (local) is allowed" >&2
  exit 1
  ;;
esac
export RPC
export GAS_PRICE_WEI="${GAS_PRICE_WEI:-100000000}"
# forge 按模拟结果估 gas 再乘这个百分比（forge 默认 130）。MockPoD 按时间产出，模拟和广播之间时间推进后，开奖时领取产出的
# 循环会比模拟时长，130 可能不够（anvil 上 pulse 阶段会 OutOfGas），所以默认 200
GAS_ESTIMATE_MULTIPLIER="${GAS_ESTIMATE_MULTIPLIER:-200}"
export TESTNET_FAST=1 STAKE_MODE="${STAKE_MODE:-max}"
# 基金会地址必须和手续费接收地址（FEE_SAFE，默认部署者）不同（主板构造函数检查 foundation != feeRecipient）。
# FOUNDATION 不设时，DeployTestnet 用玩家种子（TEST_MNEMONIC）派生第 99 个玩家地址（和 TestnetScenario 的玩家同一规则，
# 派生编号 100）：确定、和部署者不同，也不在 fund / mint 的玩家范围 [0, PLAYERS) 里。种子不经过 shell 命令行。
[ -n "${FOUNDATION:-}" ] && export FOUNDATION
export FEE_SAFE="${FEE_SAFE:-$DEPLOYER}"
PLAYERS="${PLAYERS:-50}"
STD_FROM=0
MONTH_FROM=25
HALF=25
# DEPLOY_NAME：部署记录的名字（默认链 ID）。v2 测试网部署用 DEPLOY_NAME=97-v2，记录写到 deployments/97-v2.json /
# 97-v2-run.log，不覆盖 v1.5 的 deployments/97.json（运营机器人在用）
DEPLOY_NAME="${DEPLOY_NAME:-$CHAIN}"
DEP="deployments/$DEPLOY_NAME.json"
LOG="deployments/$DEPLOY_NAME-run.log"
START_FILE="deployments/$DEPLOY_NAME-start-balance"
export DEPLOYMENT_FILE="$DEP"

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

# 遮掉私钥、种子和 RPC 地址；去掉 forge 的进度行（交易哈希由 print_txs 统一打印）
redact() {
  python3 -c '
import os, re, sys
keys = ("TESTNET_DEPLOYER_PK", "TESTNET_PLAYER_SEED", "TEST_MNEMONIC", "BSC_TESTNET_RPC_URL", "RPC")
secrets = [os.environ.get(k, "") for k in keys]
pk = os.environ.get("TESTNET_DEPLOYER_PK", "")
if pk:
    secrets.append(pk[2:] if pk.startswith("0x") else "0x" + pk)
secrets = sorted({s for s in secrets if len(s) > 8}, key=len, reverse=True)
skip = re.compile(r"^\s*$|^#+|^\s*\[\d|Waiting for receipts|Sensitive values|Transactions saved|ONCHAIN EXECUTION|Paid:|Hash:|Block:|Contract Address:|^\s*✅|Total Paid|Estimated|Setting up|SIMULATION COMPLETE|^=+$|Chain \d+|No files changed|Compiling|Compiler run|Solc ")
for line in sys.stdin:
    for s in secrets:
        line = line.replace(s, "<redacted>")
    if not skip.search(line):
        sys.stdout.write(line)
        sys.stdout.flush()
'
}

check_chain() {
  local id
  id="$(cast chain-id --rpc-url "$RPC")"
  if [ "$id" != "$CHAIN" ]; then
    echo "refusing: RPC chain id $id != expected $CHAIN" >&2
    exit 1
  fi
}

chain_now() { cast block latest -f timestamp --rpc-url "$RPC"; }
balance() { cast balance "$1" --rpc-url "$RPC"; }
addr() { python3 -c "import json,sys; print(json.load(open('$DEP'))[sys.argv[1]])" "$1"; }
num() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }
std_board() { num "$(addr factory)" "boardByNumber(uint256)(address)" 1; }
month_board() { num "$(addr monthFactory)" "boardByNumber(uint256)(address)" "$1"; }
recruiting_month() { num "$(addr monthFactory)" "recruitingBoard()(address)"; }

# 等到链上时间 ≥ $1。anvil 上直接推进时间；测试网上每 15 秒查一次
wait_until() {
  local target="$1" label="$2" now
  now="$(chain_now)"
  if [ "$now" -ge "$target" ]; then return 0; fi
  echo "-- waiting $((target - now))s for: $label"
  if [ "$KEY_SOURCE" = "anvil" ]; then
    cast rpc evm_setNextBlockTimestamp "$target" --rpc-url "$RPC" >/dev/null
    cast rpc evm_mine --rpc-url "$RPC" >/dev/null
  else
    while [ "$(chain_now)" -lt "$target" ]; do sleep 15; done
  fi
}

# 打印本阶段的全部交易哈希、gas 和手续费，并追加到 deployments/<链 ID>-run.log
print_txs() {
  local stage="$1" file="$2"
  if [ ! -f "$file" ]; then
    echo "   (no transactions)" | tee -a "$LOG"
    return 0
  fi
  python3 - "$stage" "$file" <<'PY' | tee -a "$LOG"
import json, sys
stage, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
rc = {r["transactionHash"]: r for r in d.get("receipts", [])}
gas = fee = 0
failed = 0
lines = []
for t in d["transactions"]:
    h = t.get("hash")
    r = rc.get(h, {})
    g = int(r.get("gasUsed", "0x0"), 16)
    p = int(r.get("effectiveGasPrice", "0x0"), 16)
    gas += g
    fee += g * p
    ok = r.get("status") == "0x1"
    failed += 0 if ok else 1
    what = t.get("function") or ("deploy " + (t.get("contractName") or "?"))
    target = t.get("contractAddress") or (t.get("transaction") or {}).get("to") or ""
    lines.append(f"   {h}  {'ok' if ok else 'FAILED'}  {what}  {target}")
print(f"== {stage}: {len(d['transactions'])} txs, gas {gas:,}, fee {fee / 1e18:.8f} tBNB" + (f", {failed} FAILED" if failed else ""))
print("\n".join(lines))
PY
}

# 执行一次 forge script（broadcast + --slow），然后打印交易
fs() {
  local stage="$1" script="$2"
  local latest="broadcast/$(basename "$script")/$CHAIN/run-latest.json"
  rm -f "$latest"
  check_chain
  echo "## stage $stage ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" >>"$LOG"
  forge script "$script" --rpc-url "$RPC" "${WALLET[@]}" --broadcast --slow --legacy \
    --with-gas-price "$GAS_PRICE_WEI" --gas-estimate-multiplier "$GAS_ESTIMATE_MULTIPLIER" 2>&1 | redact
  print_txs "$stage" "$latest"
}

scenario() { # scenario <阶段名> <STAGE> [VAR=值 ...]
  local stage="$1" st="$2"
  shift 2
  (
    export STAGE="$st"
    for kv in "$@"; do export "${kv?}"; done
    fs "$stage" script/TestnetScenario.s.sol
  )
}

# 月局 [当前招募中] 已过期就先关闭；离截止不到 330 秒就等它过期再关闭
fresh_month() {
  local m deadline now
  m="$(recruiting_month)"
  deadline="$(num "$m" "recruitDeadline()(uint256)")"
  now="$(chain_now)"
  if [ "$KEY_SOURCE" != "anvil" ] && [ "$now" -lt "$deadline" ] && [ $((now + 330)) -gt "$deadline" ]; then
    wait_until "$((deadline + 1))" "month board recruit deadline (too close to join safely)"
    now="$(chain_now)"
  fi
  if [ "$now" -ge "$deadline" ]; then scenario "$1-close" close; fi
}

# ---------------------------------------------------------------------------
# 各阶段
# ---------------------------------------------------------------------------

st_deploy() {
  check_chain
  # 先按主网规则（EIP-170 / EIP-3860）把全部合约在本地部署一遍，超限就不部署
  echo "-- size check: FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol"
  if ! FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol >/dev/null 2>&1; then
    echo "refusing to deploy: contract size check failed (run the command above with -vv for details)" >&2
    exit 1
  fi
  [ -f "$START_FILE" ] || balance "$DEPLOYER" >"$START_FILE"
  (
    export WRITE_DEPLOYMENT=1
    # 部署交易用 forge 默认的 130%：工厂部署约 860 万 gas，按 200% 估会超过单笔交易 16,777,216（2^24）的上限
    GAS_ESTIMATE_MULTIPLIER=130
    fs deploy script/DeployTestnet.s.sol
  )
  # 地址文件是在模拟阶段写出的：确认工厂确实已经上链
  if [ "$(cast code "$(addr factory)" --rpc-url "$RPC")" = "0x" ] || [ "$(cast code "$(addr monthFactory)" --rpc-url "$RPC")" = "0x" ]; then
    echo "deployment incomplete: factory contracts are not on chain; $DEP is not valid" >&2
    mv "$DEP" "$DEP.invalid"
    exit 1
  fi
  echo "== addresses ($DEP)"
  python3 -c "import json; [print(f'   {k:14} {v}') for k, v in json.load(open('$DEP')).items()]" | tee -a "$LOG"
}

st_fund() { scenario fund fund PLAYER_FROM=0 PLAYER_COUNT=$PLAYERS; }
st_mint() { scenario mint mint PLAYER_FROM=0 PLAYER_COUNT=$PLAYERS; }

st_genesis() {
  local at
  at=$(($(num "$(addr splitter)" "mintStart()(uint256)") + $(num "$(addr factory)" "genesisDelay()(uint256)") + 1))
  wait_until "$at" "genesis delay"
  scenario genesis genesis
  echo "   standard board #1 $(std_board)"
  echo "   month board #1    $(month_board 1)"
}

st_join_month() {
  fresh_month join-month
  scenario join-month join BOARD=month PLAYER_FROM=$MONTH_FROM PLAYER_COUNT=$HALF
}
st_machines_month() { scenario machines-month machines BOARD=month MONTH_NUMBER=1; }
st_join_std() { scenario join-std join BOARD=std PLAYER_FROM=$STD_FROM PLAYER_COUNT=$HALF; }
st_machines_std() { scenario machines-std machines BOARD=std; }

st_reward() {
  scenario reward-1 reward REWARD_RANK=1
  scenario reward-2 reward REWARD_RANK=2
}

st_month_yield() {
  wait_until "$(($(num "$(month_board 1)" "prepEnd()(uint256)") + 1))" "month board #1 preparation period"
  scenario month-yield yield BOARD=month MONTH_NUMBER=1 YIELD_BEM=10
}

st_pulse_half() { scenario pulse-half pulse REPEAT=$((HALF / 2)); }

st_fallback_std() {
  local last
  last="$(num "$(std_board)" "lastPulseAt()(uint256)")"
  wait_until "$((last + $(operator_grace) + 1))" "operator grace on the standard board"
  scenario fallback-std fallback BOARD=std PLAYER_FROM=$STD_FROM PLAYER_COUNT=$HALF
}

st_pulse_rest() { scenario pulse-rest pulse REPEAT=200; }
st_settle_std() { scenario settle-std settle BOARD=std; }
st_distribute_std() { scenario distribute-std distribute BOARD=std; }

st_join_month2() {
  local end
  end="$(num "$(month_board 1)" "miningEnd()(uint256)")"
  wait_until "$((end - 120))" "2 minutes before month board #1 mining ends"
  fresh_month join-month2
  scenario join-month2 join BOARD=month PLAYER_FROM=$STD_FROM PLAYER_COUNT=$HALF
  echo "   month board #2 $(month_board 2)"
}

st_draw_m1() {
  wait_until "$(($(num "$(month_board 1)" "miningEnd()(uint256)") + 1))" "month board #1 mining period"
  scenario draw-m1 draw MONTH_NUMBER=1
}

st_settle_m1() { scenario settle-m1 settle BOARD=month MONTH_NUMBER=1 RELAY_TO=2; }

st_settle_m1_auto() {
  local m
  m="$(month_board 1)"
  wait_until "$(($(num "$m" "settleStart()(uint256)") + $(auto_list_delay) + 1))" "auto listing at cost on month board #1"
  scenario settle-m1-auto settle BOARD=month MONTH_NUMBER=1
}

st_fallback_month() {
  local m
  m="$(month_board 1)"
  wait_until "$(($(num "$m" "settleStart()(uint256)") + $(operator_grace) + 1))" "operator grace on month board #1"
  scenario fallback-month fallback BOARD=month MONTH_NUMBER=1 PLAYER_FROM=$MONTH_FROM PLAYER_COUNT=$HALF
}

st_join_month3() {
  fresh_month join-month3
  scenario join-month3 join BOARD=month PLAYER_FROM=$MONTH_FROM PLAYER_COUNT=$HALF
  local n m
  n="$(num "$(addr monthFactory)" "currentNumber()(uint256)")"
  m="$(month_board $((n - 1)))"
  echo "   month board #$((n - 1)) $m  rollover received: $(num "$m" "subsidyCapital()(uint256)") (BEM, 8 decimals)" | tee -a "$LOG"
  echo "   month board #1 rolled over: $(num "$(month_board 1)" "rolledOver()(uint256)")" | tee -a "$LOG"
}

st_firsto() {
  scenario firsto firsto PLAYER_FROM="${FIRSTO_FROM:-0}" PLAYER_COUNT="${FIRSTO_PLAYERS:-4}" \
    FIRSTO_ASKS_FILE="deployments/$DEPLOY_NAME-firsto-asks.json" FIRSTO_BIDS_FILE="deployments/$DEPLOY_NAME-firsto-bids.json"
  python3 - "deployments/$DEPLOY_NAME-firsto-asks.json" "deployments/$DEPLOY_NAME-firsto-bids.json" <<'PY' | tee -a "$LOG"
import json, sys
for p in sys.argv[1:]:
    d = json.load(open(p))
    with open(p, "w") as fh:
        json.dump(d, fh, indent=1)
        fh.write("\n")
a = json.load(open(sys.argv[1]))
print(f"== mock Firsto asks: {len(a['rows'])} -> {sys.argv[1]}")
for r in a["rows"]:
    w = r["mining"]["weight"]
    c = int(r["bestAsk"]["buyerCostWei"]) / 1e18
    print(f"   token {r['tokenId']:>4}  weight {w:>3}  buyerCost {c:.6f} tBNB  maker {r['owner']}")
b = json.load(open(sys.argv[2]))
print(f"== mock Firsto bids -> {sys.argv[2]}")
for x in b["bids"]:
    d, g = int(x["dailyCapacityPriceWei"]) / 1e18, int(x["remainingBudgetWei"]) / 1e18
    print(f"   order {x['orderId']}  dcp {d:.6f}  budget {g:.4f} tBNB  size {x['minCircuitH']}-{x['maxCircuitH']}")
PY
}

st_markets() {
  scenario markets markets PLAYER_FROM="${MARKET_FROM:-4}" PLAYER_COUNT="${MARKET_PLAYERS:-4}" \
    MARKET_FEED_FILE="deployments/$DEPLOY_NAME-tape-feed.json" TAPE_LISTINGS_FILE="deployments/$DEPLOY_NAME-tape-listings.json" \
    SEAPORT_OFFERS_FILE="deployments/$DEPLOY_NAME-seaport-offers.json"
  python3 - "deployments/$DEPLOY_NAME-tape-feed.json" "deployments/$DEPLOY_NAME-tape-listings.json" \
    "deployments/$DEPLOY_NAME-seaport-offers.json" <<'PY' | tee -a "$LOG"
import json, sys
for p in sys.argv[1:]:
    d = json.load(open(p))
    with open(p, "w") as fh:
        json.dump(d, fh, indent=1)
        fh.write("\n")
f = json.load(open(sys.argv[1]))
print(f"== mock tapeout.market feed: {len(f['items'])} items -> {sys.argv[1]}")
for it in f["items"]:
    l = it["listing"]
    ref = l["listingId"] or l["orderHash"][:18]
    pays = int(l["buyerPaysWei"]) / 1e18
    print(f"   {l['source']:<19} {it['processor']:<8} token {l['tokenId']:>4}  weight {it['hashrate']:>3}  buyer pays {pays:.6f} tBNB  {ref}")
o = json.load(open(sys.argv[2]))
w = json.load(open(sys.argv[3]))
print(f"== mock Seaport orders: {len(o)} -> {sys.argv[2]}; WBNB offers: {len(w['offers'])} -> {sys.argv[3]}")
PY
}

st_sweep() { scenario sweep sweep PLAYER_FROM=0 PLAYER_COUNT=$PLAYERS; }

st_report() {
  check_chain
  local start now
  start="$(cat "$START_FILE")"
  now="$(balance "$DEPLOYER")"
  python3 - "$start" "$now" <<'PY' | tee -a "$LOG"
import sys
s, n = int(sys.argv[1]), int(sys.argv[2])
print(f"== deployer balance: start {s / 1e18:.8f}, now {n / 1e18:.8f}, spent {(s - n) / 1e18:.8f} tBNB")
PY
  st_status
}

st_status() {
  check_chain
  (
    export STAGE=status
    forge script script/TestnetScenario.s.sol --rpc-url "$RPC" "${WALLET[@]}" 2>&1 | redact
  )
}

# 参数读取：operatorGrace（3 天）/ autoListDelay（1 天）按部署时的时间比例缩短（deployments/<链 ID>.json 的 timeDivisor）
time_divisor() { python3 -c "import json; print(json.load(open('$DEP')).get('timeDivisor', 720))"; }
operator_grace() { echo $((3 * 86400 / $(time_divisor))); }
auto_list_delay() { echo $((86400 / $(time_divisor))); }

st_prep_summary() {
  echo "== prep done (timeDivisor $(time_divisor)); the operator bot takes over from here" | tee -a "$LOG"
  echo "   standard board #1 $(std_board)   month board #1 $(month_board 1)" | tee -a "$LOG"
  echo "   players [0, $PLAYERS) hold a pass and 100 MockBEM each; boards start when filled (join-std / join-month" | tee -a "$LOG"
  echo "   stages or real users), machines are sold with machines-std / machines-month (MockPoD then mines on its own)" | tee -a "$LOG"
}

STAGES=(deploy fund mint genesis join-month machines-month join-std machines-std reward month-yield pulse-half
  fallback-std pulse-rest settle-std distribute-std join-month2 draw-m1 settle-m1 settle-m1-auto fallback-month
  join-month3 sweep report)

run_stage() {
  local s="$1"
  case "$s" in
  status) st_status ;;
  prep)
    for x in deploy fund mint genesis; do run_stage "$x"; done
    st_prep_summary
    ;;
  all) for x in "${STAGES[@]}"; do run_stage "$x"; done ;;
  *)
    local fn="st_${s//-/_}"
    if ! declare -F "$fn" >/dev/null; then
      echo "unknown stage: $s" >&2
      echo "stages: ${STAGES[*]} status all prep" >&2
      exit 1
    fi
    echo ">>> $s"
    "$fn"
    ;;
  esac
}

[ $# -ge 1 ] || {
  echo "usage: bash script/testnet.sh <stage> [<stage> ...] | from <stage> | prep   (stages: ${STAGES[*]} status all)" >&2
  exit 1
}
# from <阶段>：从这个阶段开始按顺序跑完剩下的（中断后接着跑）
if [ "$1" = "from" ]; then
  first="${2:?usage: bash script/testnet.sh from <stage>}"
  started=0
  set --
  for x in "${STAGES[@]}"; do
    if [ "$x" = "$first" ]; then started=1; fi
    if [ "$started" = 1 ]; then set -- "$@" "$x"; fi
  done
  if [ $# -eq 0 ]; then
    echo "unknown stage: $first" >&2
    exit 1
  fi
fi
mkdir -p deployments
for s in "$@"; do run_stage "$s"; done
