# TapeSurge 晶涌协议 · 合约

运行在 BNB Smart Chain 上的 TapeSurge 协议合约（Solidity 0.8.28，Foundry）。参与者用创世通行证加入主板，汇集 BEM 收购 TapeOut PoD 矿机挖矿，产出按链上规则分配（标准局 / 月局两种）。

- **版本**：`v2.0-audit.6`（本仓库是主网部署的完整源码；持仓盘口 2026-10-30 升级到新地址）。
- **审阅**：`v2.0-audit.5` 经过 **5 轮第三方独立审阅**（2026-10-24 首次审阅，2026-10-25 两次复核和一次全局审阅），报告见 [`audits/`](audits/) 01–04；发现的问题全部已修复并经复核，回归测试在 `test/Audit*.t.sol`。上线版 `v2.0-audit.6` 在它之上做了一次规则调整（规则决定 6.37：收购从最便宜的挂单往上扫、保底结局收 2%、月局买满就开挖），**这次调整由项目方内部审阅（[`audits/`](audits/) 05），没有经过第三方**。审阅范围是 `src/` 下 35 个合约文件（不含 `src/mocks/`），不包括 TapeOut、PoD、Firsto、TapeOut 官方矿机市场等外部合约。这些都不是审计公司出具的正式审计报告；审阅能降低风险，但不能保证没有漏洞。
- **应用**：https://app.tapesurge.com （默认 BNB Chain 主网）。
- **X Layer 版**：在单独的仓库 [tapesurge-xlayer](https://github.com/lincwang123-bot/tapesurge-xlayer)：月局、自带的 RIG 矿机市场、drand 链上验签开奖，目前在 X Layer 测试网运行，参加 OKX Xccelerate（X Layer TapeOut 开发者加速计划）。规则和本仓库的 `v2.0-audit.6` 相同，链相关的部分不同（RIG 凭证代替 PoD 矿机、drand 代替 Chainlink VRF、行情由运营地址从 BSC 转报）。
- **规则**：以 [`docs/v2月局规则决定-2026-10-22.md`](docs/v2月局规则决定-2026-10-22.md) 为准；白皮书见 [`docs/TapeSurge白皮书-V5.md`](docs/TapeSurge白皮书-V5.md)。
- **主网合约地址（BSC，链 ID 56）**，完整记录见 [`deployments/56.json`](deployments/56.json)：

| 合约 | 地址 |
|---|---|
| GenesisSplitter（分账合约，创世处理器的 creator） | [`0x69781Ed90a24Ee1fbA7Da94357890007A11E3128`](https://bscscan.com/address/0x69781Ed90a24Ee1fbA7Da94357890007A11E3128) |
| BoardFactory（标准局工厂） | [`0xa45315fE9CD1425d030d90c7e41f23280AdE98Ca`](https://bscscan.com/address/0xa45315fE9CD1425d030d90c7e41f23280AdE98Ca) |
| MonthFactory（月局工厂） | [`0x7076FF61580C4C442f7Ca7CC92e271F0DBB7B575`](https://bscscan.com/address/0x7076FF61580C4C442f7Ca7CC92e271F0DBB7B575) |
| 持仓凭证 TSP | [`0xBe28468A51416c266B22fEA851c2276ec8375782`](https://bscscan.com/address/0xBe28468A51416c266B22fEA851c2276ec8375782) |
| 持仓盘口 | [`0xb912402ad99dC779d7625d2E57f0400192b34585`](https://bscscan.com/address/0xb912402ad99dC779d7625d2E57f0400192b34585) |
| 月局卖矿 | [`0x31d9Dfb5190E6346011040688647A04D8247E9aD`](https://bscscan.com/address/0x31d9Dfb5190E6346011040688647A04D8247E9aD) |
| 月局集体清算 | [`0x952973fB9A234ffa9adf104b10434E3271B6fcCD`](https://bscscan.com/address/0x952973fB9A234ffa9adf104b10434E3271B6fcCD) |
| 标准局卖矿 | [`0x050Adee3782108bA4C48F6D35934C311A036626c`](https://bscscan.com/address/0x050Adee3782108bA4C48F6D35934C311A036626c) |
| MarketPriceFeed（报价） | [`0x5479E1ca5EA5052d3EB699BF9C738Ac358FC3465`](https://bscscan.com/address/0x5479E1ca5EA5052d3EB699BF9C738Ac358FC3465) |
| MarketTrader（矿机买卖） | [`0x2bfaa9C9Df5e51778fADac2Ad326CAcbef515298`](https://bscscan.com/address/0x2bfaa9C9Df5e51778fADac2Ad326CAcbef515298) |
| MachineRules（矿机资格） | [`0x238c3BC0f3EFbcd1C9168a37BF8eeb6658b0003b`](https://bscscan.com/address/0x238c3BC0f3EFbcd1C9168a37BF8eeb6658b0003b) |
| MachineLister（挂单） | [`0xB4e2f765eB6781Afb724cE057282433FB619C82D`](https://bscscan.com/address/0xB4e2f765eB6781Afb724cE057282433FB619C82D) |
| 兑换适配器 | [`0x27f28eAE56159Daf368FC354678Ad5C3A4842076`](https://bscscan.com/address/0x27f28eAE56159Daf368FC354678Ad5C3A4842076) |
| PancakeV3TwapOracle | [`0x3A65298d4Bf1816ed9548bAe5d99C15369aAA44C`](https://bscscan.com/address/0x3A65298d4Bf1816ed9548bAe5d99C15369aAA44C) |
| ChainlinkVRFAdapter | [`0x3e7Cd11EBE0b1A13840d90C878814098Ab01a508`](https://bscscan.com/address/0x3e7Cd11EBE0b1A13840d90C878814098Ab01a508) |

- **不构成投资建议，不承诺保本。**

```bash
forge build
forge test        # 397 个通过；主网分叉测试需要设置 BSC_RPC_URL
FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol -vv
```

English: smart contracts of the TapeSurge protocol on BNB Smart Chain. Version `v2.0-audit.6`. `v2.0-audit.5` went through five rounds of independent third-party review (reports in `audits/` 01–04; all findings were fixed and re-checked, with regression tests in `test/Audit*.t.sol`); the final rule change in `v2.0-audit.6` was reviewed internally by the project (`audits/` 05), not by a third party. None of these is a formal audit-firm report. Not investment advice; no principal guarantee.

---

# TapeSurge 合约（BSC）

> 状态：**上线版 `v2.0-audit.6`（2026-10-25 晚，规则决定 6.37：收购改成由运营地址经 MarketTrader 在市场上从最便宜的挂单往上买、每单位算力不超过 min(卖一, 一年产出)，主板只认 MarketTrader，新增 Firsto 签名卖单 V2 买入入口；月局买满就开挖；标准局保底结局收 2% 手续费和 10% 溢价分成。这次改动由项目方内部审阅，没有经过第三方）；之前的送审版 `v2.0-audit.5`（2026-10-25；`v2.0-audit.5` 只比 `.4` 多全局审计的 G-1：报过价之后停运一律暂停收购、开局前必须报过价，部署检查改为硬性，规则决定 6.36；`.4` 是第二次复核的 N-2：停运按最后一次有效报价算，规则决定 6.35）= rc10 + 标准局市价期底价（规则决定 6.31）+ 第三方预审修复（规则决定 6.33）+ 复核后的追价模式（规则决定 6.34：市价离上次报价超过 5% 时用 `postCatchUp` 分步追，追价期间暂停按报价买卖）。第三方预审修复（报价任何时候单次 ≤ 5%、月局清算价不低于买一 × 95%、提前退出只在升级冷静期内、标准局买单只收未出局持仓、重发的随机数请求都有效、运营地址为 0 只暂停）。**
>
> 历史：**v2 已实现（`v2.0-rc9`；rc8 起矿机可在 Firsto / TapeOut 官方矿机市场 / Seaport 多来源买卖并收所有工厂处理器的矿机，rc9 起卖矿时在各平台保持排序第一、不低于成本，rc10 起主板矿机也挂到 Firsto 签名卖单 V2）：两种局的持仓都可以在同一个链上挂单簿转让（标准局自 rc6 起，开奖等待随机数期间锁定）；两种局卖矿溢价（超过成本的部分）的 10% 给手续费地址（标准局只在正常终局收，rc7）；两种局的矿机买卖都按 Firsto 买一 / 卖一由合约公式定价，并且可以经 `FirstoTrader` 直接在 Firsto 吃单买入 / 卖给统一买单；月局只收入场费；过期未领的 BEM 销毁；新局模板可经 7 天时间锁更换；标准局主板 `TapeBoard` 在 rc6 改成按持仓（插槽）记账；BoardFactory 加了模板时间锁。主网部署脚本已备好，未部署主网。** 本目录不包含任何私钥。ABI 变化见 [`V2-ABI.md`](V2-ABI.md)。
> 规格依据：白皮书 [`docs/TapeSurge白皮书-V5.md`](docs/TapeSurge白皮书-V5.md) 和 [`docs/v2月局规则决定-2026-10-22.md`](docs/v2月局规则决定-2026-10-22.md)。

**已开局的主板永远不能升级**：每块主板是一个 EIP-1167 最小代理，固定指向开局时的实现合约（模板），参数全是构造参数，没有任何升级、暂停、改参数的入口。**之后新开的局可以换模板**（项目方 2026-10-22 决定，规则决定 6.11）：手续费 Safe 在两个工厂上 `proposeImplementation` 提议新模板，链上公示 7 天（期间可以撤销），之后 7 天内任何人可以让它生效；生效时正在招募的那块仍用旧模板。工厂、分账合约、持仓凭证不可替换。

**权限**：手续费 Safe 只能 ① 更换运营地址（`BoardFactory.setOperator`）② 经 7 天时间锁提议新局模板；不能动任何已开局主板的资金、持仓、参数和开奖。**运营地址**只能开奖、自动发放、月局交接 / 挂单（经 `MonthMachineSales`）、每小时报 Firsto 买一 / 卖一（`MarketPriceFeed`，每次 ±5% 以内、间隔 ≥ 50 分钟；两种局的买卖价都由合约按公式算），3 天不执行由本局参与者（月局：持仓的持有人）兜底；运营地址可以设成 0，这时报价暂停（两种局暂停按报价买卖矿机），其余操作由参与者执行；最后一次有效报价满 7 天后停运，月局矿机任何人可以按成本价买，收购一直暂停（全局审计 G-1）。此外，`noteSentinel()` / `reopen()` / `closeRecruitment()` / `harvest()` / `buyback()` / `claimReward()` 等推进函数任何人都可以调用，它们不能改变结果。详见第 3 节"运营地址与参与者兜底"。

---

## 1. 怎么运行

```bash
# 1. 安装 Foundry（本机已用 foundryup 装好 1.8.5，位于 ~/.foundry/bin）
export PATH="$PATH:$HOME/.foundry/bin"

# 2. 编译（solc 0.8.28，EVM shanghai，优化器 200 runs）
forge build --sizes

# 3. 全部单元测试 + 统计测试（约 4 秒；没有 BSC_RPC_URL 时分叉测试自动跳过）
forge test

# 4. 只看统计测试的频率输出
forge test --match-contract StatisticsTest -vv

# 5. BSC 主网分叉的只读测试：在本地分叉的主网状态上运行，不发送任何交易
BSC_RPC_URL=https://bsc-dataseed.bnbchain.org forge test --match-contract ForkBSCTest -vv

# 6. 测试网部署脚本：只在本地内存里模拟，不连网、不广播、不需要私钥
forge script script/DeployTestnet.s.sol
VRF_SUBSCRIPTION_ID=<订阅号> forge script script/DeployTestnet.s.sol   # 改用 Chainlink VRF 适配器
```

当前结果：**190 个测试通过，0 个失败**；另有 5 个分叉测试（含端到端演练），设置 `BSC_RPC_URL` 后也全部通过（2026-10-19）。合约大小按主网规则检查：`FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol`。

真正部署时，由部署者自己提供签名账户（例如 `--account`）；本仓库和脚本不保存任何私钥。

### 主网分叉端到端演练

`test/E2EForkBSC.t.sol` 用真实的 TapeOut 工厂、PoD、BEM、官方矿机、PancakeSwap V3 路由和池子，以及 Chainlink VRF v2.5 协调器，把两种局从头到尾跑一遍。全程在本地分叉里运行，不发交易。

```bash
BSC_RPC_URL=https://bsc-mainnet.public.blastapi.io forge test --match-contract E2EForkBSCTest -vv
```

### 公开测试网演练（脚本已备好）

- `TESTNET_FAST=1`：部署脚本把所有以天计的时长按同一比例缩短，1 天 → 2 分钟（÷ 720）。例如招募 7 天 → 14 分钟，月局挖矿 30 天 → 60 分钟，领取期限 365 天 → 约 12 小时。同时把测试网 mock 的费用降到主网的 1/100：创世晶体管铸造价 0.001 → 0.00001，协议费 0.0001 → 0.000001，流片费 0.0002 → 0.000002，部署费 0.001 → 0.00001（`MOCK_FEE_DIVISOR` 可改比例）。主网参数（`TapeSurgeDefaults`）不受影响。
- `WRITE_DEPLOYMENT=1`：把地址写到 `deployments/<chainId>.json`。这个文件在模拟阶段就写出了，`script/testnet.sh deploy` 会在广播后确认工厂确实上链，否则把文件改名为 `.invalid`。
- `script/TestnetScenario.s.sol`：单个阶段的实现（fund、mint、genesis、close、join、reward、machines、yield、pulse、draw、finalize、settle、distribute、fallback、sweep、status），用法写在文件开头。部署者（同时是运营地址、矿机卖家和买家）用命令行签名；玩家的测试私钥在运行时由 `TEST_MNEMONIC` 派生，脚本里不写任何私钥。会 revert 的调用（卖矿机、交接、领回馈）先在本地试执行，能成才广播。两个脚本都只接受链 ID 97（BSC 测试网）或 31337（本地）。
- `script/testnet.sh`：按顺序执行完整流程，共 23 个阶段：deploy → fund → mint → genesis → join-month → machines-month → join-std → machines-std → reward → month-yield → pulse-half → fallback-std → pulse-rest → settle-std → distribute-std → join-month2 → draw-m1 → settle-m1 → settle-m1-auto → fallback-month → join-month3 → sweep → report。
  - 每个阶段先用 `cast chain-id` 确认链 ID，然后带 `--slow` 广播，最后打印本阶段全部交易哈希、gas 和手续费，并追加到 `deployments/<chainId>-run.log`。需要等链上时间的阶段会自己等待：在测试网上每 15 秒查一次，在 anvil 上直接推进时间。
  - `KEY_SOURCE=env-file`（默认）读取 `.env.testnet`；`KEY_SOURCE=anvil` 用 anvil 公开的开发账户在本地演练。输出里的私钥、种子和 RPC 地址会被遮掉。
  - 50 个玩家：标准局 25 人、月局 #1 25 人，每人投最大额。月局 #2 和 #3 复用标准局和月局 #1 退回的通行证。

```bash
# 本地内存链上一次跑完（不连网、不广播）
STAGE=all TESTNET_FAST=1 STAKE_MODE=max forge script script/TestnetScenario.s.sol
# 本地 anvil 演练（anvil 默认会按主网规则检查合约大小）
anvil --base-fee 0 --gas-price 100000000
KEY_SOURCE=anvil bash script/testnet.sh all
# BSC 测试网：按阶段执行，中断后用 from 接着跑
bash script/testnet.sh deploy
bash script/testnet.sh from fund
```

- 默认参数：`FEE_SAFE` = 部署者；`FOUNDATION` 不设时由 `DeployTestnet` 取玩家种子（`TEST_MNEMONIC`，测试网是 `.env.testnet` 的 `TESTNET_PLAYER_SEED`）派生的**第 99 个玩家地址**（和 `TestnetScenario` 的玩家同一规则：派生编号 100；十六进制种子时私钥 = keccak256(种子, 100) mod n，助记词时按 BIP-44 第 100 个），部署日志里打印 `Foundation` 地址。主板构造函数要求 `foundation != feeRecipient`，所以两者不能都默认成部署者；第 99 个玩家不在 fund / mint 的范围里。种子只在 forge 进程里使用，不经过 shell 命令行。两个变量都可以用环境变量覆盖。
- `DEPLOY_NAME`（默认链 ID）：部署记录名，地址写到 `deployments/<DEPLOY_NAME>.json`，交易记录追加到 `<DEPLOY_NAME>-run.log`（`DeployTestnet` / `TestnetScenario` 通过 `DEPLOYMENT_FILE` 读写同一个文件）。
- `GAS_ESTIMATE_MULTIPLIER`（默认 200）：forge 估 gas 的倍率。MockPoD 按时间产出，开奖时领取产出的循环在广播时可能比模拟时长，forge 默认的 130 在 anvil 上会让 pulse 阶段 OutOfGas。

> 2026-10-24 清理：v1.5 的两次测试网部署记录（`deployments/97.json`、`97-run.log`、`97-first-run.json`）已从工作目录删除，需要时用 `git show v2.0-audit.1:deployments/97.json` 查看。下面提到它们的段落是历史记录。

**v2 测试网部署（当前是 `v2.0-rc10`，2026-10-24，`TIME_DIVISOR=288`：1 天 = 5 分钟，起始区块 138,574,546；rc9 那次 138,503,856，rc5 那次 138,461,769，rc4 那次 138,386,959）**：rc10 多了 `firstoSignedAsk`（模拟 Firsto 签名卖单 V2）；rc9 多了 `marketTrader` / `machineRules` / `machineLister` / `officialMarket` / `seaport` / `wbnb` / `behemoth`，`bash script/testnet.sh markets` 生成的模拟 tapeout.market 文件在 `deployments/97-v2-tape-feed.json` / `97-v2-tape-listings.json` / `97-v2-seaport-offers.json`。rc5 记录：加了 `firstoTrader` / `firstoSwapper` / `firstoAskExchange` / `firstoBidExchange`（mock）和 `bemPerBnb`，`bash script/testnet.sh firsto` 生成的模拟 Firsto 订单在 `deployments/97-v2-firsto-asks.json` / `97-v2-firsto-bids.json`（rc6 还没部署到测试网）。`DEPLOY_NAME=97-v2 TIME_DIVISOR=288 GENESIS_DELAY=120`，记录在 `deployments/97-v2.json`（覆盖了之前 48 倍的几份；键 `priceFeed`（MarketPriceFeed）、`stdSales`；管理员 = 部署者，可以在测试网上演练模板升级；报价"停运"取下限 3 小时、标准局市价期 2.5 小时随倍率缩短，报价间隔 50 分钟、过期 3 小时、卖价降价周期 6 小时按真实时间）和 `deployments/97-v2-run.log`（两次都在里面）；比 v1.5 多 `monthPositions` / `monthSales` / `monthGovernor` / `positionExchange` 四个地址。`deployments/97.json`、`97-run.log` 仍是 v1.5 第二次部署（运营机器人在用），`97-first-run.json` 是第一次部署。注意 `deployments/97-v2-prep.console.log` / `97-v2-join.console.log`（未提交）是 v1.5 第二次部署的控制台输出，和 v2 无关。

```bash
DEPLOY_NAME=97-v2 TIME_DIVISOR=48 bash script/testnet.sh prep            # deploy → fund → mint → genesis
DEPLOY_NAME=97-v2 bash script/testnet.sh join-month machines-month join-std machines-std
```

**机器人值守演练（第二次测试网部署）**：`TIME_DIVISOR=48`（1 天 → 30 分钟：标准局招募约 3.5 小时，月局招募 / 准备各约 1.5 小时，挖矿约 15 小时），`bash script/testnet.sh prep` 只做部署 → 打 tBNB → 铸通行证 → 开局，之后的开奖、发放交给运营机器人。`deployments/97.json` 里的 `timeDivisor` 记录比例；MockPoD 按"主网单位产出 × 比例"自动产出，不需要定期调用（主板开奖时自己领取）。`GENESIS_DELAY` 可以缩短开局等待（默认 7 天 ÷ 比例 = 3.5 小时）。

在 anvil 上按主网大小规则跑完全部 23 个阶段：719 笔交易，部署者净花费 0.0139 tBNB（gas 价格 0.1 gwei）。

v2（第 5 阶段，2026-10-22）在 anvil 上用默认参数（`TIME_DIVISOR` 720、上面的 `FOUNDATION` 默认值）从头跑完全部 23 个阶段：部署 16 笔（多 4 个 v2 单例），月局 #1 第 0 台经 `MonthMachineSales.relay` 卖给月局 #2、第 1 台挂单成交、其余按成本价自动成交、参与者兜底推送都通过；部署者净花费 0.0157 tBNB（gas 价格 0.1 gwei）。

### BSC 主网部署（脚本已备好，未部署）

`script/mainnet.sh` 是唯一入口，只接受链 ID 56；钱包只能是你自己的 `--account`（加密 keystore）或 `--ledger`，不接受明文私钥，不读取任何 `.env` 文件。

```bash
export BSC_RPC_URL=<付费 BSC RPC>  SENDER=<部署者地址>  OPERATOR=<运营热钱包地址>  VRF_SUBSCRIPTION_ID=<订阅号>
bash script/mainnet.sh simulate                   # 部署前自检 + 部署计划，不发送交易
bash script/mainnet.sh deploy --account <名字>     # 跑测试和大小检查 → 模拟 → 输入 DEPLOY → 广播 13 笔 → 确认上链 → 写 deployments/56.json
bash script/mainnet.sh check                      # 只读核对全部参数（含 6 个单例和模板时间锁），不一致标红，不一致标红（EXPECT_OPERATOR 可选）
bash script/mainnet.sh verify                     # 可选：BscScan（ETHERSCAN_API_KEY）或 VERIFIER=sourcify
```

- 部署前自检：每个外部地址都有代码；读出 createCPU 部署费和电路信标当前的 implementation（哨兵基准）；两个池子的 30 分钟 TWAP 和 observation cardinality；两个 Safe 的 `getThreshold` / `getOwners`；VRF 订阅存在；部署者余额够用；运营地址非零（等于部署者时警告）。
- 部署后：在 vrf.chain.link 把 `vrfAdapter` 加为订阅的 consumer，再跑 `check`。分账合约一上链创世倒计时就开始（7 天或 10,000 颗）。
- 主网分叉演练（anvil，2026-10-21）：5 笔部署交易共 1,962 万 gas，按 0.05 gwei 约 0.00098 BNB，加 0.001 BNB 部署费，合计约 0.002 BNB；`check` 71 项全部通过。
- v2 主网分叉演练（anvil 分叉区块约 129,083,800，2026-10-22，部署者用 anvil 0 号账户、`--unlocked`，没有用任何主网钥匙）：9 笔部署交易（原 5 个 + `MonthPositions`、`MonthMachineSales`、`MonthExitGovernor`、`PositionExchange`）共 2,753 万 gas，按 0.05 gwei 约 0.00138 BNB，加 0.001 BNB 部署费，合计约 0.0024 BNB；`check` 94 项全部通过（新增 v2 单例的相互引用和不可变参数 23 项；第 6 阶段又加了交易所的 `MAX_VALIDITY` / `TRADE_HISTORY` / `MIN_BID_BUDGET` / `MAX_OPEN_BIDS` 4 项，共 98 项）。第 6 阶段（挂单簿）后重新演练：9 笔共 2,886 万 gas，按 0.05 gwei 约 0.00144 BNB，加 0.001 BNB 部署费，合计约 0.0024 BNB；`check` 98 项全部通过。第 7 阶段（`v2.0-rc2`：模板时间锁 + `MonthBuyPriceFeed`）后再演练：10 笔共 3,043 万 gas，按 0.05 gwei 约 0.00152 BNB，加 0.001 BNB 部署费，合计约 0.0025 BNB；`check` 111 项全部通过。第 8 阶段（`v2.0-rc3`：`MarketPriceFeed` 两种局共用 + `StdMachineSales`）后再演练：11 笔共 3,180 万 gas，按 0.05 gwei 约 0.00159 BNB，加 0.001 BNB 部署费，合计约 0.0026 BNB；`check` 119 项全部通过。`v2.0-rc4` 再演练：11 笔共 3,182 万 gas，合计约 0.0026 BNB；`check` 120 项全部通过（多了 `sellStepInterval`）。`v2.0-rc5`（加 `PancakeFirstoSwapper`、`FirstoTrader`）再演练：13 笔共 3,554 万 gas，按 0.05 gwei 约 0.00178 BNB，加 0.001 BNB 部署费，合计约 0.0028 BNB；`check` 140 项全部通过。`v2.0-rc6`（持仓合集和盘口认标准局、StdMachineSales 加宽限期参数、入场费 2%、溢价分成 10%）再演练（分叉区块约 129,328,400）：13 笔共 3,684 万 gas，按 0.05 gwei 约 0.00184 BNB，加 0.001 BNB 部署费，合计约 0.0028 BNB；`check` 146 项全部通过。`v2.0-rc7`（标准局入场费回到 1%、StdMachineSales 加溢价分成参数）再演练：13 笔共 3,698 万 gas，合计约 0.0028 BNB；`check` 147 项全部通过。`v2.0-rc8`（加 `MachineRules`、`MachineLister`，`FirstoTrader` 换成 `MarketTrader`；分叉区块 129,358,233，2026-10-24）再演练：15 笔共 4,271 万 gas，按 0.05 gwei 约 0.00214 BNB，加 0.001 BNB 部署费，合计约 0.0031 BNB；`check` 170 项全部通过（故意传错运营地址时标红、退出码 2）。部署文件的键 `firstoTrader` 改为 `marketTrader`，新增 `machineRules`、`machineLister`、`officialMarket`、`seaport`。`deployments/56.json` 多了 `monthPositions` / `monthSales` / `monthGovernor` / `positionExchange` 四个键。

### v2 月局（项目方 2026-10-22 决定，规则基线 [`docs/v2月局规则决定-2026-10-22.md`](docs/v2月局规则决定-2026-10-22.md)）

| 项目 | v2 |
|---|---|
| 买入（两种局） | 运营地址每小时经 `MarketPriceFeed.post(bid, ask)` 报 Firsto 买一 / 卖一（每单位权重的 BEM 价）。收购价 = `min(卖一, 买一 × (1 + 0.5% × (本轮收购已过整小时 + 1)), 一年产出)`（没有下限，规则决定 6.19）；报价超过 3 小时没更新或运营地址为 0 就暂停收购；从没报过价或 7 天没报价（停运）时按原来的上涨曲线。报价每次 bid / ask 各自最多变 5%，**任何时候都限**（停报再久也不能一步跳价，规则决定 6.33） |
| 30 天开奖 | 请求开奖时奖金池定死，5 个奖 60 / 15 / 15 / 5 / 5；**月局只收 1% 入场费，奖金池不再扣 3% / 2%**（规则决定 6.15） |
| 卖出（两种局） | 不再由运营地址挂单，价格由合约按公式算：每单位权重 = `max(买一, 卖一 × (99% − 0.5% × 卖出阶段已过整小时))`。月局整台不低于成本价，报价过期（3 小时）暂停，**报价停运（从没报过或 7 天没更新；运营地址为 0 只是暂停，规则决定 6.33）时任何人按成本价可买**；多数清算计划价不低于当时买一 × 算力 × 95%，报价过期时暂停；"保持排序第一"的目标价最多比公式价低 5%；标准局（`StdMachineSales`）没有成本价底线，但市价期也不低于拍卖底价（采购均价 × 60%，规则决定 6.31），进入终局 30 天后改为降价拍卖（起价 = 当时买一，报价无效时采购均价 × 150%；14 天降到 60%，底价停 7 天循环，不依赖报价） |
| 低于成本价 | 不卖，继续挖矿，产出按投入比例分（不变） |
| 跨局交接 | 旧月局在新月局的收购拍卖里当普通卖家（`relayOut` → 新局 `sellMachine`），按新局当前收购价成交，且不低于成本价 |
| 持仓 | 每个插槽是一份 ERC-721 持仓（`MonthPositions`，编号 = 月局地址 << 96 \| slot）。**只在结算阶段可以整份转让**；转让时卖方已累计的款项结转给卖方（`credit` / `withdrawCredit`），通行证立刻退回原持有人 |
| 持仓交易 | `PositionExchange` 链上挂单簿（第 6 阶段）：持有人 `listAsk` 挂非托管卖单（按每 1 BEM 本金报价，可改价、撤单，最长 30 天），持仓换手或局交易版本号变化后自动失效；买家 `buyAsk` 吃一张或 `buyBest` 按最优价批量吃。买家也可以 `placeBid` 挂本局通用买单（托管 ≥ 1 BEM，可限定持仓大小，每地址每局最多 20 张），持有人 `sellToBid` 卖给它（标准局只收未出局的持仓，规则决定 6.33）；撤单、过期退款。成交款、退款都直接到账；`book` / `recentTrades` 读盘口和最近 20 笔成交；市场费 0 |
| 多数集体清算 | `MonthExitGovernor`：结算开始 7 天后，≥ 10% 原始本金支持的具体价格计划可以开启 24 小时投票；赞成 > 全部原始本金的一半才通过；24 小时等待后 48 小时内执行；之后矿机可以按计划（7 天从起价线性降到底价）低于成本价卖出；失败冷却 14 天（改价 7 天） |
| 领取 | 按持仓编号：`owed(slot)` / `withdraw(slot)` / `claimAll(slot)` / `returnPass(slot)`，付给当前持有人；分批推送 `MonthMachineSales.distribute(board, from, count)` |

### `v2.0-rc9`：卖矿机在各平台保持排序第一（规则决定 6.29）

- 运营地址每 5 分钟报一个"同类最低挂单再低 0.1%"的目标价（`MarketPriceFeed.postFloor`，每单位权重、主板净得的 BEM）；卖矿合约只在 [买入成本, 原公式价] 之间采用它，主板直接购买价和平台挂单价一致；挂单每台最多 30 分钟改一次价。换算方法见 `V2-ABI.md` 的 rc9 一节。
- 顺带 TapeCode 预审第 17、18 条。主网分叉部署演练 15 笔、`check` 171 项全部通过；测试网脚本加了 `markets` 阶段（模拟官方矿机市场 / Seaport 挂单和 WBNB 出价）。

### `v2.0-rc8`：多来源自动买卖矿机、收所有工厂处理器的矿机（规则决定 6.26，送审定稿）

- **PoD 字段改正**：主网分叉实测 `getMiner` 的 [7] 是处理器倍数、[9] 是状态（1 在挖 / 3 已停）、[19] 是实际分产出的权重。rc7 以前会把已停挖、在未验证池的矿机当成合格。rc8：合格 = 状态 1 且 [19] > 0；**计价算力 = min(基础算力 × 倍数, [19])**（不含最优加成）。
- **收哪些矿机**（新单例 `MachineRules`）：工厂 `isCPU` 的合集，且代码和官方矿机电路合约相同（同一个信标，升级哨兵覆盖得到），例如 Behemoth（倍数 6）。主板收矿改为 `sellMachine(合集, 编号, 最低单价)`，矿机记录多了 `collection`。
- **多来源买入**（`MarketTrader`，取代 FirstoTrader）：Firsto 卖单、TapeOut 官方矿机市场挂单、Seaport（tapeout.market）卖单；机器人挑按每单位算力最便宜的递单，合约保证不超过公式价。
- **多来源卖出**：Firsto 统一买单、Seaport WBNB 出价（`MarketTrader.sellToOffer`），以及 **`MachineLister` 把主板矿机按公式价同时挂到官方矿机市场和 Seaport、随公式改价**；成交时卖款推给挂单库，同一笔交易里按成交那一刻的公式价结算，不够就整笔回滚。Firsto 只吃单。
- 价格规则、维护费 10%、F-2 / F-3 / F-4 都不变；有人直接按公式价向主板买时，寄售中的矿机先自动撤单拿回。
- 主网分叉集成（真实部署脚本 + 真实市场）：`test/probe/MarketModulesFork.t.sol`；接口变化见 `V2-ABI.md` 的 rc8 一节。

月局 v2 的合约：`MonthBoard`（游戏与记账，24,158 B）、`MonthFactory`、`month/MonthPositions`、`month/MonthMachineSales`、`month/MonthExitGovernor`、`month/PositionExchange`。下文第 3–5 节里月局"按成本价交接""7 天降到成本价并锁定""一地址一局的 `socketOf`"等描述是 v1.5 的，v2 以本节为准。

---

## 2. 目录结构

```
src/
  BoardFactory.sol           标准局工厂 + 注册中心：核对先部署的分账合约、部署标准局实现；开局；开新主板；金额自动调整；
                             两种局合计的开局顺序（首批回馈用）；isBoard 同时认两种局
  GenesisSplitter.sol        分账合约：创世处理器的 creator；分账、回购销毁、领取回馈
  TapeBoard.sol              标准局（每局一个代理）：招募、采购拍卖、脉冲抽签、硅王、终局拍卖、保底
  MonthFactory.sol           月局工厂：部署月局实现；开新月局；金额自动调整；回馈资本滚存
  MonthBoard.sol             月局 v2（每局一个代理）：招募、准备矿机（收购；旧月局在这里当普通卖家）、30 天挖矿、
                             5 个奖独立抽取、结算记账（按持仓）、持仓转移钩子、交割（releaseMachine / relayOut）
  month/MonthPositions.sol   v2 持仓凭证（ERC-721，所有月局共用）：所有转移都经过主板的 onPositionTransfer
  month/MonthMachineSales.sol v2 结算阶段卖矿定价：挂单（≥ 成本价、可改价）、成本价兜底、购买、交接、分批推送、清算计划曲线
  month/MonthExitGovernor.sol v2 多数集体清算：计划、意向、投票、执行等待、执行 / 过期、冷却
  month/PositionExchange.sol  v2 持仓交易所：链上挂单簿（卖单 + 托管买单），两种局共用
  MarketPriceFeed.sol        两种局共用的矿机报价（运营地址报买一 / 卖一）与买卖公式
  StdMachineSales.sol        标准局终局卖矿定价（市价期 / 降价拍卖）、溢价分成、按持仓领取、寄售接口
  TemplateTimelock.sol       新局模板 7 天时间锁
  MachineRules.sol           rc8：收哪些合集的矿机、合格条件、计价算力（两种局共用）
  market/MarketTrader.sol    rc8：在 Firsto / 官方矿机市场 / Seaport 买矿机给主板，把主板矿机卖给 Firsto 买单 / Seaport 出价
  market/MachineLister.sol   rc8：把主板矿机按公式价挂到官方矿机市场和 Seaport（每台一个挂单库 ListingVault），成交结算
  market/SaleSettlement.sol  rc8：卖出所得的溢价分成（MarketTrader / MachineLister 共用）
  market/IMarkets.sol        rc8：官方矿机市场、Seaport 1.6 的接口和结构
  firsto/                    Firsto 订单结构、PancakeSwap 闪电兑换适配器
  interfaces/                TapeOut / PoD / 随机数 / 兑换 / 标准局 / 月局 / 注册中心 的接口
  libraries/EjectionTree.sol 抽签用的树状数组 + 最大值线段树（标准局按 S − wⱼ 抽出局者，月局按投入比例抽奖）
  libraries/PrizeDraw.sol    月局开奖：一个随机数派生 5 次独立抽取，奖金比例 60 / 15 / 15 / 5 / 5
  libraries/PoDReader.sol    按字位置读取 PoD getMiner；计算每单位权重的产出
  libraries/TickMath.sol     V3 tick → 价格（TWAP 用）
  random/ChainlinkVRFAdapter.sol   随机数适配器：Chainlink VRF v2.5（主网和测试网共用）
  oracle/PancakeV3TwapOracle.sol   多跳 TWAP 预言机（回购和回馈兑换的最低成交量）
  mocks/                     仅用于测试 / 测试网的模拟合约（MockBEM、MockPoD（按主网实测的 22 字布局）、MockCircuits+MockBeacon、
                             MockTapeOutFactory+MockTransistors、MockRandomSource、MockRouter、MockPriceOracle、
                             MockFirsto*、MockOfficialMarket、MockSeaport、MockWBNB）
script/
  TapeSurgeDefaults.sol      默认参数与主网地址（测试、部署脚本、本 README 共用这一份）
  TapeSurgeDeploy.sol        主网部署逻辑（DeployMainnet 与 E2EForkBSC 共用）
  DeployMainnet.s.sol        BSC 主网部署脚本（只接受链 ID 56，含部署前自检）
  CheckMainnet.s.sol         主网部署后的只读核对
  mainnet.sh                 主网部署入口：simulate / deploy / check / verify
  DeployTestnet.s.sol        BSC 测试网部署脚本（Mock 环境 + 真实 Chainlink VRF v2.5）
  TestnetScenario.s.sol      测试网分阶段场景；testnet.sh 是它的执行入口
test/                        见第 7 节
```

---

## 3. 架构

```
           ┌──────────────────────────── BoardFactory（构造时部署下面两个）────────────────────────────┐
           │                                                                                          │
   GenesisSplitter ──createCPU──▶ TapeOut 工厂 ──▶ 创世晶体管（ERC-1155）+ 创世电路（通行证 ERC-721）     │
     │  distribute / buyback / claimReward                                                           │
     │       └──（BNB→USDT→BEM，TWAP 下限）──▶ 0x…dEaD / 第 1–5 块主板（depositSubsidy）               │
     │                                                                                               │
   TapeBoard 实现 ◀── EIP-1167 代理（第 1 块、第 2 块……，同一时间只有一块在招募）                         │
           └──────────────────────────────────────────────────────────────────────────────────────────┘

   TapeBoard ──sellMachine / claim / claimMany──▶ PoD、官方矿机电路
             ──requestRandomness──▶ IRandomSource（ChainlinkVRFAdapter / MockRandomSource）──onRandomness──▶ TapeBoard

   MonthFactory（单独部署，构造时部署 MonthBoard 实现；地址预先算好传给 BoardFactory）
     ├─ openFirst（由 BoardFactory.startGenesis 调用）→ 第 1 块月局（100 BEM，3 天招募）
     ├─ onBoardStarted → BoardFactory.registerStart（两种局合计的开局顺序）→ 开下一块 → 把滚存的回馈资本转给刚开局的月局
     └─ 持有滚存资金（月局局终收回的回馈资本）

   MonthMachineSales.relay ─▶ MonthBoard A（结算中）.relayOut ─▶ MonthBoard B（准备矿机中）.sellMachine：按 B 的收购价（≥ A 的成本价）
   MonthPositions.transferFrom（直接 / 授权 / PositionExchange 成交）─▶ MonthBoard.onPositionTransfer（锁、结转、退通行证、版本号）
   MonthExitGovernor ─▶ MonthBoard.setGovernanceLock / startLiquidation，MonthMachineSales.installPlan
```

- **部署顺序**：先单独部署 `GenesisSplitter`，构造参数里带着按部署者 nonce 预先算好的 BoardFactory 地址。分账合约在自己的构造函数里调用 TapeOut 工厂的 `createCPU`，因此成为创世处理器的 creator。接着部署 **BoardFactory**：它核对 `splitter.boardFactory() == 本合约`，再用创世电路合约地址部署 `TapeBoard` 实现合约。这样几个合约互相知道地址，不需要任何"事后设置"的管理员函数。
- **为什么分账合约单独部署**：原先 BoardFactory 的构造函数里同时创建分账合约和标准局实现，初始化代码加构造参数共 49,642 字节，超过 EIP-3860 的 49,152 字节上限。2026-10-19 部署到 BSC 测试网时被节点拒绝才发现，因为 Foundry 默认不检查大小。拆开后 BoardFactory 是 37,867 字节（含构造参数），余量约 11 KB。现在 `test/SizeLimits.t.sol` 会按主网规则（`FOUNDRY_PROFILE=sizecheck`，EVM 真实执行 EIP-170 / EIP-3860）把全部合约部署一遍，`script/testnet.sh deploy` 部署前也会先跑这一项。
- 随机数适配器只接受本协议主板发起的请求（`BoardFactory.isBoard` 同时认标准局和月局）。它要在 BoardFactory 之前部署，所以由部署脚本预先算出 BoardFactory 的地址，传给适配器（脚本会校验预测地址与实际地址一致）。
- **为什么月局单独一个工厂**：BoardFactory 的初始化代码里已经包含标准局实现，放不下月局实现。所以 `MonthFactory` 单独部署，BoardFactory 担任两种局共用的**注册中心**（开局顺序 `rewardBoard(rank)`、`isBoard`、创世电路与分账合约地址）。部署顺序：（可选）VRF 适配器 → GenesisSplitter → BoardFactory（构造参数里带着预测好的 MonthFactory 地址）→ MonthFactory（构造时校验 `hub.monthFactory() == 本合约`）。全程没有任何"事后设置"的管理员函数。
- **资金发放 = 自动推送 + 自领兜底**（设计审计 H4）：
  - 标准局每次出局时，105% 直接推送给出局者，并退还他的通行证；硅王的 105% 在最后一次脉冲时推送。推送失败时（BEM 是普通 ERC20，正常不会发生）改为记账，通行证退还失败时保留记录，都由本人之后自领，VRF 回调不会因此失败；
  - 月局开奖时 5 个奖金、3% 和 2% 直接推送；
  - 其余（终局 / 保底的分配、月局本金和溢价、卖不出的矿机继续挖的产出、招募失败的退款、通行证）由运营地址分批调用 `distribute(fromSlot, count)` 推送，每次把一段插槽的人当前可领的全部金额打过去，并退还通行证；没有可领的跳过，可以重复调用；
  - 推送和自领（`withdraw` / `claimAll` / `returnPass`，任何人可以替别人触发）用同一套记账，不会重复支付；退通行证一律 `transferFrom`，不触发回调；
  - 标准局出局时的 3% / 2% 记在两个 Safe 名下，任何人都可以 `withdraw(Safe 地址)` 把它转过去。

### 运营地址与参与者兜底

- **只存一处**：运营地址（`operator`）存在 BoardFactory（注册中心）里，两种局每次都去读。只有手续费 Safe（写死在主板参数里的 `feeRecipient`）可以调用 `BoardFactory.setOperator` 任命或更换，并发出 `OperatorChanged` 事件；可以设成 0。
- **运营地址专属的操作，以及参与者兜底的起算时刻**（运营地址在起算时刻之后 `operatorGrace`，即 3 天，内没执行，**本局参与者**就可以执行；其他地址始终不行）：

| 操作 | 参与者兜底的起算时刻 |
|---|---|
| 标准局 `pulse()`：请求随机数，或只剩硅王时发放 105% 并进入终局 | 开局或上一次出局的时间（`lastPulseAt`）。合约里难以精确记录"脉冲池达到门槛"的时刻，所以用它近似：距开局或上一次出局超过 3 天、且门槛满足时，参与者可以推进 |
| 两种局 `retryDraw()`（请求 24 小时后才能重发） | 请求时间 + 24 小时 |
| 月局 `drawPrizes()` | 30 天挖矿到期（`miningEnd`） |
| 月局 `finalizePrizes()` | 随机数到账的时间 |
| 两种局 `distribute(fromSlot, count)` | 本阶段开始：标准局开局 / 进入终局 / 招募失败；月局进入结算 / 招募失败 |
| 月局 `relayMachine()`（交接） | 进入结算 |
| 月局 `setListing()`（挂单定价） | **只有运营地址**，没有参与者兜底：结算开始 1 天内没挂单的矿机会自动按成本价挂单并锁定，参与者兜底已经没有意义 |

- **运营地址设成 0 时**：上表的操作参与者随时可以执行（没有运营地址可等）；`setListing` 无人可调，所有矿机 1 天后按成本价挂单。
- **保持任何人可调**（改变不了结果，限制反而增加卡住的风险）：`harvest` / `sweep` / `sync` / 分账 `distribute` 与 `buyback` / `claimReward`、`closeRecruitment`、VRF 停摆 7 天的保底（`triggerSafeExit` / `triggerSafeSettle`）、最长期限保底 `expire`、升级哨兵的退出（`emergencyExit` / `emergencySettle`，仍只限参与者）、`closeClaims`、外部买家 `buyMachine`、矿工 `sellMachine`、自领入口、升级哨兵登记 `BoardFactory.noteSentinel()` 和冷静期后的 `reopen()`。
- **不再有调用者奖励**：标准局每次出局的 2% 和月局开奖的 2% 全部给手续费 Safe。

---

## 4. 与白皮书章节的对应

| 白皮书 | 合约实现 |
|---|---|
| 3.1 创世处理器（66,666 颗，每颗 0.001 BNB；最多 13,333 张通行证） | `GenesisSplitter` 构造函数调用 `createCPU`；会校验 `creator() == 本合约`，不满足就部署失败 |
| 3.2 / 附录 B 通行证电路 | `TapeBoard.join`：`ownerOf(passId) == msg.sender`，且 `keccak256(netlist(passId)) == 0xfffa29f1…2ca0`。只认创世处理器的电路合约（`PASS_CIRCUITS`），其他处理器上的同款半加器不认 |
| 3.3 通行证可重复使用、一地址一局 | `socketOf[msg.sender]` 不为 0 就拒绝；通行证锁在主板里，招募失败或终局后用 `returnPass` 原样退还 |
| 4 开局（铸满 10,000 颗或满 7 天） | `BoardFactory.startGenesis`：先 `distribute` 一次，再同时开出第 1 块标准局（500 BEM，7 天）和第 1 块月局（100 BEM，3 天） |
| 5.1 投入为目标的 0.2%–4%，入场费 1% | 投入范围在主板开出时由工厂传入、之后固定，支持小数；入场费先留在主板，开局时一次转给手续费地址，招募失败时随本金一起退还 |
| 5.2 主板金额自动调整 | `BoardFactory.onBoardStarted` / `onBoardFailed`：2 天内招满 × 1.25；2–7 天内招满不变；到期 ≥ 60% 按实际金额开局 × 0.75；到期 < 60% 退款重开 × 0.5；范围 100–1,000 BEM，**向下取整**到 1 BEM |
| 5.3 采购（价格上涨的荷兰式拍卖） | `TapeBoard.sellMachine`：按 `权重 × 当前价` 付款；成交前先替卖家 `claim`，再 `transferFrom` 收入矿机 |
| 5.4 脉冲门槛 | `pulseGross(在局最大投入)` = ⌈投入 × 105% ÷ 95%⌉，在局最大投入由最大值线段树 O(1) 读出 |
| 5.5 / 附录 A 出局抽签 | `EjectionTree.selectEject`：r = 随机数 mod ((n−1)·S)，用树状数组二进制下降找"第一个前缀权重 > r"的插槽，O(log n) |
| 5.6 硅王 | 只剩 1 人时用 `findByCount(1)` 找出硅王；脉冲池够付他的 105% 时由 `pulse()` 直接发放，并进入终局 |
| 5.7 终局 65 / 30 / 3 / 2 | `_startLiquidation(Normal)` + `buyMachine` + `_allocate`：用累加器分多次分配底池 |
| 5.8 异常与保底 | `retryDraw`（24 小时，运营地址）、`triggerSafeExit`（7 天）、`expire`（最长期限）、`emergencyExit`（升级哨兵）、`syncMachine`（撤销/降级） |
| 6 月局 | `MonthBoard` + `MonthFactory`，逐条对应见下面的"月局"小节 |
| 7 资金流 | `test/Conservation.t.sol`、`test/MonthSettlement.t.sol` 验证：所有流入 = 所有流出 + 合约余额 |
| 8 铸造收入 40 / 10 / 20 / 30 | `GenesisSplitter.distribute`；比例是构造参数；"第 1–5 块"按两种局合计、真正开局的先后排序（`BoardFactory.rewardBoard`）；已结束主板那一桶的新增部分转入回购 |
| 10 合约架构 | 见第 3 节。标准局的 `draw()` 对应 `onRandomness()`（VRF 回调），`finalize()` 对应"硅王领完 105% 后自动进入终局"加上 `buyMachine` / `sweep` / `distribute`；月局的 `drawPrizes()` 发起开奖，VRF 回调 `onRandomness()` 只记下随机数，`finalizePrizes()` 完成 5 次抽取并推送奖金，`settle()` 对应结算阶段的 `relayMachine` / `setListing` / `buyMachine` / `harvest` / `distribute` |
| 附录 C 地址 | 见 `script/TapeSurgeDefaults.sol` 与 `test/ForkBSC.t.sol` |
| 附录 D 待定参数 | 全部做成构造参数，测试网默认值见第 5 节 |

### 月局（白皮书第 6 节、规则文档 §8）

| 规则 | 合约实现 |
|---|---|
| 6.1 招募 3 天；1 天内招满 × 1.25、1–3 天不变、到期 ≥ 60% 按实际开局 × 0.75、< 60% 退款重招 × 0.5；100–1,000 BEM；投入为目标的 0.2%–4%；入场费 1% | `MonthBoard.join` / `closeRecruitment` + `MonthFactory.onBoardStarted` / `onBoardFailed`，规则与标准局相同，只是参数不同；两种局各自排队、各自调整 |
| 同一张通行证同一时间只能锁在一块主板里 | 加入时通行证 NFT 转进主板，自然无法再加入别的主板 |
| 6.2-1 准备矿机：先按成本价接手上一批月局的矿机，不够再收购，最多 3 天 | `acceptRelay`（接手方）：成本价 ≤ 权重 × 本局当前的收购价上限，且预算够才接；`sellMachine`：收购拍卖，规则同标准局；准备期固定 `prepDuration`（3 天），期满后开始挖矿 |
| 买不满的 BEM 留在主板，局终原样退还 | 未花完的 `budget` 在结算开始时按"本金 → 回馈"的顺序退还 |
| 6.2-2 挖矿 30 天，产出全部进奖金池 | 准备期结束起计 30 天（`miningEnd`）；`drawPrizes` 之前领取的产出都进 `prizePool`，请求开奖时奖金池定死 |
| 6.2-3 开奖：3% 基金会、2% 手续费，5 个奖 60 / 15 / 15 / 5 / 5，各自独立按投入比例抽取 | 运营地址 `drawPrizes()` 请求随机数 → VRF 回调只记下随机数 → 运营地址 `finalizePrizes()` 用 `PrizeDraw.winners`（rₖ = keccak256(word, k) mod S，按投入前缀和查找），奖金和 3% / 2% 直接推送；取整余数并入头奖 |
| 6.4 收回本金：先按成本价交接，交接不了就挂单（≥ 成本价）；1 天未挂自动按成本价挂；7 天未卖出降到成本价且不能再调高；卖不出继续挖 | 运营地址 `relayMachine`（结算期间任何时候）；运营地址 `setListing`（≥ 成本价）；`priceLocked` / `askPrice` 实现 1 天自动挂单与 7 天降价锁定；任何人 `buyMachine`（带 maxPrice）；卖不出的矿机产出由运营地址 `distribute` 推送 |
| 6.5 VRF 24 小时可重发、只认最新请求；停摆 7 天不抽奖，奖金池按比例分，不收 3% / 2% | `retryDraw` / `triggerSafeSettle` |
| 6.5 升级哨兵：停止新加入、暂停拍卖；参与者可以提前结算 | 哨兵是 **30 天冷静期**（外部审计 #2，项目方 2026-10-20 选方案 A）：冷静期内 `join`、矿机收购和出售（`sellMachine` / `acceptRelay` / `relayMachine` / `buyMachine`）revert，工厂不开新月局；登记满 30 天后全部恢复，冷静期内招募失败、没有重开的月局由 `MonthFactory.reopen()` 重开；`emergencySettle()`（参与者，对还没到期的局，**只在冷静期内**，规则决定 6.33）按停摆规则结算 |
| 8 首批回馈：两种局合计按开局顺序排出第 1–5 块；月局的回馈并入采购本金，局终收回的回馈部分转入下一块月局 | `BoardFactory.registerStart` 排序；`MonthBoard.depositSubsidy` 计入 `subsidyCapital`；局终收回时回馈资本转到 `MonthFactory`，下一块月局开局时全部转给它 |

### 关键公式（都用 BEM 最小单位，1 BEM = 1e8）

- 出局者得：`payout = stake × 10500 / 10000`（105%）
- 脉冲总额：`gross = ceil(payout × 10000 / 9500)`
  - 基金会 `gross × 3%`，手续费地址拿剩下的（约 2%，含取整余数）
- 底池每次到账 `A`：
  - Normal：基金会 3%，手续费地址 2%，硅王 30%，其余约 65% 按投入分给硅王以外的人
  - 异常结局（Fallback：最长期限、首轮一台没买到、升级哨兵；SafeExit：VRF 停摆 7 天）统一用保底公式：先填"未出局者取回投入"，填满之前全部按未出局者的投入比例分（不够就按比例）；填满后剩余部分**全部**按投入分给**所有**参与者（包括已出局的人）。**2% 手续费照收（分配之前从进入底池的全部金额里扣，规则决定 6.37），不收基金会 3%，没有调用者奖励，没有硅王奖**
- 月局开奖：奖金池 `P`，基金会 `P × 3%`，手续费地址 `P × 2%`，其余 `N` 中第 2–5 个奖各 `N × 15% / 15% / 5% / 5%`，头奖 = `N −` 其余四个奖（60% 加取整余数）
- 月局收回的资本 `C`（接力款、拍卖款、未花完的预算）按顺序：先填参与者本金（按投入比例）→ 再填回馈资本（转入 MonthFactory 滚存）→ 超出成本的部分按投入比例分给参与者；结算阶段的产出全部按投入比例分给参与者，不收费
- 取整一律向下，取整尘埃留在合约里，领取期满后随过期资金一起转到黑洞地址 `0x…dEaD` 销毁（设计审计 L4；规则决定 6.13）

---

## 5. 默认参数（`script/TapeSurgeDefaults.sol`）

### 已定稿的规则

| 参数 | 值 |
|---|---|
| 晶体管上限 / mintPrice | 66,666 颗（最多 13,333 张通行证；2026-10-21 项目方决定由 666,666 改回）/ 0.001 BNB |
| 开局条件 | 已铸 ≥ 10,000 颗或开始铸造满 7 天 |
| 第 1 块主板目标 | 500 BEM；范围 100–1,000 BEM；取整 1 BEM |
| 单人投入 | 目标的 0.2%–4%（500 BEM 时 1–20 BEM，1,000 BEM 时 2–40 BEM） |
| 金额调整 | 2 天内招满 × 1.25；到期 ≥ 60% 按实际开局 × 0.75；到期 < 60% 退款 × 0.5 |
| 入场费 | 1%（另收） |
| 招募期 | 7 天，从主板开出时计时 |
| 出局 / 硅王 | 105%；脉冲 95 / 3 / 2 |
| 终局 | 65 / 30 / 3 / 2 |
| 铸造收入 | 40% 回购销毁 / 10% 项目方（手续费 Safe）/ 20% 基金会 / 30% 回馈（10 : 8 : 5 : 4 : 3） |
| 基金会 Safe | `0x04B649076a11819EF7AdA36e02DD55e0923550Ee` |
| 手续费 Safe | `0x6ea5FfB01378a1E5ce55C8A119A90a87e542C995` |
| VRF 超时 | 24 小时可重新请求；7 天进入安全退出 |

### 测试网阶段的默认值（附录 D 待定参数，均为构造参数）

| 参数 | 默认值 | 说明 |
|---|---|---|
| 采购价上限 | `min(当前每单位权重日产出 × 365, 3 BEM)` | 日产出 = `currentRate × 86400 × 99% ÷ totalVerifWeight`。主网现值约 **1.6465 BEM / 单位权重**，即每单位权重的买入价不超过约一年的产出（设计审计 H3） |
| 采购价曲线 | 上限 × 50% 起，每 6 小时 + 5%，60 小时到上限 | 读不到 PoD 产出速率时价格为 0，暂停收购 |
| 一轮收购 | 7 天 | 买不满时剩下的 BEM 留在主板，终局并入底池；回馈补贴到账会开启新一轮 |
| 矿机资格 | 已验证、在挖、已运行 ≥ 7 天、权重 10–300 | "已运行"读 getMiner 第 [8] 个字（推断为开挖时间，设计审计 M2） |
| 每块主板最多矿机 | 100 台 | 控制 harvest 的 gas |
| 终局拍卖 | 采购均价 × 150% 起，14 天线性降到 × 60%（底价），在底价停 7 天，然后重新开始一轮（每轮 21 天） | 设计审计 H2 |
| 卖不出的处理 | **不强制贱卖**：矿机继续挖，产出照常并入底池按同样比例分配，下一轮再拍卖 | |
| 最长期限 | 开局后 730 天 | 之后任何人可调 `expire()` 进入保底 |
| 首轮收购一台没买到 | 首轮结束后可以立即 `expire()` | 未出局者全额取回投入（入场费已在开局时转给手续费地址） |
| 运营地址兜底 | `operatorGrace` = 3 天 | 运营地址 3 天没执行，本局参与者可以执行（见第 3 节） |
| 初始运营地址 | 测试网：部署者地址（`DeployTestnet.s.sol` 里的常量 `INITIAL_OPERATOR = 0` 表示用部署者；也可用环境变量 `OPERATOR`） | 之后由手续费 Safe 调用 `setOperator` 更换 |
| 领取期限 | 365 天 | 从招募失败、或终局卖完最后一台矿机时开始计；过期后 `closeClaims()` 把剩余 BEM 转到黑洞地址 `0x…dEaD` 销毁（2026-10-23 起，两种局相同）。通行证不过期（设计审计 M3） |
| 回购 / 回馈兑换 | 每次最多 0.5 BNB；同一用途间隔 ≥ 1 小时；成交量 ≥ 30 分钟 TWAP × 98%（主网，`TapeSurgeDefaults.MAINNET_MAX_SLIPPAGE_BPS = 200`，外部审计 #6）；测试网部署仍用 97%（`TESTNET_MAX_SLIPPAGE_BPS = 300`） |
| 升级哨兵冷静期 | 登记满 30 天后恢复加入、矿机收购和出售、开新主板（`sentinelResumeDelay`，两种局相同，外部审计 #2） |
| 收购价上限 | 每轮收购开始时快照，本轮都按快照值（外部审计 #3）；快照时读不到 PoD 则为 0、暂停收购，本轮第一次有人卖矿机时补一次快照 | 路径 WBNB →（0.01%）→ USDT →（1%）→ BEM（设计审计 M1） |
| VRF 回调 gas | 750,000（`TapeSurgeDefaults.VRF_CALLBACK_GAS`，主网和测试网部署共用） | 主网分叉实测标准局回调最高约 35.8 万（含推送 105% 和真实电路合约退通行证），500 人的标准局用 mock 约 26.3 万；月局回调只记随机数，约 7.4 万。Chainlink 按实际用量收费，上限调高不多花钱 |
| VRF（BSC 测试网） | 协调器 `0xDA3b641D438362C440Ac5458c57e00a712b66700`，keyHash（50 gwei）`0x8596b430971ac45bdf6088665b9ad8e8630c9d5049ab54b14dff711bee7c0e26` | 2026-10-19 链上只读核实：协调器有 v2.5 的 `getActiveSubscriptionIds`、`MAX_NUM_WORDS = 500`、`LINK() = 0x84b9…7b06`；该 keyHash 已登记 |

### 月局的默认参数（`TapeSurgeDefaults.monthParams`）

| 参数 | 默认值 |
|---|---|
| 第 1 块月局目标 | 100 BEM；范围 100–1,000 BEM；取整 1 BEM；投入为目标的 0.2%–4%（100 BEM 时 0.2–4 BEM） |
| 招募 / 金额调整 | 3 天；1 天内招满 × 1.25；到期 ≥ 60% 按实际开局 × 0.75；< 60% 退款 × 0.5；入场费 1% |
| 准备矿机 | 最多 3 天；收购价曲线与上限同标准局（上限 × 50% 起，每 6 小时 + 5%，上限 = 365 天产出，另有 3 BEM 绝对上限）；矿机资格同标准局 |
| 挖矿 | 30 天 |
| 奖项 | 60 / 15 / 15 / 5 / 5，各自独立按投入比例抽取；3% 基金会、2% 手续费，开奖时直接推送 |
| 收回本金 | 结算期间运营地址随时可按成本价交接；运营地址挂单价 ≥ 成本价；结算开始 1 天内没挂单 → 按成本价挂单（`autoListDelay`）；第一次挂单满 7 天没卖出 → 降到成本价并锁定（`listingMaxAge`，改价不重新计时）；卖不出继续挖 |
| VRF / 领取 | 24 小时可重发；7 天停摆不抽奖；领取期限 365 天 |

---

## 6. 设计审计清单的落实情况（`../设计审计-v1.md`）

| 编号 | 落实方式 |
|---|---|
| H1 推动游戏的费用 | VRF v2.5 订阅制，适配器的 `nativePayment` 可配置为用 BNB 或 LINK 付费；项目方 10% 铸造收入用于预充订阅、运行运营机器人。**开奖、自动发放、月局交接 / 挂单由运营地址执行**，运营地址 3 天没执行时由本局参与者兜底（第 3 节）。原来的 0.5% 调用者奖励已取消，2% 手续费全部给手续费 Safe |
| H2 终局拍卖压价 | 标准局：底价 = 采购均价 × 60%，到底价没卖掉的矿机继续挖，过 7 天重新拍卖。月局：挂单价不低于成本价，1 天未挂自动按成本价挂，7 天未卖出降到成本价且锁定 |
| H3 采购拍卖抬价 | 价格上限 = 每单位权重 365 天产出（另有 3 BEM 绝对上限）；买不满的 BEM 留在主板 |
| H4 推送被卡死 | 推送都是分批的（`distribute(fromSlot, count)`），或者在出局 / 开奖时只推给少数几个人；推送失败时改为记账，自领入口一直保留；退通行证用 `transferFrom`；主板和分账合约里所有改状态的外部函数都加了 `nonReentrant`（`initialize` 只能由工厂调用，工厂的回调只接受招募中的那块主板） |
| H5 保底顺序 | 停止抽签 → 卖矿机（沿用终局拍卖与底价规则）→ 先退未出局者投入（不够按比例）→ 剩余部分全部按投入分给所有人（含已出局者）→ 取消硅王奖；**2% 手续费照收（分配之前扣，规则决定 6.37），不收基金会 3%，没有调用者奖励**。最长期限、VRF 安全退出、升级哨兵退出三个入口都走这一套。见 `test_MaxDurationFallbackRefundsAliveFirstThenProRataAll`、`test_FallbackProRataWhenPotBelowAlivePrincipal`、`test_SafeExitRefundsAliveFirstThenProRataAll`、`test_SafeExitProRataWhenPotBelowAlivePrincipal`、`test_EmergencyExitUsesFallbackFormula` |
| H6 外部合约可升级 | 升级哨兵：部署时记录信标实现地址；之后实现地址变化或信标读不出来，就停止新加入、暂停两次拍卖。产出领取和开奖照常进行；未出局的参与者可以调用 `emergencyExit()` 按保底规则退出；招募中的主板可以立即宣布招募失败并退款，工厂不再开新主板。**哨兵是 30 天冷静期**（外部审计 #2，项目方 2026-10-20 决定、方案 A）：`BoardFactory.noteSentinel()` 任何人可调，登记第一次观察到触发的时间（两种局共用一个记录 `sentinelSince`；任一种局的电路信标被升级都算；`emergencyExit` / `emergencySettle` 也会顺带登记；信标恢复后再调用清零）。主板的 `sentinelPaused()` 在"已触发且登记不满 `sentinelResumeDelay`（30 天）"时为真：冷静期内暂停加入、矿机收购和出售，工厂不开新主板（`startGenesis`、招募失败后重开）；冷静期内参与者仍可提前退出 / 提前结算，开奖照常。满 30 天后全部恢复，冷静期内没有重开的主板由 `BoardFactory.reopen()` / `MonthFactory.reopen()`（任何人可调）重开 |
| M1 回购被夹 | 多跳路径走 BEM/USDT 1% 池；最低成交量取 30 分钟以上 TWAP；单次限额、最短间隔 |
| M2 坏矿机 | 只收已验证、在挖、运行 ≥ 7 天、权重 10–300 的矿机；之后被撤销或停止的矿机可以用 `syncMachine` 移出产出计算；终局按 min(收购时权重, 当前权重) 计价；在 PoD 上未验证的按收购时权重 × 底价出售，不会被 0 价拿走（外部审计 #4） |
| M3 资金永久卡住 | 领取期限 365 天，过期转基金会 |
| M4 withdraw 语义 | **已在主网分叉上确认**：creator 调用 `withdraw()` 会收到 BNB；分账合约有 `receive()`；withdraw 失败不阻塞分账 |
| M5 VRF 重抽竞态 | 没超时不能重发；**同一次开奖发出的所有请求都有效，先到先用**（v2.0-audit.2 起，第三方预审 M-3：重发不能作废已在路上的结果）；别的开奖的、重复的回调忽略（不 revert） |
| M6 合约钱包 | BEM 推送是普通 ERC20 转账，不会被拒收；通行证用 `transferFrom`；自领入口保留 |
| L4 小数尘埃 | 统一向下取整，领取期满后归基金会 |

---

### 外部合约审计（2026-10-19，4 中 4 低）的处理情况

| 编号 | 问题 | 处理 |
|---|---|---|
| 1（中） | 月局矿机最低只卖到成本价，市价跌破成本时本金长期收不回 | **维持现状，不改**（项目方 2026-10-20 决定）："本金不低于成本价收回"是月局的核心规则；卖不出的矿机继续挖，产出照常分给参与者 |
| 2（中） | 升级哨兵触发后矿机买卖永久暂停 | **已修（2026-10-20 项目方决定，方案 A）**：哨兵改成 30 天冷静期，登记满 30 天后恢复加入、矿机收购和出售、开新主板（两种局）；这 30 天里参与者仍可提前退出 / 提前结算，开奖照常 |
| 3（中） | 收购价上限读 PoD 即时值 | **已修（2026-10-20 项目方决定）**：每轮收购开始时快照上限，本轮都按快照值（标准局：开局和每次新一轮；月局：开局） |
| 4（中） | 终局拍卖中未验证的矿机可 0 价买走 | **已修**：按收购时权重 × 底价出售 |
| 5（低） | getMiner 字段位置靠推断 | **已修**：`tryRead` 核对返回的电路合约地址和编号；字段位置已在主网分叉上核对过 |
| 6（低） | 兑换期限是 `block.timestamp`，可能被夹 | **已改参数（2026-10-20 项目方决定）**：主网默认 `maxSlippageBps` 300 → 200；测试网部署仍是 300 |
| 7（低） | 基金会 / 项目方拒收 BNB 会卡住分账 | **已修**：拒收时记账，之后 `withdrawOwed` 补转 |
| 8（低） | 标准局 VRF 回调 gas 偏大 | **已处理（参数）**：`callbackGasLimit` 默认值从 50 万提到 75 万，实测最高 35.8 万。拆成两步需要的字节 TapeBoard 放不下，暂不改合约 |

## 7. 测试覆盖

| 文件 | 内容 |
|---|---|
| `Recruit.t.sol` | 网表哈希与白皮书一致；通行证是半加器（eval 四组向量）；标准网表通过；换了门顺序的网表被拒；其他处理器上的同款半加器被拒；不是本人的通行证被拒；一地址一局；通行证退还后可在下一局再用；投入范围 0.2%–4%；小数投入；入场费托管与开局后转出；最后一笔只接受到恰好满额；剩余额度小于最小投入时可以恰好补满；招募失败退款（本金 + 入场费 + 通行证）；60% 按实际开局；2 天内招满 × 1.25 封顶 1,000；2–7 天不变；失败 × 0.5 到 100 为止；编号只算真正开局的主板；**1,000 / 20 参数组** |
| `Purchase.t.sol` | 价格上限 = 一年产出（≈ 1.6465）；50% → 100% 的价格曲线；绝对上限；读不到速率时暂停；按 权重 × 价 付款且旧产出归卖家；转入后产出归主板；非持有者不能卖；未验证 / 不在挖 / 未满 7 天 / 权重越界被拒；卖家最低价；预算不足；一轮结束后剩余预算留在主板；撤销矿机不再计入、恢复后重新计入；claimMany 失败时逐台领取；矿机数量上限；PoD 返回别的矿机时拒收（外部审计 #5）；**收购价上限是本轮开始时的快照**，本轮内 PoD 即时值变高变低都不影响，新一轮重新快照；快照时读不到 PoD 则暂停、卖矿机时补拍（外部审计 #3） |
| `Draw.t.sol` | 门槛 = 最大投入 × 105% ÷ 95%；低于门槛不开奖；出局时 **105% 直接推送并退还通行证**，95 / 3 / 2（2% 全部给手续费 Safe，没有调用者奖励），之后自领拿到 0；大额投入的人都出局后门槛下降；只接受随机数源、只接受最新请求、重复回调忽略；24 小时内不能重发，重发后旧请求作废；**pulse / retryDraw 运营地址专属，参与者 3 天兜底，外人 3 天后仍被拒绝**；**手续费 Safe 更换运营地址、非 Safe 被拒绝、运营地址为 0 时参与者随时可推进**；7 天安全退出（重发不重置计时）；硅王 105% 推送后进入正常终局；每人恰好出局一次；**退通行证失败或推送失败时 VRF 回调照样成功，改为自领** |
| `Settlement.t.sol` | 终局拍卖价格下降、停在底价、重新开始；买矿机转 NFT、卖前产出并入底池；卖不出时产出继续按比例分配；未验证的矿机按收购时权重 × 底价卖出、不会被 0 价拿走；**65 / 30 / 3 / 2 精确分配**，运营地址分批推送后自领拿到 0，只剩尘埃；**三种异常结局**（最长期限保底、VRF 安全退出、升级哨兵退出）都先退未出局者、剩余按投入分给所有人；底池不够退本金时按比例；基金会、手续费地址、调用者、买家都没有新增记账；无硅王奖；首轮一台没买到时全额退本金；领取期限过期转基金会、通行证仍可取回 |
| `Sentinel.t.sol` | 通行证信标升级后不能加入、立即退款、不再开新主板；矿机信标升级后暂停两次拍卖但照常开奖；只有未出局者能 emergencyExit；信标读不出来也算触发；触发后不能开局；**30 天冷静期**：冷静期内收购、终局拍卖、加入、开局、重开都被拒绝，满 30 天后矿机收购（新一轮）、终局拍卖、加入恢复，`reopen()` 重开冷静期内失败的主板，之后招募失败照常自动重开；冷静期内不能开局、满 30 天后可以；没人登记时一直暂停；信标恢复后登记清零（外部审计 #2） |
| `Hardening.t.sol` | 主网定稿前的内审修改：**哨兵登记随信标 implementation 变化作废**（升级 → 登记 → 恢复 → 再次升级会重新进入冷静期；第二次升级后登记从调用时刻重新计 30 天；只有月局信标变化时只影响月局）；**构造参数校验**（VRF 重发间隔 ≥ 1 小时、所有时长 ≤ 10 年、招募期 / 收购期 / 准备期不能为 0、VRF 适配器的协调器 / 注册中心 / 回调 gas / 3–200 确认数）；mock 的 `protocolFee()` |
| `MachineMarkets.t.sol`（rc8） | PoD 真实字段（停挖、未验证池被拒）；倍数 6 的合集按 基础 × 6 计价、范围按计价算力查、最优加成不计价；合集核对（非工厂、代码不同的通行证合集被拒）；`syncMachine` 识别停挖；多合集卖出和交接；`MarketTrader` 从官方市场 / Seaport 买入；接受 Seaport 单台和整合集 WBNB 出价；`MachineLister` 挂单 → 官方市场 / Seaport 成交结算（主板拿到不低于成交时公式价，另一边撤单）；公式价上涨后旧挂单成交回滚、改价后成交、旧 Seaport 单按旧参数撤掉；撤单权限；直接按公式价买 / 接受出价 / 交接时先撤回寄售的矿机；寄售期间产出转回；哨兵冷静期暂停；官方市场改成"先记账"时的提款退路；标准局挂单成交的溢价分成和拍卖期改价 |
| `MarketTrader.t.sol` | rc5 的 Firsto 买卖（吃卖单、卖给统一买单、滑点、主板规则、溢价分成、两种局完整流程），rc8 起合约名改为 MarketTrader |
| `probe/*`（默认跳过） | 主网分叉探针：Firsto（`FirstoProbe`、`MarketTraderFork`、`SwapCostFork`，`FIRSTO_PROBE=1`）、官方矿机市场 / Seaport / PoD 字段（`MarketProbe`、`SeaportProbe`、`PoDWordsProbe`，`MARKET_PROBE=1`）、rc8 真实市场集成（`MarketModulesFork`） |
| `SizeLimits.t.sol` | 按部署顺序、带默认构造参数把全部生产合约部署一遍；在 `FOUNDRY_PROFILE=sizecheck`（`code_size_limit = 24576`）下由 EVM 真实执行 EIP-170 / EIP-3860 |
| `Splitter.t.sol` | creator = 分账合约；"第 i 块主板"按两种局合计的开局顺序（月局部分见 `Month.t.sol`）；**40 / 10 / 20 / 30** 与 10 : 8 : 5 : 4 : 3；**50 / 0 / 20 / 30** 备选比例；比例之和必须 100%；路径必须 WBNB → … → BEM；直接转入的 BNB 也计入收入；回购限额、间隔、转入 dEaD；TWAP 最低成交量；调用者自定的最低成交量；领取回馈并入主板采购预算并开启新一轮收购；只认处于 Active 的第 i 块主板；已结束主板那一桶转入回购；withdraw 失败不阻塞；**基金会 / 项目方拒收 BNB 时改为记账**，不卡住分账和回购，之后用 `withdrawOwed` 补转（外部审计 #7）；分账合约必须单独部署且 `boardFactory` 正确 |
| `Factory.t.sol` | 开局条件（7 天 / 10,000 颗）、只能开局一次、开局前先分账；开局后自动开下一块；只有招募中的主板能回报；主板不能被重复初始化；参数公开；参数校验 |
| `EjectionTree.t.sol` | **穷举精确验证**：白皮书例子 1 / 20 / 79 在 200 个 r 上恰好被抽中 99 / 80 / 21 次；有人出局后仍然精确；1 / 20 / 5 / 10 / 64；模糊测试：二进制下降与线性扫描结果一致、最大值线段树正确 |
| `Statistics.t.sol` | 大量模拟开局：1 / 20 / 79、1 / 20 / 5 / 10 / 64、1 / 1 / 2 / 5 / 10 / 20 / 20 / 41 各 2 万局，60 人小数投入 2,000 局。硅王频率与 wᵢ / S（`模拟/反推出局概率.py` 的精确值）的偏差都在 5σ 以内；卡方统计量 0.32 / 4.95 / 2.35 |
| `Conservation.t.sol` | 端到端（500 / 20 与 1,000 / 20 两组）：小数投入、按时间产出、回馈补贴、4 台矿机、终局拍卖跨多轮、一半人自领一半人由运营地址分批推送；正常终局、最长期限保底、VRF 安全退出、升级哨兵退出四种结局都满足"流入 = 各方实际收到的 BEM + 余额"（按余额变化核算，取消 0.5% 后），只剩尘埃；没有调用者奖励；异常结局中基金会和手续费地址没有新增记账 |
| `VRFAdapter.t.sol` | 只有主板能请求、只有协调器能回调；请求参数（keyHash、订阅号、确认数、回调 gas、numWords、extraArgs）；通过适配器完成一次抽签；500 人的标准局回调约 24.6 万 gas；**月局通过适配器开奖**，回调只记随机数（约 7.4 万 gas） |
| `Month.t.sol` | 开局同时开出两种局；月局招募四种结果（1 天内 × 1.25、1–3 天不变、≥ 60% 按实际开局 × 0.75、< 60% 退款 × 0.5 到 100 为止）；两种局各自排队；同一张通行证不能同时锁在两块主板里；首批回馈按两种局合计的开局顺序；回馈并入月局采购预算；准备期 3 天收购、期满开始 30 天挖矿；一台矿机都没买到时原样退还本金；挖矿期产出进奖金池；开奖时 3% / 2% 与 60 / 15 / 15 / 5 / 5（可重复中奖）**直接推送**；**drawPrizes / finalizePrizes 运营地址专属、参与者 3 天兜底、外人始终被拒**；奖金池为 0 时不请求 VRF；VRF 24 小时重发只认最新请求；随机数到账后不能重发、不能走停摆；**VRF 停摆 7 天按比例分、不收 3% / 2%**；升级哨兵：不能加入、参与者可以提前结算、拍卖暂停、已到期的局必须正常开奖；领取期限；只有月局工厂能登记开局顺序；地址预测校验；不能重复初始化；**招募失败的退款由运营地址分批推送、参与者 3 天兜底、重复调用不重复支付**；**30 天冷静期**：冷静期内月局不能加入、招募失败不重开，满 30 天后 `reopen()` 重开、可以加入（外部审计 #2） |
| `MonthSettlement.t.sol` | **交接**按成本价转给正在准备矿机的月局；**成本价高于接手方上限时拒绝**；接手方预算不够时只接一部分；只能在月局之间、且接手方在准备期；**交接运营地址专属、参与者 3 天兜底、外人始终被拒**；**挂单价 < 成本价被拒绝**，只有运营地址能挂单；**1 天未挂单自动按成本价挂**，之后不能调高；**第一次挂单满 7 天自动降到成本价**（改价不重新计时），之后不能再调高；溢价卖出时本金和溢价都归参与者；**卖不出继续挖**，产出由运营地址推送、不收费；被撤销的矿机不降价出售；**回馈资本滚入下一块月局**；**分批推送 + 自领不重复支付**、通行证全部退还；**资金守恒**（交接 + 溢价挂单 + 成本价成交 + 继续挖矿 + 推送 + 自领，每人至少拿回本金，只剩尘埃）；**收购价上限是开局时的快照**，准备期内不随 PoD 变化（外部审计 #3）；**哨兵触发满 30 天后恢复出售**（外部审计 #2） |
| `MonthStats.t.sol` | 按投入比例抽取的穷举精确验证；5 个奖各自的中奖频率 ≈ 投入占比（1 / 20 / 79、8 人、40 人小数投入，5σ 以内）；**独立性**：头奖与第一个二奖落在同一人的频率 ≈ Σ pᵢ²（13,281 对理论 13,284） |
| `TwapOracle.t.sol` | TickMath 已知值（0、±1、MIN / MAX）；多跳报价；窗口 ≥ 30 分钟；路径校验 |
| `ForkBSC.t.sol`（需要 `BSC_RPC_URL`） | 合约调用 `createCPU` 成为 creator；`minted()` 按颗计数；`owed(creator)` 与 `withdraw()` 打给 creator；在真实电路合约上流片通行证，哈希一致、`eval(0x03) = 0x02`、`circuitInfo = (2, 2, 0, 5)`；getMiner 字段位置；每单位产出；矿机转给合约后产出归新持有者、转账不停止挖矿、合约可以 stop；**整套系统部署在主网状态上**：25 张真实通行证加入、收购 #10901、一天后领到产出 |

---

## 8. 推断与待确认项

### 已经在主网分叉上确认（2026-10-19，只读）

1. **`createCPU` 由合约调用时 creator = 调用合约**；`deployFee() = 0.001 BNB`。
2. **`withdraw()`**：creator 调用后收到 `owed(creator)` 的 BNB（铸 5 颗得到 0.005 BNB）。`minted()` 按晶体管颗数计。
3. **getMiner 字段**：返回 22 个 32 字节字。[0] 电路合约、[1] 编号、[3] 权重、[7] 在挖、[8] 时间戳、[9] 已验证、[10] 登记人，与推断一致。合约按字的位置读取（`PoDReader`），没有用 `abi.decode`。`tryRead` 会核对返回的电路合约地址和编号与查询的矿机一致，不一致时当作读取失败（外部审计 #5）。
4. **创世电路合约和官方矿机电路合约共用同一个信标** `0xf8D6…8156`，所以升级哨兵在主网上监控的其实是同一个信标。
5. **矿机转移**：真实执行 `transferFrom` 后，矿机仍在挖、仍为已验证；之后的 `claim` 付给新持有者（合约），原主人收不到。
6. **`pending()` 只是下限**：`claim` 时 PoD 会先把累计量更新到当前时间，实际付的比 `pending` 显示的略多；而且 `pending` 不随时间自动增长。因此 `sellMachine` 改为成交前**总是**用 try/catch 调一次 `claim`，不再依赖 `pending > 0`。

### 仍需确认或请你决定

1. **getMiner [8] 的含义**：推断是"开挖时间"，用来检查"已运行 ≥ 7 天"。如果它其实是别的时间（比如最近一次抽检），只需改 `PoDReader.WORD_SINCE`，或把 `minMachineAge` 设成 0 关掉这项检查。
2. **PoD 没有可领产出时 `claim` 是否 revert**：合约里都用 try/catch 包住，两种情况都能正常运行。
3. **`currentRate()` 的含义**：主网读到 8,333,333（每秒 0.0833 BEM，即每天 7,200 BEM）。采购价上限依赖它和 `totalVerifWeight()`。2030 年减半后上限会自动跟着减半。
4. ✅ **已决定（2026-10-19）**：SafeExit（VRF 停摆 7 天）和 emergencyExit（升级哨兵）都统一用最长期限保底的公式：先退未出局者的投入（不够按比例），剩余按投入分给所有参与者（含已出局者），不发硅王奖。`SettleMode` 仍然区分 `Fallback` 和 `SafeExit`，只用来记录触发原因，分配公式完全相同。
5. ✅ **已决定（2026-10-19）**：异常结局不收 3% 基金会和 2% 手续费。正常终局（65 / 30 / 3 / 2）和每次出局的脉冲（95 / 3 / 2）不变。之后又决定（见下面"运营地址方案"）取消所有调用者奖励。
   **为什么异常结局的入口保持任何人可调、也不需要奖励**：每一个入口都有人有动力触发，不会卡住——
   - `expire()` / `triggerSafeExit()` / `emergencyExit()`：未出局的参与者会优先取回投入，他们最有动力触发（`emergencyExit` 本来就只允许未出局者调用）；
   - `buyMachine()`：买家为了买到矿机自己会调用；
   - `harvest()` / `sweep()`：参与者想多领就会调用；而且 `withdraw()` 每次都会先 sweep，卖矿机也会自动 sweep；不调用也不会丢钱，产出会一直留在 PoD 里，等下一次领取；
   - 唯一可能"没人管"的情况是参与者都不再关心，这时资金也不会丢：领取期满后由 `closeClaims()` 转到黑洞地址销毁。
6. **最后一笔超出剩余额度**：选的是"**只接受到恰好满额**"（多出的不收）；剩余额度小于最小投入时，也可以直接投恰好等于剩余额度的金额。
7. **金额取整**：调整后的目标**向下取整**到 1 BEM（例如 781.25 → 781，140.5 → 140），然后限制在 100–1,000 之间。
8. **`emergencyExit` 的发起人**：只有未出局的参与者可以发起，避免外人在一次无害的升级后强行结束牌局。任何一个未出局的人都可以发起（不需要投票）。
9. **终局拍卖卖不出时**：不强制贱卖，按"底价停 7 天 → 重新拍卖"循环，期间产出照常分配。只要还有矿机没卖出，领取期限就不开始计算。
10. **主网兑换路由和池子**：需要确认 PancakeSwap V3 SwapRouter（v3-periphery 版本，带 deadline）的地址；WBNB/USDT 池的费率档（默认按 0.01% 编码）；BEM/USDT 1% 池的地址，以及两个池子的 observation cardinality 是否覆盖 30 分钟（不够的话 `observe` 会 revert，回购会暂停，不会按坏价格成交）。
11. **VRF 订阅**：订阅的所有者（一个 EOA 或你的 Safe）需要把适配器加为 consumer 并充值。订阅所有者可以取消订阅，这是 VRF 订阅制本身带来的外部依赖；取消后会走"24 小时重发 / 7 天安全退出"的兜底规则。
12. **开始铸造时间**：以分账合约部署（`createCPU`）的时刻作为"开始铸造"计时起点。假设处理器创建后立即可以铸造，分叉测试中确实可以立即铸造。

### 月局：实现时的取舍与和规格的出入（✅ 已确认（2026-10-19））

1. **开奖分两步**（和规格措辞不同，但结果一样）：实测在 VRF 回调里一次做完 5 次抽取、记账、开始结算，会超过当时 50 万的回调 gas 上限（现在默认 75 万），回调失败后这一局只能等 7 天停摆保底、发不出奖。所以改成 Chainlink 推荐的做法：回调只记下随机数（约 7.4 万 gas），之后运营地址调用 `finalizePrizes()` 完成抽奖、推送奖金并进入结算（3 天后参与者兜底）。随机数到账后就不能再重发，也不能再走停摆保底，只能用这个随机数开奖。
2. **"下一块已招满的月局"怎么认**：同类型的上一块开局时就开出下一块，而一局要挖 30 天，所以同时会有很多块月局在挖矿。一块月局局终时，"下一块"在合约里理解为**任何一块正在准备矿机的月局**（同一个 MonthFactory 创建、处于 3 天准备期内）。交接由运营地址调用 `relayMachine(index, 接手方)` 发起，结算期间任何时候都可以（3 天后参与者兜底）。
3. ~~接力优先期 + 120% 降价拍卖 + 每 7 天重拍~~：已被"先交接、交接不了就挂单"取代，规则见第 4、5 节。
4. **准备期固定 3 天**：不会因为买够了矿机就提前开始挖矿（提前开挖需要判断"已经买够"，容易被人钻空子）。挖矿从准备期结束时开始计 30 天。一台矿机都没买到时，直接结算、原样退还本金。
5. **奖金池的范围**：从开局到 `drawPrizes`（请求开奖，它会先领取一次产出）为止领取的全部产出（准备期、30 天挖矿期）。请求开奖时奖金池就定死；之后到账的产出（等待随机数、随机数到账到 `finalizePrizes` 之间，以及结算期间）都按投入比例分给参与者，不收 3% / 2%。不抽奖结算（VRF 停摆、升级哨兵）同样如此。（项目方 2026-10-21 决定，TapeCode 第二轮 A1；和 X Layer 版一致。）
6. **收回资本的顺序**：先退参与者的本金，再收回回馈资本（滚给下一块月局），最后超出成本的部分（拍卖溢价）按投入比例分给参与者。规格没有说溢价归谁，这里按"收益归参与者"处理。如果有矿机长期卖不出去，先受影响的是回馈资本，参与者的本金优先收回。
7. **回馈的领取时段**：月局开局后、开奖前（准备、挖矿、等待开奖）都可以领取首批回馈。准备期内到账的会继续用来买矿机；准备期之后到账的留在主板，局终和其他回馈资本一起滚给下一块月局。月局结算开始即视为"已结束"，它那一桶的新增收入转入回购。
8. **回馈资本滚存**：局终收回的回馈资本转到 MonthFactory，**下一块开局的月局**一次全部拿走，并且继续算作回馈资本（不属于参与者），这样一直滚下去。
9. **挂单价按整台计**，不按权重计价，底线是成本价。被撤销或降级的矿机也照样按成本价挂单，不会降价，所以这部分本金可能很久拿不回来（规格已经提示这一风险；外部审计 #1 提出后，项目方 2026-10-20 决定维持现状）。只要还有矿机没卖出，领取期限就不开始计时。
10. **提前结算的范围**：`emergencySettle()` 只能对还没到期的局发起（准备期中，或挖矿未满 30 天），任何参与者都可以发起；已经到期的局照常开奖。
11. **最后一笔超额**：和标准局一样，只接受到恰好满额为止。

### 运营地址方案：实现时的取舍（✅ 已确认（2026-10-19））

1. **标准局脉冲的兜底计时用近似**：合约不记录"脉冲池达到门槛"的时刻，参与者兜底的起算时刻用"开局或上一次出局"（`lastPulseAt`）。也就是说，距上一次出局超过 3 天、而且脉冲池已经够门槛时，参与者就可以推进；如果运营地址在第 2 天就按时推进，参与者不会有机会抢先。
2. **运营地址为 0 时参与者不用等 3 天**：规格说"这时只剩参与者兜底"。没有运营地址可等，所以参与者随时可以执行（`setListing` 无人可调，矿机 1 天后自动按成本价挂单）。
3. **挂单没有参与者兜底**：结算开始 1 天内运营地址没挂单的矿机，会自动按成本价挂单并锁定，参与者兜底已经没有意义，所以 `setListing` 只有运营地址能调。
4. **"1 天内没挂单"之后也视为锁定**：规格写的是"1 天未挂单 → 按成本价挂单"，"成本价以后不能再调高"写在 7 天规则里。合约把两种"变成成本价"都视为锁定，运营地址错过 1 天就不能再挂高价，以保护参与者。
5. **月局"进入结算时退还全部通行证"改为分批**：一块月局最多约 500 人，在进入结算的那笔交易里一次退还全部通行证 gas 太大，而且这笔交易可能是 VRF 相关的开奖交易。所以通行证随 `distribute(fromSlot, count)` 分批退还，本人也随时可以 `returnPass` / `claimAll`。进入结算后通行证立即可以领回。
6. **标准局出局时的 3% / 2% 仍记账**：为了控制 VRF 回调的 gas，只推送 105% 和退还通行证；基金会和手续费 Safe 的份额记在它们名下，任何人都可以 `withdraw(Safe 地址)` 转过去。月局开奖不在 VRF 回调里，所以 3% / 2% 直接推送。
7. **推送失败的兜底**：标准局出局时推送 105% 用的是不会 revert 的底层调用，失败就改为记账；退通行证失败就保留记录。目的是保证 VRF 回调一定成功。正常情况下（BEM 是普通 ERC20）不会触发。
8. **合约体积**：为了把两份主板合约控制在 24 KB 以内，月局去掉了 `syncMachine`（月局只挖 30 天，被撤销矿机的领取失败已经由逐台 try/catch 处理）和 `previewWinners` 视图；几个内部时间戳改成 internal。

### 外部审计第 2、3、6 条：实现时的取舍（2026-10-20）

1. **30 天从第一次链上登记算起**：链上读不到信标是什么时候升级的，所以注册中心 `BoardFactory` 记录"第一次观察到哨兵触发"的时间（`sentinelSince`，两种局共用），30 天从这时算起。任何人都可以调用 `BoardFactory.noteSentinel()` 登记，参与者提前退出 / 提前结算时也会顺带登记。哨兵触发后，运营地址应尽快调用一次，否则冷静期不会开始计时，一直暂停。
2. **冷静期过后全部恢复（方案 A）**：最初只恢复矿机收购和出售；项目方 2026-10-20 选了方案 A，加入和开新主板也一起恢复。冷静期内招募失败的主板工厂不会自动重开（这时 `recruitingBoard` 为 0），冷静期结束后需要有人调用 `BoardFactory.reopen()` / `MonthFactory.reopen()`（任何人可调）重开；之后的招募失败照常自动重开。
3. **快照失败时补拍一次**：本轮收购开始时如果读不到 PoD 产出速率，快照为 0、收购暂停；本轮第一次有人卖矿机（月局还包括交接进来）时补拍一次，之后本轮都按它计价。这样 PoD 一时读不到不会让整轮收购作废（标准局首轮一台都买不到会全额退本金结束）。
4. **测试网滑点不变**：`TapeSurgeDefaults.MAINNET_MAX_SLIPPAGE_BPS = 200` 是主网默认值；`DeployTestnet` 用 `TESTNET_MAX_SLIPPAGE_BPS = 300`，测试网和之前一样。
5. **合约体积**：加了冷静期之后，TapeBoard 24,459 B（余量 **117**）、MonthBoard 24,376 B（余量 200），还放得下，没有挪逻辑进库合约。以后再改主板合约，几乎都需要先把部分逻辑挪进库合约。

### 主网定稿前的内审修改（2026-10-20 / 21，项目方确认）

1. **哨兵登记会过期（F1）**：原来信标恢复后如果没人调用 `noteSentinel()` 清零，旧的登记时间会一直留着，之后再升级一次就没有冷静期。现在 `BoardFactory` 登记时同时记下两种局监控的全部信标当时的 implementation（指纹）；`sentinelSince()`（ABI 不变）发现 implementation 和登记时不同就返回 0，`noteSentinel()` 遇到变化时重新计时。剩下的边界情况：信标恢复后又升级回**完全相同**的 implementation，而中间没人调用过 `noteSentinel()`，会沿用旧的登记时间。运营机器人发现哨兵触发或恢复时都应调用一次。
2. **快照时机（F2）**：每轮收购开始时快照上限，新一轮可以由任何人通过 `claimReward` 触发。维持项目方的决定"本轮都按快照值"，列为已知问题，请审计方评估 PoD 的已验证总权重能不能在一笔交易里被临时改变。
3. **构造参数校验（F3）**：两份主板合约要求 `vrfRetryDelay ≥ 1 小时`、所有时长 ≤ 10 年、招募期 / 收购期（标准局）/ 准备期（月局）> 0；VRF 适配器要求协调器和注册中心非零、回调 gas > 0、确认数 3–200。只影响初始化代码，用默认参数部署时运行时字节码（除元数据哈希外）和修改前逐字节相同。测试网快速模式下 VRF 重发 / 安全退出两个时长不低于 1 小时（测试网用 Mock 随机数，不影响演练）。

### 已知限制

- **合约大小**：TapeBoard 运行时 23,955 B、MonthBoard 运行时 23,994 B（上限 24,576 B，余量只有约 0.6 KB，之后再加功能就需要拆库或拆合约）；BoardFactory 初始化代码 46,922 B、MonthFactory 初始化代码 34,834 B（上限 49,152 B）。为了省空间，主板的数值参数是 internal，统一从 `BoardFactory.boardConfig()` / `MonthFactory.boardConfig()` 读取。
- **代码重复**：月局的招募、通行证校验、升级哨兵、各自领取这几部分与标准局基本相同，是复制后按月局调整的（没有抽成共同的基类，以免改动已经测试过的标准局）。审计时两边要一起看。
- **`forge lint`**：剩下的提示都已逐类检查过。重入类：所有外部入口都有 `nonReentrant`，外部合约是 BEM / PoD / 电路 / 适配器 / 固定的 Safe。时间戳比较：期限规则本来就依赖区块时间。类型转换：都在有界范围内。"锁定 ETH"：只出现在 Mock 里。
- 合约还**没有经过审计**。白皮书承诺审计完成前不部署主网。
