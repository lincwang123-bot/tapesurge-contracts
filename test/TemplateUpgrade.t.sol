// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TapeSurgeDefaults} from "../script/TapeSurgeDefaults.sol";
import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {TemplateTimelock} from "../src/TemplateTimelock.sol";
import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";

/// @title 主板模板切换（7 天时间锁，只影响之后新开的局，规则决定 6.11 / 6.12）
contract TemplateUpgradeTest is Fixture {
    address internal constant NEW_FOUNDATION = address(0xF0F0);

    function setUp() public override {
        super.setUp();
        _startGenesis();
    }

    /// @dev 新的标准局模板：基金会地址换成 NEW_FOUNDATION（便于从外部区分新旧模板）
    function _stdCode() internal view returns (bytes memory) {
        TapeBoard.Config memory c = factory.boardConfig();
        c.foundation = NEW_FOUNDATION;
        return abi.encodePacked(type(TapeBoard).creationCode, abi.encode(c));
    }

    /// @dev 新的月局模板：换一个新的报价单例（不同参数），演示"新局绑定新单例、旧局继续用旧的"
    function _monthCode(address feed) internal view returns (bytes memory) {
        MonthBoard.Config memory c = monthFactory.boardConfig();
        c.priceFeed = feed;
        return abi.encodePacked(type(MonthBoard).creationCode, abi.encode(c));
    }

    function _newFeed() internal returns (MarketPriceFeed) {
        MarketPriceFeed.Params memory p = TapeSurgeDefaults.feedParams(7 days);
        p.buyStepBps = 100; // 新报价单例：收购价每小时加 1%（演示新模板绑定不同参数的单例）
        return new MarketPriceFeed(address(factory), p);
    }

    // ---------------- 权限与时间锁 ----------------

    function test_AdminIsFeeSafeForBothFactories() public view {
        assertEq(factory.admin(), FEE_SAFE);
        assertEq(monthFactory.admin(), FEE_SAFE);
        assertEq(factory.implementationCount(), 1);
        assertEq(factory.implementationHistory(0), factory.boardImplementation());
        assertEq(monthFactory.implementationHistory(0), monthFactory.boardImplementation());
    }

    function test_OnlyAdminProposesAndCancels() public {
        bytes memory code = _stdCode();
        vm.expectRevert(TemplateTimelock.OnlyAdmin.selector);
        factory.proposeImplementation(code);
        vm.prank(FEE_SAFE);
        factory.proposeImplementation(code);
        vm.expectRevert(TemplateTimelock.OnlyAdmin.selector);
        factory.cancelImplementation();
        bytes memory mcode = _monthCode(address(priceFeed));
        vm.expectRevert(TemplateTimelock.OnlyAdmin.selector);
        monthFactory.proposeImplementation(mcode);
    }

    function test_ProposeCancelActivateExpire() public {
        address old = factory.boardImplementation();
        bytes memory code = _stdCode();
        vm.prank(FEE_SAFE);
        address impl = factory.proposeImplementation(code);
        assertEq(factory.pendingImplementation(), impl);
        assertEq(factory.pendingEta(), block.timestamp + 7 days);
        assertEq(TapeBoard(impl).FACTORY(), address(factory), "deployed by the factory itself");
        assertEq(TapeBoard(impl).FOUNDATION(), NEW_FOUNDATION);

        // 公示期内撤销
        vm.prank(FEE_SAFE);
        factory.cancelImplementation();
        assertEq(factory.pendingImplementation(), address(0));
        vm.expectRevert(TemplateTimelock.NoPendingImplementation.selector);
        factory.activateImplementation();
        vm.prank(FEE_SAFE);
        vm.expectRevert(TemplateTimelock.NoPendingImplementation.selector);
        factory.cancelImplementation();

        // 重新提议：7 天内不能生效
        vm.prank(FEE_SAFE);
        impl = factory.proposeImplementation(code);
        uint256 eta = factory.pendingEta();
        vm.warp(eta - 1);
        vm.expectRevert(TemplateTimelock.TooEarly.selector);
        factory.activateImplementation();
        // 公示期满后 7 天内没人生效：过期作废
        vm.warp(eta + 7 days);
        vm.expectRevert(TemplateTimelock.ProposalExpired.selector);
        factory.activateImplementation();
        assertEq(factory.boardImplementation(), old);

        // 再提议一次，任何人在窗口内生效
        vm.prank(FEE_SAFE);
        impl = factory.proposeImplementation(code);
        vm.warp(factory.pendingEta());
        vm.prank(address(0xA11CE));
        factory.activateImplementation();
        assertEq(factory.boardImplementation(), impl);
        assertEq(factory.implementationCount(), 2);
        assertEq(factory.implementationHistory(1), impl);
        assertEq(factory.pendingImplementation(), address(0));
    }

    function test_NewProposalReplacesPending() public {
        bytes memory code = _stdCode();
        vm.startPrank(FEE_SAFE);
        address a = factory.proposeImplementation(code);
        vm.warp(block.timestamp + 3 days);
        address b = factory.proposeImplementation(code);
        vm.stopPrank();
        assertTrue(a != b);
        assertEq(factory.pendingImplementation(), b);
        assertEq(factory.pendingEta(), block.timestamp + 7 days, "clock restarts");
    }

    function test_BadTemplatesRejected() public {
        // 标准局：分账合约不对
        TapeBoard.Config memory c = factory.boardConfig();
        c.splitter = address(0xBAD);
        MonthBoard.Config memory mc = monthFactory.boardConfig();
        mc.hub = address(0xBAD);
        vm.startPrank(FEE_SAFE);
        vm.expectRevert(TemplateTimelock.BadTemplate.selector);
        factory.proposeImplementation(abi.encodePacked(type(TapeBoard).creationCode, abi.encode(c)));
        // 构造失败
        vm.expectRevert(TemplateTimelock.DeployFailed.selector);
        factory.proposeImplementation(hex"60006000fd"); // 构造时 revert
        // 月局：注册中心不对
        vm.expectRevert(TemplateTimelock.BadTemplate.selector);
        monthFactory.proposeImplementation(abi.encodePacked(type(MonthBoard).creationCode, abi.encode(mc)));
        vm.stopPrank();
    }

    // ---------------- 只影响新开的局 ----------------

    /// @dev 标准局：切换前开出的（正在招募的）主板仍用旧模板；它开局后开出的下一块用新模板
    function test_StandardOnlyNewBoardsUseNewTemplate() public {
        address old = factory.boardImplementation();
        bytes memory code = _stdCode();
        vm.prank(FEE_SAFE);
        address impl = factory.proposeImplementation(code);
        vm.warp(factory.pendingEta());
        // 公示期里第 1 块招募到期：关闭后工厂按旧模板重开同一编号
        _board().closeRecruitment();
        TapeBoard b1 = _board();
        assertEq(factory.implementationOf(address(b1)), old);
        factory.activateImplementation();
        // 生效时正在招募的 b1 仍是旧模板，规则不变
        assertEq(factory.implementationOf(address(b1)), old);
        assertEq(b1.FOUNDATION(), FOUNDATION);
        _fillUniform(b1, 50, b1.target() / 50);
        assertEq(uint256(b1.state()), uint256(BoardState.Active));
        TapeBoard b2 = _board();
        assertTrue(address(b2) != address(b1));
        assertEq(factory.implementationOf(address(b2)), impl);
        assertEq(b2.FOUNDATION(), NEW_FOUNDATION, "next board runs the new template");
        assertTrue(factory.isBoard(address(b2)));
        assertEq(b1.FOUNDATION(), FOUNDATION, "started board unchanged");
    }

    /// @dev 月局：新模板绑定新的报价单例，旧局继续用旧单例；持仓凭证共用，编号按主板地址区分
    function test_MonthOnlyNewBoardsUseNewTemplate() public {
        address old = monthFactory.boardImplementation();
        MarketPriceFeed feed2 = _newFeed();
        bytes memory code = _monthCode(address(feed2));
        vm.prank(FEE_SAFE);
        address impl = monthFactory.proposeImplementation(code);
        assertEq(MonthBoard(impl).PRICE_FEED(), address(feed2));
        vm.warp(monthFactory.pendingEta());
        _monthBoard().closeRecruitment(); // 到期关闭，按旧模板重开
        MonthBoard m1 = _monthBoard();
        monthFactory.activateImplementation();
        assertEq(monthFactory.implementationOf(address(m1)), old);
        assertEq(m1.PRICE_FEED(), address(priceFeed));
        _fillMonth(m1);
        assertEq(uint256(m1.state()), uint256(MonthState.Preparing));
        MonthBoard m2 = _monthBoard();
        assertEq(monthFactory.implementationOf(address(m2)), impl);
        assertEq(m2.PRICE_FEED(), address(feed2), "new board binds the new singleton");
        assertEq(m1.PRICE_FEED(), address(priceFeed), "old board keeps the old singleton");
        assertEq(m2.POSITIONS(), m1.POSITIONS(), "position collection shared");
        // 新旧局都能照常加入 / 运行
        _joinMonth(m2, m2.maxStake());
        assertEq(positions.ownerOf(positions.idOf(address(m2), 1)), m2.socket(1).owner);
        assertEq(positions.ownerOf(positions.idOf(address(m1), 1)), m1.socket(1).owner);
    }
}
