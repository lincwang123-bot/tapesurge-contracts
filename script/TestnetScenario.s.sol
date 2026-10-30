// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";
import {StdMachineSales} from "../src/StdMachineSales.sol";
import {console2} from "forge-std/Script.sol";
import {DeployTestnet} from "./DeployTestnet.s.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {MonthFactory} from "../src/MonthFactory.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthMachineSales} from "../src/month/MonthMachineSales.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {MockBEM} from "../src/mocks/MockBEM.sol";
import {MockPoD} from "../src/mocks/MockPoD.sol";
import {MockCircuits} from "../src/mocks/MockCircuits.sol";
import {MockTransistors} from "../src/mocks/MockTapeOut.sol";
import {MockRandomSource} from "../src/mocks/MockRandom.sol";
import {MockFirstoAskExchange, MockFirstoBidExchange, MockFirstoSwapper} from "../src/mocks/MockFirsto.sol";
import {MockPriceOracle} from "../src/mocks/MockSwap.sol";
import {PoDReader} from "../src/libraries/PoDReader.sol";
import {MockOfficialMarket, MockSeaport, MockWBNB} from "../src/mocks/MockMarkets.sol";
import {
    Order, OrderComponents, OrderParameters, OfferItem, ConsiderationItem
} from "../src/market/IMarkets.sol";
import {TapeSurgeDefaults} from "./TapeSurgeDefaults.sol";

/// @title 测试网分阶段场景脚本（配合 DeployTestnet.s.sol，建议 TESTNET_FAST=1 部署）
/// @notice 每个阶段单独执行，阶段之间等链上时间推进（快速参数下 1 天 = 2 分钟）。
///
///   BSC 测试网上用 script/testnet.sh 按阶段执行（bash script/testnet.sh <阶段>，顺序见那个文件开头）：
///   它读取 .env.testnet、每个阶段先确认链 ID 是 97、带 --slow 广播，并把私钥、种子和 RPC 地址从输出里遮掉；
///   KEY_SOURCE=anvil 时改为在本地 anvil 上演练。也可以直接执行：
///     STAGE=<阶段> forge script script/TestnetScenario.s.sol --rpc-url <bsc-testnet> --broadcast --slow
///       --private-key <部署者私钥>（或 --account <keystore 名>）
///
///   部署者（= 运营地址、矿机卖家、买家）用命令行的 --private-key 或 --account 签名，脚本里不写任何私钥；
///   玩家的测试私钥在运行时由环境变量 TEST_MNEMONIC 派生（助记词，或 32 字节十六进制种子），只存在于本次执行的内存里。
///   只能在 BSC 测试网（chainid 97）或本地内存链（31337）上运行。
///
///   阶段（STAGE）：
///     status      打印各主板状态和时间点
///     fund        部署者给玩家 [PLAYER_FROM, PLAYER_FROM + PLAYER_COUNT) 每人转 FUND_WEI（默认 = 通行证费用 + 0.001 tBNB）
///     mint        玩家各铸 5 颗创世 NAND、流片 HA1 通行证，并领 100 MockBEM
///     genesis     开局（快速参数下部署 14 分钟后）
///     close       关闭已过招募期的月局（招募失败，工厂接着开下一块）
///     join        手上有通行证的玩家加入当前招募中的主板（BOARD=std | month），招满为止；STAKE_MODE=max 时每人投最大额。
///                 测试网上距招募截止不到 JOIN_MARGIN 秒（默认 300）时拒绝执行，等它过期后先 close
///     reward      领取首批回馈：REWARD_RANK=i（两种局合计的开局顺序，1–5），任何人可调
///     machines    部署者铸模拟矿机、登记到 MockPoD、卖给主板（BOARD=std | month，MONTH_NUMBER 指定月局编号）
///     yield       给主板的矿机注入产出（标准局：补到开奖门槛；月局：先 sync 进入挖矿，再注入 YIELD_BEM，默认 10）
///     pulse       标准局：运营地址推进开奖（MockRandomSource 时顺带交付随机数）；REPEAT=n 连续 n 次（仅 Mock 随机数）
///     draw        月局：同步阶段并开奖（drawPrizes；Mock 随机数时顺带交付并 finalizePrizes）
///     finalize    月局：用已到账的 VRF 随机数完成开奖（Chainlink 随机数时用）
///     settle      标准局：买走终局拍卖中的矿机；月局：交接第 0 台给 RELAY_TO 号月局、第 1 台挂 120%、买走所有可买的
///     distribute  运营地址分批打款并退还通行证（BATCH，默认 100）
///     fallback    运营地址兜底：运营地址超过 operatorGrace（快速参数 6 分钟）没执行时，由本局一位参与者代为执行。
///                 标准局：参与者推进脉冲（部署者先补产出、事后交付 Mock 随机数）；月局：参与者分批打款
///     sweep       玩家把剩下的 tBNB 退回部署者（每人留 GAS_PRICE_WEI × 50,000 付手续费；SWEEP_KEEP_WEI 可改留存额）
///     markets     模拟 tapeout.market 的两个来源（只跑一次）：玩家 [PLAYER_FROM, PLAYER_FROM + PLAYER_COUNT)（默认 3 人）
///                 各持两台模拟矿机（官方合集 / 模拟 Behemoth 交替），一台挂到 MockOfficialMarket，一台在 MockSeaport 上链上挂单；
///                 部署者用 MockWBNB 建两张合集出价。行情按 tapeout.market feed 格式写到 MARKET_FEED_FILE，Seaport 完整订单
///                 和出价写到 SEAPORT_ORDERS_FILE。价格以报价合约的买一 / 卖一为准（同 firsto 阶段）
///     firsto      模拟 Firsto 市场（只跑一次）：部署者给玩家 [PLAYER_FROM, PLAYER_FROM + PLAYER_COUNT) 各铸 2–3 台模拟矿机并登记，
///                 玩家对 MockFirstoAskExchange 授权；按主网 API 格式生成卖单，写到 FIRSTO_ASKS_FILE；部署者在
///                 MockFirstoBidExchange 上建 3 张统一买单（买单列表写到 FIRSTO_BIDS_FILE），并把 MockFirstoSwapper 的 tBNB
///                 补到 FIRSTO_SWAPPER_TARGET。价格以报价合约当前的买一 / 卖一为准（报价无效时部署者先报一次价）
///     all         只在本地内存链（chainid 31337）上：按测试网的顺序一次性跑完全部阶段（用 vm.warp 推进时间），验证脚本并统计 gas
contract TestnetScenario is DeployTestnet {
    bytes internal constant PASS_NETLIST = hex"0000000200000300000002000004000000030000040000000500000600000004000004";
    bytes internal constant MACHINE_NETLIST = hex"00000002000003";
    uint256 internal constant BEM_1 = 1e8;
    /// @dev 只用于本地内存链上的 STAGE=all 模拟：Foundry / Hardhat 公开的开发助记词（任何人都知道，绝不能用于真实资金）
    string internal constant LOCAL_DEV_MNEMONIC = "test test test test test test test test test test test junk";

    // 已部署的合约
    BoardFactory internal f;
    MonthFactory internal mf;
    MonthMachineSales internal msales;
    GenesisSplitter internal sp;
    MockBEM internal mbem;
    MockPoD internal mpod;
    MockCircuits internal mmachines;
    MockTransistors internal tr;
    MockCircuits internal pass;
    MockRandomSource internal mockRng; // 0 = 用 Chainlink VRF

    address internal deployer;
    string internal mnemonic;
    uint256 internal txCount; // 粗略统计交易笔数（用于估算固有 gas）

    function run() public override {
        string memory stage = vm.envOr("STAGE", string("status"));
        if (_eq(stage, "all")) return _all();
        _requireTestnet();
        _load();
        mnemonic = vm.envOr("TEST_MNEMONIC", string(""));
        (, deployer,) = vm.readCallers();
        if (_eq(stage, "status")) return _status();
        if (_eq(stage, "fund")) return _fund(_from(), _count(), _fundAmount());
        if (_eq(stage, "mint")) return _mintPasses(_from(), _count());
        if (_eq(stage, "genesis")) return _genesis();
        if (_eq(stage, "close")) return _close();
        if (_eq(stage, "join")) {
            _join(_isStd(), _from(), _count());
            return;
        }
        if (_eq(stage, "machines")) return _machines(_isStd());
        if (_eq(stage, "reward")) return _reward(vm.envOr("REWARD_RANK", uint256(1)));
        if (_eq(stage, "yield")) return _yield(_isStd());
        if (_eq(stage, "pulse")) return _pulse(vm.envOr("REPEAT", uint256(1)));
        if (_eq(stage, "draw")) return _draw();
        if (_eq(stage, "finalize")) return _finalize();
        if (_eq(stage, "settle")) return _settle(_isStd());
        if (_eq(stage, "distribute")) return _distribute(_isStd());
        if (_eq(stage, "fallback")) return _fallback(_isStd(), _from(), _count());
        if (_eq(stage, "sweep")) return _sweepPlayers(_from(), _count());
        if (_eq(stage, "firsto")) return _firsto(_from(), vm.envOr("PLAYER_COUNT", uint256(4)));
        if (_eq(stage, "markets")) return _markets(_from(), vm.envOr("PLAYER_COUNT", uint256(4)));
        revert(string.concat("unknown STAGE: ", stage));
    }

    // =====================================================================
    // 读取部署
    // =====================================================================

    function _load() internal {
        string memory path =
            vm.envOr("DEPLOYMENT_FILE", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        string memory json = vm.readFile(path);
        f = BoardFactory(vm.parseJsonAddress(json, ".factory"));
        mf = MonthFactory(vm.parseJsonAddress(json, ".monthFactory"));
        msales = MonthMachineSales(vm.parseJsonAddress(json, ".monthSales"));
        sp = GenesisSplitter(payable(vm.parseJsonAddress(json, ".splitter")));
        mbem = MockBEM(vm.parseJsonAddress(json, ".bem"));
        mpod = MockPoD(vm.parseJsonAddress(json, ".pod"));
        mmachines = MockCircuits(vm.parseJsonAddress(json, ".machines"));
        tr = MockTransistors(vm.parseJsonAddress(json, ".transistors"));
        pass = MockCircuits(vm.parseJsonAddress(json, ".passCircuits"));
        priceFeed = MarketPriceFeed(vm.parseJsonAddress(json, ".priceFeed"));
        oracle = MockPriceOracle(vm.parseJsonAddress(json, ".oracle"));
        firstoAsk = MockFirstoAskExchange(payable(vm.parseJsonAddress(json, ".firstoAskExchange")));
        firstoBid = MockFirstoBidExchange(vm.parseJsonAddress(json, ".firstoBidExchange"));
        firstoSwapper = MockFirstoSwapper(payable(vm.parseJsonAddress(json, ".firstoSwapper")));
        officialMarket = MockOfficialMarket(vm.parseJsonAddress(json, ".officialMarket"));
        seaport = MockSeaport(vm.parseJsonAddress(json, ".seaport"));
        wbnbToken = MockWBNB(payable(vm.parseJsonAddress(json, ".wbnb")));
        behemoth = MockCircuits(vm.parseJsonAddress(json, ".behemoth"));
        if (vm.parseJsonBool(json, ".mockRandom")) {
            mockRng = MockRandomSource(vm.parseJsonAddress(json, ".randomSource"));
        }
    }

    function _useDeployed() internal {
        f = factory;
        mf = monthFactory;
        msales = monthSales;
        sp = factory.splitter();
        mbem = bem;
        mpod = pod;
        mmachines = machines;
        tr = MockTransistors(address(factory.transistors()));
        pass = MockCircuits(factory.passCircuits());
        mockRng = MockRandomSource(randomSource);
    }

    // =====================================================================
    // 各阶段
    // =====================================================================

    /// @dev 第 i 个玩家（派生编号 i + 1，第 0 个留给别的用途）。种子是助记词时按 BIP-44 派生；
    ///      是 32 字节十六进制时，私钥 = keccak256(种子, 编号) mod n。
    function _player(uint256 i) internal view returns (address who, uint256 pk) {
        bytes memory m = bytes(mnemonic);
        require(m.length > 0, "set TEST_MNEMONIC (test seed for player keys)");
        if (m.length == 66 && m[0] == "0" && (m[1] == "x" || m[1] == "X")) {
            pk = uint256(keccak256(abi.encode(vm.parseBytes32(mnemonic), i + 1))) % SECP256K1_N;
        } else if (m.length == 64 && _isHex(m)) {
            pk = uint256(keccak256(abi.encode(vm.parseBytes32(string.concat("0x", mnemonic)), i + 1))) % SECP256K1_N;
        } else {
            pk = vm.deriveKey(mnemonic, uint32(i + 1));
        }
        require(pk != 0, "bad player key");
        who = vm.addr(pk);
    }

    /// @dev 每个玩家需要的 tBNB：5 颗 NAND 的铸造价和协议费 + 流片费 + 1,000 万 gas（0.1 gwei）的手续费余量。
    ///      余量偏大，是因为 forge 按预估 gas × 1.3 检查余额，兜底打款的参与者一笔要两三百万 gas；用剩的最后由 sweep 退回。
    function _fundAmount() internal view returns (uint256) {
        return vm.envOr("FUND_WEI", (tr.mintPrice() + tr.protocolFee()) * 5 + pass.TAPEOUT_FEE() + 0.001 ether);
    }

    function _fund(uint256 from, uint256 count, uint256 amount) internal {
        uint256 sent;
        vm.startBroadcast();
        for (uint256 i = from; i < from + count; i++) {
            (address who,) = _player(i);
            if (who.balance >= amount / 2) continue;
            (bool ok,) = who.call{value: amount}("");
            require(ok, "fund");
            sent++;
            txCount++;
        }
        vm.stopBroadcast();
        console2.log("funded players", sent, "each (wei)", amount);
    }

    function _mintPasses(uint256 from, uint256 count) internal {
        uint256 price = (tr.mintPrice() + tr.protocolFee()) * 5;
        uint256 minted;
        for (uint256 i = from; i < from + count; i++) {
            (address who, uint256 pk) = _player(i);
            if (pass.lastMintedBy(who) != 0) continue;
            vm.startBroadcast(pk);
            tr.mint{value: price}(0, 5);
            pass.tapeout{value: pass.TAPEOUT_FEE()}(PASS_NETLIST, 2, 2);
            mbem.mint(who, 100 * BEM_1);
            vm.stopBroadcast();
            minted++;
            txCount += 3;
        }
        console2.log("passes minted now", minted, "transistors minted so far", tr.minted());
    }

    /// @dev 开局前必须报过价（全局审计 G-1）：机器人还没报过时，部署者（运营地址）先按"收购价上限 × 80%"报一次
    ///      （FEED_ASK / FEED_BID 可改，口径同主板的 _liveCap 和 _marketRef）
    function _genesis() internal {
        vm.startBroadcast();
        if (priceFeed.updatedAt() == 0) {
            (bool ok, uint256 perDay) = PoDReader.tryUnitYieldPerDay(address(mpod), firstoBid.VERIFIED_SHARE_BPS());
            require(ok && perDay > 0, "PoD rate unavailable");
            uint256 cap = perDay * f.boardConfig().buyCapDays;
            if (cap > f.boardConfig().buyMaxPrice) cap = f.boardConfig().buyMaxPrice;
            uint256 a = vm.envOr("FEED_ASK", cap * 80 / 100);
            uint256 b = vm.envOr("FEED_BID", a * 99 / 100);
            priceFeed.post(b, a);
            txCount++;
            console2.log("price feed posted by the deployer before genesis (bid, ask)", b, a);
        }
        f.startGenesis();
        vm.stopBroadcast();
        txCount++;
        console2.log("genesis started: standard board", f.recruitingBoard());
        console2.log("                 month board", mf.recruitingBoard());
    }

    /// @dev 招募期已过的月局：关闭（未达 60% 时招募失败、退款），工厂开出下一块
    function _close() internal {
        MonthBoard m = MonthBoard(mf.recruitingBoard());
        require(block.timestamp >= m.recruitDeadline(), "month board still recruiting");
        vm.startBroadcast();
        m.closeRecruitment();
        vm.stopBroadcast();
        txCount++;
        console2.log("closed month board", address(m), "state", uint256(m.state()));
        MonthBoard n = MonthBoard(mf.recruitingBoard());
        console2.log("now recruiting", address(n), "deadline", n.recruitDeadline());
    }

    /// @return next 下一个还没用过的玩家编号
    function _join(bool std, uint256 from, uint256 count) internal returns (uint256 next) {
        address board = std ? f.recruitingBoard() : mf.recruitingBoard();
        uint256 deadline = std ? TapeBoard(board).recruitDeadline() : MonthBoard(board).recruitDeadline();
        require(block.timestamp < deadline, "recruitment is over: run STAGE=close first (month board)");
        // 测试网上交易要一笔一笔上链：留足时间，避免后面几笔在截止之后才上链
        if (block.chainid != 31337) {
            require(
                block.timestamp + vm.envOr("JOIN_MARGIN", uint256(300)) <= deadline,
                "too close to the recruit deadline: wait for it to pass, then STAGE=close"
            );
        }
        uint256 joined;
        next = from;
        for (uint256 i = from; i < from + count; i++) {
            if (!_recruiting(board, std)) break;
            next = i + 1;
            (address who, uint256 pk) = _player(i);
            uint256 passId = pass.lastMintedBy(who);
            if (passId == 0 || pass.ownerOf(passId) != who) continue; // 没有通行证，或通行证还在别的主板里
            if ((std ? TapeBoard(board).holderCount(who) : MonthBoard(board).holderCount(who)) != 0) continue;
            uint256 lo = std ? TapeBoard(board).minStake() : MonthBoard(board).minStake();
            uint256 hi = std ? TapeBoard(board).maxStake() : MonthBoard(board).maxStake();
            uint256 amt = _eq(vm.envOr("STAKE_MODE", string("random")), "max")
                ? hi
                : lo + (uint256(keccak256(abi.encode(board, i))) % (hi - lo)) / 1e6 * 1e6;
            vm.startBroadcast(pk);
            if (mbem.balanceOf(who) < amt * 2) {
                mbem.mint(who, 100 * BEM_1);
                txCount++;
            }
            pass.approve(board, passId);
            mbem.approve(board, type(uint256).max);
            TapeBoard(board).join(passId, amt); // 两种主板的 join 签名相同
            vm.stopBroadcast();
            txCount += 3;
            joined++;
        }
        console2.log(std ? "standard board" : "month board", board);
        console2.log("  joined now", joined, "still recruiting", _recruiting(board, std));
        if (!std && !_recruiting(board, std)) console2.log("  month board number", MonthBoard(board).number());
    }

    /// @dev 部署者铸模拟矿机、登记到 MockPoD（开挖时间往前调 30 天）、卖给主板，直到预算不够。
    ///      先在本地试卖一次（_wouldSucceed），确认能成交才广播，不会把注定 revert 的交易发上链。
    ///      规则决定 6.37 起主板只认 MarketTrader，部署者不能再直接卖：模拟试卖不过就停（一台都不卖），
    ///      测试网的矿机改由机器人经 MarketTrader 去买 firsto / markets 阶段生成的模拟挂单。
    function _machines(bool std) internal {
        address board = std ? f.boardByNumber(vm.envOr("STD_NUMBER", uint256(1))) : _monthBoardFromEnv();
        uint256 n = vm.envOr("MACHINE_COUNT", std ? uint256(6) : uint256(4));
        uint256 w = vm.envOr("MACHINE_WEIGHT", std ? uint256(90) : uint256(20));
        uint256 sold;
        for (uint256 k = 0; k < n; k++) {
            if (!(std ? TapeBoard(board).isPurchasing() : MonthBoard(board).isPurchasing())) break;
            vm.startBroadcast();
            uint256 id = mmachines.mintCircuit(deployer, MACHINE_NETLIST, 2, 1);
            bytes32 key = mpod.register(address(mmachines), id, w);
            mpod.setSince(key, block.timestamp > 30 days ? block.timestamp - 30 days : 1);
            mmachines.approve(board, id);
            vm.stopBroadcast();
            txCount += 4;
            bytes memory call_ =
                abi.encodeWithSignature("sellMachine(address,uint256,uint256)", address(mmachines), id, uint256(0));
            if (!_wouldSucceed(deployer, board, call_)) break;
            vm.startBroadcast();
            TapeBoard(board).sellMachine(address(mmachines), id, 0); // 两种主板的 sellMachine 签名相同
            vm.stopBroadcast();
            sold++;
            txCount++;
        }
        console2.log("machines sold to board", board, "count", sold);
    }

    function _reward(uint256 rank) internal {
        bool ok = _wouldSucceed(deployer, address(sp), abi.encodeWithSignature("claimReward(uint256)", rank));
        vm.startBroadcast();
        if (ok) {
            uint256 out = sp.claimReward(rank);
            console2.log("reward rank", rank, "BEM", out);
        } else {
            sp.distribute();
            console2.log("reward rank", rank, "not claimable now; mint revenue distributed only");
        }
        vm.stopBroadcast();
        txCount++;
    }

    function _yield(bool std) internal {
        vm.startBroadcast();
        if (std) {
            TapeBoard b = TapeBoard(f.boardByNumber(vm.envOr("STD_NUMBER", uint256(1))));
            uint256 need = b.drawThreshold();
            uint256 have = b.pool();
            if (need > have) mpod.addYield(b.machine(0).key, need - have);
            txCount++;
        } else {
            MonthBoard m = MonthBoard(_monthBoardFromEnv());
            m.sync(); // 准备期结束后先进入挖矿
            txCount++;
            uint256 total = vm.envOr("YIELD_BEM", uint256(10)) * BEM_1;
            uint256 n = m.machineCount();
            for (uint256 k = 0; k < n; k++) {
                if (!m.machine(k).sold) mpod.addYield(m.machine(k).key, total / n);
                txCount++;
            }
        }
        vm.stopBroadcast();
    }

    /// @dev 标准局开奖。Mock 随机数时可以连续 REPEAT 次（每次先补到门槛、开奖、交付随机数）
    function _pulse(uint256 repeat) internal {
        TapeBoard b = TapeBoard(f.boardByNumber(vm.envOr("STD_NUMBER", uint256(1))));
        for (uint256 r = 0; r < repeat; r++) {
            if (b.state() != BoardState.Active) break;
            if (b.drawPending()) {
                if (address(mockRng) == address(0)) break; // 等 Chainlink 交付
                vm.startBroadcast();
                mockRng.fulfill(b.pendingRequestId(), uint256(keccak256(abi.encode(block.timestamp, r))));
                vm.stopBroadcast();
                txCount++;
                continue;
            }
            vm.startBroadcast();
            uint256 need = b.drawThreshold();
            if (b.pool() < need) mpod.addYield(b.machine(0).key, need - b.pool());
            b.pulse();
            txCount += 2;
            if (address(mockRng) != address(0) && b.drawPending()) {
                mockRng.fulfill(b.pendingRequestId(), uint256(keccak256(abi.encode(block.timestamp, r, "w"))));
                txCount++;
            }
            vm.stopBroadcast();
        }
        console2.log("standard board alive", b.aliveCount(), "state", uint256(b.state()));
    }

    function _draw() internal {
        MonthBoard m = MonthBoard(_monthBoardFromEnv());
        vm.startBroadcast();
        m.sync();
        m.drawPrizes();
        txCount += 2;
        if (address(mockRng) != address(0) && m.drawPending()) {
            mockRng.fulfill(m.pendingRequestId(), uint256(keccak256(abi.encode(block.timestamp, "month"))));
            m.finalizePrizes();
            txCount += 2;
        }
        vm.stopBroadcast();
        console2.log("month board state", uint256(m.state()), "prizes drawn", m.prizesDrawn());
    }

    function _finalize() internal {
        MonthBoard m = MonthBoard(_monthBoardFromEnv());
        vm.startBroadcast();
        m.finalizePrizes();
        vm.stopBroadcast();
        txCount++;
    }

    function _settle(bool std) internal {
        if (std) {
            // 终局卖矿经 StdMachineSales：30 天内按报价公式价（报价无效时部署者作为运营地址按底价报一次买一 = 卖一），
            // 30 天后按降价拍卖；部署者自己买走
            TapeBoard b = TapeBoard(f.boardByNumber(vm.envOr("STD_NUMBER", uint256(1))));
            StdMachineSales ss = StdMachineSales(b.SALES());
            vm.startBroadcast();
            mbem.mint(deployer, 10_000 * BEM_1);
            mbem.approve(address(ss), type(uint256).max);
            txCount += 2;
            for (uint256 k = 0; k < b.machineCount(); k++) {
                if (b.machine(k).sold) continue;
                (, uint8 phase) = ss.askPrice(address(b), k);
                if (phase == 0) {
                    uint256 fp = b.sellFloorPrice() == 0 ? 1 : b.sellFloorPrice();
                    MarketPriceFeed(b.PRICE_FEED()).post(fp, fp);
                    txCount++;
                }
                ss.buyMachine(address(b), k, type(uint256).max);
                txCount++;
            }
            vm.stopBroadcast();
            console2.log("standard board machines left", b.unsoldMachines());
            return;
        }
        MonthBoard m = MonthBoard(_monthBoardFromEnv());
        // 交接第 0 台给正在准备矿机的月局（RELAY_TO 指定编号，默认是当前招募中的那块）。先在本地试一次，能成才广播。
        uint256 rn = vm.envOr("RELAY_TO", uint256(0));
        MonthBoard r = MonthBoard(rn == 0 ? mf.recruitingBoard() : mf.boardByNumber(rn));
        bool relay = m.machineCount() > 0 && !m.machine(0).sold && r.isPurchasing()
            && _wouldSucceed(
                deployer, address(msales), abi.encodeCall(MonthMachineSales.relay, (address(m), 0, address(r)))
            );
        vm.startBroadcast();
        mbem.mint(deployer, 10_000 * BEM_1);
        mbem.approve(address(msales), type(uint256).max);
        txCount += 2;
        if (relay) {
            msales.relay(address(m), 0, address(r));
            txCount++;
            console2.log("machine 0 relayed to month board (at its buy price)", r.number());
        }
        // 卖价由报价公式决定（整台不低于成本价）。报价过期（又没到"停运"）时卖出暂停：部署者作为运营地址报一次价，
        // 买一 = 第 1 台的每单位成本，卖一 = 买一 × 120%
        MarketPriceFeed feed = MarketPriceFeed(m.PRICE_FEED());
        if (m.machineCount() > 1 && !m.machine(1).sold && !feed.fresh() && !feed.abandoned()) {
            uint256 unit = uint256(m.machine(1).cost) / m.machine(1).weight + 1;
            feed.post(unit, unit * 12 / 10);
            txCount++;
        }
        for (uint256 k = 0; k < m.machineCount(); k++) {
            if (msales.askPrice(address(m), k) > 0) {
                msales.buyMachine(address(m), k, type(uint256).max);
                txCount++;
            }
        }
        vm.stopBroadcast();
        console2.log("month board machines left", m.unsoldMachines());
    }

    function _distribute(bool std) internal {
        uint256 batch = vm.envOr("BATCH", uint256(100));
        vm.startBroadcast();
        if (std) {
            TapeBoard b = TapeBoard(f.boardByNumber(vm.envOr("STD_NUMBER", uint256(1))));
            // 标准局的分批发放在 StdMachineSales（rc6 起，按持仓领取）；基金会 / 手续费地址的份额记在地址上，用 withdrawCredit
            StdMachineSales ss = StdMachineSales(b.SALES());
            for (uint256 from = 1; from <= b.socketCount(); from += batch) {
                ss.distribute(address(b), from, batch);
                txCount++;
            }
            if (b.credit(b.FOUNDATION()) > 0) {
                b.withdrawCredit(b.FOUNDATION());
                txCount++;
            }
            if (b.credit(b.FEE_RECIPIENT()) > 0) {
                b.withdrawCredit(b.FEE_RECIPIENT());
                txCount++;
            }
        } else {
            MonthBoard m = MonthBoard(_monthBoardFromEnv());
            for (uint256 from = 1; from <= m.socketCount(); from += batch) {
                msales.distribute(address(m), from, batch);
                txCount++;
            }
        }
        vm.stopBroadcast();
    }

    /// @dev 运营地址兜底：从 [from, from + count) 里找一位本局参与者，代替运营地址执行
    function _fallback(bool std, uint256 from, uint256 count) internal {
        address board = std ? f.boardByNumber(vm.envOr("STD_NUMBER", uint256(1))) : _monthBoardFromEnv();
        (address who, uint256 pk) = _participant(board, std, from, count);
        if (std) {
            TapeBoard b = TapeBoard(board);
            require(b.state() == BoardState.Active && !b.drawPending(), "standard board is not waiting for a pulse");
            require(
                block.timestamp >= b.lastPulseAt() + f.boardConfig().operatorGrace, "operator grace is not over yet"
            );
            vm.startBroadcast();
            uint256 need = b.drawThreshold();
            if (b.pool() < need) mpod.addYield(b.machine(0).key, need - b.pool());
            vm.stopBroadcast();
            vm.startBroadcast(pk);
            b.pulse();
            vm.stopBroadcast();
            txCount += 2;
            if (address(mockRng) != address(0) && b.drawPending()) {
                vm.startBroadcast();
                mockRng.fulfill(b.pendingRequestId(), uint256(keccak256(abi.encode(block.timestamp, "fallback"))));
                vm.stopBroadcast();
                txCount++;
            }
            console2.log("participant pulsed the standard board", who, "alive", b.aliveCount());
        } else {
            MonthBoard m = MonthBoard(board);
            require(m.state() == MonthState.Settling, "month board is not settling");
            require(
                block.timestamp >= m.settleStart() + mf.boardConfig().operatorGrace, "operator grace is not over yet"
            );
            uint256 batch = vm.envOr("BATCH", uint256(100));
            vm.startBroadcast(pk);
            for (uint256 s = 1; s <= m.socketCount(); s += batch) {
                msales.distribute(address(m), s, batch);
                txCount++;
            }
            vm.stopBroadcast();
            console2.log("participant distributed the month board", who);
        }
    }

    /// @dev 玩家把剩下的 tBNB 退回部署者
    function _sweepPlayers(uint256 from, uint256 count) internal {
        // 默认每人留 5 万 gas 的手续费；SWEEP_KEEP_WEI 可改（重新部署前收回时多留一点，下一轮 mint / join 还要用）
        uint256 keep = vm.envOr("SWEEP_KEEP_WEI", 50_000 * vm.envOr("GAS_PRICE_WEI", uint256(0.1 gwei)));
        uint256 total;
        uint256 n;
        for (uint256 i = from; i < from + count; i++) {
            (address who, uint256 pk) = _player(i);
            uint256 bal = who.balance;
            if (bal <= keep * 2) continue;
            vm.startBroadcast(pk);
            (bool ok,) = payable(deployer).call{value: bal - keep}("");
            vm.stopBroadcast();
            require(ok, "sweep");
            total += bal - keep;
            n++;
            txCount++;
        }
        console2.log("players swept", n, "tBNB returned (wei)", total);
    }

    function _status() internal view {
        console2.log("now", block.timestamp, "operator", f.operator());
        console2.log("genesis started", f.genesisStarted(), "transistors minted", tr.minted());
        if (!f.genesisStarted()) console2.log("  genesis possible at", sp.mintStart() + f.genesisDelay());
        uint256 n = f.currentNumber();
        for (uint256 i = 1; i <= n; i++) {
            TapeBoard b = TapeBoard(f.boardByNumber(i));
            console2.log("std board", i, address(b));
            console2.log("  state", uint256(b.state()), "alive", b.aliveCount());
            console2.log("  recruitDeadline", b.recruitDeadline(), "lastPulseAt", b.lastPulseAt());
            console2.log("  pool", b.pool(), "threshold", b.drawThreshold());
            console2.log("  liquidationStart", b.liquidationStart(), "unsold", b.unsoldMachines());
        }
        uint256 mn = mf.currentNumber();
        for (uint256 i = 1; i <= mn; i++) {
            MonthBoard m = MonthBoard(mf.boardByNumber(i));
            console2.log("month board", i, address(m));
            console2.log("  state", uint256(m.state()), "players", m.socketCount());
            console2.log("  recruitDeadline", m.recruitDeadline(), "prepEnd", m.prepEnd());
            console2.log("  miningEnd", m.miningEnd(), "settleStart", m.settleStart());
            console2.log("  prizePool", m.prizePool(), "subsidyCapital", m.subsidyCapital());
        }
    }

    // =====================================================================
    // 模拟 Firsto 市场（STAGE=firsto）
    // =====================================================================

    /// @dev 一张模拟卖单（单叶子批次：merkleRoot = leafHash，证明为空；mock 卖单合约不验签名，signature 为空）
    struct MockAsk {
        address maker;
        uint256 tokenId;
        uint256 weight;
        uint256 priceWei;
        uint256 buyerCost;
        uint256 batchNonce;
        bytes32 leafHash;
        bytes32 batchHash;
    }

    /// @dev 价格参照：bid / ask = 报价合约当前的买一 / 卖一（每单位权重 BEM）；rate = mock 预言机汇率；perDay = 每单位日产出
    struct MarketRef {
        uint256 bid;
        uint256 ask;
        uint256 rate;
        uint256 perDay;
        uint256 expiry;
        uint256 n; // 卖单总数
        uint256 k; // 已生成的卖单数
    }

    uint256 internal constant FIRSTO_FEE_BPS = 100;

    function _firsto(uint256 from, uint256 count) internal {
        require(count > 0, "PLAYER_COUNT");
        MarketRef memory r = _marketRef();
        for (uint256 i = 0; i < count; i++) {
            r.n += i % 2 == 0 ? 3 : 2;
        }
        string memory rows = "";
        for (uint256 i = from; i < from + count; i++) {
            (address who, uint256 pk) = _player(i);
            uint256 per = (i - from) % 2 == 0 ? 3 : 2;
            for (uint256 j = 0; j < per; j++) {
                MockAsk memory a = _mockAsk(who, r);
                rows = string.concat(rows, r.k == 0 ? "" : ",", _askRowJson(a, r));
                r.k++;
            }
            if (!mmachines.isApprovedForAll(who, address(firstoAsk))) {
                vm.startBroadcast(pk);
                mmachines.setApprovalForAll(address(firstoAsk), true);
                vm.stopBroadcast();
                txCount++;
            }
        }
        string memory askFile = vm.envOr("FIRSTO_ASKS_FILE", string("deployments/firsto-asks.json"));
        vm.writeFile(askFile, _asksJson(rows, r.n));
        console2.log("mock Firsto asks", r.n, "written to", askFile);

        string memory bidFile = vm.envOr("FIRSTO_BIDS_FILE", string("deployments/firsto-bids.json"));
        vm.writeFile(bidFile, _firstoBids(r));
        console2.log("mock Firsto bids written to", bidFile);

        uint256 target = vm.envOr("FIRSTO_SWAPPER_TARGET", uint256(0.015 ether));
        uint256 have = address(firstoSwapper).balance;
        if (have < target) {
            vm.startBroadcast();
            (bool ok,) = address(firstoSwapper).call{value: target - have}("");
            require(ok, "fund swapper");
            vm.stopBroadcast();
            txCount++;
        }
        console2.log("MockFirstoSwapper tBNB (wei)", address(firstoSwapper).balance);
    }

    /// @dev 报价有效就用当前的买一 / 卖一；否则部署者（运营地址）先报一次价：卖一 = 标准局 #1 收购价上限 × 80%（FEED_ASK 可改），
    ///      买一 = 卖一 × 99%（FEED_BID 可改）。买卖价差故意很窄：报价合约的"每小时 +0.5%"按真实时间走，而 288 倍测试网上
    ///      一轮收购只有约 35 分钟，收购价基本停在买一 × 1.005，价差大了最便宜的卖单也吃不到。
    ///      报价后机器人要等 50 分钟（最短间隔）才能再报，且 3 小时内每次变动不超过 ±5%
    function _marketRef() internal returns (MarketRef memory r) {
        if (!priceFeed.fresh()) {
            uint256 cap = TapeBoard(f.boardByNumber(1)).buyPriceCap();
            uint256 a = vm.envOr("FEED_ASK", cap * 80 / 100);
            uint256 b = vm.envOr("FEED_BID", a * 99 / 100);
            vm.startBroadcast();
            priceFeed.post(b, a);
            vm.stopBroadcast();
            txCount++;
            console2.log("price feed posted by the deployer (bid, ask per weight unit)", b, a);
        }
        r.bid = priceFeed.bid();
        r.ask = priceFeed.ask();
        r.rate = oracle.bemPerBnb();
        bool ok;
        (ok, r.perDay) = PoDReader.tryUnitYieldPerDay(address(mpod), firstoBid.VERIFIED_SHARE_BPS());
        require(ok && r.perDay > 0, "unit yield");
        r.expiry = block.timestamp + vm.envOr("FIRSTO_ASK_TTL", uint256(30 days));
        console2.log("feed bid / ask (BEM per weight unit)", r.bid, r.ask);
        console2.log("mock BEM per BNB / unit yield per day", r.rate, r.perDay);
    }

    /// @dev 第 r.k 张卖单：铸一台模拟矿机给 maker、登记到 MockPoD（开挖时间往前调 30 天），
    ///      含费总价 = 卖一 × 权重 折合 tBNB × (97% … 103%，按序号均匀分布)
    function _mockAsk(address maker, MarketRef memory r) internal returns (MockAsk memory a) {
        uint256[8] memory weights = [uint256(10), 12, 15, 10, 20, 11, 14, 16];
        a.maker = maker;
        a.weight = weights[r.k % 8];
        vm.startBroadcast();
        a.tokenId = mmachines.mintCircuit(maker, MACHINE_NETLIST, 2, 1);
        bytes32 key = mpod.register(address(mmachines), a.tokenId, a.weight);
        mpod.setSince(key, block.timestamp > 30 days ? block.timestamp - 30 days : 1);
        vm.stopBroadcast();
        txCount += 3;
        uint256 factor = r.n > 1 ? 9_700 + 600 * r.k / (r.n - 1) : 10_000;
        uint256 cost = r.ask * a.weight * factor / 10_000 * 1e18 / r.rate;
        a.priceWei = cost * 10_000 / (10_000 + FIRSTO_FEE_BPS) / 1e9 * 1e9;
        a.buyerCost = a.priceWei + a.priceWei * FIRSTO_FEE_BPS / 10_000; // 和 mock 卖单合约的算法一致
        a.batchNonce = uint256(keccak256(abi.encode(maker, a.tokenId, block.chainid, r.expiry)));
        a.leafHash = keccak256(
            abi.encode(maker, address(mmachines), a.tokenId, a.priceWei, maker, FIRSTO_FEE_BPS, 1, a.batchNonce, 0, 1)
        );
        a.batchHash = keccak256(abi.encode(maker, a.leafHash, a.batchNonce, r.expiry, maker, FIRSTO_FEE_BPS, 1, 1));
    }

    /// @dev 一行卖单，字段和主网 GET /v1/circuits 的 rows[] 相同（只保留机器人用得到的；数值和主网一样用字符串）
    function _askRowJson(MockAsk memory a, MarketRef memory r) internal view returns (string memory) {
        string memory c = _lc(address(mmachines));
        string memory m = _lc(a.maker);
        string memory id = vm.toString(a.tokenId);
        return string.concat(
            '{"id":"',
            c,
            ":",
            id,
            '","collection":"',
            c,
            '","tokenId":"',
            id,
            '","owner":"',
            m,
            '","classification":"official_mining","category":"official_mining","minAskBuyerCostWei":"',
            vm.toString(a.buyerCost),
            '","maxBidSellerNetWei":null,"bestAsk":',
            _bestAskJson(a, r),
            ',"bestBid":null,"askCount":1,"bidCount":0,"mining":',
            _miningJson(a, r),
            "}"
        );
    }

    function _bestAskJson(MockAsk memory a, MarketRef memory r) internal view returns (string memory) {
        string memory m = _lc(a.maker);
        return string.concat(
            '{"id":"',
            vm.toString(a.leafHash),
            '","account":"',
            m,
            '","venue":"firsto","funding":"direct","priceWei":"',
            vm.toString(a.priceWei),
            '","buyerCostWei":"',
            vm.toString(a.buyerCost),
            '","expiresAt":"',
            _iso(r.expiry),
            '","createdAt":"',
            _iso(block.timestamp),
            '","status":"open","nonce":"',
            vm.toString(a.batchNonce),
            '","execution":',
            _executionJson(a, r),
            "}"
        );
    }

    /// @dev bestAsk.execution：MarketTrader.buyFromAsk 的 AskOrder 全部取自这里（字段同 Firsto API）
    function _executionJson(MockAsk memory a, MarketRef memory r) internal view returns (string memory) {
        string memory m = _lc(a.maker);
        string memory head = string.concat(
            '{"kind":"circuit_batch_ask","chainId":',
            vm.toString(block.chainid),
            ',"exchange":"',
            _lc(address(firstoAsk)),
            '","batchHash":"',
            vm.toString(a.batchHash),
            '","leafHash":"',
            vm.toString(a.leafHash),
            '","maker":"',
            m,
            '","merkleRoot":"',
            vm.toString(a.leafHash),
            '","batchNonce":"',
            vm.toString(a.batchNonce),
            '","expiry":"',
            vm.toString(r.expiry)
        );
        return string.concat(
            head,
            '","payoutRecipient":"',
            m,
            '","feeBps":100,"feeEpoch":"1","schemaVersion":"1","collection":"',
            _lc(address(mmachines)),
            '","tokenId":"',
            vm.toString(a.tokenId),
            '","priceWei":"',
            vm.toString(a.priceWei),
            '","leafIndex":"0","merkleProof":[],"signature":"0x"}'
        );
    }

    function _miningJson(MockAsk memory a, MarketRef memory r) internal view returns (string memory) {
        string memory w = vm.toString(a.weight);
        return string.concat(
            '{"status":"verified","taskId":"1","bstar":"',
            w,
            '","bonus":"0","weight":"',
            w,
            '","verifiedWeight":"',
            w,
            '","unverifiedWeight":"0","estimated24hAtomic":"',
            vm.toString(r.perDay * a.weight),
            '","tokenSymbol":"BEM","tokenDecimals":8,"sourceBlock":"',
            vm.toString(block.number),
            '"}'
        );
    }

    function _asksJson(string memory rows, uint256 n) internal view returns (string memory) {
        return string.concat(
            '{"note":"TESTNET MOCK Firsto asks in the mainnet GET /v1/circuits format (rows[].bestAsk.execution + rows[].mining); orders live on MockFirstoAskExchange, which does not check signatures or Merkle proofs","sourceBlock":"',
            vm.toString(block.number),
            '","page":1,"pageSize":',
            vm.toString(n),
            ',"total":',
            vm.toString(n),
            ',"totalPages":1,"rows":[',
            rows,
            "]}"
        );
    }

    /// @dev 3 张统一买单（部署者建，矿机收到部署者），日产能价围绕报价合约的买一：
    ///      #a 不限大小、= 买一；#b 不限大小、买一 × 97%；#c 只收 10–15 单位、买一 × 101%。
    ///      日产能价 = 买一（每单位 BEM）折合 tBNB ÷ 每单位日产出 × 1e8（毛价 = 日产能价 × 预计日产出 ÷ 1e8，正好是买一 × 权重）
    function _firstoBids(MarketRef memory r) internal returns (string memory json) {
        uint256 ref = r.bid * 1e18 / r.rate * 1e8 / r.perDay;
        uint256[3] memory dcp = [ref / 1e12 * 1e12, ref * 97 / 100 / 1e12 * 1e12, ref * 101 / 100 / 1e12 * 1e12];
        uint256[3] memory minH = [uint256(0), 0, 10];
        uint256[3] memory maxH = [uint256(0), 0, 15];
        uint256[3] memory budget = [
            vm.envOr("FIRSTO_BID_BUDGET_A", uint256(0.012 ether)),
            vm.envOr("FIRSTO_BID_BUDGET_B", uint256(0.008 ether)),
            vm.envOr("FIRSTO_BID_BUDGET_C", uint256(0.008 ether))
        ];
        string memory bids = "";
        for (uint256 i = 0; i < 3; i++) {
            vm.startBroadcast();
            uint256 id = firstoBid.createBid{value: budget[i]}(dcp[i], minH[i], maxH[i], deployer);
            vm.stopBroadcast();
            txCount++;
            bids = string.concat(bids, i == 0 ? "" : ",", _bidJson(id, dcp[i], budget[i], minH[i], maxH[i]));
            console2.log("bid orderId / dailyCapacityPriceWei", id, dcp[i]);
        }
        json = string.concat(
            '{"status":"live","source":"TESTNET MOCK (MockFirstoBidExchange)","sourceBlock":"',
            vm.toString(block.number),
            '","asOf":"',
            _iso(block.timestamp),
            '","exchange":"',
            vm.toString(address(firstoBid)),
            '","bids":[',
            bids,
            '],"fills":[]}'
        );
    }

    function _bidJson(uint256 id, uint256 dcp, uint256 budget, uint256 minH, uint256 maxH)
        internal
        view
        returns (string memory)
    {
        string memory d = vm.toString(deployer);
        return string.concat(
            string.concat('{"orderId":"', vm.toString(id), '","maker":"', d, '","nftRecipient":"', d),
            string.concat('","refundRecipient":"', d, '","dailyCapacityPriceWei":"', vm.toString(dcp)),
            string.concat('","remainingBudgetWei":"', vm.toString(budget), '","minCircuitH":"', vm.toString(minH)),
            string.concat('","maxCircuitH":"', vm.toString(maxH), '","feeBps":100,"state":"active","createdBlock":"'),
            string.concat(vm.toString(block.number), '","createdAt":"', _iso(block.timestamp), '"}')
        );
    }

    function _lc(address a) internal pure returns (string memory) {
        return vm.toLowercase(vm.toString(a));
    }

    /// @dev Unix 时间 → "YYYY-MM-DDTHH:MM:SS.000Z"（UTC，Howard Hinnant 的 civil_from_days）
    function _iso(uint256 ts) internal pure returns (string memory) {
        uint256 z = ts / 1 days + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 mo = mp < 10 ? mp + 3 : mp - 9;
        uint256 y = yoe + era * 400 + (mo <= 2 ? 1 : 0);
        uint256 s = ts % 1 days;
        return string.concat(
            vm.toString(y),
            "-",
            _2(mo),
            "-",
            _2(doy - (153 * mp + 2) / 5 + 1),
            "T",
            _2(s / 3600),
            ":",
            _2(s / 60 % 60),
            ":",
            _2(s % 60),
            ".000Z"
        );
    }

    function _2(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }

    // =====================================================================
    // 模拟 tapeout.market 的两个来源（STAGE=markets）：官方矿机市场 + Seaport
    // =====================================================================

    /// @dev 一台模拟挂单
    struct Lot {
        address seller;
        address collection;
        uint256 tokenId;
        uint256 weight; // PoD 计价算力（基础 × 处理器倍数）
        uint256 buyerPays; // 买家实付（tBNB）
        uint256 priceWei; // 官方市场：挂单价（= 买家实付）；Seaport：卖方对价
        uint256 fee; // 官方市场：卖方付的手续费；Seaport：买方付的手续费项
        uint256 listingId; // 官方市场挂单号（Seaport 为 0）
        bytes32 orderHash; // Seaport 单哈希（官方市场为 0）
        uint256 salt;
        uint256 endTime;
    }

    function _markets(uint256 from, uint256 count) internal {
        require(count > 0, "PLAYER_COUNT");
        MarketRef memory r = _marketRef();
        r.n = count * 2;
        string memory items = "";
        string memory orders = "";
        for (uint256 i = from; i < from + count; i++) {
            (address who, uint256 pk) = _player(i);
            _approveMarkets(who, pk);
            for (uint256 j = 0; j < 2; j++) {
                bool sea = j == 1;
                Lot memory l = _mintLot(who, r, (i - from) % 2 == j ? mmachines : behemoth);
                vm.startBroadcast(pk);
                if (sea) {
                    l.orderHash = _validateSeaport(l, r.expiry);
                } else {
                    l.priceWei = l.buyerPays; // 官方市场：买家正好付挂单价，1% 从卖方所得里扣
                    l.listingId = officialMarket.list(l.collection, l.tokenId, uint96(l.priceWei));
                }
                vm.stopBroadcast();
                txCount++;
                items = string.concat(items, r.k == 0 ? "" : ",", _feedItemJson(l, r));
                if (sea) {
                    orders = string.concat(
                        orders, bytes(orders).length == 0 ? "" : ",", _listingEntryJson(l.orderHash, _sellParams(l, r.expiry))
                    );
                }
                r.k++;
            }
        }
        // 再挂一台不合格的（官方合集、算力 5 < 10）：机器人应该跳过它
        {
            (address who, uint256 pk) = _player(from);
            Lot memory bad = _mintLotWeight(who, r, mmachines, 5);
            bad.priceWei = bad.buyerPays;
            vm.startBroadcast(pk);
            bad.listingId = officialMarket.list(bad.collection, bad.tokenId, uint96(bad.priceWei));
            vm.stopBroadcast();
            txCount++;
            items = string.concat(items, ",", _feedItemJson(bad, r));
        }
        string memory feedFile = vm.envOr("MARKET_FEED_FILE", string("deployments/tape-feed.json"));
        vm.writeFile(
            feedFile,
            string.concat(
                '{"note":"TESTNET MOCK tapeout.market feed (GET /api/v1/circuit-market/feed): TAPEOUT_OFFICIAL = MockOfficialMarket, TAPEMARKET_SEAPORT = MockSeaport (orders validated on chain; full orders in the tape-listings file, like GET /api/v1/listings/<orderHash>). The last item (weight 5) is deliberately ineligible.","generatedAt":"',
                _iso(block.timestamp),
                '","returned":',
                vm.toString(r.n + 1),
                ',"items":[',
                items,
                "]}"
            )
        );
        console2.log("mock market listings", r.n + 1, "written to", feedFile);
        string memory listingFile = vm.envOr("TAPE_LISTINGS_FILE", string("deployments/tape-listings.json"));
        vm.writeFile(listingFile, string.concat("{", orders, "}"));
        console2.log("mock Seaport orders written to", listingFile);
        string memory offerFile = vm.envOr("SEAPORT_OFFERS_FILE", string("deployments/seaport-offers.json"));
        vm.writeFile(offerFile, string.concat('{"offers":[', _seaportOffers(r), "]}"));
        console2.log("mock Seaport WBNB offers written to", offerFile);
    }

    /// @dev 玩家把两个合集都授权给两个市场（已授权的跳过）
    function _approveMarkets(address who, uint256 pk) internal {
        MockCircuits[2] memory cs = [mmachines, behemoth];
        vm.startBroadcast(pk);
        for (uint256 c = 0; c < 2; c++) {
            if (!cs[c].isApprovedForAll(who, address(officialMarket))) {
                cs[c].setApprovalForAll(address(officialMarket), true);
                txCount++;
            }
            if (!cs[c].isApprovedForAll(who, address(seaport))) {
                cs[c].setApprovalForAll(address(seaport), true);
                txCount++;
            }
        }
        vm.stopBroadcast();
    }

    /// @dev 第 r.k 台：铸给 seller、登记到 MockPoD（开挖时间往前调 30 天）。官方合集按基础算力 10–20，Behemoth 基础 2–3
    ///      （× 处理器倍数 6 = 12–18）。买家实付 = 卖一 × 计价算力 折合 tBNB × (97% … 103%，按序号均匀分布)
    function _mintLot(address seller, MarketRef memory r, MockCircuits c) internal returns (Lot memory l) {
        uint256[6] memory baseOfficial = [uint256(10), 12, 15, 11, 20, 14];
        return _mintLotWeight(seller, r, c, address(c) == address(behemoth) ? 2 + r.k % 2 : baseOfficial[r.k % 6]);
    }

    /// @dev 同上，指定基础算力
    function _mintLotWeight(address seller, MarketRef memory r, MockCircuits c, uint256 base) internal returns (Lot memory l) {
        bool beh = address(c) == address(behemoth);
        l.seller = seller;
        l.collection = address(c);
        l.weight = beh ? base * 6 : base;
        vm.startBroadcast();
        l.tokenId = c.mintCircuit(seller, MACHINE_NETLIST, 2, 1);
        bytes32 key = mpod.register(address(c), l.tokenId, base);
        mpod.setSince(key, block.timestamp > 30 days ? block.timestamp - 30 days : 1);
        vm.stopBroadcast();
        txCount += 3;
        uint256 factor = r.n > 1 && r.k < r.n ? 9_700 + 600 * r.k / (r.n - 1) : 10_000;
        l.buyerPays = r.ask * l.weight * factor / 10_000 * 1e18 / r.rate / 1e9 * 1e9;
        l.endTime = r.expiry;
        l.salt = uint256(keccak256(abi.encode(seller, address(c), l.tokenId, block.chainid)));
    }

    /// @dev Seaport 链上挂单（offerer = 玩家，不用签名）：对价 = [卖价 → 卖家, 1% → 手续费地址（测试网 = 部署者，
    ///      和 MachineLister 的 seaportFeeRecipient 相同）]，买家实付 = 卖价 × 101%
    function _validateSeaport(Lot memory l, uint256 expiry) internal returns (bytes32) {
        l.priceWei = l.buyerPays * 10_000 / 10_100;
        l.fee = l.priceWei * TapeSurgeDefaults.TAPEMARKET_FEE_BPS / 10_000;
        l.buyerPays = l.priceWei + l.fee;
        OrderParameters memory p = _sellParams(l, expiry);
        Order[] memory os = new Order[](1);
        os[0] = Order(p, "");
        seaport.validate(os);
        return seaport.getOrderHash(_components(p));
    }

    function _sellParams(Lot memory l, uint256 expiry) internal view returns (OrderParameters memory p) {
        p.offerer = l.seller;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(2, l.collection, l.tokenId, 1, 1);
        p.consideration = new ConsiderationItem[](2);
        p.consideration[0] = ConsiderationItem(0, address(0), 0, l.priceWei, l.priceWei, payable(l.seller));
        p.consideration[1] = ConsiderationItem(0, address(0), 0, l.fee, l.fee, payable(deployer));
        p.startTime = block.timestamp;
        p.endTime = expiry;
        p.salt = l.salt;
        p.totalOriginalConsiderationItems = 2;
    }

    function _components(OrderParameters memory p) internal pure returns (OrderComponents memory) {
        return OrderComponents(
            p.offerer,
            p.zone,
            p.offer,
            p.consideration,
            p.orderType,
            p.startTime,
            p.endTime,
            p.zoneHash,
            p.salt,
            p.conduitKey,
            0
        );
    }

    /// @dev 部署者在 Seaport 上建两张 WBNB 合集出价（每个合集一张，任意一台都可以卖给它；卖方付 1% 手续费项），
    ///      出价 = 买一 × MARKET_OFFER_WEIGHT（默认 12）单位折合 tBNB。返回出价单 JSON
    function _seaportOffers(MarketRef memory r) internal returns (string memory json) {
        uint256 units = vm.envOr("MARKET_OFFER_WEIGHT", uint256(12));
        uint256 amount = r.bid * units * 1e18 / r.rate / 1e9 * 1e9;
        MockCircuits[2] memory cs = [mmachines, behemoth];
        vm.startBroadcast();
        wbnbToken.deposit{value: amount * 2}();
        wbnbToken.approve(address(seaport), type(uint256).max);
        for (uint256 c = 0; c < 2; c++) {
            OrderParameters memory p;
            p.offerer = deployer;
            p.offer = new OfferItem[](1);
            p.offer[0] = OfferItem(1, address(wbnbToken), 0, amount, amount);
            p.consideration = new ConsiderationItem[](2);
            p.consideration[0] = ConsiderationItem(4, address(cs[c]), 0, 1, 1, payable(deployer)); // 合集出价（条件 = 0）
            p.consideration[1] = ConsiderationItem(1, address(wbnbToken), 0, amount / 100, amount / 100, payable(deployer));
            p.startTime = block.timestamp;
            p.endTime = block.timestamp + 30 days;
            p.salt = uint256(keccak256(abi.encode("offer", address(cs[c]), block.number)));
            p.totalOriginalConsiderationItems = 2;
            Order[] memory os = new Order[](1);
            os[0] = Order(p, "");
            seaport.validate(os);
            json = string.concat(json, c == 0 ? "" : ",", _orderJson(seaport.getOrderHash(_components(p)), p));
        }
        vm.stopBroadcast();
        txCount += 4;
        console2.log("WBNB collection offers (each, wei)", amount);
    }

    /// @dev 一行行情（字段同 tapeout.market feed 的 items[]，只保留机器人用得到的；数值用字符串）
    function _feedItemJson(Lot memory l, MarketRef memory r) internal view returns (string memory) {
        uint256 daily = r.perDay * l.weight;
        bool sea = l.orderHash != bytes32(0);
        string memory listing = string.concat(
            '{"source":"',
            sea ? "TAPEMARKET_SEAPORT" : "TAPEOUT_OFFICIAL",
            '","protocol":"',
            sea ? "SEAPORT" : "TAPEOUT_OFFICIAL",
            '","chainId":',
            vm.toString(block.chainid),
            ',"seller":"',
            _lc(l.seller),
            '","collectionAddress":"',
            _lc(l.collection),
            '","tokenId":"',
            vm.toString(l.tokenId)
        );
        listing = string.concat(
            listing,
            '","priceWei":"',
            vm.toString(sea ? l.priceWei : l.buyerPays),
            '","buyerPaysWei":"',
            vm.toString(l.buyerPays),
            '","estimatedProtocolFeeWei":"',
            vm.toString(sea ? l.fee : l.buyerPays * 100 / 10_000),
            '","listingId":',
            sea ? "null" : string.concat('"', vm.toString(l.listingId), '"'),
            ',"orderHash":',
            sea ? string.concat('"', vm.toString(l.orderHash), '"') : "null",
            ',"marketplaceAddress":"',
            _lc(sea ? address(seaport) : address(officialMarket)),
            '","startTime":',
            sea ? string.concat('"', vm.toString(block.timestamp), '"') : "null",
            ',"endTime":',
            sea ? string.concat('"', vm.toString(l.endTime), '"') : "null",
            ',"purchasable":true,"lifecycleStatus":"ACTIVE"}'
        );
        return string.concat(
            '{"hashrate":"',
            vm.toString(l.weight),
            '","poolState":"verified","processor":"',
            l.collection == address(behemoth) ? "behemoth" : "tapeout",
            '","dailyOutput":{"availability":"available","amount":"',
            vm.toString(daily),
            '","bemUnit":"100000000"},"capacityPriceWei":"',
            vm.toString(l.buyerPays * 1e8 / daily),
            '","listing":',
            listing,
            "}"
        );
    }

    /// @dev 挂单文件的一项（格式同 tapeout.market GET /api/v1/listings/<orderHash>）："<orderHash>": {status, parameters, signature}
    function _listingEntryJson(bytes32 h, OrderParameters memory p) internal pure returns (string memory) {
        return string.concat(
            '"', vm.toString(h), '":{"status":"ACTIVE","orderHash":"', vm.toString(h), '","signature":"0x","parameters":', _paramsJson(p), "}"
        );
    }

    /// @dev 一张出价单（链上已 validate，signature 为空）
    function _orderJson(bytes32 h, OrderParameters memory p) internal pure returns (string memory) {
        return string.concat('{"orderHash":"', vm.toString(h), '","signature":"0x","parameters":', _paramsJson(p), "}");
    }

    /// @dev Seaport OrderComponents 各字段（数字用字符串；counter = 0）
    function _paramsJson(OrderParameters memory p) internal pure returns (string memory) {
        string memory offer = "";
        for (uint256 i = 0; i < p.offer.length; i++) {
            OfferItem memory o = p.offer[i];
            offer = string.concat(
                offer,
                i == 0 ? "" : ",",
                _itemJson(o.itemType, o.token, o.identifierOrCriteria, o.startAmount, o.endAmount),
                "}"
            );
        }
        string memory cons = "";
        for (uint256 i = 0; i < p.consideration.length; i++) {
            ConsiderationItem memory c = p.consideration[i];
            cons = string.concat(
                cons,
                i == 0 ? "" : ",",
                _itemJson(c.itemType, c.token, c.identifierOrCriteria, c.startAmount, c.endAmount),
                ',"recipient":"',
                _lc(c.recipient),
                '"}'
            );
        }
        return string.concat(
            string.concat('{"offerer":"', _lc(p.offerer), '","zone":"', _lc(p.zone), '","offer":[', offer),
            string.concat('],"consideration":[', cons, '],"orderType":"', vm.toString(uint256(p.orderType))),
            string.concat('","startTime":"', vm.toString(p.startTime), '","endTime":"', vm.toString(p.endTime)),
            string.concat('","zoneHash":"', vm.toString(p.zoneHash), '","salt":"', vm.toString(p.salt)),
            string.concat('","conduitKey":"', vm.toString(p.conduitKey), '","totalOriginalConsiderationItems":"'),
            string.concat(vm.toString(p.totalOriginalConsiderationItems), '","counter":"0"}')
        );
    }

    function _itemJson(uint8 t, address token, uint256 idc, uint256 s, uint256 e) internal pure returns (string memory) {
        return string.concat(
            '{"itemType":"',
            vm.toString(uint256(t)),
            '","token":"',
            _lc(token),
            '","identifierOrCriteria":"',
            vm.toString(idc),
            '","startAmount":"',
            vm.toString(s),
            '","endAmount":"',
            vm.toString(e),
            '"'
        );
    }

    // =====================================================================
    // STAGE=all：本地内存链上按测试网的顺序一次性跑完（验证脚本 + 统计 gas）
    // =====================================================================

    function _all() internal {
        require(block.chainid == 31337, "STAGE=all only runs on the local in-memory chain");
        mnemonic = vm.envOr("TEST_MNEMONIC", LOCAL_DEV_MNEMONIC);
        vm.startBroadcast();
        (, deployer,) = vm.readCallers();
        _deployAll(deployer, 0);
        vm.stopBroadcast();
        txCount += 10;
        _useDeployed();
        uint256 players = vm.envOr("PLAYER_COUNT", uint256(50));
        _fund(0, players, _fundAmount());
        _mintPasses(0, players);
        vm.warp(block.timestamp + f.genesisDelay() + 1);
        _genesis();

        // 标准局和第 1 块月局同时招募
        uint256 stdEnd = _join(true, 0, players);
        (MonthBoard m1, uint256 m1End) = _freshMonth(stdEnd, players - stdEnd);
        vm.setEnv("MONTH_NUMBER", vm.toString(m1.number()));
        _reward(1); // 标准局是第 1 块开局的主板
        _reward(2); // 月局 m1 是第 2 块
        _machines(true);
        _machines(false);

        // 标准局：开奖一半 → 运营地址超过 operatorGrace 没推进，参与者兜底一次 → 开奖到硅王 → 终局拍卖 → 打款
        TapeBoard b = TapeBoard(f.boardByNumber(1));
        vm.warp(block.timestamp + 1);
        _pulse(stdEnd / 2);
        vm.warp(b.lastPulseAt() + f.boardConfig().operatorGrace);
        _fallback(true, 0, stdEnd);
        _pulse(200);
        require(b.state() == BoardState.Liquidating, "standard board finished");
        vm.warp(block.timestamp + 1 hours);
        _settle(true);
        _distribute(true);
        console2.log("standard board finished; players used", stdEnd);

        // 月局 m1：挖矿 → 挖矿结束前用标准局退回的通行证开出 m2 → 开奖 → 交接给 m2 / 挂单 / 自动成本价 →
        //          运营地址超过 operatorGrace 没打款，参与者兜底 → 回馈资本滚到下一块开局的月局
        vm.warp(m1.prepEnd());
        _yield(false);
        vm.warp(m1.miningEnd() - 120);
        (MonthBoard m2,) = _freshMonth(0, stdEnd);
        vm.warp(m1.miningEnd() + 1);
        _draw();
        require(m1.state() == MonthState.Settling, "m1 settling");
        vm.setEnv("RELAY_TO", vm.toString(m2.number()));
        _settle(false); // 交接第 0 台，其余按报价公式价成交（没报过价时按成本价）
        vm.warp(block.timestamp + MarketPriceFeed(m1.PRICE_FEED()).abandonAfter()); // 报价停运：按成本价可买
        _settle(false);
        vm.warp(m1.settleStart() + mf.boardConfig().operatorGrace);
        _fallback(false, stdEnd, m1End - stdEnd);
        console2.log("m1 machines left", m1.unsoldMachines(), "rolled over", m1.rolledOver());
        (MonthBoard m3,) = _freshMonth(stdEnd, m1End - stdEnd);
        console2.log("next month board", m3.number(), "rollover received", m3.subsidyCapital());
        _sweepPlayers(0, players);
        console2.log("approx tx count", txCount);
    }

    /// @dev 只用于 STAGE=all：当前招募中的月局已过期就先关闭，再让 [from, from + count) 的玩家加入
    function _freshMonth(uint256 from, uint256 count) internal returns (MonthBoard m, uint256 next) {
        m = MonthBoard(mf.recruitingBoard());
        if (block.timestamp >= m.recruitDeadline()) {
            _close();
            m = MonthBoard(mf.recruitingBoard());
        }
        next = _join(false, from, count);
        require(m.isPurchasing(), "month board started");
    }

    // =====================================================================
    // 小工具
    // =====================================================================

    /// @dev 在本地试执行一次（以 from 的身份），然后撤销状态。用来避免把会 revert 的交易广播上链。
    function _wouldSucceed(address from, address target, bytes memory data) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(from);
        (ok,) = target.call(data);
        vm.revertToState(snap);
    }

    function _participant(address board, bool std, uint256 from, uint256 count)
        internal
        view
        returns (address who, uint256 pk)
    {
        for (uint256 i = from; i < from + count; i++) {
            (who, pk) = _player(i);
            if ((std ? TapeBoard(board).holderCount(who) : MonthBoard(board).holderCount(who)) != 0) return (who, pk);
        }
        revert("no participant of this board in [PLAYER_FROM, PLAYER_FROM + PLAYER_COUNT)");
    }

    function _recruiting(address board, bool std) internal view returns (bool) {
        if (std) return TapeBoard(board).state() == BoardState.Recruiting;
        return MonthBoard(board).state() == MonthState.Recruiting;
    }

    function _monthBoardFromEnv() internal view returns (address) {
        uint256 n = vm.envOr("MONTH_NUMBER", uint256(0));
        if (n == 0) return mf.recruitingBoard();
        return mf.boardByNumber(n);
    }

    function _isStd() internal view returns (bool) {
        return !_eq(vm.envOr("BOARD", string("std")), "month");
    }

    function _from() internal view returns (uint256) {
        return vm.envOr("PLAYER_FROM", uint256(0));
    }

    function _count() internal view returns (uint256) {
        return vm.envOr("PLAYER_COUNT", uint256(50));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
