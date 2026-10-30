# deployments

`script/DeployTestnet.s.sol` 在设置 `WRITE_DEPLOYMENT=1` 时，把部署出的合约地址写到这里的 `<chainId>.json`（BSC 测试网是 `97.json`），
`script/TestnetScenario.s.sol` 从这里读取。这些文件只包含合约地址，不包含任何私钥。

`97-v2.json` 是 v2 测试网部署（`DEPLOY_NAME=97-v2`），`bemPerBnb` 是 mock 预言机 / 路由的汇率（主网量级 × mock 费用缩小比例 100）。
`bash script/testnet.sh firsto` 生成两份模拟 Firsto 订单（只在测试网有效，订单在 mock 合约上）：

- `97-v2-firsto-asks.json`：卖单，格式同主网 `GET /v1/circuits`（`rows[].bestAsk.execution` 直接组成 `FirstoTrader.buyFromAsk` 的 `AskOrder`，`rows[].mining` 是权重和预计日产出）。mock 卖单合约不验签名和 Merkle 证明，`signature` 为 `0x`、`merkleProof` 为空。
- `97-v2-firsto-bids.json`：统一买单，格式同主网 `GET /v1/circuit/capacity-bids` 的 `bids[]`（链上状态以 `MockFirstoBidExchange.bid(orderId)` 为准）。
- `97-v2-tape-feed.json`（`bash script/testnet.sh markets` 生成）：模拟 tapeout.market 行情，格式同 `GET /api/v1/circuit-market/feed`（`{"items": [...]}`）。`listing.source` = `TAPEOUT_OFFICIAL`（mock 官方矿机市场，`listingId` 直接给 `MarketTrader.buyFromOfficial`，`buyerPaysWei` = 挂单价）或 `TAPEMARKET_SEAPORT`（mock Seaport，`buyerPaysWei` = 对价项之和，按 `orderHash` 去下一个文件取完整订单）；两种来源各 4 台，至少一台是模拟 Behemoth（倍数 6）；最后一台算力 5，故意不合格，机器人应该跳过（主板会拒收）。`capacityPriceWei` = 买家实付 × 1e8 ÷ 预计日产出。
- `97-v2-tape-listings.json`：`{"<orderHash>": {"status": "ACTIVE", "parameters": {...}, "signature": "0x"}}`，格式同 tapeout.market `GET /api/v1/listings/<orderHash>`（parameters 是 Seaport `OrderComponents` 各字段，数字用字符串；链上已 `validate`，签名为空，可以直接组 `AdvancedOrder(parameters, 1, 1, "0x", "0x")` 调 `MarketTrader.buyFromSeaport`）。
- `97-v2-seaport-offers.json`：部署者用 MockWBNB 建的两张合集出价（`MarketTrader.sellToOffer` 用，`criteriaResolvers` 给出矿机编号）。
