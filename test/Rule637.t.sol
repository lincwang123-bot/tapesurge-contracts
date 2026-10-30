// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";

/// @notice 规则决定 6.37：
///         - 主板只经 MarketTrader（运营地址递单）在市场上买矿机，外部的人不能按报价直接卖给主板（堵住"从协议自己的卖单买、
///           再卖给另一块正在收购的局"的套利）；月局交接只认同一工厂的旧月局；
///         - 收购价上限 = min(卖一, 一年产出)，开局就按卖一；
///         - 月局买满（100 台，或剩余预算按当前收购价上限连一台最小算力的矿机都买不下）就提前开始 30 天挖矿。
///         保底结局收 2% 手续费、溢价分成照收的测试在 Settlement / Conservation / StdPremiumFee 里。
contract Rule637Test is Fixture {
    MonthBoard internal m;
    address internal seller;

    function setUp() public override {
        super.setUp();
        _startGenesis();
        m = _monthBoard();
        _fillMonth(m);
        assertTrue(m.isPurchasing());
        seller = _newUser();
    }

    /// @dev 矿机持有人、别的合约都不能直接卖给月局；MarketTrader 可以
    function test_MonthBoardOnlyBuysThroughTheTrader() public {
        (uint256 id,) = _newMachine(seller, 30);
        uint256 spent = 30 * m.buyPrice();
        vm.startPrank(seller);
        machines.approve(address(m), id);
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.sellMachine(address(machines), id, 0);
        vm.stopPrank();
        assertEq(_traderSell(address(m), address(machines), id, seller, spent), spent);
        assertEq(m.machineCount(), 1);
    }

    /// @dev 套利路径被堵上：从结算中的旧局按卖价买到的矿机，买家自己不能转手卖给正在收购的新局
    function test_NoArbitrageFromASettlingBoardIntoAPreparingOne() public {
        address arb = _newUser();
        (uint256 id,) = _newMachine(arb, 30); // 相当于刚从旧局按卖价买到手
        TapeBoard sb = _board();
        _fillUniform(sb, 25, 20 * BEM_1);
        vm.startPrank(arb);
        machines.approve(address(m), id);
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.sellMachine(address(machines), id, 0);
        machines.approve(address(sb), id);
        vm.expectRevert(TapeBoard.NotAuthorized.selector);
        sb.sellMachine(address(machines), id, 0);
        vm.stopPrank();
    }

    /// @dev 剩余预算连一台最小算力（10）的矿机都买不下：买完这一台就提前开始挖矿，30 天从这一刻算
    function test_MonthStartsMiningEarlyWhenBoughtOut() public {
        uint256 price = m.buyPrice();
        uint256 w1 = m.budget() / price - 15; // 买完后剩约 15 单位算力的钱：还能再买一台 10 的
        _sellMonth(m, seller, w1);
        assertEq(uint256(m.state()), uint256(MonthState.Preparing), "still room for a 10-unit machine");
        assertGe(m.budget(), 10 * price);
        uint256 prepEnd0 = m.prepEnd();
        vm.warp(block.timestamp + 5 hours);
        _sellMonth(m, seller, 10); // 剩约 5 单位算力的钱 < 一台最小算力
        assertLt(m.budget(), 10 * price);
        assertEq(uint256(m.state()), uint256(MonthState.Mining), "bought out: mining starts now");
        assertEq(m.prepEnd(), block.timestamp);
        assertLt(m.prepEnd(), prepEnd0);
        assertEq(m.miningStart(), block.timestamp);
        assertEq(m.miningEnd(), block.timestamp + 30 days);
        assertFalse(m.isPurchasing());
        // 之后卖不进来；剩下的预算留到局终原样退还
        (uint256 id,) = _newMachine(seller, 10);
        _toTrader(address(m), address(machines), id, seller);
        vm.prank(address(trader));
        vm.expectRevert(MonthBoard.BuyRoundInactive.selector);
        m.sellMachine(address(machines), id, 0);
    }

    /// @dev 没买满时照常等满 3 天准备期；报价无效（收购价为 0）时不会被误判为买满
    function test_MonthWaitsWhenNotBoughtOut() public {
        _sellMonth(m, seller, 10);
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Preparing));
        priceFeed.post(m.buyPriceCap() / 2, m.buyPriceCap() / 2);
        vm.warp(block.timestamp + 3 hours); // 报价过期：收购价 0
        assertEq(m.buyPrice(), 0);
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Preparing), "stale feed is not 'bought out'");
        vm.warp(m.prepEnd());
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Mining));
        assertEq(m.miningStart(), m.prepEnd());
    }

    /// @dev 收购价上限 = min(卖一, 一年产出)：报价有效时开局就是卖一，不随时间往上爬
    function test_BuyCapIsTheAskFromTheStart() public {
        uint256 cap = m.buyPriceCap();
        priceFeed.post(cap / 2, cap * 7 / 10);
        assertEq(m.buyPrice(), cap * 7 / 10);
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 2 hours);
            priceFeed.post(cap / 2, cap * 7 / 10); // 机器人每隔一段时间重报同样的价
        }
        assertEq(m.buyPrice(), cap * 7 / 10, "no hourly climb after 20 hours");
    }
}
