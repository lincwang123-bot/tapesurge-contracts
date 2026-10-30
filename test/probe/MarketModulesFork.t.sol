// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ITransistors, ICircuits} from "../../src/interfaces/ITapeOut.sol";
import {BoardFactory} from "../../src/BoardFactory.sol";
import {TapeBoard} from "../../src/TapeBoard.sol";
import {StdMachineSales} from "../../src/StdMachineSales.sol";
import {MarketPriceFeed} from "../../src/MarketPriceFeed.sol";
import {MachineRules} from "../../src/MachineRules.sol";
import {MarketTrader} from "../../src/market/MarketTrader.sol";
import {SignedAsk, IFirstoSignedAsk, FirstoSignedAskLib} from "../../src/market/FirstoSignedAsk.sol";
import {MachineLister} from "../../src/market/MachineLister.sol";
import {
    IOfficialMarket,
    AdvancedOrder,
    CriteriaResolver,
    OrderParameters,
    OrderComponents,
    OfferItem,
    ConsiderationItem
} from "../../src/market/IMarkets.sol";
import {BoardState} from "../../src/interfaces/ITapeBoard.sol";
import {TapeSurgeDefaults} from "../../script/TapeSurgeDefaults.sol";
import {TapeSurgeDeploy} from "../../script/TapeSurgeDeploy.sol";

interface IVRFSubscriptionV2PlusFork {
    function createSubscription() external returns (uint256 subId);
    function fundSubscriptionWithNative(uint256 subId) external payable;
}

interface ISeaportView {
    function getOrderHash(OrderComponents calldata order) external view returns (bytes32);
    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize);
    function information() external view returns (string memory, bytes32 domainSeparator, address);
    function validate(SeaportOrder[] calldata orders) external returns (bool);
    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool);
}

struct SeaportOrder {
    OrderParameters parameters;
    bytes signature;
}

interface IWBNBFork {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title rc8 主网分叉集成测试：真实部署（TapeSurgeDeploy，和主网脚本同一份）+ 真实 TapeOut 官方矿机市场 / Seaport 1.6 /
///        PoD / PancakeSwap V3 / 真实挂单（规则决定 6.26）
/// @notice MARKET_PROBE=1 FORK_BLOCK=129350109 BSC_RPC_URL=<主网 RPC> forge test --match-contract MarketModulesFork -vv
///         真实挂单（tapeout.market API 2026-10-24 抓取）在 FORK_BLOCK 时有效；换区块后要换挂单号 / 卖单。
contract MarketModulesForkTest is Test {
    bytes internal constant PASS_NETLIST = hex"0000000200000300000002000004000000030000040000000500000600000004000004";
    uint256 internal constant BEM_1 = 1e8;

    TapeSurgeDefaults.Mainnet internal m;
    BoardFactory internal factory;
    StdMachineSales internal stdSales;
    MarketPriceFeed internal feed;
    MachineRules internal rules;
    MarketTrader internal trader;
    MachineLister internal lister;
    ITransistors internal transistors;
    ICircuits internal passCircuits;
    address internal operator = makeAddr("operator");
    /// @dev 递单的地址：规则决定 6.37 起 MarketTrader 的买入只认运营地址
    address internal keeper = operator;
    address internal buyer = makeAddr("market buyer");
    uint256 internal nonce;

    function setUp() public {
        if (!vm.envOr("MARKET_PROBE", false)) return;
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(129350109));
        vm.createSelectFork(vm.envString("BSC_RPC_URL"), blk);
        m = TapeSurgeDefaults.mainnetAddresses();
        vm.deal(address(this), 100 ether);
        uint256 subId = IVRFSubscriptionV2PlusFork(m.vrfCoordinator).createSubscription();
        IVRFSubscriptionV2PlusFork(m.vrfCoordinator).fundSubscriptionWithNative{value: 1 ether}(subId);
        TapeSurgeDeploy.Deployment memory d =
            TapeSurgeDeploy.deployMainnet(address(this), TapeSurgeDeploy.defaultSettings(operator, subId));
        factory = d.factory;
        stdSales = d.stdSales;
        feed = d.priceFeed;
        rules = d.rules;
        trader = d.trader;
        lister = d.lister;
        transistors = factory.transistors();
        passCircuits = ICircuits(factory.passCircuits());
        vm.deal(buyer, 100 ether);
    }

    // ---------------- 辅助 ----------------

    function _player() internal returns (address u, uint256 passId) {
        u = address(uint160(uint256(keccak256(abi.encode("mm player", ++nonce)))));
        vm.deal(u, 1 ether);
        vm.startPrank(u);
        transistors.mint{value: 5 * 0.0011 ether}(0, 5);
        vm.recordLogs();
        (bool ok,) =
            address(passCircuits).call{value: 0.0002 ether}(abi.encodeCall(ICircuits.tapeout, (PASS_NETLIST, 2, 2)));
        require(ok, "tapeout");
        vm.stopPrank();
        passId = _mintedId(vm.getRecordedLogs(), address(passCircuits));
        deal(m.bem, u, 50 * BEM_1);
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

    /// @dev 创世 + 25 人各投 20 BEM 招满第一块标准局（500 BEM）
    function _activeBoard() internal returns (TapeBoard b) {
        address[] memory us = new address[](25);
        uint256[] memory ids = new uint256[](25);
        for (uint256 i = 0; i < 25; i++) {
            (us[i], ids[i]) = _player();
        }
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 7 * 28_800 * 2);
        // 开局前必须报过价（全局审计 G-1）：先报一次，开局后把报价合约恢复成"从没报过价"，下面招满后再按上限报第一次价
        vm.prank(operator);
        feed.post(1, 1);
        b = TapeBoard(factory.startGenesis());
        vm.store(address(feed), bytes32(uint256(0)), bytes32(0)); // bid
        vm.store(address(feed), bytes32(uint256(1)), bytes32(0)); // ask
        vm.store(address(feed), bytes32(uint256(2)), bytes32(0)); // updatedAt
        vm.store(address(feed), bytes32(uint256(6)), bytes32(0)); // liveAt
        for (uint256 i = 0; i < 25; i++) {
            vm.startPrank(us[i]);
            IERC721(address(passCircuits)).approve(address(b), ids[i]);
            IERC20(m.bem).approve(address(b), type(uint256).max);
            b.join(ids[i], 20 * BEM_1);
            vm.stopPrank();
        }
        assertEq(uint256(b.state()), uint256(BoardState.Active));
        // 运营地址报价：买一 = 卖一 = 收购上限（一年产出），收购价 = 上限
        uint256 cap = b.buyPriceCap();
        vm.prank(operator);
        feed.post(cap, cap);
        console2.log("buy price cap (BEM units / weight)", cap, "buy price", b.buyPrice());
    }

    /// @dev 规则决定 6.37：运营地址经 MarketTrader.buyFromSignedAsk 买一张真实的 Firsto 签名卖单 V2。
    ///      SIGNED_ASK_FILE = 一张卖单的 JSON（字段同 SignedAsk 加 signature，按 Firsto 接口 bestAsk.execution 整理），
    ///      FORK_BLOCK 设成抓取卖单时的区块（卖单被买走或撤销后要重新抓）。没设置时跳过。
    function test_BuySignedAskFromLiveMarket() public {
        if (!vm.envOr("MARKET_PROBE", false)) return;
        string memory f = vm.envOr("SIGNED_ASK_FILE", string(""));
        if (bytes(f).length == 0) return;
        string memory j = vm.readFile(f);
        SignedAsk memory a = SignedAsk({
            maker: vm.parseJsonAddress(j, ".maker"),
            collection: vm.parseJsonAddress(j, ".collection"),
            tokenId: vm.parseJsonUint(j, ".tokenId"),
            nonce: vm.parseJsonUint(j, ".nonce"),
            price: uint128(vm.parseJsonUint(j, ".price")),
            expiry: uint64(vm.parseJsonUint(j, ".expiry")),
            payoutRecipient: vm.parseJsonAddress(j, ".payoutRecipient"),
            feeBps: uint16(vm.parseJsonUint(j, ".feeBps")),
            feeEpoch: vm.parseJsonUint(j, ".feeEpoch"),
            schemaVersion: uint16(vm.parseJsonUint(j, ".schemaVersion"))
        });
        bytes memory sig = vm.parseJsonBytes(j, ".signature");
        TapeBoard b = _activeBoard();
        uint256 seller0 = a.payoutRecipient.balance;
        uint256 budget0 = b.budget();
        vm.prank(address(0xBEEF));
        vm.expectRevert(MarketTrader.NotOperator.selector);
        trader.buyFromSignedAsk(address(b), a, sig);
        vm.prank(keeper);
        uint256 g = gasleft();
        uint256 paid = trader.buyFromSignedAsk(address(b), a, sig);
        console2.log("REPORT buyFromSignedAsk gas", g - gasleft(), "BEM paid", paid);
        assertEq(IERC721(a.collection).ownerOf(a.tokenId), address(b), "machine delivered to the board");
        assertEq(b.machineCount(), 1);
        assertEq(budget0 - b.budget(), paid, "books the real cost");
        assertEq(a.payoutRecipient.balance - seller0, a.price, "seller got exactly the ask price");
        assertEq(IERC20(m.bem).balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);
        // 实际花费 ≤ 计价算力 × 收购价上限
        assertLe(paid, uint256(b.machine(0).weight) * b.buyPrice());
    }

    /// @dev tapeout.market 卖单 0x0fa8…2e47：官方矿机 #8340（71 算力）
    function _order8340() internal pure returns (AdvancedOrder memory a) {
        OrderParameters memory p;
        p.offerer = 0x78e3a21209a35FD6BD101eb9eA0f44D00EcE2F88;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(2, 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C, 8340, 1, 1);
        p.consideration = new ConsiderationItem[](2);
        p.consideration[0] =
            ConsiderationItem(0, address(0), 0, 3164337029702970300, 3164337029702970300, payable(p.offerer));
        p.consideration[1] = ConsiderationItem(
            0, address(0), 0, 31643370297029703, 31643370297029703, payable(TapeSurgeDefaults.TAPEMARKET_FEE_RECIPIENT)
        );
        p.startTime = 1792668741;
        p.endTime = 1793273541;
        p.salt = 0x66e82ff5a011fc4b;
        p.totalOriginalConsiderationItems = 2;
        a = AdvancedOrder(
            p,
            1,
            1,
            hex"1cab36df043c2014562750423f992aa452c348f7f8694c35e2faf584b9fcd5e80b7032b32b1eee90ba2905ff01fe3e9bfae26fdd80a1678a950a38d880d2c9dd",
            ""
        );
    }

    /// @dev tapeout.market 卖单 0xd4df…64be：Behemoth #1050（基础 10 × 倍数 6 = 60 单位）
    function _order1050() internal pure returns (AdvancedOrder memory a) {
        OrderParameters memory p;
        p.offerer = 0x1A1443e6B832F2Db3Ee86F099fa22aBCa7e763A2;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(2, 0x1F5Cb4aeaE1807Bf60c3b9C0D8aDBCC14e91f12C, 1050, 1, 1);
        p.consideration = new ConsiderationItem[](2);
        p.consideration[0] = ConsiderationItem(0, address(0), 0, 3.5 ether, 3.5 ether, payable(p.offerer));
        p.consideration[1] = ConsiderationItem(
            0, address(0), 0, 0.035 ether, 0.035 ether, payable(TapeSurgeDefaults.TAPEMARKET_FEE_RECIPIENT)
        );
        p.startTime = 1792743192;
        p.endTime = 1793347992;
        p.salt = 0xd5d3fb172e54bdda;
        p.totalOriginalConsiderationItems = 2;
        a = AdvancedOrder(
            p,
            1,
            1,
            hex"507fc7bc9c510ebffef3a3210c68b7b44f5cc3af246782d8690852a6d8c1282dab273a01657e14ba6da6469617c29a5bd3959e87b4985cc49015339e49a6de28",
            ""
        );
    }

    /// @dev 创世要等 7 天，tapeout.market 的真实卖单那时已过期：由真实持有人在真实 Seaport 上按同样的对价链上重新挂一张
    ///      （offerer 本人 validate，不需要签名；持有人此前已经授权 Seaport）
    function _relist(AdvancedOrder memory a) internal returns (AdvancedOrder memory) {
        a.parameters.startTime = block.timestamp;
        a.parameters.endTime = block.timestamp + 7 days;
        a.parameters.salt += 1;
        a.signature = "";
        SeaportOrder[] memory os = new SeaportOrder[](1);
        os[0] = SeaportOrder(a.parameters, "");
        vm.prank(a.parameters.offerer);
        ISeaportView(m.seaport).validate(os);
        return a;
    }

    function _l(address vault) internal view returns (MachineLister.Listing memory l) {
        (bool ok, bytes memory ret) = address(lister).staticcall(abi.encodeWithSignature("listings(address)", vault));
        require(ok);
        l = abi.decode(ret, (MachineLister.Listing));
    }

    function _sellOrder(TapeBoard b, uint256 index) internal view returns (AdvancedOrder memory a, uint256 total) {
        address vault = lister.vaultOf(address(b), index);
        MachineLister.Listing memory l = _l(vault);
        OrderParameters memory p;
        p.offerer = vault;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(2, b.machine(index).collection, b.machine(index).circuitId, 1, 1);
        p.consideration = new ConsiderationItem[](2);
        p.consideration[0] = ConsiderationItem(0, address(0), 0, l.net, l.net, payable(vault));
        p.consideration[1] = ConsiderationItem(
            0, address(0), 0, l.seaportFee, l.seaportFee, payable(TapeSurgeDefaults.TAPEMARKET_FEE_RECIPIENT)
        );
        p.startTime = l.seaportStart;
        p.endTime = l.seaportEnd;
        p.salt = l.salt;
        p.totalOriginalConsiderationItems = 2;
        a = AdvancedOrder(p, 1, 1, "", "");
        total = l.net + l.seaportFee;
    }

    function _status(AdvancedOrder memory a) internal view returns (bool validated, bool cancelled, uint256 filled) {
        OrderParameters memory p = a.parameters;
        OrderComponents memory c;
        c.offerer = p.offerer;
        c.offer = p.offer;
        c.consideration = p.consideration;
        c.startTime = p.startTime;
        c.endTime = p.endTime;
        c.salt = p.salt;
        bytes32 h = ISeaportView(m.seaport).getOrderHash(c);
        (validated, cancelled, filled,) = ISeaportView(m.seaport).getOrderStatus(h);
    }

    // ---------------- 主流程 ----------------

    TapeBoard internal b;
    address internal constant BEH = 0x1F5Cb4aeaE1807Bf60c3b9C0D8aDBCC14e91f12C;

    function test_BuyFromAllSourcesThenListAndSell() public {
        if (!vm.envOr("MARKET_PROBE", false)) return vm.skip(true);
        b = _activeBoard();
        _buyPhase();
        // 进入终局（最长期限）；运营地址报价，卖价 ≈ 上限 × 90%
        vm.warp(b.startedAt() + 730 days);
        vm.roll(block.number + 1000);
        b.expire();
        uint256 unit = b.buyPriceCap() * 9 / 10;
        _forceFeed(address(feed), unit, unit); // 730 天后报价早已过期：直接放到这个价（审计 H-1 后不能一步跳价）
        _listPhase(unit);
        _sellOnOfficial();
        _sellOnSeaport();
        if (b.machineCount() > 2) _directBuyRecalls();
    }

    function _buyPhase() internal {
        // 1. 官方市场：未验证池的矿机 #4533（挂单 23950）—— rc8 按 PoD 真实字段拒绝
        vm.prank(keeper);
        vm.expectRevert(MachineRules.MachineNotEligible.selector);
        trader.buyFromOfficial(address(b), 23950);
        console2.log("REPORT unverified-pool machine #4533 rejected (MachineNotEligible)");

        // 2. 官方市场挂单 23951：#17999（10 单位，0.5 BNB）
        uint256 g = gasleft();
        vm.prank(keeper);
        uint256 paid0 = trader.buyFromOfficial(address(b), 23951);
        console2.log("REPORT buyFromOfficial gas", g - gasleft(), "BEM paid", paid0);
        assertEq(IERC721(m.machineCircuits).ownerOf(17999), address(b));

        // 3. Seaport：官方矿机 #8340（71 单位）
        AdvancedOrder memory o8340 = _relist(_order8340());
        g = gasleft();
        vm.prank(keeper);
        uint256 paid1 = trader.buyFromSeaport(address(b), o8340);
        console2.log("REPORT buyFromSeaport gas", g - gasleft(), "BEM paid", paid1);
        assertEq(IERC721(m.machineCircuits).ownerOf(8340), address(b));

        // 4. Seaport：Behemoth #1050（按 60 单位计价；单价接近一年产出上限，可能超出）
        AdvancedOrder memory o1050 = _relist(_order1050());
        vm.prank(keeper);
        try trader.buyFromSeaport(address(b), o1050) returns (uint256 paid2) {
            console2.log("REPORT Behemoth #1050 bought, BEM paid", paid2);
            assertEq(IERC721(BEH).ownerOf(1050), address(b));
            assertEq(b.machine(2).weight, 60, "Behemoth priced at base 10 x multiplier 6");
            assertEq(b.machine(2).collection, BEH);
        } catch (bytes memory reason) {
            console2.log("REPORT Behemoth #1050 not bought (above the formula cap)");
            console2.logBytes(reason);
        }
        // 5. Behemoth #1509（基础 4 × 倍数 6 = 24 单位）按收购价上限卖给主板：规则决定 6.37 起主板只认 MarketTrader，
        //    这里模拟它已经在市场上买下这台（持有人转给 MarketTrader，再以它的身份卖）
        if (b.machineCount() == 2) {
            address owner = IERC721(BEH).ownerOf(1509);
            vm.prank(owner);
            IERC721(BEH).transferFrom(owner, address(trader), 1509);
            uint256 spentB = 24 * b.buyPrice();
            vm.startPrank(address(trader));
            IERC721(BEH).approve(address(b), 1509);
            uint256 paidB = b.sellMachine(BEH, 1509, spentB);
            IERC20(m.bem).transfer(owner, IERC20(m.bem).balanceOf(address(trader))); // 货款转回原持有人，MarketTrader 不留资金
            vm.stopPrank();
            console2.log("REPORT Behemoth #1509 sold directly, weight", b.machine(2).weight, "BEM paid", paidB);
            assertEq(b.machine(2).weight, 24, "real PoD: base 4 x multiplier 6");
            assertEq(paidB, 24 * b.buyPrice());
        }
        assertGe(b.machineCount(), 2);
        assertEq(IERC20(m.bem).balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);
    }

    function _listPhase(uint256 unit) internal {
        IOfficialMarket om = IOfficialMarket(m.officialMarket);
        // 挂单：#17999（第 0 台）、#8340（第 1 台）同时挂到真实官方市场和 Seaport
        uint256 g = gasleft();
        vm.prank(keeper);
        lister.list(address(b), 0);
        console2.log("REPORT lister.list gas (consign + official list + Seaport validate)", g - gasleft());
        vm.prank(keeper);
        lister.list(address(b), 1);
        _checkOfficial(om, lister.vaultOf(address(b), 0));
        (AdvancedOrder memory sp0,) = _sellOrder(b, 0);
        (bool validated,,) = _status(sp0);
        assertTrue(validated, "Seaport order validated on chain");

        // 改价：没变化时拒绝；报价上调 3% 后改价（官方 setPrice，Seaport 撤旧单挂新单）
        vm.expectRevert(MachineLister.NoChange.selector);
        lister.reprice(address(b), 0);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(operator);
        feed.post(unit * 103 / 100, unit * 103 / 100);
        g = gasleft();
        lister.reprice(address(b), 0);
        console2.log("REPORT lister.reprice gas", g - gasleft());
        (, bool cancelledOld,) = _status(sp0);
        assertTrue(cancelledOld, "old Seaport order cancelled");
        (AdvancedOrder memory sp0new,) = _sellOrder(b, 0);
        (validated,,) = _status(sp0new);
        assertTrue(validated, "new Seaport order validated");
    }

    /// @dev 规则决定 6.37 起保底结局也收卖矿溢价分成：按公式价算的那一份（超过成本的部分 × 10%）。实际成交价 ≥ 公式价时，
    ///      主板到手 = 成交价 − (成交价 − 成本) × 10% ≥ 公式价 − (公式价 − 成本) × 10%
    function _premiumFee(uint256 index, uint256 quote) internal view returns (uint256) {
        uint256 basis = stdSales.machineCost(address(b), index);
        return quote > basis ? (quote - basis) * stdSales.PREMIUM_FEE_BPS() / 10_000 : 0;
    }

    function _checkOfficial(IOfficialMarket om, address v0) internal view {
        assertEq(IERC721(m.machineCircuits).ownerOf(17999), v0);
        MachineLister.Listing memory l0 = _l(v0);
        (address seller, address col, uint256 tid, uint256 price, uint256 feeBps, uint256 st) =
            om.listingView(l0.officialId);
        assertEq(seller, v0);
        assertEq(col, m.machineCircuits);
        assertEq(tid, 17999);
        assertEq(price, l0.officialPrice);
        assertEq(st, 1);
        console2.log("REPORT official listing id", l0.officialId, "price wei", price);
        console2.log("REPORT official fee bps", feeBps, "vault net wei", l0.net);
    }

    /// @dev 有人在真实官方市场买走第 0 台：卖款推给挂单库 → 真实 PancakeSwap 换 BEM → 主板按成交时的要价记账
    function _sellOnOfficial() internal {
        address v0 = lister.vaultOf(address(b), 0);
        MachineLister.Listing memory l0 = _l(v0);
        (AdvancedOrder memory sp0,) = _sellOrder(b, 0);
        uint256 quote0 = stdSales.quote(address(b), 0);
        uint256 bal0 = IERC20(m.bem).balanceOf(address(b));
        uint256 g = gasleft();
        vm.prank(buyer);
        IOfficialMarket(m.officialMarket).buy{value: l0.officialPrice}(l0.officialId, uint96(l0.officialPrice));
        console2.log("REPORT official buy of a listed board machine, total gas", g - gasleft());
        assertEq(IERC721(m.machineCircuits).ownerOf(17999), buyer);
        assertTrue(b.machine(0).sold);
        uint256 got0 = IERC20(m.bem).balanceOf(address(b)) - bal0;
        console2.log("REPORT board BEM", got0, "quote", quote0);
        assertGe(got0 + _premiumFee(0, quote0), quote0, "board got at least the formula price minus the premium fee");
        (, bool c0,) = _status(sp0);
        assertTrue(c0, "Seaport side cancelled after the official sale");
    }

    /// @dev 有人在真实 Seaport 买走第 1 台。它是在报价上调 3% 之前挂的：先按旧价成交 → 结算低于成交时的公式价，
    ///      整笔回滚（BelowFormula 原样从 Seaport 冒出来）；改价后再成交
    function _sellOnSeaport() internal {
        (AdvancedOrder memory stale, uint256 staleTotal) = _sellOrder(b, 1);
        vm.prank(buyer);
        try ISeaportView(m.seaport).fulfillAdvancedOrder{value: staleTotal}(
            stale, new CriteriaResolver[](0), bytes32(0), buyer
        ) {
            revert("stale listing should not settle");
        } catch (bytes memory reason) {
            console2.log("REPORT stale Seaport listing rejected at settlement:");
            console2.logBytes(reason);
        }
        lister.reprice(address(b), 1);
        (, bool cancelledStale,) = _status(stale);
        assertTrue(cancelledStale, "stale order cancelled on reprice");
        (AdvancedOrder memory sp1, uint256 total1) = _sellOrder(b, 1);
        MachineLister.Listing memory l1 = _l(lister.vaultOf(address(b), 1));
        uint256 quote1 = stdSales.quote(address(b), 1);
        uint256 bal0 = IERC20(m.bem).balanceOf(address(b));
        uint256 g = gasleft();
        vm.prank(buyer);
        ISeaportView(m.seaport).fulfillAdvancedOrder{value: total1}(sp1, new CriteriaResolver[](0), bytes32(0), buyer);
        console2.log("REPORT Seaport fill of a listed board machine, total gas", g - gasleft());
        assertEq(IERC721(m.machineCircuits).ownerOf(8340), buyer);
        assertTrue(b.machine(1).sold);
        assertGe(IERC20(m.bem).balanceOf(address(b)) - bal0 + _premiumFee(1, quote1), quote1, "formula price minus the premium fee");
        assertEq(IERC20(m.bem).balanceOf(address(lister)), 0);
        assertEq(address(lister).balance, 0);
        (,,,,, uint256 st) = IOfficialMarket(m.officialMarket).listingView(l1.officialId);
        assertTrue(st != 1, "official listing withdrawn after the Seaport sale");
    }

    /// @dev 第 2 台（Behemoth）：挂单后有人直接按公式价向主板买 → 先撤真实市场上的单
    function _directBuyRecalls() internal {
        vm.prank(keeper);
        lister.list(address(b), 2);
        MachineLister.Listing memory l2 = _l(lister.vaultOf(address(b), 2));
        deal(m.bem, buyer, 1_000 * BEM_1);
        vm.startPrank(buyer);
        IERC20(m.bem).approve(address(stdSales), type(uint256).max);
        uint256 g = gasleft();
        stdSales.buyMachine(address(b), 2, type(uint256).max);
        console2.log("REPORT direct formula buy of a consigned machine (recall + release) gas", g - gasleft());
        vm.stopPrank();
        assertEq(IERC721(b.machine(2).collection).ownerOf(b.machine(2).circuitId), buyer);
        (,,,,, uint256 st2) = IOfficialMarket(m.officialMarket).listingView(l2.officialId);
        assertTrue(st2 != 1, "official listing withdrawn");
    }


    /// @dev 规则决定 6.30：主板矿机经挂单模块挂到真实 Firsto 单笔签名卖单 V2（EIP-1271，maker = 挂单库），
    ///      改价换 nonce（真实 V2 上旧 nonce 作废），买家 fillSignedAsk 成交 → 主板按成交时的要价结算、其他平台撤单
    function test_SellOnFirstoSignedAskV2() public {
        if (!vm.envOr("MARKET_PROBE", false)) return vm.skip(true);
        b = _activeBoard();
        _buyPhase();
        vm.warp(b.startedAt() + 730 days);
        vm.roll(block.number + 1000);
        b.expire();
        uint256 unit = b.buyPriceCap() * 9 / 10;
        _forceFeed(address(feed), unit, unit); // 730 天后报价早已过期：直接放到这个价（审计 H-1 后不能一步跳价）
        vm.prank(keeper);
        lister.list(address(b), 0);
        address v0 = lister.vaultOf(address(b), 0);
        IFirstoSignedAsk v2 = IFirstoSignedAsk(m.firstoSignedAsk);
        (SignedAsk memory a1, bytes32 d1) = lister.firstoAsk(address(b), 0);
        assertTrue(d1 != bytes32(0), "listed on Firsto");
        assertEq(d1, FirstoSignedAskLib.digest(address(v2), a1));
        assertEq(IERC721(m.machineCircuits).getApproved(17999), address(v2), "per-token approval for V2");
        console2.log("REPORT Firsto ask price wei", uint256(a1.price), "nonce", a1.nonce);
        // 改价：报价上调 3%，旧 nonce 在真实 V2 上作废
        vm.warp(block.timestamp + 1 hours);
        vm.prank(operator);
        feed.post(unit * 103 / 100, unit * 103 / 100);
        lister.reprice(address(b), 0);
        assertTrue(v2.isSignedAskNonceInvalidated(v0, a1.nonce), "old nonce cancelled on the real V2");
        (SignedAsk memory a2,) = lister.firstoAsk(address(b), 0);
        uint256 cost1 = uint256(a1.price) + uint256(a1.price) * a1.feeBps / 10_000;
        vm.prank(buyer);
        (bool ok,) = address(v2).call{value: cost1}(abi.encodeCall(IFirstoSignedAsk.fillSignedAsk, (a1, hex"01", buyer)));
        assertFalse(ok, "old Firsto order cannot fill");
        // 成交
        MachineLister.Listing memory l0 = _l(v0);
        (AdvancedOrder memory sp0,) = _sellOrder(b, 0);
        uint256 quote0 = stdSales.quote(address(b), 0);
        uint256 bal0 = IERC20(m.bem).balanceOf(address(b));
        uint256 cost2 = uint256(a2.price) + uint256(a2.price) * a2.feeBps / 10_000;
        uint256 g = gasleft();
        vm.prank(buyer);
        v2.fillSignedAsk{value: cost2}(a2, hex"01", buyer);
        console2.log("REPORT Firsto fillSignedAsk of a listed board machine, total gas", g - gasleft());
        assertEq(IERC721(m.machineCircuits).ownerOf(17999), buyer);
        assertTrue(b.machine(0).sold);
        uint256 got = IERC20(m.bem).balanceOf(address(b)) - bal0;
        console2.log("REPORT board BEM", got, "quote", quote0);
        assertGe(got + _premiumFee(0, quote0), quote0, "board got at least the formula price minus the premium fee");
        (,,,,, uint256 st) = IOfficialMarket(m.officialMarket).listingView(l0.officialId);
        assertTrue(st != 1, "official listing withdrawn after the Firsto sale");
        (, bool c0,) = _status(sp0);
        assertTrue(c0, "Seaport order cancelled after the Firsto sale");
        assertEq(address(lister).balance, 0);
    }

    function _signedOffer(uint256 wbnb, uint256 pk, address bidder) internal view returns (AdvancedOrder memory) {
        OrderParameters memory p;
        p.offerer = bidder;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(1, m.wbnb, 0, wbnb, wbnb);
        p.consideration = new ConsiderationItem[](1);
        p.consideration[0] = ConsiderationItem(4, m.machineCircuits, 0, 1, 1, payable(bidder)); // 整个合集任意一台
        p.startTime = block.timestamp;
        p.endTime = block.timestamp + 1 days;
        p.salt = 77;
        p.totalOriginalConsiderationItems = 1;
        OrderComponents memory c;
        c.offerer = bidder;
        c.offer = p.offer;
        c.consideration = p.consideration;
        c.startTime = p.startTime;
        c.endTime = p.endTime;
        c.salt = p.salt;
        (, bytes32 domain,) = ISeaportView(m.seaport).information();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, ISeaportView(m.seaport).getOrderHash(c))));
        return AdvancedOrder(p, 1, 1, abi.encodePacked(r, s, v), "");
    }

    /// @dev 接受真实 Seaport 上的 WBNB 出价（普通钱包签名，EIP-712）：主板的矿机经 MarketTrader 卖出
    function test_SellToSignedSeaportOffer() public {
        if (!vm.envOr("MARKET_PROBE", false)) return vm.skip(true);
        b = _activeBoard();
        vm.prank(keeper);
        trader.buyFromOfficial(address(b), 23951);
        vm.warp(b.startedAt() + 730 days);
        b.expire();
        uint256 unit = b.buyPriceCap() * 9 / 10;
        _forceFeed(address(feed), unit, unit); // 730 天后报价早已过期：直接放到这个价（审计 H-1 后不能一步跳价）
        // 先挂到真实官方市场和 Seaport（寄售到挂单库）；接受出价时由卖矿合约先撤单拿回
        vm.prank(keeper);
        lister.list(address(b), 0);
        MachineLister.Listing memory l0 = _l(lister.vaultOf(address(b), 0));
        (AdvancedOrder memory listed,) = _sellOrder(b, 0);
        uint256 ask = stdSales.quote(address(b), 0);
        (address bidder, uint256 pk) = makeAddrAndKey("seaport bidder");
        uint256 wbnb = ask * 1e18 / lister.ORACLE().quoteBemOut(1e18) * 115 / 100;
        vm.deal(bidder, wbnb + 1 ether);
        vm.startPrank(bidder);
        IWBNBFork(m.wbnb).deposit{value: wbnb}();
        IWBNBFork(m.wbnb).approve(m.seaport, type(uint256).max);
        vm.stopPrank();
        AdvancedOrder memory offer = _signedOffer(wbnb, pk, bidder);
        CriteriaResolver[] memory cr = new CriteriaResolver[](1);
        cr[0] = CriteriaResolver(0, 1, 0, 17999, new bytes32[](0));
        uint256 bal0 = IERC20(m.bem).balanceOf(address(b));
        uint256 g = gasleft();
        vm.prank(keeper);
        uint256 got = trader.sellToOffer(address(b), 0, offer, cr, ask);
        console2.log("REPORT sellToOffer (real Seaport, signed WBNB collection offer) gas", g - gasleft());
        console2.log("REPORT BEM to board", got, "ask", ask);
        assertEq(IERC721(m.machineCircuits).ownerOf(17999), bidder);
        assertGe(IERC20(m.bem).balanceOf(address(b)) - bal0, ask);
        assertEq(IWBNBFork(m.wbnb).balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);
        (,,,,, uint256 st) = IOfficialMarket(m.officialMarket).listingView(l0.officialId);
        assertTrue(st != 1, "official listing withdrawn by the recall");
        (, bool cancelled,) = _status(listed);
        assertTrue(cancelled, "Seaport listing cancelled by the recall");
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
}
