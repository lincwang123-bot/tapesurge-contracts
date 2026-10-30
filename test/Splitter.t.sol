// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";
import {TapeSurgeDefaults} from "../script/TapeSurgeDefaults.sol";

/// @notice 铸造收入分账：40 / 10 / 20 / 30 与回馈桶 10 : 8 : 5 : 4 : 3、回购、领取回馈
contract SplitterTest is Fixture {
    address internal minter = address(0xA11CE);

    /// @dev 有人铸造 n 颗创世晶体管：每颗 0.001 BNB 归 creator（分账合约）
    function _mintTransistors(uint256 n) internal {
        vm.deal(minter, minter.balance + n * 0.0011 ether);
        vm.prank(minter);
        transistors.mint{value: n * 0.0011 ether}(0, n);
    }

    function test_SplitterIsCreatorOfGenesisProcessor() public view {
        assertEq(transistors.creator(), address(splitter));
        assertEq(splitter.circuits(), address(passCircuits));
        assertEq(splitter.boardFactory(), address(factory));
        assertEq(transistors.supplyCap(), 66_666);
        assertEq(transistors.mintPrice(), 0.001 ether);
        assertEq(splitter.mintStart(), START_TIME);
    }

    function test_DistributeSplits40_10_20_30() public {
        _mintTransistors(1_000); // 1 BNB 铸造收入
        uint256 f0 = FOUNDATION.balance;
        uint256 p0 = FEE_SAFE.balance;
        uint256 fresh = splitter.distribute();
        assertEq(fresh, 1 ether);
        assertEq(FOUNDATION.balance - f0, 0.2 ether);
        assertEq(FEE_SAFE.balance - p0, 0.1 ether);
        assertEq(splitter.buybackPool(), 0.4 ether);
        assertEq(splitter.rewardBucket(1), 0.1 ether);
        assertEq(splitter.rewardBucket(2), 0.08 ether);
        assertEq(splitter.rewardBucket(3), 0.05 ether);
        assertEq(splitter.rewardBucket(4), 0.04 ether);
        assertEq(splitter.rewardBucket(5), 0.03 ether);
        assertEq(address(splitter).balance, 0.7 ether);
        // 再调一次没有新收入
        assertEq(splitter.distribute(), 0);
    }

    function test_DistributeAlternativeSplit50_0_20_30() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.buybackBps = 5_000;
        sp.projectBps = 0;
        _deploySystem(defaultParams(), defaultMonthParams(), sp);
        _mintTransistors(1_000);
        uint256 p0 = FEE_SAFE.balance;
        splitter.distribute();
        assertEq(splitter.buybackPool(), 0.5 ether);
        assertEq(FEE_SAFE.balance, p0);
        assertEq(splitter.rewardBucket(1), 0.1 ether);
    }

    function test_RevertWhen_SplitDoesNotSumTo100Percent() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.boardFactory = address(0xFAC7);
        sp.buybackBps = 4_100;
        vm.expectRevert(GenesisSplitter.BadParams.selector);
        new GenesisSplitter{value: 0.001 ether}(sp);
    }

    function test_RevertWhen_SwapPathDoesNotEndInBem() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.boardFactory = address(0xFAC7);
        sp.swapPath = abi.encodePacked(WBNB, uint24(500), USDT);
        vm.expectRevert(GenesisSplitter.BadParams.selector);
        new GenesisSplitter{value: 0.001 ether}(sp);
    }

    function test_RevertWhen_SplitterWithoutBoardFactory() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        vm.expectRevert(GenesisSplitter.BadParams.selector);
        new GenesisSplitter{value: 0.001 ether}(sp);
    }

    // ---------------- 审计 #7：Safe 拒收 BNB 时改为记账，不卡住分账 ----------------

    function test_RejectedBnbIsOwedAndDoesNotBlock() public {
        BnbRejector rejector = new BnbRejector();
        TapeSurgeDefaults.Addresses memory a = defaultAddresses();
        a.foundation = address(rejector);
        GenesisSplitter.Params memory sp = TapeSurgeDefaults.splitterParams(a);
        _deploySystem(defaultParams(), defaultMonthParams(), sp);
        _mintTransistors(1_000); // 1 BNB 铸造收入
        uint256 project0 = FEE_SAFE.balance;
        splitter.distribute(); // 基金会拒收，不 revert
        assertEq(splitter.owedBnb(address(rejector)), 0.2 ether);
        assertEq(splitter.totalOwedBnb(), 0.2 ether);
        assertEq(FEE_SAFE.balance - project0, 0.1 ether, "project still paid");
        assertEq(splitter.buybackPool(), 0.4 ether);
        assertEq(splitter.distribute(), 0, "owed BNB is not counted as new revenue");
        // 回购照常
        vm.warp(block.timestamp + 1 hours);
        splitter.buyback();
        // 对方仍然拒收：withdrawOwed revert，记账不变
        vm.expectRevert(GenesisSplitter.TransferFailed.selector);
        splitter.withdrawOwed(address(rejector));
        rejector.setAccept(true);
        assertEq(splitter.withdrawOwed(address(rejector)), 0.2 ether);
        assertEq(address(rejector).balance, 0.2 ether);
        assertEq(splitter.totalOwedBnb(), 0);
        vm.expectRevert(GenesisSplitter.NothingToSwap.selector);
        splitter.withdrawOwed(address(rejector));
    }

    function test_DirectBnbCountsAsRevenue() public {
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(splitter.distribute(), 1 ether);
    }

    function test_BuybackRespectsCapIntervalAndBurnsToDead() public {
        _mintTransistors(10_000); // 10 BNB，回购池 4 BNB
        uint256 out = splitter.buyback();
        assertEq(splitter.buybackPool(), 3.5 ether);
        assertEq(out, BEM_PER_BNB / 2); // 每次最多 0.5 BNB
        assertEq(bem.balanceOf(DEAD), out);
        assertEq(splitter.totalBemBurned(), out);
        assertEq(router.lastPath(), swapPath()); // 走 WBNB → USDT → BEM
        vm.expectRevert(GenesisSplitter.TooSoon.selector);
        splitter.buyback();
        vm.warp(block.timestamp + 1 hours);
        splitter.buyback();
        assertEq(bem.balanceOf(DEAD), 2 * out);
    }

    function test_BuybackMinOutFromTwap() public {
        _mintTransistors(1_000);
        assertEq(splitter.minOutFor(1 ether), BEM_PER_BNB * 9_800 / 10_000);
        // 成交价比参考价差 2.5%（超过主网 2% 滑点上限，外部审计 #6）：拒绝成交
        router.setRate(BEM_PER_BNB * 9_750 / 10_000);
        vm.expectRevert(bytes("Too little received"));
        splitter.buyback();
        // 差 1.5%：可以成交
        router.setRate(BEM_PER_BNB * 9_850 / 10_000);
        splitter.buyback();
        assertEq(splitter.buybackPool(), 0);
    }

    function test_BuybackCallerMinOutRespected() public {
        _mintTransistors(1_000);
        vm.expectRevert(bytes("Too little received"));
        splitter.buyback(BEM_PER_BNB);
    }

    function test_RevertWhen_NothingToBuyBack() public {
        vm.expectRevert(GenesisSplitter.NothingToSwap.selector);
        splitter.buyback();
    }

    function test_ClaimRewardBecomesBoardSubsidy() public {
        _mintTransistors(1_000);
        TapeBoard b = _startGenesis(); // 开局时先分账一次：桶 1 = 0.1 BNB
        assertEq(splitter.rewardBucket(1), 0.1 ether);
        vm.expectRevert(GenesisSplitter.BoardNotActive.selector);
        splitter.claimReward(1); // 还在招募
        _fillUniform(b, 25, 20 * BEM_1);
        vm.warp(block.timestamp + 7 days); // 首轮收购结束
        assertFalse(b.isPurchasing());
        // 参与者铸通行证也带来了铸造收入（25 张 × 0.005 BNB），先分账再看桶 1
        splitter.distribute();
        uint256 bucket = splitter.rewardBucket(1);
        assertEq(bucket, 0.1 ether + 0.125 ether * 1_000 / 10_000);

        uint256 out = splitter.claimReward(1);
        assertEq(out, bucket * BEM_PER_BNB / 1e18);
        assertEq(b.totalSubsidy(), out);
        assertEq(b.budget(), 500 * BEM_1 + out);
        assertEq(splitter.rewardBucket(1), 0);
        assertEq(splitter.totalRewardBem(1), out);
        // 补贴到账开启新一轮收购
        assertTrue(b.isPurchasing());
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(GenesisSplitter.NothingToSwap.selector);
        splitter.claimReward(1); // 桶已经领空

        // 之后有新的铸造收入，可以再次领取（同一用途要间隔 1 小时）
        _mintTransistors(1_000);
        uint256 out2 = splitter.claimReward(1);
        assertEq(out2, 0.1 ether * BEM_PER_BNB / 1e18);
        assertEq(b.totalSubsidy(), out + out2);
        _mintTransistors(1_000);
        vm.expectRevert(GenesisSplitter.TooSoon.selector);
        splitter.claimReward(1);
    }

    function test_RevertWhen_BadBucketOrNoBoard() public {
        vm.expectRevert(GenesisSplitter.BadBucket.selector);
        splitter.claimReward(0);
        vm.expectRevert(GenesisSplitter.BadBucket.selector);
        splitter.claimReward(6);
        vm.expectRevert(GenesisSplitter.BoardNotActive.selector);
        splitter.claimReward(2);
    }

    function test_EndedBoardShareGoesToBuyback() public {
        _mintTransistors(1_000);
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        // 第 1 块主板首轮收购一台没买到，进入保底 = 已结束
        splitter.distribute(); // 先把参与者铸通行证的收入分掉
        uint256 oldBucket1 = splitter.rewardBucket(1);
        uint256 oldBucket2 = splitter.rewardBucket(2);
        vm.warp(block.timestamp + 7 days);
        b.expire();
        assertTrue(splitter.boardEnded(1));
        _mintTransistors(1_000);
        uint256 poolBefore = splitter.buybackPool();
        splitter.distribute();
        // 桶 1 的旧余额 + 新收入 1 BNB 的 40% + 10%（桶 1 的份额）都进回购池
        assertEq(splitter.rewardBucket(1), 0);
        assertEq(splitter.buybackPool() - poolBefore, oldBucket1 + 0.4 ether + 0.1 ether);
        assertEq(splitter.rewardBucket(2), oldBucket2 + 0.08 ether);
    }

    function test_WithdrawFailureDoesNotBlockDistribution() public {
        // 没有可提取的收入时 withdraw 会 revert，分账照常
        vm.expectEmit(false, false, false, false, address(splitter));
        emit GenesisSplitter.WithdrawFailed("");
        assertEq(splitter.distribute(), 0);
    }
}

/// @dev 测试用：可以切换是否接收 BNB 的地址（模拟拒收的 Safe）
contract BnbRejector {
    bool public accept;

    function setAccept(bool v) external {
        accept = v;
    }

    receive() external payable {
        require(accept, "rejected");
    }
}
