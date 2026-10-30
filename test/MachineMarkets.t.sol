// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MachineRules} from "../src/MachineRules.sol";
import {MarketTrader} from "../src/market/MarketTrader.sol";
import {MachineLister, ListingVault} from "../src/market/MachineLister.sol";
import {MonthMachineSales} from "../src/month/MonthMachineSales.sol";
import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";
import {StdMachineSales} from "../src/StdMachineSales.sol";
import {SignedAsk, FirstoSignedAskLib} from "../src/market/FirstoSignedAsk.sol";
import {MockFirstoSignedAsk} from "../src/mocks/MockFirsto.sol";
import {MockCircuits} from "../src/mocks/MockCircuits.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    Order,
    OrderComponents,
    OrderParameters,
    OfferItem,
    ConsiderationItem
} from "../src/market/IMarkets.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {BoardState, SettleMode} from "../src/interfaces/ITapeBoard.sol";

/// @title rc8（规则决定 6.26）：PoD 字段、多合集、多市场买卖、主板矿机挂单——本地 mock 市场
contract MachineMarketsTest is Fixture {
    address internal seller = address(0x5E11);
    /// @dev 递单的运营地址（规则决定 6.37：买入只认运营地址；夹具的运营地址就是测试合约自己）
    address internal keeper = address(this);
    address internal buyer = address(0xB0B0);
    address internal bidder = address(0xB1DD);
    MockCircuits internal behemoth;

    function setUp() public override {
        super.setUp();
        // 第二个合集：和"官方矿机"同一份代码（同一个信标代理的模拟），工厂创建，处理器倍数 6（主网 Behemoth）
        behemoth = new MockCircuits("Behemoth", "BEH", address(0), 0.0002 ether);
        tapeout.registerCPU(address(behemoth));
        pod.setMultiplier(address(behemoth), 6);
        vm.deal(buyer, 1_000 ether);
        vm.deal(keeper, 1 ether);
    }

    // ---------------- 辅助 ----------------

    function _newIn(MockCircuits c, address owner, uint256 baseWeight) internal returns (uint256 id, bytes32 key) {
        id = c.mintCircuit(owner, MACHINE_NETLIST, 2, 1);
        key = pod.register(address(c), id, baseWeight);
        pod.setSince(key, block.timestamp - 30 days);
    }

    function _monthPreparing() internal returns (MonthBoard m) {
        _startGenesis();
        m = _monthBoard();
        _fillMonth(m);
        assertTrue(m.isPurchasing());
    }

    function _monthSettling(MonthBoard m) internal {
        vm.warp(m.prepEnd());
        m.sync();
        vm.warp(m.miningEnd());
        m.drawPrizes();
        if (m.state() == MonthState.Drawing) {
            rng.fulfill(m.pendingRequestId(), 7);
            m.finalizePrizes();
        }
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
    }

    /// @dev 一块正在准备矿机的新月局（之前那块招募已过期时先宣布失败、重开）
    function _freshPreparing() internal returns (MonthBoard r) {
        r = _monthBoard();
        if (block.timestamp >= r.recruitDeadline()) {
            r.closeRecruitment();
            r = _monthBoard();
        }
        _fillMonth(r);
        assertTrue(r.isPurchasing());
    }

    /// @dev 规则决定 6.37：经 MarketTrader 按 计价算力 × 收购价上限 卖给主板（见 Fixture._traderSell）
    function _sellInto(address board, MockCircuits c, uint256 id) internal returns (uint256 paid) {
        (, uint256 w) = rules.check(address(c), id, 0, type(uint256).max, 0);
        paid = _traderSell(board, address(c), id, c.ownerOf(id), w * MonthBoard(board).buyPrice()); // 两种主板同名
    }

    /// @dev 月局里放两台矿机（官方 30 单位、Behemoth 基础 5 × 6 = 30 单位），进入结算阶段
    function _monthWithMachines() internal returns (MonthBoard m, uint256 id0, uint256 id1) {
        m = _monthPreparing();
        (id0,) = _newIn(machines, seller, 30);
        (id1,) = _newIn(behemoth, seller, 5);
        _sellInto(address(m), machines, id0);
        _sellInto(address(m), behemoth, id1);
        _monthSettling(m);
    }

    function _l(address vault) internal view returns (MachineLister.Listing memory l) {
        (bool ok, bytes memory ret) = address(lister).staticcall(abi.encodeWithSignature("listings(address)", vault));
        require(ok);
        l = abi.decode(ret, (MachineLister.Listing));
    }

    /// @dev 挂单库现在的 Seaport 卖单（和 MachineLister._order 相同）
    function _sellOrder(MonthBoard m, uint256 index) internal view returns (OrderParameters memory p, uint256 total) {
        address vault = lister.vaultOf(address(m), index);
        MachineLister.Listing memory l = _l(vault);
        uint256 net = l.net;
        uint256 fee = l.seaportFee;
        p.offerer = vault;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(2, m.machine(index).collection, m.machine(index).circuitId, 1, 1);
        p.consideration = new ConsiderationItem[](2);
        p.consideration[0] = ConsiderationItem(0, address(0), 0, net, net, payable(vault));
        p.consideration[1] = ConsiderationItem(0, address(0), 0, fee, fee, TM_FEE);
        p.startTime = l.seaportStart;
        p.endTime = l.seaportEnd;
        p.salt = l.salt;
        p.totalOriginalConsiderationItems = 2;
        total = net + fee;
    }

    function _officialOf(MonthBoard m, uint256 index) internal view returns (uint256 id, uint256 price) {
        MachineLister.Listing memory l = _l(lister.vaultOf(address(m), index));
        return (l.officialId, l.officialPrice);
    }

    function _fillSeaport(OrderParameters memory p, uint256 value) internal {
        vm.prank(buyer);
        seaport.fulfillAdvancedOrder{value: value}(
            AdvancedOrder(p, 1, 1, "", ""), new CriteriaResolver[](0), bytes32(0), buyer
        );
    }

    // ================= PoD 字段（主网实测的真实布局）=================

    /// @dev 已停挖（状态 3）、在未验证池的矿机：rc7 会误收，rc8 拒绝
    function test_StoppedAndUnverifiedMachinesRejected() public {
        MonthBoard m = _monthPreparing();
        (uint256 a, bytes32 ka) = _newIn(machines, seller, 30);
        vm.prank(seller);
        pod.stop(ka);
        _toTrader(address(m), address(machines), a, seller);
        vm.prank(address(trader));
        vm.expectRevert(MachineRules.MachineNotEligible.selector);
        m.sellMachine(address(machines), a, 0);
        (uint256 b, bytes32 kb) = _newIn(machines, seller, 30);
        pod.setFlags(kb, true, false); // 在挖，但在未验证池
        _toTrader(address(m), address(machines), b, seller);
        vm.prank(address(trader));
        vm.expectRevert(MachineRules.MachineNotEligible.selector);
        m.sellMachine(address(machines), b, 0);
        (uint256 c,) = _newIn(machines, seller, 30);
        assertGt(_sellInto(address(m), machines, c), 0);
    }

    /// @dev 计价算力 = min(基础算力 × 倍数, 已验证池权重)：Behemoth 按 ×6 计；范围按计价算力查；最优加成不计价
    function test_MultiplierAndBonusWeight() public {
        MonthBoard m = _monthPreparing();
        uint256 price = m.buyPrice();
        (uint256 b1,) = _newIn(behemoth, seller, 5);
        assertEq(_sellInto(address(m), behemoth, b1), 30 * price, "5 x 6 = 30 units");
        assertEq(m.machine(0).weight, 30);
        assertEq(m.machine(0).collection, address(behemoth));
        (uint256 b2,) = _newIn(behemoth, seller, 51); // 51 × 6 = 306 > 300
        _toTrader(address(m), address(behemoth), b2, seller);
        vm.prank(address(trader));
        vm.expectRevert(MachineRules.MachineNotEligible.selector);
        m.sellMachine(address(behemoth), b2, 0);
        (uint256 o1, bytes32 k1) = _newIn(machines, seller, 20);
        pod.setBonus(k1, 10); // 最优加成：PoD 按 30 分产出，主板按 20 计价
        assertEq(_sellInto(address(m), machines, o1), 20 * price);
        assertEq(m.machine(1).weight, 20);
    }

    /// @dev 合集：工厂创建的处理器 + 代码和官方矿机电路合约相同。不是工厂创建的、或代码不同（通行证合集）都拒绝
    function test_CollectionChecks() public {
        MonthBoard m = _monthPreparing();
        MockCircuits rogue = new MockCircuits("Rogue", "R", address(0), 0.0002 ether); // 同代码、不是工厂创建
        (uint256 r,) = _newIn(rogue, seller, 30);
        _toTrader(address(m), address(rogue), r, seller);
        vm.prank(address(trader));
        vm.expectRevert(MachineRules.MachineNotEligible.selector);
        m.sellMachine(address(rogue), r, 0);
        assertTrue(tapeout.isCPU(address(passCircuits)));
        assertFalse(rules.isMachineCollection(address(passCircuits)), "pass collection: different code");
        assertTrue(rules.isMachineCollection(address(machines)));
        assertTrue(rules.isMachineCollection(address(behemoth)));
    }

    /// @dev 标准局 syncMachine 按新字段识别停挖
    function test_SyncDetectsStop() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        (uint256 id,) = _newIn(behemoth, seller, 5);
        _sellInto(address(b), behemoth, id);
        assertEq(b.activeWeight(), 30);
        bytes32 key = b.machine(0).key;
        vm.prank(address(b));
        pod.stop(key);
        b.syncMachine(0);
        assertFalse(b.machine(0).active);
        assertEq(b.activeWeight(), 0);
    }

    /// @dev 多合集的矿机卖出、交接都用矿机自己的合集
    function test_BehemothSoldAndRelayed() public {
        (MonthBoard m,, uint256 id1) = _monthWithMachines();
        MonthBoard r = _freshPreparing();
        uint256 cost = m.machine(1).cost;
        while (r.buyPrice() * 30 < cost && r.isPurchasing()) {
            vm.warp(block.timestamp + 6 hours);
        }
        sales.relay(address(m), 1, address(r));
        assertEq(behemoth.ownerOf(id1), address(r));
        assertEq(r.machine(0).collection, address(behemoth));
        bem.mint(buyer, 1_000 * BEM_1);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        sales.buyMachine(address(m), 0, type(uint256).max);
        vm.stopPrank();
        assertEq(m.unsoldMachines(), 0);
    }

    // ================= MarketTrader：官方矿机市场 / Seaport 买入 =================

    function test_BuyFromOfficialMarket() public {
        MonthBoard m = _monthPreparing();
        (uint256 id,) = _newIn(behemoth, seller, 5);
        uint256 bnb = 30 * m.buyPrice() * 1e18 / oracle.quoteBemOut(1e18) * 9 / 10;
        vm.startPrank(seller);
        behemoth.setApprovalForAll(address(officialMarket), true);
        uint256 lid = officialMarket.list(address(behemoth), id, uint96(bnb));
        vm.stopPrank();
        uint256 s0 = seller.balance;
        vm.prank(keeper);
        uint256 paid = trader.buyFromOfficial(address(m), lid);
        assertEq(behemoth.ownerOf(id), address(m));
        assertEq(m.machine(0).cost, paid);
        assertEq(seller.balance - s0, bnb - bnb / 100, "seller paid minus the 1% fee");
        assertLe(paid, 30 * m.buyPrice());
        assertEq(bem.balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);
        // 太贵：主板拒绝
        (uint256 id2,) = _newIn(machines, seller, 30);
        vm.startPrank(seller);
        machines.setApprovalForAll(address(officialMarket), true);
        uint256 lid2 = officialMarket.list(address(machines), id2, uint96(bnb * 2));
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert(MonthBoard.PriceBelowMinimum.selector);
        trader.buyFromOfficial(address(m), lid2);
    }

    function test_BuyFromSeaport() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        (uint256 id,) = _newIn(machines, seller, 40);
        uint256 net = 40 * b.buyPrice() * 1e18 / oracle.quoteBemOut(1e18) * 9 / 10;
        OrderParameters memory p;
        p.offerer = seller;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(2, address(machines), id, 1, 1);
        p.consideration = new ConsiderationItem[](2);
        p.consideration[0] = ConsiderationItem(0, address(0), 0, net, net, payable(seller));
        p.consideration[1] = ConsiderationItem(0, address(0), 0, net / 100, net / 100, TM_FEE);
        p.startTime = block.timestamp;
        p.endTime = block.timestamp + 1 days;
        p.totalOriginalConsiderationItems = 2;
        Order[] memory os = new Order[](1);
        os[0] = Order(p, "");
        vm.startPrank(seller);
        machines.setApprovalForAll(address(seaport), true);
        seaport.validate(os);
        vm.stopPrank();
        vm.prank(keeper);
        uint256 paid = trader.buyFromSeaport(address(b), AdvancedOrder(p, 0, 0, "", ""));
        assertEq(machines.ownerOf(id), address(b));
        assertEq(b.totalSpent(), paid);
        assertEq(TM_FEE.balance, net / 100);
        // 只收"一台 ERC721 换原生币"的单
        p.consideration[1].itemType = 1;
        vm.prank(keeper);
        vm.expectRevert(MarketTrader.BadOrder.selector);
        trader.buyFromSeaport(address(b), AdvancedOrder(p, 1, 1, "", ""));
    }

    // ================= MarketTrader：接受 Seaport 出价 =================

    function _offer(address col, uint256 id, uint256 wbnb, bool criteria, uint256 salt)
        internal
        returns (OrderParameters memory p)
    {
        vm.deal(bidder, wbnb + 1 ether);
        vm.startPrank(bidder);
        wbnbToken.deposit{value: wbnb}();
        wbnbToken.approve(address(seaport), type(uint256).max);
        p.offerer = bidder;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(1, address(wbnbToken), 0, wbnb, wbnb);
        p.consideration = new ConsiderationItem[](2);
        p.consideration[0] = ConsiderationItem(criteria ? 4 : 2, col, criteria ? 0 : id, 1, 1, payable(bidder));
        p.consideration[1] = ConsiderationItem(1, address(wbnbToken), 0, wbnb / 100, wbnb / 100, TM_FEE); // 卖方付 1%
        p.startTime = block.timestamp;
        p.endTime = block.timestamp + 1 days;
        p.salt = salt;
        p.totalOriginalConsiderationItems = 2;
        Order[] memory os = new Order[](1);
        os[0] = Order(p, "");
        seaport.validate(os);
        vm.stopPrank();
    }

    function test_SellToSeaportOffers() public {
        (MonthBoard m, uint256 id0, uint256 id1) = _monthWithMachines();
        uint256 ask0 = sales.askPrice(address(m), 0);
        uint256 wbnb = ask0 * 13 / 10 * 1e18 / oracle.quoteBemOut(1e18);
        OrderParameters memory p = _offer(address(machines), id0, wbnb, false, 1);
        uint256 bal0 = bem.balanceOf(address(m));
        vm.prank(keeper);
        uint256 got = trader.sellToOffer(address(m), 0, AdvancedOrder(p, 1, 1, "", ""), new CriteriaResolver[](0), ask0);
        assertEq(machines.ownerOf(id0), bidder);
        assertEq(bem.balanceOf(address(m)) - bal0, got);
        assertGt(got, ask0 * 12 / 10, "board gets the surplus over the ask");
        assertEq(wbnbToken.balanceOf(TM_FEE), wbnb / 100, "seller-side fee paid from the WBNB received");
        assertEq(wbnbToken.balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);

        // 整合集出价（按条件）：调用者给出编号
        uint256 ask1 = sales.askPrice(address(m), 1);
        OrderParameters memory c =
            _offer(address(behemoth), 0, ask1 * 12 / 10 * 1e18 / oracle.quoteBemOut(1e18), true, 2);
        CriteriaResolver[] memory cr = new CriteriaResolver[](1);
        cr[0] = CriteriaResolver(0, 1, 0, id1, new bytes32[](0));
        vm.prank(keeper);
        trader.sellToOffer(address(m), 1, AdvancedOrder(c, 1, 1, "", ""), cr, ask1);
        assertEq(behemoth.ownerOf(id1), bidder);
        assertEq(m.unsoldMachines(), 0);
    }

    function test_SellToOfferRejectsNonWbnbOrLowOffers() public {
        (MonthBoard m, uint256 id0,) = _monthWithMachines();
        uint256 ask0 = sales.askPrice(address(m), 0);
        OrderParameters memory p =
            _offer(address(machines), id0, ask0 * 9 / 10 * 1e18 / oracle.quoteBemOut(1e18), false, 1);
        vm.prank(keeper);
        vm.expectRevert(MarketTrader.InsufficientProceeds.selector);
        trader.sellToOffer(address(m), 0, AdvancedOrder(p, 1, 1, "", ""), new CriteriaResolver[](0), ask0);
        p.offer[0].token = address(bem);
        vm.prank(keeper);
        vm.expectRevert(MarketTrader.BadOrder.selector);
        trader.sellToOffer(address(m), 0, AdvancedOrder(p, 1, 1, "", ""), new CriteriaResolver[](0), ask0);
        assertEq(machines.ownerOf(id0), address(m));
    }

    // ================= MachineLister：挂单 / 成交结算 =================

    function test_ListThenSoldOnOfficialMarket() public {
        (MonthBoard m, uint256 id0,) = _monthWithMachines();
        uint256 quote = sales.quote(address(m), 0);
        {
            (uint256 q, uint256 net, uint256 official, uint256 fee) = lister.prices(address(m), 0);
            assertEq(q, quote);
            assertEq(fee, net / 100);
            // 挂单价：要价按 TWAP 折 BNB ÷ 98%；官方市场再 ÷ 99%（从卖方扣 1%）
            assertApproxEqRel(net, quote * 1e18 / oracle.quoteBemOut(1e18) * 10_000 / 9_800, 1e12);
            assertApproxEqRel(official, net * 10_000 / 9_900, 1e12);
        }
        vm.prank(keeper);
        lister.list(address(m), 0);
        address vault = lister.vaultOf(address(m), 0);
        assertEq(machines.ownerOf(id0), vault, "consigned to the vault");
        assertEq(m.machine(0).sold, false, "still the board's machine");
        (uint256 lid, uint256 price) = _officialOf(m, 0);
        assertEq(price, _l(vault).officialPrice);

        uint256 got = bem.balanceOf(address(m)) + bem.balanceOf(FEE_SAFE);
        vm.prank(buyer);
        officialMarket.buy{value: price}(lid, uint96(price));
        assertEq(machines.ownerOf(id0), buyer, "delivered to the market buyer");
        assertTrue(m.machine(0).sold);
        got = bem.balanceOf(address(m)) + bem.balanceOf(FEE_SAFE) - got;
        assertGe(got, quote, "board got at least the formula price (incl. premium fee)");
        assertEq(bem.balanceOf(vault), 0);
        assertEq(bem.balanceOf(address(lister)), 0);
        assertEq(address(lister).balance, 0);
        MachineLister.Listing memory after_ = _l(vault);
        assertEq(after_.net, 0);
        assertEq(after_.officialId, 0);
        assertEq(after_.seaportEnd, 0, "Seaport order cancelled after the official sale");
    }

    function test_ListThenSoldOnSeaport() public {
        (MonthBoard m,, uint256 id1) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 1);
        (OrderParameters memory p, uint256 total) = _sellOrder(m, 1);
        uint256 quote = sales.quote(address(m), 1);
        uint256 bal0 = bem.balanceOf(address(m));
        _fillSeaport(p, total);
        assertEq(behemoth.ownerOf(id1), buyer);
        assertTrue(m.machine(1).sold);
        assertGe(bem.balanceOf(address(m)) - bal0, quote * 99 / 100);
        assertEq(TM_FEE.balance, p.consideration[1].startAmount, "tapeout.market buyer fee");
        (uint256 lid,) = _officialOf(m, 1);
        assertEq(lid, 0, "official listing removed");
    }

    /// @dev 成交那一刻的公式价高于挂单折算价：结算不过，买家的成交整笔回滚；改价后能成交
    function test_SaleBelowCurrentFormulaReverts() public {
        (MonthBoard m,,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        (uint256 lid, uint256 price) = _officialOf(m, 0);
        // 报价上来：整台要价 = 30 × 单价 ≈ 成本 × 1.2
        uint256 unit = _unitFor(m, 0, 12_000);
        _postPrices(unit, unit);
        assertGt(sales.quote(address(m), 0), m.machine(0).cost);
        vm.prank(buyer);
        vm.expectRevert(); // BelowFormula
        officialMarket.buy{value: price}(lid, uint96(price));
        vm.prank(keeper);
        lister.reprice(address(m), 0);
        (, uint256 price2) = _officialOf(m, 0);
        assertGt(price2, price);
        vm.prank(buyer);
        officialMarket.buy{value: price2}(lid, uint96(price2));
        assertTrue(m.machine(0).sold);
    }

    /// @dev 公式价成交照常开着（F-3）：有人直接向主板买寄售中的矿机时，先撤单把矿机拿回来
    function test_DirectBuyRecallsConsignedMachine() public {
        (MonthBoard m, uint256 id0,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        (uint256 lid, uint256 price) = _officialOf(m, 0);
        (OrderParameters memory p, uint256 total) = _sellOrder(m, 0);
        bem.mint(buyer, 1_000 * BEM_1);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        sales.buyMachine(address(m), 0, type(uint256).max);
        vm.stopPrank();
        assertEq(machines.ownerOf(id0), buyer);
        vm.prank(buyer);
        vm.expectRevert(); // 官方挂单已撤
        officialMarket.buy{value: price}(lid, uint96(price));
        vm.prank(buyer);
        vm.expectRevert(); // Seaport 单已撤
        seaport.fulfillAdvancedOrder{value: total}(
            AdvancedOrder(p, 1, 1, "", ""), new CriteriaResolver[](0), bytes32(0), buyer
        );
    }

    /// @dev MarketTrader 卖给 Firsto 买单 / 出价时，寄售中的矿机也是先撤回
    function test_SellToOfferRecallsConsignedMachine() public {
        (MonthBoard m, uint256 id0,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        uint256 ask0 = sales.askPrice(address(m), 0);
        OrderParameters memory p =
            _offer(address(machines), id0, ask0 * 13 / 10 * 1e18 / oracle.quoteBemOut(1e18), false, 3);
        vm.prank(keeper);
        trader.sellToOffer(address(m), 0, AdvancedOrder(p, 1, 1, "", ""), new CriteriaResolver[](0), ask0);
        assertEq(machines.ownerOf(id0), bidder);
    }

    /// @dev 撤单：卖矿合约随时；其他人只能在现在不能卖（报价过期）时
    function test_RecallAuthorization() public {
        (MonthBoard m, uint256 id0,) = _monthWithMachines();
        uint256 unit = _unitFor(m, 0, 11_000);
        _postPrices(unit, unit);
        vm.prank(keeper);
        lister.list(address(m), 0);
        vm.prank(keeper);
        vm.expectRevert(MachineLister.NotAuthorized.selector);
        lister.recall(address(m), 0);
        vm.warp(block.timestamp + 3 hours + 1); // 报价过期：月局暂停卖出
        assertEq(sales.quote(address(m), 0), 0);
        vm.prank(keeper);
        lister.recall(address(m), 0);
        assertEq(machines.ownerOf(id0), address(m));
        // 已经在主板：再调用什么也不做
        vm.prank(keeper);
        lister.recall(address(m), 0);
    }

    /// @dev 寄售期间的产出领到挂单库，成交时转回主板（作为结算期产出按投入比例分，不算卖出所得）
    function test_YieldWhileConsignedGoesBack() public {
        (MonthBoard m,,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        address vault = lister.vaultOf(address(m), 0);
        pod.addYield(m.machine(0).key, 3 * BEM_1);
        m.harvest();
        assertEq(bem.balanceOf(vault), 3 * BEM_1, "PoD pays the holder (the vault)");
        (uint256 lid, uint256 price) = _officialOf(m, 0);
        uint256 bal0 = bem.balanceOf(address(m));
        uint256 quote = sales.quote(address(m), 0);
        vm.prank(buyer);
        officialMarket.buy{value: price}(lid, uint96(price));
        assertEq(bem.balanceOf(vault), 0);
        assertGe(bem.balanceOf(address(m)) - bal0, quote * 99 / 100 + 3 * BEM_1);
    }

    /// @dev 官方市场如果升级成"先记账后提"：矿机被买走后任何人可以替挂单库提款，照常结算
    function test_PullOfficialProceedsIfMarketStopsPushing() public {
        (MonthBoard m, uint256 id0,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        (uint256 lid, uint256 price) = _officialOf(m, 0);
        officialMarket.setPullMode(true);
        vm.prank(buyer);
        officialMarket.buy{value: price}(lid, uint96(price));
        assertEq(machines.ownerOf(id0), buyer);
        assertFalse(m.machine(0).sold, "not settled yet");
        uint256 bal0 = bem.balanceOf(address(m));
        lister.pullOfficialProceeds(address(m), 0);
        assertTrue(m.machine(0).sold);
        assertGe(bem.balanceOf(address(m)) - bal0, m.machine(0).cost * 99 / 100);
        vm.expectRevert(MachineLister.NotListed.selector);
        lister.pullOfficialProceeds(address(m), 1);
    }

    function test_RepriceThreshold() public {
        (MonthBoard m,,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        vm.expectRevert(MachineLister.NoChange.selector);
        lister.reprice(address(m), 0);
        // Seaport 单 1 天内到期：可以续挂
        vm.warp(block.timestamp + TAPE_LIST_DURATION - 1 days + 1);
        (OrderParameters memory p0,) = _sellOrder(m, 0);
        assertTrue(seaport.validated(_hashOf(p0)));
        lister.reprice(address(m), 0);
        (OrderParameters memory p1,) = _sellOrder(m, 0);
        assertEq(p1.salt, p0.salt + 1);
        assertGt(p1.endTime, p0.endTime);
        assertTrue(seaport.cancelled(_hashOf(p0)), "old order cancelled with its own parameters");
        assertTrue(seaport.validated(_hashOf(p1)));
        // 报价变了（net 变）：旧单按旧价撤掉
        uint256 unit = _unitFor(m, 0, 11_000);
        _postPrices(unit, unit);
        lister.reprice(address(m), 0);
        (OrderParameters memory p2,) = _sellOrder(m, 0);
        assertGt(p2.consideration[0].startAmount, p1.consideration[0].startAmount);
        assertTrue(seaport.cancelled(_hashOf(p1)), "old-price order cancelled");
        vm.prank(buyer);
        vm.expectRevert(); // 旧单不能再成交
        seaport.fulfillAdvancedOrder{value: 10 ether}(
            AdvancedOrder(p1, 1, 1, "", ""), new CriteriaResolver[](0), bytes32(0), buyer
        );
    }

    function _hashOf(OrderParameters memory p) internal view returns (bytes32) {
        return seaport.getOrderHash(
            OrderComponents(
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
            )
        );
    }

    uint256 internal constant TAPE_LIST_DURATION = 30 days;

    function test_ListGuards() public {
        (MonthBoard m,,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        vm.expectRevert(MachineLister.AlreadyListed.selector);
        lister.list(address(m), 0);
        vm.expectRevert(MachineLister.NotBoard.selector);
        lister.list(address(0xBAD), 0);
        vm.expectRevert(MachineLister.NotVault.selector);
        lister.onProceeds{value: 1}(address(0));
        // 矿机还在挂单库时有人往挂单库打 BNB：不是成交，回滚
        address vault = lister.vaultOf(address(m), 0);
        (bool ok,) = vault.call{value: 1 ether}("");
        assertFalse(ok);
        // 只有卖矿合约能寄售
        vm.expectRevert(MonthMachineSales.NotAuthorized.selector);
        sales.consign(address(m), 1, address(this));
        vm.expectRevert(ListingVault.NotLister.selector);
        ListingVault(payable(vault)).exec(address(machines), "");
    }

    /// @dev 月局交接：寄售中的矿机先撤回再交接
    function test_RelayRecallsConsignedMachine() public {
        (MonthBoard m,, uint256 id1) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 1);
        MonthBoard r = _freshPreparing();
        uint256 cost = m.machine(1).cost;
        while (r.buyPrice() * 30 < cost && r.isPurchasing()) {
            vm.warp(block.timestamp + 6 hours);
        }
        sales.relay(address(m), 1, address(r));
        assertEq(behemoth.ownerOf(id1), address(r));
    }

    /// @dev 升级哨兵冷静期内：不能寄售，挂着的单成交也会回滚（卖出暂停）
    function test_SentinelPausesListingAndSales() public {
        (MonthBoard m,,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        (uint256 lid, uint256 price) = _officialOf(m, 0);
        machineBeacon.upgradeTo(address(0xBEEF));
        assertTrue(m.sentinelPaused());
        vm.prank(keeper);
        vm.expectRevert();
        lister.list(address(m), 1);
        vm.prank(buyer);
        vm.expectRevert();
        officialMarket.buy{value: price}(lid, uint96(price));
    }

    // ================= 标准局 =================

    /// @dev 标准局正常终局：挂单成交按成交时的市价期要价结算，高出成本的部分扣 10%
    function test_StandardBoardListingSale() public {
        TapeBoard sb = _startGenesis();
        _fillUniform(sb, 25, 20 * BEM_1);
        (uint256 id,) = _newIn(behemoth, seller, 10); // 60 单位
        _sellInto(address(sb), behemoth, id);
        _drawUntilKing(sb, 9);
        _topUpPool(sb);
        sb.pulse();
        assertEq(uint256(sb.settleMode()), uint256(SettleMode.Normal));
        uint256 basis = stdSales.machineCost(address(sb), 0);
        uint256 unit = basis * 15 / 10 / 60;
        _postPrices(unit, unit);
        uint256 quote = stdSales.quote(address(sb), 0);
        assertGt(quote, basis);
        vm.prank(keeper);
        lister.list(address(sb), 0);
        address vault = lister.vaultOf(address(sb), 0);
        assertEq(behemoth.ownerOf(id), vault);
        uint256 lid = _l(vault).officialId;
        uint256 price = _l(vault).officialPrice;
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        uint256 pot0 = sb.potAllocated();
        vm.prank(buyer);
        officialMarket.buy{value: price}(lid, uint96(price));
        assertEq(behemoth.ownerOf(id), buyer);
        assertEq(sb.unsoldMachines(), 0);
        uint256 fee = bem.balanceOf(FEE_SAFE) - fee0;
        // 换出的 BEM = (挂单价 − 官方市场 1%) 按 mock 汇率 − 0.5%；全部算这台矿机的卖出所得
        uint256 got = oracle.quoteBemOut(price - price / 100) * 9_950 / 10_000;
        assertGe(got, quote);
        assertApproxEqAbs(fee, (got - basis) / 10, 2, "10% of everything above cost");
        sb.sweep(); // 要价以外多出来的 BEM 在交割之后才转进主板，下一次 sweep（领取时也会）记入底池
        assertGe(sb.potAllocated() - pot0, got - fee);
    }

    /// @dev 标准局拍卖期：挂单随拍卖价下调（reprice），成交时按当时的拍卖价结算
    function test_StandardBoardAuctionReprice() public {
        TapeBoard sb = _startGenesis();
        _fillUniform(sb, 25, 20 * BEM_1);
        (uint256 id,) = _newIn(machines, seller, 60);
        _sellInto(address(sb), machines, id);
        vm.warp(sb.startedAt() + 730 days);
        sb.expire();
        vm.warp(sb.liquidationStart() + 30 days);
        (, uint8 phase) = stdSales.askPrice(address(sb), 0);
        assertEq(phase, 2, "auction");
        vm.prank(keeper);
        lister.list(address(sb), 0);
        address vault = lister.vaultOf(address(sb), 0);
        uint256 net0 = _l(vault).net;
        vm.warp(block.timestamp + 3 days);
        lister.reprice(address(sb), 0);
        uint256 net1 = _l(vault).net;
        uint256 lid = _l(vault).officialId;
        uint256 price = _l(vault).officialPrice;
        assertLt(net1, net0, "follows the falling auction price");
        vm.prank(buyer);
        officialMarket.buy{value: price}(lid, uint96(price));
        assertEq(machines.ownerOf(id), buyer);
        assertEq(sb.unsoldMachines(), 0);
    }


    // ================= 规则决定 6.29：保持排序第一 =================

    function test_FloorQuoteOperatorOnlyAndExpires() public {
        vm.prank(address(0x6EE9));
        vm.expectRevert(MarketPriceFeed.NotOperator.selector);
        priceFeed.postFloor(1e8);
        priceFeed.postFloor(1e8); // 测试合约是运营地址
        assertEq(priceFeed.floorQuote(), 1e8);
        // 不限频率、不限幅度
        priceFeed.postFloor(0.5e8);
        assertEq(priceFeed.floorQuote(), 0.5e8);
        vm.warp(block.timestamp + 3 hours);
        assertEq(priceFeed.floorQuote(), 0, "stale after 3 hours");
        priceFeed.postFloor(0.7e8);
        assertEq(priceFeed.floorQuote(), 0.7e8);
        priceFeed.postFloor(0);
        assertEq(priceFeed.floorQuote(), 0, "revoked");
    }

    /// @dev 月局：目标价 × 收购时权重 ≥ 成本价时取 min(原公式价, 目标价)，目标价最低按原公式价的 95% 算（规则决定 6.33）；
    ///      低于成本价不追；高于原公式价不涨
    function test_MonthFloorUndercutsFormulaButNeverBelowCost() public {
        (MonthBoard m,,) = _monthWithMachines();
        uint256 unit = _unitFor(m, 0, 13_000);
        _postPrices(unit, unit);
        uint256 formula = sales.askPrice(address(m), 0);
        uint256 cost = m.machine(0).cost;
        uint256 w = m.machine(0).weight;
        assertGt(formula, cost);
        // 目标价在 [原公式价 × 95%, 原公式价] 之间：采用
        uint256 target = _unitFor(m, 0, 12_600);
        assertGe(target * w * 10_000, formula * 9_500);
        priceFeed.postFloor(target);
        assertEq(sales.askPrice(address(m), 0), target * w);
        assertEq(sales.quote(address(m), 0), target * w);
        // 比原公式价低 5% 以上：按原公式价的 95%（运营地址不能一下子压到成本价，审计 H-1）
        priceFeed.postFloor(_unitFor(m, 0, 11_000));
        assertEq(sales.askPrice(address(m), 0), formula * 9_500 / 10_000);
        priceFeed.postFloor(_unitFor(m, 0, 9_000));
        assertEq(sales.askPrice(address(m), 0), formula * 9_500 / 10_000);
        // 高于原公式价：不涨
        priceFeed.postFloor(unit * 2);
        assertEq(sales.askPrice(address(m), 0), formula);
        // 按目标价成交，溢价分成照常按（成交价 − 成本）的 10%
        priceFeed.postFloor(target);
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        bem.mint(buyer, 1_000 * BEM_1);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        uint256 paid = sales.buyMachine(address(m), 0, type(uint256).max);
        vm.stopPrank();
        assertEq(paid, target * w);
        assertEq(bem.balanceOf(FEE_SAFE) - fee0, (paid - cost) / 10);
    }

    /// @dev 标准局：市价期和拍卖期都适用；目标价 × 计价权重低于这台的买入成本（平均单位成本 × 收购算力）时不追
    function test_StandardFloorInMarketAndAuctionPhases() public {
        TapeBoard sb = _startGenesis();
        _fillUniform(sb, 25, 20 * BEM_1);
        (uint256 id,) = _newIn(machines, seller, 60);
        _sellInto(address(sb), machines, id);
        _drawUntilKing(sb, 9);
        _topUpPool(sb);
        sb.pulse();
        uint256 basis = stdSales.machineCost(address(sb), 0);
        uint256 costUnit = (basis + 59) / 60;
        _postPrices(costUnit * 15 / 10, costUnit * 15 / 10);
        (uint256 formula, uint8 phase) = stdSales.askPrice(address(sb), 0);
        assertEq(phase, 1);
        uint256 near = formula * 97 / 100; // 比原公式价低 3%：采用
        priceFeed.postFloor(near);
        (uint256 p,) = stdSales.askPrice(address(sb), 0);
        assertEq(p, near, "market phase: undercut");
        assertEq(stdSales.quote(address(sb), 0), p * 60);
        // 低 5% 以上：按原公式价的 95%（规则决定 6.33）
        priceFeed.postFloor(costUnit * 12 / 10);
        (p,) = stdSales.askPrice(address(sb), 0);
        assertEq(p, formula * 9_500 / 10_000, "market phase: at most 5% below the formula");
        // 原公式价的 95% 都低于这台的买入成本时不追：把报价降到接近成本，再报一个更低的目标价
        _postPrices(costUnit, costUnit);
        (formula,) = stdSales.askPrice(address(sb), 0);
        priceFeed.postFloor(costUnit / 2);
        (p,) = stdSales.askPrice(address(sb), 0);
        assertEq(p, formula, "below cost: no chase");
        // 拍卖期
        vm.warp(sb.liquidationStart() + 30 days);
        stdSales.startAuction(address(sb));
        (uint256 auction, uint8 ph2) = stdSales.askPrice(address(sb), 0);
        assertEq(ph2, 2);
        uint256 t = auction * 98 / 100;
        if (t * 60 >= basis) {
            priceFeed.postFloor(t);
            (p,) = stdSales.askPrice(address(sb), 0);
            assertEq(p, t, "auction phase: undercut too");
        }
    }

    /// @dev 挂单模块的改价节奏：降价（追第一）每台最多 30 分钟一次；涨价 ≥ 0.5% 随时可改
    function test_ListerRepricesEveryThirtyMinutesAtMost() public {
        (MonthBoard m,,) = _monthWithMachines();
        uint256 unit = _unitFor(m, 0, 13_000);
        _postPrices(unit, unit);
        vm.prank(keeper);
        lister.list(address(m), 0);
        address vault = lister.vaultOf(address(m), 0);
        uint256 net0 = _l(vault).net;
        assertEq(lister.REPRICE_INTERVAL(), 30 minutes);
        priceFeed.postFloor(_unitFor(m, 0, 12_000));
        vm.expectRevert(MachineLister.NoChange.selector);
        lister.reprice(address(m), 0);
        vm.warp(block.timestamp + 30 minutes);
        lister.reprice(address(m), 0);
        uint256 net1 = _l(vault).net;
        assertLt(net1, net0, "chased down after 30 minutes");
        // 撤销目标价：要价回到原公式价（涨幅 ≥ 0.5%），马上可以改
        priceFeed.postFloor(0);
        lister.reprice(address(m), 0);
        assertEq(_l(vault).net, net0);
    }

    /// @dev TapeCode 预审第 17 条：标准局卖矿合约实际到账额不等于要价时回滚（和月局一致）
    function test_StandardSalePaymentMismatchReverts() public {
        TapeBoard sb = _startGenesis();
        _fillUniform(sb, 25, 20 * BEM_1);
        (uint256 id,) = _newIn(machines, seller, 60);
        _sellInto(address(sb), machines, id);
        vm.warp(sb.startedAt() + 730 days);
        sb.expire();
        uint256 floor = sb.sellFloorPrice();
        _postPrices(floor, floor);
        bem.mint(buyer, 1_000 * BEM_1);
        vm.prank(buyer);
        bem.approve(address(stdSales), type(uint256).max);
        // 模拟"转账扣费"的代币：transferFrom 返回成功但没有转账
        vm.mockCall(address(bem), abi.encodeWithSelector(bem.transferFrom.selector), abi.encode(true));
        vm.prank(buyer);
        vm.expectRevert(StdMachineSales.PaymentMismatch.selector);
        stdSales.buyMachine(address(sb), 0, type(uint256).max);
        vm.clearMockedCalls();
    }


    // ================= 规则决定 6.30：Firsto 单笔签名卖单 V2（EIP-1271）=================

    function _firstoOf(MonthBoard m, uint256 index) internal view returns (SignedAsk memory a, bytes32 d) {
        return lister.firstoAsk(address(m), index);
    }

    function _fillFirsto(SignedAsk memory a) internal returns (bool ok, bytes memory ret) {
        uint256 cost = uint256(a.price) + uint256(a.price) * a.feeBps / 10_000;
        vm.prank(buyer);
        (ok, ret) = address(firstoSigned).call{value: cost}(abi.encodeCall(firstoSigned.fillSignedAsk, (a, hex"01", buyer)));
    }

    /// @dev list 同时挂 Firsto：maker = payoutRecipient = 挂单库，price = 净价，按编号授权；挂单库只认当前摘要
    function test_ListAlsoPostsFirstoSignedAsk() public {
        (MonthBoard m, uint256 id0,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        address vault = lister.vaultOf(address(m), 0);
        (SignedAsk memory a, bytes32 d) = _firstoOf(m, 0);
        (, uint256 net,,) = lister.prices(address(m), 0);
        assertEq(a.maker, vault);
        assertEq(a.payoutRecipient, vault);
        assertEq(a.collection, address(machines));
        assertEq(a.tokenId, id0);
        assertEq(a.nonce, 1);
        assertEq(uint256(a.price), net, "Firsto price = net (buyer pays Firsto's 1% on top)");
        assertEq(a.feeBps, 100);
        assertEq(a.feeEpoch, 1);
        assertEq(a.schemaVersion, 2);
        assertEq(uint256(a.expiry), block.timestamp + TAPE_LIST_DURATION);
        assertEq(d, FirstoSignedAskLib.digest(address(firstoSigned), a));
        assertEq(machines.getApproved(id0), address(firstoSigned), "exact per-token approval");
        assertEq(ListingVault(payable(vault)).isValidSignature(d, ""), bytes4(0x1626ba7e));
        assertEq(ListingVault(payable(vault)).isValidSignature(keccak256("other"), ""), bytes4(0xffffffff));
        a.price += 1; // 改了价格的单：摘要不同，验不过
        (bool ok,) = _fillFirsto(a);
        assertFalse(ok, "only the registered terms");
    }

    function test_SoldOnFirstoSettlesAtFormulaAndClearsOtherVenues() public {
        (MonthBoard m, uint256 id0,) = _monthWithMachines();
        uint256 quote = sales.quote(address(m), 0);
        vm.prank(keeper);
        lister.list(address(m), 0);
        address vault = lister.vaultOf(address(m), 0);
        (uint256 lid, uint256 price) = _officialOf(m, 0);
        (SignedAsk memory a,) = _firstoOf(m, 0);
        uint256 got = bem.balanceOf(address(m)) + bem.balanceOf(FEE_SAFE);
        (bool ok, bytes memory ret) = _fillFirsto(a);
        if (!ok) emit log_bytes(ret);
        assertTrue(ok);
        assertEq(machines.ownerOf(id0), buyer, "delivered to the Firsto buyer");
        assertTrue(m.machine(0).sold);
        got = bem.balanceOf(address(m)) + bem.balanceOf(FEE_SAFE) - got;
        assertGe(got, quote, "board got at least the formula price");
        MachineLister.Listing memory l = _l(vault);
        assertEq(l.firstoDigest, bytes32(0));
        assertEq(l.officialId, 0);
        assertEq(l.seaportEnd, 0);
        vm.prank(buyer);
        vm.expectRevert(); // 官方挂单已撤
        officialMarket.buy{value: price}(lid, uint96(price));
        (ok,) = _fillFirsto(a);
        assertFalse(ok, "Firsto nonce used");
    }

    /// @dev 改价：旧 nonce 撤销、旧摘要作废，新单 nonce + 1
    function test_FirstoRepriceReplacesTheOrder() public {
        (MonthBoard m,,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        address vault = lister.vaultOf(address(m), 0);
        (SignedAsk memory a1, bytes32 d1) = _firstoOf(m, 0);
        uint256 unit = _unitFor(m, 0, 11_000);
        _postPrices(unit, unit);
        lister.reprice(address(m), 0);
        (SignedAsk memory a2, bytes32 d2) = _firstoOf(m, 0);
        assertEq(a2.nonce, 2);
        assertGt(a2.price, a1.price);
        assertTrue(firstoSigned.isSignedAskNonceInvalidated(vault, 1), "old nonce cancelled");
        assertEq(ListingVault(payable(vault)).isValidSignature(d1, ""), bytes4(0xffffffff), "old digest void");
        assertEq(ListingVault(payable(vault)).isValidSignature(d2, ""), bytes4(0x1626ba7e));
        (bool ok,) = _fillFirsto(a1);
        assertFalse(ok);
        (ok,) = _fillFirsto(a2);
        assertTrue(ok);
        assertTrue(m.machine(0).sold);
    }

    /// @dev 公式价上涨后、改价前，按旧价成交会因为低于公式价整笔回滚
    function test_FirstoFillBelowCurrentFormulaReverts() public {
        (MonthBoard m,,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        (SignedAsk memory a,) = _firstoOf(m, 0);
        uint256 unit = _unitFor(m, 0, 12_000);
        _postPrices(unit, unit);
        (bool ok, bytes memory ret) = _fillFirsto(a);
        assertFalse(ok);
        assertEq(bytes4(ret), MockFirstoSignedAsk.PayoutFailed.selector, "vault settlement reverted (BelowFormula)");
        assertFalse(m.machine(0).sold);
    }

    /// @dev 直接按公式价向主板买：寄售的矿机先撤回，Firsto 单随之作废
    function test_DirectBuyCancelsFirstoOrder() public {
        (MonthBoard m, uint256 id0,) = _monthWithMachines();
        vm.prank(keeper);
        lister.list(address(m), 0);
        address vault = lister.vaultOf(address(m), 0);
        (SignedAsk memory a, bytes32 d) = _firstoOf(m, 0);
        bem.mint(buyer, 1_000 * BEM_1);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        sales.buyMachine(address(m), 0, type(uint256).max);
        vm.stopPrank();
        assertEq(machines.ownerOf(id0), buyer);
        assertTrue(firstoSigned.isSignedAskNonceInvalidated(vault, a.nonce));
        assertEq(ListingVault(payable(vault)).isValidSignature(d, ""), bytes4(0xffffffff));
    }

    /// @dev Firsto 挂不上（合约暂停读数回滚）时，其他两个平台照挂
    function test_FirstoDownDoesNotBlockOtherVenues() public {
        (MonthBoard m,,) = _monthWithMachines();
        vm.mockCallRevert(address(firstoSigned), abi.encodeWithSelector(firstoSigned.defaultTakerFeeBps.selector), "down");
        vm.prank(keeper);
        lister.list(address(m), 0);
        vm.clearMockedCalls();
        address vault = lister.vaultOf(address(m), 0);
        MachineLister.Listing memory l = _l(vault);
        assertEq(l.firstoDigest, bytes32(0));
        assertGt(l.officialId, 0);
        assertGt(l.seaportEnd, 0);
        // 恢复后到期续挂时补挂上
        vm.warp(block.timestamp + TAPE_LIST_DURATION - 1 days + 1);
        lister.reprice(address(m), 0);
        (, bytes32 d) = _firstoOf(m, 0);
        assertTrue(d != bytes32(0));
    }

    receive() external payable {}
}
