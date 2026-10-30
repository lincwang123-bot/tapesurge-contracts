#!/usr/bin/env bash
# TapeSurge BSC 主网部署。只有在你自己提供钱包、并手动输入 DEPLOY 之后才会广播。
#
# 用法：
#   bash script/mainnet.sh [simulate]          只模拟（默认）：部署前自检 + 打印部署计划，不发送交易
#   bash script/mainnet.sh deploy --account <keystore 名>    或    deploy --ledger
#                                              广播部署（先确认链 ID 56、跑 forge test 和大小检查、模拟、等你输入 DEPLOY）
#   bash script/mainnet.sh check               部署后的只读核对（不一致的项标红，退出码非 0）
#   bash script/mainnet.sh verify              可选：源码验证。BscScan 需要 ETHERSCAN_API_KEY（你提供）；
#                                              VERIFIER=sourcify 不需要 key
#
# 环境变量：
#   BSC_RPC_URL（必填）     BSC 主网 RPC。本地主网分叉演练用 http://127.0.0.1:8545（anvil --fork-url ...）
#   SENDER（simulate / deploy 必填）  部署者地址（和 --account / --ledger 对应的地址一致）
#   OPERATOR、VRF_SUBSCRIPTION_ID（必填）；VRF_KEY_HASH、VRF_NATIVE_PAYMENT、VRF_CONFIRMATIONS、MAX_GAS_PRICE_WEI（可选）
#   EXPECT_OPERATOR（check 可选）：核对运营地址
#
# 安全：不读取任何 .env 文件，不接受 --private-key；钱包只能是 --account（加密 keystore）或 --ledger。
#      只有 BSC_RPC_URL 指向本机（anvil 分叉）时，deploy 才接受 --unlocked（分叉上模拟你的地址）。
#      输出里的 RPC 地址会被遮掉（可能带 API key）。
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"

CMD="${1:-simulate}"
[ $# -gt 0 ] && shift
RPC="${BSC_RPC_URL:?set BSC_RPC_URL (BSC mainnet RPC; local fork: http://127.0.0.1:8545)}"
export RPC
SCRIPT=script/DeployMainnet.s.sol
BROADCAST_FILE="broadcast/DeployMainnet.s.sol/56/run-latest.json"
FINAL=deployments/56.json
PENDING=deployments/56.pending.json

is_local() { [[ "$RPC" =~ ^https?://(127\.0\.0\.1|localhost)(:[0-9]+)?/?$ ]]; }

redact() {
  python3 -c '
import os, sys
rpc = os.environ.get("RPC", "")
for line in sys.stdin:
    if len(rpc) > 8:
        line = line.replace(rpc, "<rpc>")
    sys.stdout.write(line)
    sys.stdout.flush()
'
}

check_chain() {
  local id
  id="$(cast chain-id --rpc-url "$RPC")"
  if [ "$id" != "56" ]; then
    echo "refusing: RPC chain id is $id, expected 56 (BSC mainnet)" >&2
    exit 1
  fi
}

need_env() {
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      echo "set $v" >&2
      exit 1
    fi
  done
}

# 打印广播的每笔交易：gas、按实际 gas 价格折算的 BNB、附带的 value（createCPU 部署费）
print_txs() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rc = {r["transactionHash"]: r for r in d.get("receipts", [])}
tot_gas = tot_fee = tot_value = 0
for t in d["transactions"]:
    r = rc.get(t.get("hash"), {})
    g = int(r.get("gasUsed", "0x0"), 16)
    p = int(r.get("effectiveGasPrice", "0x0"), 16)
    v = int((t.get("transaction") or {}).get("value", "0x0") or "0x0", 16)
    tot_gas += g; tot_fee += g * p; tot_value += v
    ok = "ok" if r.get("status") == "0x1" else "FAILED"
    name = t.get("contractName") or t.get("function") or "?"
    print(f"   {t.get('hash')}  {ok}  {name:22} gas {g:>11,}  fee {g * p / 1e18:.8f} BNB" + (f"  value {v / 1e18:.6f} BNB" if v else ""))
print(f"== total: {len(d['transactions'])} txs, gas {tot_gas:,}, fee {tot_fee / 1e18:.8f} BNB, value {tot_value / 1e18:.6f} BNB, all-in {(tot_fee + tot_value) / 1e18:.8f} BNB")
PY
}

case "$CMD" in
simulate)
  check_chain
  need_env SENDER OPERATOR VRF_SUBSCRIPTION_ID
  PENDING_FILE=deployments/56.simulated.json forge script "$SCRIPT" --rpc-url "$RPC" --sender "$SENDER" "$@" 2>&1 | redact
  rm -f deployments/56.simulated.json
  echo "(simulation only: nothing was broadcast)"
  ;;

deploy)
  need_env SENDER OPERATOR VRF_SUBSCRIPTION_ID
  WALLET=("$@")
  has() { for a in "${WALLET[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
  if has --private-key || has --mnemonics || has --mnemonic; then
    echo "refusing: use --account (encrypted keystore) or --ledger, not a raw key" >&2
    exit 1
  fi
  if has --unlocked; then
    is_local || { echo "refusing: --unlocked is only allowed against a local anvil fork" >&2; exit 1; }
  elif ! has --account && ! has --ledger; then
    echo "usage: bash script/mainnet.sh deploy --account <keystore name> | --ledger" >&2
    exit 1
  fi
  if [ -f "$FINAL" ] && ! is_local; then
    echo "refusing: $FINAL already exists (protocol already deployed?)" >&2
    exit 1
  fi
  check_chain
  echo "-- forge test"
  # 主网分叉测试（E2E 等）不在这里跑（约 5 分钟）；上线前请单独跑一次 BSC_RPC_URL=... forge test --match-contract ForkBSC
  BSC_RPC_URL= forge test >/dev/null 2>&1 || { echo "forge test failed; run it to see why" >&2; exit 1; }
  echo "-- size check (EIP-170 / EIP-3860)"
  FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol >/dev/null 2>&1 \
    || { echo "size check failed: FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol -vv" >&2; exit 1; }
  echo "-- deployment plan (simulation)"
  PENDING_FILE=deployments/56.simulated.json forge script "$SCRIPT" --rpc-url "$RPC" --sender "$SENDER" 2>&1 | redact
  rm -f deployments/56.simulated.json
  echo
  echo "This will broadcast 15 contract deployments (5 + 10 singletons) to BSC MAINNET from $SENDER,"
  echo "then mint ${RESERVE_TRANSISTORS:-330} NAND transistors at the public price for the community airdrop (rule 6.32)."
  echo "The genesis countdown starts as soon as GenesisSplitter is deployed."
  read -r -p "Type DEPLOY to broadcast: " answer
  [ "$answer" = "DEPLOY" ] || { echo "aborted, nothing was broadcast"; exit 1; }
  rm -f "$PENDING" "$BROADCAST_FILE"
  PENDING_FILE="$PENDING" forge script "$SCRIPT" --rpc-url "$RPC" --sender "$SENDER" "${WALLET[@]}" \
    --broadcast --slow 2>&1 | redact
  [ -f "$BROADCAST_FILE" ] || { echo "no broadcast record found" >&2; exit 1; }
  echo "-- transactions"
  print_txs "$BROADCAST_FILE"
  # 地址文件是在模拟阶段写出的：确认每个合约都已上链，并把 fromBlock 改成第一笔部署交易实际所在的区块
  for key in oracle vrfAdapter splitter factory monthFactory monthPositions monthSales monthGovernor positionExchange priceFeed stdSales firstoSwapper marketTrader machineRules machineLister; do
    a="$(python3 -c "import json,sys; print(json.load(open('$PENDING'))[sys.argv[1]])" "$key")"
    if [ "$(cast code "$a" --rpc-url "$RPC")" = "0x" ]; then
      echo "deployment incomplete: $key ($a) has no code; $PENDING is NOT valid" >&2
      exit 1
    fi
  done
  python3 - "$PENDING" "$BROADCAST_FILE" "$FINAL" <<'PY'
import json, sys
pending, bc, final = sys.argv[1:]
d = json.load(open(pending))
r = json.load(open(bc))["receipts"]
d["fromBlock"] = min(int(x["blockNumber"], 16) for x in r)
json.dump(d, open(final, "w"), indent=2)
print(f"== {final} written (fromBlock {d['fromBlock']})")
PY
  rm -f "$PENDING"
  echo "NEXT: bash 上线/部署后收尾.sh (the VRF adapter was already checked as a subscription consumer in preflight)"
  ;;

check)
  check_chain
  out="$(forge script script/CheckMainnet.s.sol --rpc-url "$RPC" 2>&1 | redact)"
  # forge 打印日志时会去掉颜色转义，这里给不一致的项标红
  echo "$out" | sed -e $'s/.*MISMATCH.*/\033[31m&\033[0m/' -e $'s/.*ALL CHECKS PASSED.*/\033[32m&\033[0m/'
  if echo "$out" | grep -q "MISMATCH"; then exit 2; fi
  ;;

verify)
  check_chain
  need_env SENDER OPERATOR VRF_SUBSCRIPTION_ID
  if [ "${VERIFIER:-etherscan}" = "sourcify" ]; then
    forge script "$SCRIPT" --rpc-url "$RPC" --sender "$SENDER" --resume --verify --verifier sourcify 2>&1 | redact
  else
    need_env ETHERSCAN_API_KEY
    forge script "$SCRIPT" --rpc-url "$RPC" --sender "$SENDER" --resume --verify \
      --etherscan-api-key "$ETHERSCAN_API_KEY" 2>&1 | redact
  fi
  echo "TapeBoard / MonthBoard implementations are created inside the factory constructors;"
  echo "if BscScan does not match them automatically, verify them with forge verify-contract (constructor args = boardConfig())."
  ;;

*)
  echo "usage: bash script/mainnet.sh [simulate|deploy|check|verify]" >&2
  exit 1
  ;;
esac
