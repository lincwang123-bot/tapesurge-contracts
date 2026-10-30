// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";

/// @notice 全局审计（v2.0-audit.4）G-1 的回归测试。
///         修复（v2.0-audit.5，规则决定 6.36）：报过价之后停运一律暂停收购，不退回默认曲线；开局前必须报过价。
contract AuditGlobalTest is Fixture {
    /// @dev G-1a：从没报过价时不能开局；报过价后第一块标准局按报价收购，不按默认曲线（原测试里付了 2 倍市价）
    function test_G1_GenesisRequiresAPostThenBuysAtMarket() public {
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(BoardFactory.FeedNotPosted.selector);
        factory.startGenesis();

        uint256 market = _capNow() / 4; // 假设市价 = 一年产出的 25%（约 3 个月回本）
        priceFeed.post(market, market);
        TapeBoard b = TapeBoard(factory.startGenesis());
        _fillUniform(b, 25, 20 * BEM_1);
        assertEq(uint256(b.state()), uint256(BoardState.Active));
        assertFalse(priceFeed.abandoned());
        assertEq(b.buyPrice(), market, "feed price, not the curve's 50% of cap");
        (,, uint256 paid) = _sell(b, _newUser(), 100);
        assertEq(paid, 100 * market, "board pays the market price");
    }

    /// @dev G-1b：报过价后运营地址 7 天没有有效报价 → 停运 → 新开局的月局暂停收购（原测试里 60 小时后付了 4 倍市价）；
    ///      恢复报价后按报价收购
    function test_G1_AbandonedFeedPausesMonthPurchases() public {
        _startGenesis();
        MonthBoard m0 = _monthBoard();
        uint256 market = _capNow() / 4;
        _postPrices(market, market); // 机器人按市价报过一次
        vm.warp(block.timestamp + 7 days); // 之后机器人宕机 7 天
        assertTrue(priceFeed.abandoned());

        if (block.timestamp >= m0.recruitDeadline()) m0.closeRecruitment();
        MonthBoard m = _monthBoard();
        _fillMonth(m);
        assertTrue(m.isPurchasing());
        assertEq(m.buyPrice(), 0, "abandoned: purchases paused");
        vm.warp(block.timestamp + 60 hours);
        assertEq(m.buyPrice(), 0, "60 hours later: still paused, not one full year of output");

        priceFeed.post(market, market); // 机器人恢复：同价报价在 5% 限幅内
        assertFalse(priceFeed.abandoned());
        assertEq(m.buyPrice(), market, "resumes at the feed price");
        (,, uint256 paid) = _sellMonth(m, _newUser(), 25);
        assertEq(paid, 25 * market);
    }

    function _capNow() internal view returns (uint256) {
        // 与主板 _liveCap 相同：每单位权重日产出 × 365，上限 3 BEM
        uint256 perDay = pod.currentRate() * 1 days * 9_900 / 10_000 / pod.totalVerifWeight();
        uint256 cap = perDay * 365;
        return cap > 3 * BEM_1 ? 3 * BEM_1 : cap;
    }
}
