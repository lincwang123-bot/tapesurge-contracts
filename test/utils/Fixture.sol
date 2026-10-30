// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BoardFactory} from "../../src/BoardFactory.sol";
import {GenesisSplitter} from "../../src/GenesisSplitter.sol";
import {TapeBoard} from "../../src/TapeBoard.sol";
import {MonthBoard} from "../../src/MonthBoard.sol";
import {MonthFactory} from "../../src/MonthFactory.sol";
import {MonthPositions} from "../../src/month/MonthPositions.sol";
import {MonthMachineSales} from "../../src/month/MonthMachineSales.sol";
import {PositionExchange} from "../../src/month/PositionExchange.sol";
import {MarketPriceFeed} from "../../src/MarketPriceFeed.sol";
import {StdMachineSales} from "../../src/StdMachineSales.sol";
import {MarketTrader} from "../../src/market/MarketTrader.sol";
import {MachineLister} from "../../src/market/MachineLister.sol";
import {MachineRules} from "../../src/MachineRules.sol";
import {MockOfficialMarket, MockSeaport, MockWBNB} from "../../src/mocks/MockMarkets.sol";
import {MockFirstoAskExchange, MockFirstoBidExchange, MockFirstoSwapper, MockFirstoSignedAsk} from "../../src/mocks/MockFirsto.sol";
import {MonthExitGovernor} from "../../src/month/MonthExitGovernor.sol";
import {MonthState} from "../../src/interfaces/IMonthBoard.sol";
import {BoardState, SettleMode} from "../../src/interfaces/ITapeBoard.sol";
import {MockBEM} from "../../src/mocks/MockBEM.sol";
import {MockPoD} from "../../src/mocks/MockPoD.sol";
import {MockCircuits, MockBeacon} from "../../src/mocks/MockCircuits.sol";
import {MockTapeOutFactory, MockTransistors} from "../../src/mocks/MockTapeOut.sol";
import {MockRandomSource} from "../../src/mocks/MockRandom.sol";
import {MockRouter, MockPriceOracle} from "../../src/mocks/MockSwap.sol";
import {TapeSurgeDefaults} from "../../script/TapeSurgeDefaults.sol";

/// @notice 测试夹具：部署全部 Mock 与 BoardFactory（默认参数来自 script/TapeSurgeDefaults.sol，与 README 一致）。
abstract contract Fixture is Test {
    address internal constant FOUNDATION = 0x04B649076a11819EF7AdA36e02DD55e0923550Ee;
    address internal constant FEE_SAFE = 0x6ea5FfB01378a1E5ce55C8A119A90a87e542C995;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant WBNB = address(0xBB4C);
    address internal constant USDT = address(0x55D3);

    /// @dev 白皮书附录 B：Surge Pass · HA1（5 个 NAND 的半加器）
    bytes internal constant PASS_NETLIST = hex"0000000200000300000002000004000000030000040000000500000600000004000004";
    bytes32 internal constant PASS_HASH = 0xfffa29f1e30fa6438ba0e6ebd40ef157b53d0eff3f21cc4bc46942e27cb32ca0;
    /// @dev 模拟官方矿机用的任意网表（1 个 NAND）
    bytes internal constant MACHINE_NETLIST = hex"00000002000003";

    uint256 internal constant BEM_1 = 1e8;
    uint256 internal constant START_TIME = 1_790_000_000; // 2026-09
    /// @dev 主网 2026-10-19 读到的已验证总权重
    uint256 internal constant MAINNET_VERIFIED_WEIGHT = 1_580_163;
    /// @dev 1 BNB ≈ 21.93 BEM（白皮书按 1 BEM ≈ 0.0456 BNB 换算）
    uint256 internal constant BEM_PER_BNB = 2_193_000_000;

    MockBEM internal bem;
    MockPoD internal pod;
    MockCircuits internal machines;
    MockBeacon internal machineBeacon;
    MockTapeOutFactory internal tapeout;
    MockRandomSource internal rng;
    MockRouter internal router;
    MockPriceOracle internal oracle;

    BoardFactory internal factory;
    MonthFactory internal monthFactory;
    MonthPositions internal positions;
    MonthMachineSales internal sales;
    PositionExchange internal exchange;
    MarketPriceFeed internal priceFeed;
    StdMachineSales internal stdSales;
    MockFirstoAskExchange internal firstoAsk;
    MockFirstoBidExchange internal firstoBid;
    MockFirstoSwapper internal firstoSwapper;
    MarketTrader internal trader;
    MachineRules internal rules;
    MockOfficialMarket internal officialMarket;
    MockWBNB internal wbnbToken;
    MockSeaport internal seaport;
    MockFirstoSignedAsk internal firstoSigned;
    MachineLister internal lister;
    address internal constant MARKET_WALLET = address(0x0FF1);
    address payable internal constant TM_FEE = payable(address(0x7EEE));
    address internal constant FIRSTO_FEE_TO = address(0xF1F0);
    MonthExitGovernor internal governor;
    GenesisSplitter internal splitter;
    MockTransistors internal transistors;
    MockCircuits internal passCircuits;

    uint256 internal userNonce;
    uint256 internal machineNonce;

    function setUp() public virtual {
        vm.warp(START_TIME);
        _deployMocks();
        _deploySystem(defaultParams());
    }

    function _deployMocks() internal {
        bem = new MockBEM();
        pod = new MockPoD(address(bem));
        pod.setTotalVerifWeight(MAINNET_VERIFIED_WEIGHT);
        machines = new MockCircuits("TapeOut Circuits", "CIRC", address(0), 0.0002 ether);
        machineBeacon = new MockBeacon(address(0xB1B1));
        tapeout = new MockTapeOutFactory(1);
        tapeout.registerCPU(address(machines)); // 模拟官方矿机电路合约是工厂创建的处理器
        rng = new MockRandomSource();
        router = new MockRouter(WBNB, address(bem), BEM_PER_BNB);
        oracle = new MockPriceOracle(BEM_PER_BNB);
        wbnbToken = new MockWBNB();
        firstoSigned = new MockFirstoSignedAsk(FIRSTO_FEE_TO);
    }

    function swapPath() internal view returns (bytes memory) {
        return abi.encodePacked(WBNB, uint24(100), USDT, uint24(10_000), address(bem));
    }

    function defaultAddresses() internal view returns (TapeSurgeDefaults.Addresses memory) {
        return TapeSurgeDefaults.Addresses({
            tapeoutFactory: address(tapeout),
            bem: address(bem),
            pod: address(pod),
            machineCircuits: address(machines),
            circuitsBeacon: address(machineBeacon),
            passBeacon: address(tapeout.circuitsBeacon()),
            randomSource: address(rng),
            wbnb: WBNB,
            usdt: USDT,
            router: address(router),
            oracle: address(oracle),
            foundation: FOUNDATION,
            feeSafe: FEE_SAFE,
            // v2 单例的占位地址（_deploySystem 会换成按 nonce 预测的真实地址）
            monthPositions: address(0x9051),
            monthSales: address(0x5A1E),
            monthGovernor: address(0x6011),
            priceFeed: address(0xFEED),
            stdSales: address(0x5D5A),
            marketTrader: address(0x7AD3),
            machineRules: address(0x7A1E)
        });
    }

    /// @dev 默认参数：与测试网部署脚本、README 完全相同（script/TapeSurgeDefaults.sol）
    function defaultParams() internal view returns (BoardFactory.Params memory) {
        return TapeSurgeDefaults.params(defaultAddresses());
    }

    /// @dev 分账合约默认参数（boardFactory 在部署时填入）
    function defaultSplitterParams() internal view returns (GenesisSplitter.Params memory) {
        return TapeSurgeDefaults.splitterParams(defaultAddresses());
    }

    /// @dev 1,000 BEM / 单人 1–20 BEM 的参数组（参数化测试用）
    function params1000() internal view returns (BoardFactory.Params memory p) {
        p = defaultParams();
        p.targets.initialTarget = 1_000 * BEM_1;
        p.targets.minStakeBps = 10; // 1 BEM
        p.targets.maxStakeBps = 200; // 20 BEM
    }

    /// @dev 月局默认参数（script/TapeSurgeDefaults.sol）
    function defaultMonthParams() internal view returns (MonthFactory.Params memory) {
        return TapeSurgeDefaults.monthParams(defaultAddresses());
    }

    function _deploySystem(BoardFactory.Params memory p) internal {
        _deploySystem(p, defaultMonthParams());
    }

    function _deploySystem(BoardFactory.Params memory p, MonthFactory.Params memory mp) internal {
        _deploySystem(p, mp, defaultSplitterParams());
    }

    /// @dev 依次部署分账合约、BoardFactory、MonthFactory（后两个的地址提前算好）。
    ///      没有指定运营地址时，测试合约本身就是运营地址。
    function _deploySystem(
        BoardFactory.Params memory p,
        MonthFactory.Params memory mp,
        GenesisSplitter.Params memory sp
    ) internal {
        _deploySplitter(sp, p);
        uint256 n = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), n + 1);
        address predictedPositions = vm.computeCreateAddress(address(this), n + 2);
        address predictedSales = vm.computeCreateAddress(address(this), n + 3);
        address predictedGovernor = vm.computeCreateAddress(address(this), n + 4);
        address predictedFeed = vm.computeCreateAddress(address(this), n + 6);
        address predictedStdSales = vm.computeCreateAddress(address(this), n + 7);
        p.board.priceFeed = predictedFeed;
        p.board.sales = predictedStdSales;
        // 第 9 阶段：mock 卖单（n + 8）、mock 统一买单（n + 9）、mock 兑换适配器（n + 10）、MarketTrader（n + 11）；
        // rc8：MachineRules（n + 12）、模拟官方矿机市场（n + 13）、模拟 Seaport（n + 14）、MachineLister（n + 15）
        p.board.trader = vm.computeCreateAddress(address(this), n + 11);
        mp.board.trader = p.board.trader;
        p.board.machineRules = vm.computeCreateAddress(address(this), n + 12);
        mp.board.machineRules = p.board.machineRules;
        address predictedLister = vm.computeCreateAddress(address(this), n + 15);
        p.monthFactory = predicted;
        if (p.initialOperator == address(0)) p.initialOperator = address(this);
        mp.board.positions = predictedPositions;
        p.board.positions = predictedPositions; // 持仓凭证两种局共用（规则决定 6.23）
        mp.board.sales = predictedSales;
        mp.board.governor = predictedGovernor;
        mp.board.priceFeed = predictedFeed;
        factory = new BoardFactory(p);
        monthFactory = new MonthFactory(address(factory), mp);
        positions = new MonthPositions(address(monthFactory), address(factory));
        sales = new MonthMachineSales(
            address(bem),
            address(monthFactory),
            address(factory),
            predictedGovernor,
            mp.board.operatorGrace,
            TapeSurgeDefaults.MONTH_PLAN_DECAY,
            predictedLister
        );
        governor = new MonthExitGovernor(
            address(monthFactory),
            address(sales),
            TapeSurgeDefaults.GOV_MIN_SETTLE_AGE,
            TapeSurgeDefaults.GOV_VOTE_PERIOD,
            TapeSurgeDefaults.GOV_EXECUTION_DELAY,
            TapeSurgeDefaults.GOV_EXECUTION_WINDOW,
            TapeSurgeDefaults.GOV_FAIL_COOLDOWN,
            TapeSurgeDefaults.GOV_REPRICE_COOLDOWN
        );
        exchange = new PositionExchange(address(bem), address(positions), address(monthFactory), address(factory));
        priceFeed = new MarketPriceFeed(address(factory), TapeSurgeDefaults.feedParams(TapeSurgeDefaults.FEED_ABANDON_AFTER));
        assertEq(address(priceFeed), predictedFeed, "price feed address prediction");
        stdSales = new StdMachineSales(
            address(bem),
            address(factory),
            TapeSurgeDefaults.STD_MARKET_PERIOD,
            TapeSurgeDefaults.STD_SELL_DECAY,
            TapeSurgeDefaults.STD_SELL_FLOOR_HOLD,
            p.board.operatorGrace,
            TapeSurgeDefaults.PREMIUM_FEE_BPS,
            predictedLister
        );
        assertEq(address(stdSales), predictedStdSales, "std sales address prediction");
        firstoAsk = new MockFirstoAskExchange(FIRSTO_FEE_TO);
        firstoBid = new MockFirstoBidExchange(address(pod), mp.board.verifiedShareBps, FIRSTO_FEE_TO);
        firstoSwapper = new MockFirstoSwapper(address(bem), address(oracle));
        _deployMarkets(p.board.trader, p.board.machineRules, predictedLister);
        firstoSwapper.setTrader(address(trader));
        vm.deal(address(firstoSwapper), 1_000 ether);
        assertEq(address(monthFactory), predicted, "month factory address prediction");
        assertEq(address(positions), predictedPositions, "positions address prediction");
        assertEq(address(sales), predictedSales, "sales address prediction");
        assertEq(address(governor), predictedGovernor, "governor address prediction");
        splitter = factory.splitter();
        transistors = MockTransistors(address(factory.transistors()));
        passCircuits = MockCircuits(factory.passCircuits());
    }

    /// @dev MarketTrader（n + 11）→ MachineRules（n + 12）→ 模拟官方矿机市场（n + 13）→ 模拟 Seaport（n + 14）→ MachineLister（n + 15）
    function _deployMarkets(address predictedTrader, address predictedRules, address predictedLister) internal {
        uint256 n = vm.getNonce(address(this));
        trader = new MarketTrader(
            address(bem),
            address(factory),
            MarketTrader.Markets({
                askExchange: address(firstoAsk),
                signedAsk: address(firstoSigned),
                bidExchange: address(firstoBid),
                officialMarket: vm.computeCreateAddress(address(this), n + 2),
                seaport: vm.computeCreateAddress(address(this), n + 3),
                wbnb: address(wbnbToken)
            }),
            address(firstoSwapper),
            address(oracle),
            address(pod),
            TapeSurgeDefaults.FIRSTO_SLIPPAGE_BPS
        );
        assertEq(address(trader), predictedTrader, "trader address prediction");
        rules = new MachineRules(address(pod), address(tapeout), address(machines));
        assertEq(address(rules), predictedRules, "rules address prediction");
        officialMarket = new MockOfficialMarket(address(tapeout), MARKET_WALLET);
        seaport = new MockSeaport();
        lister = new MachineLister(
            address(bem),
            address(factory),
            MachineLister.Markets({
                officialMarket: address(officialMarket),
                seaport: address(seaport),
                seaportFeeRecipient: TM_FEE,
                seaportFeeBps: TapeSurgeDefaults.TAPEMARKET_FEE_BPS,
                firstoSignedAsk: address(firstoSigned)
            }),
            address(firstoSwapper),
            address(oracle),
            TapeSurgeDefaults.FIRSTO_SLIPPAGE_BPS,
            TapeSurgeDefaults.LISTER_REPRICE_BPS,
            TapeSurgeDefaults.LISTER_REPRICE_INTERVAL,
            TapeSurgeDefaults.LISTER_DURATION
        );
        assertEq(address(lister), predictedLister, "lister address prediction");
    }

    /// @dev 部署分账合约（boardFactory 指向紧接着的下一笔部署），并把地址填进 p.splitter
    function _deploySplitter(GenesisSplitter.Params memory sp, BoardFactory.Params memory p)
        internal
        returns (GenesisSplitter s)
    {
        sp.boardFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        s = new GenesisSplitter{value: tapeout.deployFee()}(sp);
        p.splitter = address(s);
    }

    /// @dev 测试合约（运营地址）报价：买一 = bid、卖一 = ask（每单位权重）。距上次不足 50 分钟时先等够。
    ///      变动超过 5% 时（rc 审计修复后合约任何时候都不接受，审计 H-1），测试按旧的时间线先等 3 小时，再直接写入报价合约的
    ///      存储，相当于机器人已经分几次追到了这个价（只用于搭场景；限幅本身由 MarketPriceFeed.t.sol / AuditPoC.t.sol 测）
    function _postPrices(uint256 bid, uint256 ask) internal {
        uint256 t = priceFeed.updatedAt();
        if (t != 0) {
            if (block.timestamp < t + 50 minutes) vm.warp(t + 50 minutes);
            uint256 lb = priceFeed.bid();
            uint256 la = priceFeed.ask();
            bool big = bid * 10_000 > lb * 10_500 || bid * 10_000 < lb * 9_500 || ask * 10_000 > la * 10_500
                || ask * 10_000 < la * 9_500;
            if (big) {
                if (block.timestamp < t + 3 hours) vm.warp(t + 3 hours);
                _forcePrices(bid, ask);
                return;
            }
        }
        priceFeed.post(bid, ask);
    }

    /// @dev 直接写报价合约的 bid / ask / updatedAt / catchingUp / liveAt（存储槽 0 / 1 / 2 / 5 / 6），当作一次有效报价
    function _forcePrices(uint256 bid, uint256 ask) internal {
        vm.store(address(priceFeed), bytes32(uint256(0)), bytes32(bid));
        vm.store(address(priceFeed), bytes32(uint256(1)), bytes32(ask));
        vm.store(address(priceFeed), bytes32(uint256(2)), bytes32(block.timestamp));
        vm.store(address(priceFeed), bytes32(uint256(5)), bytes32(0));
        vm.store(address(priceFeed), bytes32(uint256(6)), bytes32(block.timestamp));
    }

    /// @dev 让月局第 index 台的整台卖价约等于成本价 × bps（买一 = 卖一 = 每单位价，向上取整）
    function _unitFor(MonthBoard mb, uint256 index, uint256 bps) internal view returns (uint256) {
        uint256 w = mb.machine(index).weight;
        return (uint256(mb.machine(index).cost) * bps / 10_000 + w - 1) / w;
    }

    /// @dev 标准局终局卖出一台矿机（经 StdMachineSales）：市价期内报价无效时，测试合约（运营地址）按底价报一次
    ///      买一 = 卖一 = 底价（卖价 = 底价）；拍卖期按拍卖价。buyer 按要价买走。
    /// @dev 标准局：who 当前持有的第一份持仓（0 = 没有）。rc6 起按持仓记账（规则决定 6.23）
    function _slotOf(TapeBoard b, address who) internal view returns (uint256) {
        uint256 n = b.socketCount();
        for (uint256 s = 1; s <= n; s++) {
            if (b.socket(s).owner == who) return s;
        }
        return 0;
    }

    /// @dev 标准局：who 名下的记账款 + 他持有的全部持仓的可领金额（rc6 之前 owed(address) 的口径）
    function _owedOf(TapeBoard b, address who) internal view returns (uint256 amount) {
        amount = b.credit(who);
        uint256 n = b.socketCount();
        for (uint256 s = 1; s <= n; s++) {
            if (b.socket(s).owner == who) amount += stdSales.owed(address(b), s);
        }
    }

    function _stdBuy(TapeBoard b, uint256 index, address buyer) internal returns (uint256 cost) {
        (, uint8 phase) = stdSales.askPrice(address(b), index);
        if (phase == 0) {
            uint256 p = b.sellFloorPrice();
            if (p == 0) p = 1;
            priceFeed.post(p, p);
        }
        vm.startPrank(buyer);
        bem.approve(address(stdSales), type(uint256).max);
        cost = stdSales.buyMachine(address(b), index, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev 部署后满 7 天开局，返回第 1 块主板。
    ///      开局前必须报过价（全局审计 G-1）：还没报过时先报一次，开局后把报价合约恢复成"从没报过价"
    ///      （updatedAt / liveAt 清零），让与报价无关的测试继续用主板的默认曲线收购，不必每个测试都维持报价有效。
    ///      生产中开局后报价合约不会回到这个状态；报过价之后的收购规则由 MarketPriceFeed.t.sol / AuditGlobal.t.sol 测。
    function _startGenesis() internal returns (TapeBoard b) {
        vm.warp(block.timestamp + 7 days);
        if (priceFeed.updatedAt() != 0) return TapeBoard(factory.startGenesis());
        priceFeed.post(1, 1);
        b = TapeBoard(factory.startGenesis());
        vm.store(address(priceFeed), bytes32(uint256(0)), bytes32(0));
        vm.store(address(priceFeed), bytes32(uint256(1)), bytes32(0));
        vm.store(address(priceFeed), bytes32(uint256(2)), bytes32(0));
        vm.store(address(priceFeed), bytes32(uint256(6)), bytes32(0));
    }

    function _board() internal view returns (TapeBoard) {
        return TapeBoard(factory.recruitingBoard());
    }

    function _monthBoard() internal view returns (MonthBoard) {
        return MonthBoard(monthFactory.recruitingBoard());
    }

    // ---------------- 月局 ----------------

    /// @dev v2：地址 → 它持有的（第一份）持仓插槽；没有时为 0（测试辅助，线性查找）
    function _slot(MonthBoard mb, address u) internal view returns (uint256) {
        uint256 n = mb.socketCount();
        for (uint256 i = 1; i <= n; i++) {
            if (mb.socket(i).owner == u) return i;
        }
        return 0;
    }

    /// @dev v2：某地址在月局可领的全部 BEM = 它持有的持仓可领 + 转让结转款
    function _mOwed(MonthBoard mb, address u) internal view returns (uint256 amount) {
        uint256 n = mb.socketCount();
        for (uint256 i = 1; i <= n; i++) {
            if (mb.socket(i).owner == u) amount += mb.owed(i);
        }
        amount += mb.credit(u);
    }

    function _mWithdraw(MonthBoard mb, address u) internal returns (uint256 amount) {
        uint256 n = mb.socketCount();
        for (uint256 i = 1; i <= n; i++) {
            if (mb.socket(i).owner == u && mb.owed(i) > 0) amount += mb.withdraw(i);
        }
        if (mb.credit(u) > 0) amount += mb.withdrawCredit(u);
        if (amount == 0) revert MonthBoard.NothingToWithdraw();
    }

    function _mClaimAll(MonthBoard mb, address u) internal returns (uint256 amount) {
        uint256 n = mb.socketCount();
        for (uint256 i = 1; i <= n; i++) {
            if (mb.socket(i).owner == u) amount += mb.claimAll(i);
        }
        if (!mb.claimsClosed() && mb.credit(u) > 0) amount += mb.withdrawCredit(u);
    }

    function _mReturnPass(MonthBoard mb, address u) internal {
        mb.returnPass(_slot(mb, u));
    }

    /// @dev v2 交接：等接手方的收购价涨到不低于出让方成本价（每 6 小时 +5%），再交接；返回实际成交额
    function _relayWhenPriced(MonthBoard from, uint256 index, MonthBoard to) internal returns (uint256 paid) {
        uint256 cost = from.machine(index).cost;
        uint256 w = from.machine(index).weight;
        while (to.buyPrice() * w < cost && to.isPurchasing()) {
            vm.warp(block.timestamp + 6 hours);
        }
        paid = sales.relay(address(from), index, address(to));
    }

    function _joinMonth(MonthBoard mb, uint256 amount) internal returns (address user) {
        user = _newUser();
        uint256 passId = _mintPass(user);
        bem.mint(user, amount * 2);
        vm.startPrank(user);
        passCircuits.approve(address(mb), passId);
        bem.approve(address(mb), type(uint256).max);
        mb.join(passId, amount);
        vm.stopPrank();
    }

    /// @dev 用最大投入把月局招满
    function _fillMonth(MonthBoard mb) internal returns (address[] memory users) {
        uint256 n;
        uint256 maxS = mb.maxStake();
        users = new address[](mb.target() / maxS + 1);
        while (mb.state() == MonthState.Recruiting) {
            users[n++] = _joinMonth(mb, maxS);
        }
        assembly {
            mstore(users, n)
        }
    }

    function _sellMonth(MonthBoard mb, address seller, uint256 weight)
        internal
        returns (uint256 id, bytes32 key, uint256 paid)
    {
        (id, key) = _newMachine(seller, weight);
        paid = _traderSell(address(mb), address(machines), id, seller, weight * mb.buyPrice());
    }

    // ---------------- 参与者 ----------------

    function _newUser() internal returns (address u) {
        u = address(uint160(0x100000 + ++userNonce));
        vm.label(u, string.concat("user", vm.toString(userNonce)));
    }

    /// @dev 用户铸 5 颗创世 NAND，按标准网表流片，得到通行证
    function _mintPass(address user) internal returns (uint256 passId) {
        return _mintCircuit(user, PASS_NETLIST);
    }

    function _mintCircuit(address user, bytes memory nl) internal returns (uint256 id) {
        uint256 gates = nl.length / 7;
        vm.deal(user, user.balance + 1 ether);
        vm.startPrank(user);
        transistors.mint{value: (0.001 ether + 0.0001 ether) * gates}(0, gates);
        id = passCircuits.tapeout{value: 0.0002 ether}(nl, 2, 2);
        vm.stopPrank();
    }

    function _approveAndJoin(TapeBoard b, address user, uint256 passId, uint256 amount) internal {
        bem.mint(user, amount * 2);
        vm.startPrank(user);
        passCircuits.approve(address(b), passId);
        bem.approve(address(b), type(uint256).max);
        b.join(passId, amount);
        vm.stopPrank();
    }

    function _join(TapeBoard b, uint256 amount) internal returns (address user) {
        user = _newUser();
        _approveAndJoin(b, user, _mintPass(user), amount);
    }

    function _fill(TapeBoard b, uint256[] memory stakes) internal returns (address[] memory users) {
        users = new address[](stakes.length);
        for (uint256 i = 0; i < stakes.length; i++) {
            users[i] = _join(b, stakes[i]);
        }
    }

    /// @dev count 个人各投 amount
    function _fillUniform(TapeBoard b, uint256 count, uint256 amount) internal returns (address[] memory users) {
        uint256[] memory stakes = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            stakes[i] = amount;
        }
        return _fill(b, stakes);
    }

    // ---------------- 矿机 ----------------

    /// @dev 新建一台已验证、在挖、已运行 30 天的官方矿机
    function _newMachine(address owner, uint256 weight) internal returns (uint256 id, bytes32 key) {
        id = machines.mintCircuit(owner, MACHINE_NETLIST, 2, 1);
        key = pod.register(address(machines), id, weight);
        pod.setSince(key, block.timestamp - 30 days);
        machineNonce++;
    }

    function _sell(TapeBoard b, address seller, uint256 weight)
        internal
        returns (uint256 id, bytes32 key, uint256 paid)
    {
        (id, key) = _newMachine(seller, weight);
        paid = _traderSell(address(b), address(machines), id, seller, weight * b.buyPrice());
    }

    /// @dev 规则决定 6.37：主板只认 MarketTrader。测试里模拟"MarketTrader 已经在市场上买下卖家的矿机"：矿机从卖家转给
    ///      MarketTrader 并授权主板（_toTrader），再以它的身份按 spent（实际花费）卖给主板；MarketTrader 收到的 BEM
    ///      （货款和主板替它领到的旧产出）原样转回卖家，保持旧测试"卖家收钱"的口径。
    function _traderSell(address board, address collection, uint256 id, address seller, uint256 spent)
        internal
        returns (uint256 paid)
    {
        _toTrader(board, collection, id, seller);
        uint256 before = bem.balanceOf(address(trader));
        vm.prank(address(trader));
        paid = TapeBoard(board).sellMachine(collection, id, spent); // 两种主板的 sellMachine 签名相同
        uint256 got = bem.balanceOf(address(trader)) - before;
        vm.prank(address(trader));
        bem.transfer(seller, got);
    }

    /// @dev 矿机从 seller 转给 MarketTrader，并由 MarketTrader 授权给 board（之后测试自己 vm.prank(address(trader)) 调 sellMachine）
    function _toTrader(address board, address collection, uint256 id, address seller) internal {
        vm.prank(seller);
        MockCircuits(collection).transferFrom(seller, address(trader), id);
        vm.prank(address(trader));
        MockCircuits(collection).approve(board, id);
    }

    /// @dev 给主板第 index 台矿机注入产出
    function _yield(TapeBoard b, uint256 index, uint256 amount) internal {
        pod.addYield(b.machine(index).key, amount);
    }

    // ---------------- 开奖 ----------------

    function _pulseAndFulfill(TapeBoard b, uint256 word) internal returns (uint256 requestId) {
        b.pulse();
        requestId = b.pendingRequestId();
        rng.fulfill(requestId, word);
    }

    /// @dev 一直开奖到只剩硅王，每次先补足脉冲池
    function _drawUntilKing(TapeBoard b, uint256 seed) internal {
        uint256 i;
        while (b.aliveCount() > 1) {
            _topUpPool(b);
            _pulseAndFulfill(b, uint256(keccak256(abi.encode(seed, i++))));
        }
    }

    /// @dev 补足脉冲池到开奖门槛
    function _topUpPool(TapeBoard b) internal {
        uint256 threshold = b.drawThreshold();
        uint256 p = b.pool();
        if (p < threshold) _yield(b, 0, threshold - p);
    }

    function _sum(uint256[] memory a) internal pure returns (uint256 s) {
        for (uint256 i = 0; i < a.length; i++) {
            s += a[i];
        }
    }

    /// @dev 白皮书公式：一次脉冲的总额 = ceil(投入 × 105% ÷ 95%)
    function _gross(uint256 stake) internal pure returns (uint256) {
        uint256 payout = stake * 10_500 / 10_000;
        return (payout * 10_000 + 9_499) / 9_500;
    }
}
