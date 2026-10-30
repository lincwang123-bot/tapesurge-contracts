// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ITapeOutFactory, ITransistors, ICircuits} from "../src/interfaces/ITapeOut.sol";
import {IPoD} from "../src/interfaces/IPoD.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {MonthFactory} from "../src/MonthFactory.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthPositions} from "../src/month/MonthPositions.sol";
import {MonthMachineSales} from "../src/month/MonthMachineSales.sol";
import {MonthExitGovernor} from "../src/month/MonthExitGovernor.sol";
import {PositionExchange} from "../src/month/PositionExchange.sol";
import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";
import {StdMachineSales} from "../src/StdMachineSales.sol";
import {MachineRules} from "../src/MachineRules.sol";
import {ChainlinkVRFAdapter} from "../src/random/ChainlinkVRFAdapter.sol";
import {PancakeV3TwapOracle} from "../src/oracle/PancakeV3TwapOracle.sol";
import {BoardState, SettleMode} from "../src/interfaces/ITapeBoard.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {TapeSurgeDefaults} from "../script/TapeSurgeDefaults.sol";
import {TapeSurgeDeploy} from "../script/TapeSurgeDeploy.sol";

interface IVRFSubscriptionV2Plus {
    function createSubscription() external returns (uint256 subId);
    function fundSubscriptionWithNative(uint256 subId) external payable;
    function addConsumer(uint256 subId, address consumer) external;
}

/// @notice BSC 主网分叉上的端到端演练（不发送任何交易）：真实 TapeOut 工厂 / PoD / BEM / 官方矿机电路 /
///         PancakeSwap V3 路由与池子 / Chainlink VRF v2.5 协调器（创建订阅、请求随机数；回调由 prank 协调器交付）。
///         两种局从头到尾跑完，每一步检查资金守恒，并输出报告数据（"REPORT" 开头的日志）。
///         运行：BSC_RPC_URL=https://bsc-mainnet.public.blastapi.io forge test --match-contract E2EForkBSCTest -vv
contract E2EForkBSCTest is Test {
    // ---------------- 主网地址（2026-10-19 只读核实） ----------------
    address internal constant TAPEOUT_FACTORY = 0x68224F668083c29e9800Be2a646d42d18cedF7e2;
    address internal constant POD = 0x7E2E0DC66a3bD9103E69b766afA62d9f7b697b46;
    address internal constant CIRC = 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C;
    address internal constant CIRC_BEACON = 0xf8D6d8EB894d6971c8976Ad8b4971cbEFE028156;
    address internal constant BEM = 0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14; // PancakeSwap V3 SwapRouter
    address internal constant POOL_WBNB_USDT = 0x172fcD41E0913e95784454622d1c3724f546f849; // 0.01%
    address internal constant POOL_USDT_BEM = 0x3098D7A051045000d68eC0360753A40C8cABEa31; // 1%
    address internal constant VRF_COORDINATOR = 0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9; // VRF v2.5
    bytes32 internal constant KEY_HASH_200GWEI = 0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4;
    address internal constant FOUNDATION = 0x04B649076a11819EF7AdA36e02DD55e0923550Ee;
    address internal constant FEE_SAFE = 0x6ea5FfB01378a1E5ce55C8A119A90a87e542C995;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes internal constant PASS_NETLIST = hex"0000000200000300000002000004000000030000040000000500000600000004000004";
    uint256 internal constant BEM_1 = 1e8;
    uint32 internal constant CALLBACK_GAS = TapeSurgeDefaults.VRF_CALLBACK_GAS; // 75 万
    /// @dev 按 BSC 0.05 gwei 估算费用
    uint256 internal constant GAS_PRICE_WEI = 0.05 gwei;

    bool internal forked;
    address internal operator = makeAddr("operator");
    address internal buyer = makeAddr("buyer");
    address internal outsider = makeAddr("outsider");

    BoardFactory internal factory;
    MonthFactory internal monthFactory;
    MonthPositions internal positions;
    MonthMachineSales internal sales;
    MonthExitGovernor internal governor;
    PositionExchange internal exchange;
    MarketPriceFeed internal priceFeed;
    /// @dev 规则决定 6.37：主板只认 MarketTrader（卖矿模拟成它）和它用的矿机资格单例
    address internal traderAddr;
    MachineRules internal rules;
    address internal joiner1; // 第 1 份 m1 持仓的原持有人（演练中转让给 newHolder，newHolder 再在交易所卖给 taker2）
    address internal newHolder;
    address internal taker2 = makeAddr("exchange taker");
    uint256 internal taker2Start;
    address internal bidder3 = makeAddr("exchange bidder");
    uint256 internal bidder3Start;
    GenesisSplitter internal splitter;
    ChainlinkVRFAdapter internal adapter;
    PancakeV3TwapOracle internal oracle;
    ITransistors internal transistors;
    ICircuits internal passCircuits;
    uint256 internal subId;
    uint256 internal genesisTime;

    uint256 internal playerNonce;
    mapping(address => uint256) internal startBal;

    // gas 统计
    uint256 internal maxCallbackGas;
    uint256 internal callbackCount;
    uint256 internal pulseGasTotal;
    uint256 internal pulseCount;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blockNo = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (blockNo == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNo);
        forked = true;
    }

    // =====================================================================
    // 主流程
    // =====================================================================

    function test_E2E_FullRunOnMainnetFork() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        console2.log("REPORT fork block", block.number, "timestamp", block.timestamp);
        _deploy();
        _genesis();
        _standardBoard();
        _monthBoards();
        console2.log("REPORT max VRF callback gas", maxCallbackGas, "callbacks", callbackCount);
        console2.log("REPORT avg pulse gas", pulseCount == 0 ? 0 : pulseGasTotal / pulseCount, "pulses", pulseCount);
        console2.log("REPORT total days elapsed", (block.timestamp - genesisTime) / 1 days);
    }

    // =====================================================================
    // 1. 部署与创世
    // =====================================================================

    function _deploy() internal {
        // 真实 VRF v2.5 协调器：创建订阅并用 BNB 充值（只在本地分叉里发生）
        vm.deal(address(this), 100 ether);
        subId = IVRFSubscriptionV2Plus(VRF_COORDINATOR).createSubscription();
        IVRFSubscriptionV2Plus(VRF_COORDINATOR).fundSubscriptionWithNative{value: 5 ether}(subId);
        // 和主网部署脚本（script/DeployMainnet.s.sol）完全相同的部署逻辑与参数：
        // TWAP 预言机 → VRF 适配器 → 分账合约 → BoardFactory → MonthFactory
        TapeSurgeDeploy.Deployment memory d =
            TapeSurgeDeploy.deployMainnet(address(this), TapeSurgeDeploy.defaultSettings(operator, subId));
        oracle = d.oracle;
        adapter = d.adapter;
        factory = d.factory;
        monthFactory = d.monthFactory;
        positions = d.positions;
        sales = d.sales;
        governor = d.governor;
        exchange = d.exchange;
        priceFeed = d.priceFeed;
        traderAddr = address(d.trader);
        rules = d.rules;
        // 部署完成后再把适配器加为订阅的 consumer（主网上由订阅所有者在 vrf.chain.link 操作）
        IVRFSubscriptionV2Plus(VRF_COORDINATOR).addConsumer(subId, address(adapter));
        assertEq(adapter.requestConfirmations(), TapeSurgeDefaults.MAINNET_VRF_CONFIRMATIONS);
        assertEq(adapter.callbackGasLimit(), CALLBACK_GAS);
        // 真实 TapeOut 工厂接受 66,666 颗的上限（2026-10-21 项目方决定由 666,666 改回）
        assertEq(factory.transistors().supplyCap(), 66_666, "transistor supply cap on mainnet factory");
        splitter = factory.splitter();
        transistors = factory.transistors();
        passCircuits = ICircuits(factory.passCircuits());
        assertEq(transistors.creator(), address(splitter), "splitter is creator");
        assertEq(splitter.maxSlippageBps(), TapeSurgeDefaults.MAINNET_MAX_SLIPPAGE_BPS);
        console2.log("REPORT vrf subscription", subId);
    }

    function _genesis() internal {
        genesisTime = block.timestamp;
        // 先铸出 45 张标准局通行证（月局的玩家之后再铸）
        for (uint256 i = 0; i < 45; i++) {
            _newPlayer();
        }
        // 典型玩家：铸 5 颗 NAND + 流片通行证的 gas
        address probe = address(uint160(uint256(keccak256("gas probe player"))));
        vm.deal(probe, 1 ether);
        vm.startPrank(probe);
        uint256 g = gasleft();
        transistors.mint{value: 5 * 0.0011 ether}(0, 5);
        uint256 gMint = g - gasleft();
        g = gasleft();
        (bool okT,) =
            address(passCircuits).call{value: 0.0002 ether}(abi.encodeCall(ICircuits.tapeout, (PASS_NETLIST, 2, 2)));
        uint256 gTape = g - gasleft();
        vm.stopPrank();
        require(okT, "tapeout");
        console2.log("REPORT gas mint 5 NAND", gMint, "tapeout pass", gTape);
        assertEq(transistors.minted(), 46 * 5);
        assertEq(transistors.owed(address(splitter)), 46 * 0.005 ether);

        vm.expectRevert(BoardFactory.GenesisConditionNotMet.selector);
        factory.startGenesis();
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 7 * 28_800 * 2);
        uint256 f0 = FOUNDATION.balance;
        uint256 p0 = FEE_SAFE.balance;
        // 开局前必须报过价（全局审计 G-1）：运营地址先报一次；开局后把报价合约恢复成"从没报过价"，后面的场景沿用原来的
        // 时间线（第一块主板按默认曲线收购，之后各步按需要报价）。生产中机器人在部署后立刻报价，开局后不会回到这个状态
        vm.expectRevert(BoardFactory.FeedNotPosted.selector);
        factory.startGenesis();
        vm.prank(operator);
        priceFeed.post(1, 1);
        g = gasleft();
        factory.startGenesis();
        uint256 gGenesis = g - gasleft();
        vm.store(address(priceFeed), bytes32(uint256(0)), bytes32(0)); // bid
        vm.store(address(priceFeed), bytes32(uint256(1)), bytes32(0)); // ask
        vm.store(address(priceFeed), bytes32(uint256(2)), bytes32(0)); // updatedAt
        vm.store(address(priceFeed), bytes32(uint256(6)), bytes32(0)); // liveAt
        uint256 revenue = 46 * 0.005 ether;
        assertEq(FOUNDATION.balance - f0, revenue * 2_000 / 10_000, "foundation 20% (real Safe received BNB)");
        assertEq(FEE_SAFE.balance - p0, revenue * 1_000 / 10_000, "project 10%");
        assertEq(splitter.buybackPool(), revenue * 4_000 / 10_000, "buyback 40%");
        console2.log("REPORT genesis revenue wei", revenue, "gas startGenesis (incl. distribute)", gGenesis);

        // 回购：真实路由 + 真实 TWAP
        uint256 dead0 = IERC20(BEM).balanceOf(DEAD);
        uint256 quote = oracle.quoteBemOut(splitter.buybackPool());
        g = gasleft();
        try splitter.buyback() returns (uint256 out) {
            uint256 gBuy = g - gasleft();
            assertEq(IERC20(BEM).balanceOf(DEAD) - dead0, out);
            console2.log("REPORT buyback BNB in", revenue * 4_000 / 10_000, "BEM burned", out);
            console2.log("REPORT buyback TWAP quote", quote, "gas", gBuy);
        } catch (bytes memory reason) {
            console2.log("REPORT buyback reverted");
            console2.logBytes(reason);
        }
    }

    // =====================================================================
    // 2. 标准局（500 BEM）
    // =====================================================================

    TapeBoard internal sb;
    address[] internal stdPlayers;
    uint256[] internal stdMachines;

    function _standardBoard() internal {
        sb = TapeBoard(factory.recruitingBoard());
        assertEq(sb.target(), 500 * BEM_1);
        uint256 t0 = block.timestamp;
        uint256 i;
        uint256 gJoin;
        while (sb.state() == BoardState.Recruiting) {
            address u = _playerAt(i);
            uint256 amt = 1 * BEM_1 + (uint256(keccak256(abi.encode("std", i))) % (19 * BEM_1)) / 1e6 * 1e6;
            uint256 g = gasleft();
            _join(address(sb), u, amt);
            if (i == 10) gJoin = g - gasleft();
            stdPlayers.push(u);
            i++;
        }
        console2.log("REPORT std players", stdPlayers.length, "totalStake", sb.totalStake());
        console2.log("REPORT gas join (typical)", gJoin);
        assertEq(IERC20(BEM).balanceOf(address(sb)), sb.budget(), "conservation after start");
        assertEq(factory.rewardBoard(1), address(sb), "standard board is rank 1");

        // 卖矿机：真实持有人（prank）把已验证、在挖、满 7 天、权重 10–300 的矿机卖给主板
        uint256[5] memory ids = [uint256(996), 1010, 1013, 1151, 1108];
        uint256 spent;
        for (uint256 k = 0; k < ids.length; k++) {
            spent += _sellReal(address(sb), ids[k], k == 0);
            stdMachines.push(ids[k]);
        }
        console2.log("REPORT std machines bought", sb.machineCount(), "weight", sb.totalWeightBought());
        console2.log("REPORT std spent", spent, "budget left", sb.budget());
        console2.log("REPORT std buy price cap per weight", sb.buyPriceCap());
        _checkStd();

        // 首批回馈：第 1 桶 → 换成 BEM → 并入采购预算 → 追加收购一台
        vm.warp(block.timestamp + 2 hours);
        uint256 g2 = gasleft();
        try splitter.claimReward(1) returns (uint256 out) {
            console2.log("REPORT std reward bucket1 BEM", out, "gas", g2 - gasleft());
            assertEq(sb.totalSubsidy(), out);
        } catch (bytes memory reason) {
            console2.log("REPORT claimReward(1) reverted");
            console2.logBytes(reason);
        }
        spent += _sellReal(address(sb), 1072, false);
        stdMachines.push(1072);
        _checkStd();

        // 挖矿与脉冲：PoD 真实累积产出；运营地址每天推进
        _runStandardPulses();
        uint256 days_ = (block.timestamp - t0) / 1 days;
        console2.log("REPORT std days until king paid", days_);
        assertEq(uint256(sb.state()), uint256(BoardState.Liquidating));
        assertEq(uint256(sb.settleMode()), uint256(SettleMode.Normal));

        _standardLiquidation();
    }

    function _runStandardPulses() internal {
        bool stallDemoDone;
        uint256 ejections;
        for (uint256 d = 0; d < 1_500; d++) {
            if (sb.state() != BoardState.Active) break;
            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 28_800 * 2);
            // 演示：第 10 次出局后运营地址停摆，3 天后由参与者兜底
            if (!stallDemoDone && ejections >= 10 && !sb.drawPending()) {
                stallDemoDone = _demoStandardStall();
                if (stallDemoDone) ejections++;
                continue;
            }
            vm.prank(operator);
            uint256 g = gasleft();
            (bool ok,) = address(sb).call(abi.encodeCall(TapeBoard.pulse, ()));
            uint256 used = g - gasleft();
            if (!ok) continue;
            pulseGasTotal += used;
            pulseCount++;
            if (sb.drawPending()) {
                _fulfill(sb.pendingRequestId(), d);
                ejections++;
                _checkStd();
            }
        }
        assertTrue(stallDemoDone, "stall demo ran");
        console2.log("REPORT std ejections", ejections);
    }

    /// @dev 运营地址停摆：参与者在 3 天内被拒绝，外人始终被拒绝，3 天后参与者推进成功
    function _demoStandardStall() internal returns (bool done) {
        uint256 last = sb.lastPulseAt();
        if (block.timestamp < last + 3 days) {
            address p = stdPlayers[0];
            vm.prank(p);
            (bool okEarly,) = address(sb).call(abi.encodeCall(TapeBoard.pulse, ()));
            assertFalse(okEarly, "participant must wait 3 days");
            vm.warp(last + 3 days);
        }
        vm.prank(outsider);
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        sb.pulse();
        // 门槛满足时参与者兜底
        if (sb.pool() < sb.drawThreshold()) sb.harvest();
        if (sb.pool() < sb.drawThreshold()) return false;
        vm.prank(stdPlayers[1]);
        sb.pulse();
        console2.log(
            "REPORT stall demo: participant pulled after 3 days, at day", (block.timestamp - genesisTime) / 1 days
        );
        _fulfill(sb.pendingRequestId(), 999_999);
        _checkStd();
        return true;
    }

    function _standardLiquidation() internal {
        uint256 kingSlot = sb.kingSocket();
        console2.log("REPORT std king slot", kingSlot, "king stake", uint256(sb.socket(kingSlot).stake));
        console2.log("REPORT std sell start price", sb.sellStartPrice(), "floor", sb.sellFloorPrice());
        StdMachineSales ss = StdMachineSales(sb.SALES());
        vm.prank(buyer);
        IERC20(BEM).approve(address(ss), type(uint256).max);
        deal(BEM, buyer, 5_000 * BEM_1);
        uint256 proceeds;
        uint256 n = sb.machineCount();
        // 第 8 阶段：30 天市价期按报价公式（max(买一, 卖一 × (99% − 0.5% × 小时数))）卖 4 台；
        // 其余第 30 天起降价拍卖（报价过期：起价 = 采购均价 × 150%），1 台按起价，其余 14 天后按底价
        uint256 avgP = sb.sellStartPrice() * 10_000 / 15_000;
        uint256 g;
        // 先按旧时间线把报价放到 avgP 附近（审计 H-1 后不能一步跳价），再正常报一次量 gas
        _forceFeed(address(priceFeed), avgP * 100 / 103, avgP * 12 / 10 * 100 / 103);
        vm.warp(block.timestamp + 50 minutes);
        vm.prank(operator);
        g = gasleft();
        priceFeed.post(avgP, avgP * 12 / 10);
        console2.log("REPORT gas priceFeed.post (bid + ask)", g - gasleft());
        for (uint256 k = 0; k < n && k < 4; k++) {
            if (k == 2) {
                vm.warp(block.timestamp + 1 hours);
                vm.prank(operator);
                priceFeed.post(avgP, avgP * 12 / 10);
            }
            (uint256 price, uint8 phase) = ss.askPrice(address(sb), k);
            assertEq(phase, 1, "market");
            vm.prank(buyer);
            g = gasleft();
            uint256 cost = ss.buyMachine(address(sb), k, price);
            if (k == 0) console2.log("REPORT gas std buyMachine (market, via StdMachineSales)", g - gasleft());
            proceeds += cost;
            console2.log("REPORT std sold machine at market formula", k, "price per weight", price);
        }
        if (n > 4) {
            vm.warp(sb.liquidationStart() + 30 days);
            ss.startAuction(address(sb));
            for (uint256 k = 4; k < n; k++) {
                if (k == 5) {
                    vm.warp(block.timestamp + 14 days);
                    sb.harvest();
                }
                (uint256 price, uint8 phase) = ss.askPrice(address(sb), k);
                assertEq(phase, 2, "auction");
                vm.prank(buyer);
                uint256 cost = ss.buyMachine(address(sb), k, type(uint256).max);
                proceeds += cost;
                console2.log("REPORT std sold auctioned machine", k, "price per weight", price);
            }
        }
        _checkStd();
        console2.log("REPORT std sale proceeds", proceeds, "pot allocated", sb.potAllocated());

        // 运营地址分批打款（每批 20 人），通行证一并退还
        uint256 n2 = sb.socketCount();
        for (uint256 from = 1; from <= n2; from += 20) {
            vm.prank(operator);
            g = gasleft();
            ss.distribute(address(sb), from, 20);
            console2.log("REPORT gas std distribute batch of 20 from", from, g - gasleft());
        }
        sb.withdrawCredit(FOUNDATION);
        sb.withdrawCredit(FEE_SAFE);
        // 守恒：每个人至少拿到 105%，硅王另得 30%；合约里只剩尘埃
        uint256 gains;
        for (uint256 s = 1; s <= n2; s++) {
            address u = sb.socket(s).owner;
            uint256 gain = IERC20(BEM).balanceOf(u) - startBal[u];
            gains += gain;
            assertGe(gain, uint256(sb.socket(s).stake) * 10_500 / 10_000, "everyone got >= 105%");
            assertEq(IERC721(address(passCircuits)).ownerOf(sb.socket(s).passId), u, "pass returned");
        }
        uint256 bal = IERC20(BEM).balanceOf(address(sb));
        assertLe(bal, n2 + 2, "dust only");
        assertEq(sb.liabilities(), bal);
        console2.log("REPORT std players total gain", gains, "dust left", bal);
        console2.log(
            "REPORT std king gain",
            IERC20(BEM).balanceOf(sb.socket(kingSlot).owner) - startBal[sb.socket(kingSlot).owner]
        );
    }

    function _checkStd() internal view {
        uint256 bal = IERC20(BEM).balanceOf(address(sb));
        if (sb.state() == BoardState.Active) {
            assertEq(bal, sb.liabilities() + sb.pool() + sb.budget(), "std: balance == liabilities + pool + budget");
        } else {
            assertGe(bal, sb.liabilities(), "std: balance >= liabilities");
        }
    }

    // =====================================================================
    // 3. 月局（100 BEM）
    // =====================================================================

    MonthBoard internal m1;
    MonthBoard internal m2;
    MonthBoard internal m3;
    address[] internal m1Players;

    function _monthBoards() internal {
        // 第 1 块月局在创世时就开出了，现在早已过了 3 天招募期：宣布失败、重开
        MonthBoard stale = MonthBoard(monthFactory.recruitingBoard());
        stale.closeRecruitment();
        m1 = MonthBoard(monthFactory.recruitingBoard());
        m1Players = _fillMonth(m1, "m1");
        console2.log("REPORT m1 target", m1.target(), "players", m1Players.length);
        assertEq(factory.rewardBoard(2), address(m1), "m1 is rank 2");

        // 首批回馈第 2 桶 → m1 的回馈资本
        vm.warp(block.timestamp + 1 hours);
        try splitter.claimReward(2) returns (uint256 out) {
            console2.log("REPORT m1 reward bucket2 BEM", out);
        } catch (bytes memory reason) {
            console2.log("REPORT claimReward(2) reverted");
            console2.logBytes(reason);
        }
        uint256 subsidy = m1.subsidyCapital();
        // 准备矿机：4 台小矿机。报价曾经报过又过期时收购暂停，所以运营地址先按一年产出的一半报一次价
        _post(m1.buyPriceCap() / 2);
        uint256[4] memory ids = [uint256(1041), 1040, 1063, 1003];
        for (uint256 k = 0; k < 4; k++) {
            _sellReal(address(m1), ids[k], false);
        }
        console2.log("REPORT m1 machines", m1.machineCount(), "spent", m1.totalSpent());
        _checkMonth(m1);
        vm.warp(m1.prepEnd());
        m1.sync();
        assertEq(uint256(m1.state()), uint256(MonthState.Mining));

        // 30 天挖矿：PoD 真实产出
        vm.warp(m1.miningEnd());
        vm.roll(block.number + 30 * 28_800 * 2);
        vm.prank(operator);
        uint256 g = gasleft();
        m1.drawPrizes();
        console2.log("REPORT gas m1 drawPrizes (harvest + VRF request)", g - gasleft());
        uint256 pot = m1.prizePool();
        console2.log("REPORT m1 prize pool after 30 days", pot);
        _fulfill(m1.pendingRequestId(), 31_337);
        uint256 f0 = IERC20(BEM).balanceOf(FOUNDATION);
        uint256 fee0 = IERC20(BEM).balanceOf(FEE_SAFE);
        vm.prank(operator);
        g = gasleft();
        m1.finalizePrizes();
        console2.log("REPORT gas m1 finalizePrizes (5 pushes + settlement start)", g - gasleft());
        // 规则决定 6.15：月局只收入场费，奖金池全部开奖
        assertEq(IERC20(BEM).balanceOf(FOUNDATION), f0, "m1 no 3%");
        assertEq(IERC20(BEM).balanceOf(FEE_SAFE), fee0, "m1 no 2%");
        for (uint256 k = 0; k < 5; k++) {
            console2.log("REPORT m1 prize", k, m1.prizeAmounts(k), m1.winnerSlots(k));
        }
        _checkMonth(m1);

        _monthSettlement(subsidy);
    }

    function _monthRelayV2() internal {
        // 交接（v2）：旧月局在新月局的收购拍卖里当普通卖家，按新局当前收购价成交，且不低于成本价
        m2 = _freshPreparingMonth("m2");
        uint256 cost0 = m1.machine(0).cost;
        uint256 w0 = m1.machine(0).weight;
        // 运营地址报价：先报一个低价（m2 收购价 × 权重 < m1 成本 → 交接失败，NFT 不动），再报到一年产出上限
        uint256 lowUnit = cost0 / w0 / 2;
        _post(lowUnit);
        if (m2.buyPrice() * w0 < cost0) {
            vm.prank(operator);
            vm.expectRevert(MonthBoard.PriceBelowMinimum.selector); // 新局收购价还低于成本价：成交失败，NFT 不动
            sales.relay(address(m1), 0, address(m2));
            console2.log("REPORT relay rejected while m2 buy price < m1 cost");
        }
        _post(m2.buyPriceCap());
        assertGe(m2.buyPrice() * w0, cost0, "m2 buy price reached m1 cost");
        vm.prank(operator);
        uint256 g = gasleft();
        uint256 relayPaid = sales.relay(address(m1), 0, address(m2));
        console2.log("REPORT gas relay (v2, sells into m2 auction)", g - gasleft());
        assertGe(relayPaid, cost0, "relayed at >= cost");
        assertEq(m2.machine(0).cost, relayPaid, "receiver cost = price paid");
        console2.log("REPORT m1 relayed machine 0, cost / paid", cost0, relayPaid);
        _sellReal(address(m2), 1064, false); // m2 自己再收购一台
        _checkMonth(m1);
        _checkMonth(m2);
    }

    function _positionTransferV2() internal {
        // 持仓转让（v2）：第 1 份持仓整份转给新地址；卖方已累计的款项结转给卖方，通行证立刻退给原持有人
        joiner1 = m1.socket(1).owner;
        newHolder = makeAddr("position buyer");
        m1.harvest();
        uint256 pid1 = positions.idOf(address(m1), 1);
        vm.prank(joiner1);
        positions.transferFrom(joiner1, newHolder, pid1);
        assertEq(m1.socket(1).owner, newHolder, "position owner updated");
        assertEq(IERC721(address(passCircuits)).ownerOf(m1.socket(1).passId), joiner1, "pass back to joiner");
        uint256 carried = m1.credit(joiner1);
        console2.log("REPORT m1 position 1 transferred, carried over to seller", carried);
        if (carried > 0) m1.withdrawCredit(joiner1);
        _checkMonth(m1);

        // 挂单簿（v2 第 6 阶段）：newHolder 挂链上卖单（本金的 25%），taker2 先看盘口、再按最优价吃单；成交款直接到卖方
        vm.prank(newHolder);
        positions.setApprovalForAll(address(exchange), true);
        uint256 unit = 25 * 1e8 / 100;
        vm.prank(newHolder);
        uint256 g = gasleft();
        exchange.listAsk(address(m1), 1, unit, uint64(block.timestamp + 1 days));
        console2.log("REPORT gas exchange listAsk (new)", g - gasleft());
        (PositionExchange.AskView[] memory bk,) = exchange.book(address(m1), 5);
        assertEq(bk.length, 1);
        assertEq(bk[0].slot, 1);
        deal(BEM, taker2, 50 * 1e8);
        taker2Start = IERC20(BEM).balanceOf(taker2);
        uint256 nh0 = IERC20(BEM).balanceOf(newHolder);
        vm.prank(taker2);
        IERC20(BEM).approve(address(exchange), type(uint256).max);
        uint256[] memory best = new uint256[](1);
        best[0] = bk[0].slot;
        vm.prank(taker2);
        g = gasleft();
        (uint256 filled, uint256 spent) = exchange.buyBest(address(m1), best, unit, bk[0].cost);
        console2.log("REPORT gas exchange buyBest 1 ask (incl. board hook)", g - gasleft());
        assertEq(filled, 1);
        assertEq(m1.socket(1).owner, taker2);
        assertEq(IERC20(BEM).balanceOf(newHolder) - nh0, spent, "seller paid directly");
        assertEq(exchange.recentTrades(address(m1)).length, 1);
        if (m1.credit(newHolder) > 0) m1.withdrawCredit(newHolder);
        assertEq(IERC20(BEM).balanceOf(address(exchange)), 0, "exchange holds nothing");

        // 买单：bidder3 挂本局通用买单（本金的 30%，预算 10 BEM），taker2 把刚买到的持仓卖给它；剩余预算不够下一份时自动退款
        deal(BEM, bidder3, 20 * 1e8);
        bidder3Start = IERC20(BEM).balanceOf(bidder3);
        vm.prank(bidder3);
        IERC20(BEM).approve(address(exchange), type(uint256).max);
        vm.prank(bidder3);
        g = gasleft();
        uint256 bidId = exchange.placeBid(address(m1), 30 * 1e8 / 100, 10 * 1e8, 0, type(uint256).max, uint64(block.timestamp + 1 days));
        console2.log("REPORT gas exchange placeBid", g - gasleft());
        (, PositionExchange.BidView[] memory bb) = exchange.book(address(m1), 5);
        assertEq(bb.length, 1);
        vm.prank(taker2);
        positions.setApprovalForAll(address(exchange), true);
        uint256 t2 = IERC20(BEM).balanceOf(taker2);
        vm.prank(taker2);
        g = gasleft();
        uint256 c2 = exchange.sellToBid(bidId, 1, 30 * 1e8 / 100);
        console2.log("REPORT gas exchange sellToBid (incl. board hook)", g - gasleft());
        assertEq(IERC20(BEM).balanceOf(taker2) - t2, c2, "seller paid directly from escrow");
        assertEq(m1.socket(1).owner, bidder3);
        if (exchange.bid(bidId).bidder != address(0)) {
            vm.prank(bidder3);
            exchange.cancelBid(bidId);
        }
        if (m1.credit(taker2) > 0) m1.withdrawCredit(taker2);
        assertEq(IERC20(BEM).balanceOf(address(exchange)), 0, "all escrow refunded");
        assertEq(exchange.recentTrades(address(m1)).length, 2);
        _checkMonth(m1);
    }

    /// @dev 多数清算（v2）：第 3 台按计划（起价 120%、底价 = 成本价，7 天线性下降）卖出；全体持有人投赞成
    function _liquidateLastMachineV2(uint256 cost3) internal {
        uint256[] memory idx = new uint256[](1);
        uint128[] memory st = new uint128[](1);
        uint128[] memory fl = new uint128[](1);
        idx[0] = 3;
        st[0] = uint128(cost3 * 12 / 10);
        fl[0] = uint128(cost3);
        bytes32 h = governor.publishPlan(address(m1), idx, st, fl);
        uint256 n = m1.socketCount();
        uint256[] memory all = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            all[i] = i + 1;
            uint256[] memory one = new uint256[](1);
            one[0] = i + 1;
            address o = m1.socket(i + 1).owner;
            vm.prank(o);
            governor.support(address(m1), one, h);
        }
        uint256 g = gasleft();
        governor.openVote(address(m1), h, all);
        console2.log("REPORT gas governor openVote (all positions)", g - gasleft());
        assertTrue(m1.governanceLocked());
        for (uint256 i = 0; i < n; i++) {
            uint256[] memory one = new uint256[](1);
            one[0] = i + 1;
            address o = m1.socket(i + 1).owner;
            vm.prank(o);
            governor.castVote(address(m1), one, 1);
        }
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m1));
        vm.warp(block.timestamp + 24 hours);
        g = gasleft();
        governor.execute(address(m1));
        console2.log("REPORT gas governor execute", g - gasleft());
        assertTrue(m1.liquidating());
        assertFalse(m1.governanceLocked());
        assertEq(sales.planAsk(address(m1), 3), cost3 * 12 / 10);
        assertLe(sales.askPrice(address(m1), 3), cost3 * 12 / 10, "ask = min(normal, plan)");
        vm.warp(block.timestamp + 7 days);
        assertEq(sales.planAsk(address(m1), 3), cost3, "plan floor reached");
        vm.prank(buyer);
        uint256 paid = sales.buyMachine(address(m1), 3, type(uint256).max);
        console2.log("REPORT m1 machine 3 sold under the majority plan", paid);
    }

    function _monthSettlement(uint256 subsidy) internal {
        _monthRelayV2();
        _positionTransferV2();

        // 第 8 阶段：卖价由报价公式决定，整台不低于成本价。运营地址报价：买一 = 卖一 = 第 1 台每单位成本 × 120%，
        // 第 1、2 台按公式价成交；第 3 台没人买，报价停运 7 天后按成本价可买（之后用多数清算卖出）
        uint256 cost1 = m1.machine(1).cost;
        uint256 cost3 = m1.machine(3).cost;
        uint256 unit = (cost1 * 12 / 10 + m1.machine(1).weight - 1) / m1.machine(1).weight;
        _post(unit);
        vm.prank(buyer);
        IERC20(BEM).approve(address(sales), type(uint256).max);
        uint256 ask1 = sales.askPrice(address(m1), 1);
        assertEq(ask1, unit * m1.machine(1).weight);
        vm.prank(buyer);
        uint256 paid1 = sales.buyMachine(address(m1), 1, ask1);
        assertGe(paid1, cost1 * 12 / 10);
        console2.log("REPORT m1 sold machine 1 at the market formula (~120% cost)", paid1);
        uint256 ask2 = sales.askPrice(address(m1), 2);
        assertGe(ask2, m1.machine(2).cost, "never below cost");
        vm.prank(buyer);
        sales.buyMachine(address(m1), 2, ask2);
        console2.log("REPORT m1 sold machine 2 at the market formula", ask2);
        vm.warp(block.timestamp + 3 hours);
        assertEq(sales.askPrice(address(m1), 3), 0, "stale feed: sale paused");
        vm.warp(m1.settleStart() + 8 days);
        assertEq(sales.askPrice(address(m1), 3), cost3, "feed abandoned for 7 days: at cost");
        m1.harvest();
        uint256 sumBefore = _sumBal(m1Players);
        vm.prank(operator);
        uint256 g = gasleft();
        sales.distribute(address(m1), 1, 50);
        console2.log("REPORT gas m1 distribute batch (all players incl. passes)", g - gasleft());
        console2.log("REPORT m1 first distribute pushed", _sumBal(m1Players) - sumBefore);
        vm.warp(block.timestamp + 10 days);
        m1.harvest();
        sumBefore = _sumBal(m1Players);
        vm.prank(operator);
        sales.distribute(address(m1), 1, 50);
        console2.log("REPORT m1 unsold machine yield pushed over 10 days", _sumBal(m1Players) - sumBefore);
        _liquidateLastMachineV2(cost3);
        assertEq(m1.unsoldMachines(), 0);
        vm.prank(operator);
        sales.distribute(address(m1), 1, 50);
        if (m1.credit(joiner1) > 0) m1.withdrawCredit(joiner1);
        if (m1.credit(newHolder) > 0) m1.withdrawCredit(newHolder);
        if (m1.credit(taker2) > 0) m1.withdrawCredit(taker2);
        _checkMonth(m1);

        // 守恒与到手：每人至少拿回本金；回馈资本滚存到月局工厂
        uint256 gains;
        for (uint256 s = 1; s <= m1.socketCount(); s++) {
            // 第 1 份已转让三次：原持有人 + newHolder + taker2 + bidder3 四方合计（成交价在各方之间转手，合计为 0）
            address u = s == 1 ? joiner1 : m1.socket(s).owner;
            uint256 gain = IERC20(BEM).balanceOf(u) - startBal[u];
            if (s == 1) {
                gain = gain + IERC20(BEM).balanceOf(newHolder) + IERC20(BEM).balanceOf(taker2) - taker2Start
                    + IERC20(BEM).balanceOf(bidder3) - bidder3Start;
            }
            gains += gain;
            assertGe(gain, uint256(m1.socket(s).stake), "principal returned");
            assertEq(IERC721(address(passCircuits)).ownerOf(m1.socket(s).passId), u, "pass returned");
        }
        uint256 bal = IERC20(BEM).balanceOf(address(m1));
        assertLe(bal, m1.socketCount() + 2, "m1 dust only");
        assertEq(m1.rolledOver(), subsidy, "subsidy capital rolled over");
        console2.log("REPORT m1 players total gain", gains, "dust", bal);
        console2.log("REPORT m1 rolled over to factory", m1.rolledOver());

        // 下一块开局的月局拿走滚存
        m3 = _freshPreparingMonth("m3");
        assertEq(m3.subsidyCapital(), subsidy, "m3 received rollover");
        console2.log("REPORT m3 number", m3.number(), "rollover received", m3.subsidyCapital());
        // 按市价收购（第 8 阶段）：运营地址报价（买一 = 卖一 = 一年产出上限的 90%），m3 按 min(卖一, 买一 × 1.005^…, 上限) 买入
        uint256 posted = m3.buyPriceCap() * 9 / 10;
        _post(posted);
        assertEq(m3.buyPrice(), posted);
        uint256 paid3 = _sellReal(address(m3), 1070, false);
        assertEq(paid3, uint256(m3.machine(m3.machineCount() - 1).weight) * posted, "bought at the posted price");
        _checkMonth(m3);

        // 模板升级（第 7 阶段）：手续费 Safe 提议同参数的新月局模板，公示 7 天后任何人生效；之后重开的月局用新模板，m3 不变
        address oldImpl = monthFactory.boardImplementation();
        bytes memory code = abi.encodePacked(type(MonthBoard).creationCode, abi.encode(monthFactory.boardConfig()));
        vm.prank(FEE_SAFE);
        g = gasleft();
        address impl = monthFactory.proposeImplementation(code);
        console2.log("REPORT gas proposeImplementation (month template, deploys 24 KB)", g - gasleft());
        vm.warp(monthFactory.pendingEta());
        monthFactory.activateImplementation();
        MonthBoard stale = MonthBoard(monthFactory.recruitingBoard());
        if (block.timestamp >= stale.recruitDeadline()) stale.closeRecruitment();
        address m4 = monthFactory.recruitingBoard();
        assertEq(monthFactory.implementationOf(m4), impl, "new board runs the new template");
        assertEq(monthFactory.implementationOf(address(m3)), oldImpl, "m3 unchanged");
    }

    /// @dev 运营地址报价（买一 = 卖一 = unit）：距上次不足 50 分钟先等够；上一次还有效且变动超过 5% 时先等它过期
    function _post(uint256 unit) internal {
        uint256 t = priceFeed.updatedAt();
        if (t != 0) {
            if (block.timestamp < t + 50 minutes) vm.warp(t + 50 minutes);
            uint256 last = priceFeed.bid();
            uint256 lastAsk = priceFeed.ask();
            bool big = unit * 10_000 > last * 10_500 || unit * 10_000 < last * 9_500 || unit * 10_000 > lastAsk * 10_500
                || unit * 10_000 < lastAsk * 9_500;
            if (big) {
                if (block.timestamp < t + 3 hours) vm.warp(t + 3 hours);
                _forceFeed(address(priceFeed), unit, unit);
                return;
            }
        }
        vm.prank(operator);
        priceFeed.post(unit, unit);
    }

    /// @dev 报价变动超过 5% 时（v2.0-audit.2 起合约任何时候都不接受，审计 H-1），按旧的时间线等过期后直接写报价合约的
    ///      bid / ask / updatedAt / catchingUp / liveAt（存储槽 0 / 1 / 2 / 5 / 6），相当于运营机器人已经分几次追到了这个价；只用于搭场景
    function _forceFeed(address f, uint256 bid_, uint256 ask_) internal {
        vm.store(f, bytes32(uint256(0)), bytes32(bid_));
        vm.store(f, bytes32(uint256(1)), bytes32(ask_));
        vm.store(f, bytes32(uint256(2)), bytes32(block.timestamp));
        vm.store(f, bytes32(uint256(5)), bytes32(0)); // catchingUp
        vm.store(f, bytes32(uint256(6)), bytes32(block.timestamp)); // liveAt
    }


    function _freshPreparingMonth(string memory tag) internal returns (MonthBoard r) {
        r = MonthBoard(monthFactory.recruitingBoard());
        if (block.timestamp >= r.recruitDeadline()) {
            r.closeRecruitment();
            r = MonthBoard(monthFactory.recruitingBoard());
        }
        _fillMonth(r, tag);
        assertTrue(r.isPurchasing());
    }

    function _fillMonth(MonthBoard mb, string memory tag) internal returns (address[] memory users) {
        users = new address[](600);
        uint256 n;
        while (mb.state() == MonthState.Recruiting) {
            address u = _newPlayer();
            uint256 span = mb.maxStake() - mb.minStake();
            uint256 amt = mb.minStake() + (uint256(keccak256(abi.encode(tag, n))) % span) / 1e6 * 1e6;
            _join(address(mb), u, amt);
            users[n++] = u;
        }
        assembly {
            mstore(users, n)
        }
    }

    function _checkMonth(MonthBoard mb) internal view {
        uint256 bal = IERC20(BEM).balanceOf(address(mb));
        MonthState st = mb.state();
        if (st == MonthState.Settling) {
            assertGe(bal, mb.liabilities(), "month: balance >= liabilities");
        } else if (st == MonthState.Preparing || st == MonthState.Mining || st == MonthState.Drawing) {
            assertEq(bal, mb.budget() + mb.prizePool(), "month: balance == budget + prize pool");
        }
    }

    // =====================================================================
    // 辅助
    // =====================================================================

    /// @dev 新玩家：真实铸造 5 颗创世 NAND 并流片 HA1 通行证，再发一些 BEM（deal）
    function _newPlayer() internal returns (address u) {
        u = address(uint160(uint256(keccak256(abi.encode("player", ++playerNonce)))));
        vm.deal(u, 1 ether);
        vm.startPrank(u);
        transistors.mint{value: 5 * 0.0011 ether}(0, 5);
        vm.recordLogs();
        (bool ok,) =
            address(passCircuits).call{value: 0.0002 ether}(abi.encodeCall(ICircuits.tapeout, (PASS_NETLIST, 2, 2)));
        require(ok, "tapeout");
        vm.stopPrank();
        uint256 passId = _mintedId(vm.getRecordedLogs(), address(passCircuits));
        passOf[u] = passId;
        deal(BEM, u, 50 * BEM_1);
    }

    mapping(address => uint256) internal passOf;

    function _playerAt(uint256 i) internal returns (address) {
        // 创世前铸好的 45 个玩家：编号 1..45
        if (i < 45) return address(uint160(uint256(keccak256(abi.encode("player", i + 1)))));
        return _newPlayer();
    }

    function _join(address board, address u, uint256 amt) internal {
        uint256 passId = passOf[u];
        vm.startPrank(u);
        IERC721(address(passCircuits)).approve(board, passId);
        IERC20(BEM).approve(board, type(uint256).max);
        TapeBoard(board).join(passId, amt); // 两种主板的 join 签名相同
        vm.stopPrank();
        startBal[u] = IERC20(BEM).balanceOf(u);
    }

    /// @dev 规则决定 6.37：主板只认 MarketTrader。这里模拟"MarketTrader 已经在市场上买下这台真实矿机"：矿机从真实持有人
    ///      转给 MarketTrader，再以它的身份按 计价算力 × 收购价上限 卖给主板，收到的 BEM（货款和主板替它领到的旧产出）转回原持有人
    function _sellReal(address board, uint256 id, bool logGas) internal returns (uint256 paid) {
        address owner = IERC721(CIRC).ownerOf(id);
        (, uint256 w) = rules.check(CIRC, id, 0, type(uint256).max, 0);
        uint256 spent = w * TapeBoard(board).buyPrice(); // 两种主板的 buyPrice / sellMachine 签名相同
        vm.prank(owner);
        IERC721(CIRC).transferFrom(owner, traderAddr, id);
        uint256 b0 = IERC20(BEM).balanceOf(traderAddr);
        vm.startPrank(traderAddr);
        IERC721(CIRC).approve(board, id);
        uint256 g = gasleft();
        paid = TapeBoard(board).sellMachine(CIRC, id, spent);
        uint256 used = g - gasleft();
        IERC20(BEM).transfer(owner, IERC20(BEM).balanceOf(traderAddr) - b0);
        vm.stopPrank();
        if (logGas) console2.log("REPORT gas sellMachine (real PoD claim + transfer)", used);
        console2.log("REPORT sold machine id", id, "paid", paid);
    }

    /// @dev VRF：由协调器地址调用适配器回调（真实适配器，回调 gas 上限与协调器相同）
    function _fulfill(uint256 requestId, uint256 seed) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256(abi.encode("vrf", seed, requestId)));
        vm.prank(VRF_COORDINATOR);
        uint256 g = gasleft();
        adapter.rawFulfillRandomWords{gas: CALLBACK_GAS}(requestId, words);
        uint256 used = g - gasleft();
        if (used > maxCallbackGas) maxCallbackGas = used;
        callbackCount++;
    }

    function _sumBal(address[] memory us) internal view returns (uint256 t) {
        for (uint256 i = 0; i < us.length; i++) {
            t += IERC20(BEM).balanceOf(us[i]);
        }
    }

    function _mintedId(Vm.Log[] memory logs, address token) internal pure returns (uint256) {
        bytes32 sig = keccak256("Transfer(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == token && logs[i].topics.length == 4 && logs[i].topics[0] == sig) {
                if (logs[i].topics[1] == bytes32(0)) return uint256(logs[i].topics[3]);
            }
        }
        revert("no mint event");
    }

    receive() external payable {}
}
