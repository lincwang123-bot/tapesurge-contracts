// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthMachineSales} from "../src/month/MonthMachineSales.sol";
import {MonthFactory} from "../src/MonthFactory.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {ChainlinkVRFAdapter} from "../src/random/ChainlinkVRFAdapter.sol";
import {BoardState, SettleMode} from "../src/interfaces/ITapeBoard.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {IBeacon} from "../src/interfaces/ITapeOut.sol";
import {IBemPriceOracle} from "../src/interfaces/ISwap.sol";
import {MockVRFCoordinatorV2Plus} from "../src/mocks/MockRandom.sol";
import {TapeSurgeDefaults} from "../script/TapeSurgeDefaults.sol";
import {PrizeHarness} from "./MonthStats.t.sol";

/// @dev 第 6 条：可以切换是否接收 BNB 的地址（模拟拒收的 Safe）
contract AuditBnbRejector {
    bool public accept;

    function setAccept(bool v) external {
        accept = v;
    }

    receive() external payable {
        require(accept, "rejected");
    }
}

/// @dev 第 12 条：注册中心桩（任何地址都算主板）和一个回调总是失败的消费方
contract AuditRegistryStub {
    function isBoard(address) external pure returns (bool) {
        return true;
    }
}

contract AuditRevertingConsumer {
    ChainlinkVRFAdapter public adapter;

    function setAdapter(ChainlinkVRFAdapter a) external {
        adapter = a;
    }

    function request() external returns (uint256) {
        return adapter.requestRandomness();
    }

    function onRandomness(uint256, uint256) external pure {
        revert("consumer reverted");
    }
}

/// @notice TapeCode 对 audit-v1.2（e56f4e8）审计报告的逐条核实（2026-10-21）。
///         每个测试名以 TCxx 开头，对应报告编号；测试证明问题成立或不成立
///         "TapeCode review (2026-10-21) — responses"。
contract AuditTapeCodeTest is Fixture {
    address internal minter = address(0xA11CE);
    address internal buyer = address(0xB0B);

    function _mintTransistors(uint256 n) internal {
        vm.deal(minter, minter.balance + n * 0.0011 ether);
        vm.prank(minter);
        transistors.mint{value: n * 0.0011 ether}(0, n);
    }

    /// @dev 月局 #1：小数投入招满 → 领首批回馈（补贴资本）→ 收购两台矿机 → 进入挖矿
    function _monthMining(bool withSubsidy) internal returns (MonthBoard m, address[] memory users) {
        _startGenesis();
        m = _monthBoard();
        uint256 n;
        users = new address[](60);
        while (m.state() == MonthState.Recruiting) {
            uint256 span = m.maxStake() - m.minStake();
            uint256 amt = m.minStake() + (uint256(keccak256(abi.encode("tc", n))) % span) / 1e6 * 1e6;
            users[n++] = _joinMonth(m, amt);
        }
        assembly {
            mstore(users, n)
        }
        if (withSubsidy) {
            _mintTransistors(2_000);
            splitter.claimReward(1);
            assertGt(m.subsidyCapital(), 0);
        }
        _sellMonth(m, _newUser(), 30);
        _sellMonth(m, _newUser(), 20);
        vm.warp(m.prepEnd());
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Mining));
    }

    function _yield2(MonthBoard m, uint256 amount) internal {
        pod.addYield(m.machine(0).key, amount / 2);
        pod.addYield(m.machine(1).key, amount - amount / 2);
    }

    // =====================================================================
    // 1（高）抽奖的权重基数：不成立
    // =====================================================================

    /// @dev totalStake 只在 join 里和树的 insert 同步增加；补贴 / 滚存只进 subsidyCapital 和 budget。
    ///      所以传给 PrizeDraw.winners 的 totalStake 恒等于树里的投入总和，补贴进来也一样；中奖结果和独立按投入抽取完全一致。
    function test_TC01_PrizeBaseEqualsTreeTotalEvenWithSubsidy() public {
        (MonthBoard m,) = _monthMining(true);
        uint256 n = m.socketCount();
        uint256 sum;
        uint256[] memory w = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            w[i] = m.socket(i + 1).stake;
            sum += w[i];
        }
        assertEq(m.totalStake(), sum, "totalStake == tree total");
        assertGt(m.subsidyCapital(), 0);
        assertEq(m.budget() + m.totalSpent(), sum + m.subsidyCapital(), "subsidy only in budget");
        _yield2(m, 10 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        uint256 word = uint256(keccak256("tc01"));
        rng.fulfill(m.pendingRequestId(), word);
        m.finalizePrizes();
        uint256[5] memory expected = new PrizeHarness(w).winnersFor(word);
        for (uint256 k = 0; k < 5; k++) {
            assertEq(m.winnerSlots(k), expected[k], "same winners as an independent stake-weighted draw");
        }
    }

    // =====================================================================
    // 2（高）收回资本的顺序：不成立（就是规则本身）
    // =====================================================================

    /// @dev 一台矿机都没买到：闲置资本 = 本金 + 补贴。先退全部本金，超出本金的部分才算回收补贴，premium = 0。
    function test_TC02_IdleCapitalReturnsPrincipalFirstThenSubsidy() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        address[] memory users = _fillMonth(m);
        _mintTransistors(2_000);
        uint256 out = splitter.claimReward(1);
        uint256 principal = m.totalStake();
        vm.warp(m.prepEnd());
        vm.expectEmit(false, false, false, true, address(m));
        emit MonthBoard.CapitalReturned(principal, out, 0);
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertEq(m.principalRemaining(), 0);
        assertEq(m.subsidyRemaining(), 0);
        assertEq(m.rolledOver(), out, "exactly the subsidy rolls over");
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(_mOwed(m, users[i]), m.socket(i + 1).stake, "principal returned exactly");
        }
    }

    /// @dev 闲置资本小于本金时全部算退还本金，补贴等矿机卖出、本金退完之后才回收
    function test_TC02_IdleBelowPrincipalIsAllPrincipal() public {
        (MonthBoard m,) = _monthMining(true);
        uint256 idle = m.budget();
        assertLt(idle, m.totalStake());
        vm.warp(m.miningEnd());
        vm.expectEmit(false, false, false, true, address(m));
        emit MonthBoard.CapitalReturned(idle, 0, 0);
        m.drawPrizes(); // 奖金池为 0：直接结算
        assertEq(m.principalRemaining(), m.totalStake() - idle);
        assertEq(m.subsidyRemaining(), m.subsidyCapital(), "subsidy not touched before principal is back");
    }

    // =====================================================================
    // 3（中）挂单反复改价：不成立
    // =====================================================================

    /// @dev 第 8 阶段（规则决定 6.17 / 6.18）：不再挂单，整台卖价 = max(收购时权重 × 公式价, 成本价)；买家用 maxPrice 防止
    ///      价格变化；报价过期暂停卖出，停运 7 天后按成本价可买
    function test_TC03_FormulaPriceNeverBelowCostAndBuyerCapped() public {
        (MonthBoard m,) = _monthMining(false);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        uint256 cost = m.machine(0).cost;
        uint256 w = m.machine(0).weight;
        assertEq(sales.askPrice(address(m), 0), cost, "never posted: at cost");
        uint256 unit = cost * 3 / w;
        _postPrices(unit, unit);
        assertEq(sales.askPrice(address(m), 0), unit * w, "market above cost");
        bem.mint(buyer, 1_000 * BEM_1);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        vm.expectRevert(MonthMachineSales.PriceAboveMaximum.selector);
        sales.buyMachine(address(m), 0, cost * 2);
        vm.stopPrank();
        vm.warp(block.timestamp + 3 hours);
        _postPrices(cost / w / 2, cost / w / 2); // 过期后第一次报价不限幅度
        assertEq(sales.askPrice(address(m), 0), cost, "market below cost: floored at cost");
        vm.warp(block.timestamp + 3 hours);
        assertEq(sales.askPrice(address(m), 0), 0, "stale: paused");
        vm.warp(priceFeed.updatedAt() + 7 days);
        assertEq(sales.askPrice(address(m), 0), cost, "abandoned 7 days: at cost");
    }

    // =====================================================================
    // 4（中）哨兵触发后提前结算能否跳过已交付的开奖：不成立
    // =====================================================================

    function test_TC04_EmergencySettleCannotSkipADeliveredDraw() public {
        (MonthBoard m, address[] memory users) = _monthMining(false);
        _yield2(m, 10 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), 42);
        assertTrue(m.wordReceived());
        machineBeacon.upgradeTo(address(0xBAD));
        vm.prank(users[0]);
        vm.expectRevert(MonthBoard.WrongState.selector);
        m.emergencySettle(); // 只允许 Preparing / 挖矿未到期
        m.finalizePrizes(); // 开奖照常
        assertTrue(m.prizesDrawn());
    }

    // =====================================================================
    // 5（中）异常结局 priorityStake = 0 除零：不成立
    // =====================================================================

    /// @dev 异常结局时 priorityStake = priorityRemaining = aliveStake ≥ 硅王候选的投入 > 0；
    ///      优先部分填满后 priorityRemaining = 0，之后的到账不再走除以 priorityStake 的分支
    function test_TC05_AbnormalEndAllocationNeverDividesByZero() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        _sell(b, _newUser(), 200);
        vm.warp(b.startedAt() + 730 days);
        b.expire();
        assertEq(uint256(b.settleMode()), uint256(SettleMode.Fallback));
        assertGt(b.priorityStake(), 0);
        _yield(b, 0, 2_000 * BEM_1); // 远超未出局者本金
        b.harvest();
        assertEq(b.priorityRemaining(), 0, "priority filled");
        _yield(b, 0, 7 * BEM_1);
        b.harvest(); // 之后的到账全部按比例分，不 revert
        b.sweep();
        assertGt(b.accProRata(), 0);
    }

    // =====================================================================
    // 6（中）分账记账和余额：不成立
    // =====================================================================

    /// @dev withdraw 失败时收入留在晶体管合约，不计入 fresh；拒收记账、回购、withdrawOwed 前后
    ///      分账合约余额始终等于 buybackPool + 各桶 + totalOwedBnb
    function test_TC06_SplitterBalanceAlwaysEqualsAccounted() public {
        AuditBnbRejector rejector = new AuditBnbRejector();
        TapeSurgeDefaults.Addresses memory a = defaultAddresses();
        a.foundation = address(rejector);
        _deploySystem(defaultParams(), defaultMonthParams(), TapeSurgeDefaults.splitterParams(a));
        assertEq(splitter.distribute(), 0, "withdraw fails (nothing owed): no fresh revenue");
        _assertSplitterBooks();
        _mintTransistors(1_000);
        splitter.distribute();
        assertEq(splitter.totalOwedBnb(), 0.2 ether);
        _assertSplitterBooks();
        splitter.buyback();
        _assertSplitterBooks();
        vm.expectRevert(GenesisSplitter.TransferFailed.selector);
        splitter.withdrawOwed(address(rejector)); // 失败整笔回滚，记账不变
        _assertSplitterBooks();
        rejector.setAccept(true);
        splitter.withdrawOwed(address(rejector));
        _assertSplitterBooks();
        assertEq(splitter.distribute(), 0, "no double counting");
    }

    function _assertSplitterBooks() internal view {
        uint256 acc = splitter.buybackPool() + splitter.totalOwedBnb();
        for (uint256 i = 1; i <= 5; i++) {
            acc += splitter.rewardBucket(i);
        }
        assertEq(address(splitter).balance, acc, "balance == accounted");
    }

    // =====================================================================
    // 7（中）noteSentinel 读取失败会 revert：不成立
    // =====================================================================

    /// @dev 信标读取已经用 staticcall 兜住：读不出来按触发处理、指纹记为 address(1)，noteSentinel 照常登记
    function test_TC07_NoteSentinelSurvivesUnreadableBeacon() public {
        TapeBoard b = _startGenesis();
        vm.mockCallRevert(address(machineBeacon), abi.encodeWithSelector(IBeacon.implementation.selector), "");
        assertTrue(b.sentinelTripped());
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), block.timestamp, "recorded although the beacon reverts");
        assertTrue(b.sentinelPaused());
        assertTrue(_monthBoard().sentinelPaused());
    }

    // =====================================================================
    // 8（中）aliveCount = 1 时的随机数回调除零：不成立
    // =====================================================================

    /// @dev drawPending 只在 aliveCount ≥ 2 时置位，回调先把它清掉再出局；硅王产生后 drawPending = false，
    ///      任何残留回调都在入口被当作过期请求忽略
    function test_TC08_StaleCallbackAfterKingIsIgnored() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 25, 20 * BEM_1);
        _sell(b, _newUser(), 200);
        uint256 i;
        while (b.aliveCount() > 2) {
            _topUpPool(b);
            _pulseAndFulfill(b, uint256(keccak256(abi.encode("tc08", i++))));
        }
        _topUpPool(b);
        b.pulse();
        uint256 oldId = b.pendingRequestId();
        vm.warp(block.timestamp + 1 days);
        b.retryDraw();
        uint256 newId = b.pendingRequestId();
        rng.fulfill(newId, 7);
        assertEq(b.aliveCount(), 1, "king crowned");
        vm.expectEmit(true, false, false, false, address(b));
        emit TapeBoard.StaleRandomness(oldId);
        rng.fulfill(oldId, 8); // 残留的旧请求：忽略，不 revert
        rng.fulfill(newId, 9); // 重复回调：忽略
        assertEq(b.aliveCount(), 1);
    }

    // =====================================================================
    // 9（中）随机数到账后卡在 Drawing / 停摆保底冲突：不成立
    // =====================================================================

    function test_TC09_DeliveredWordCannotBeSafeSettledAndParticipantsCanFinalize() public {
        (MonthBoard m, address[] memory users) = _monthMining(false);
        _yield2(m, 10 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), 77);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(MonthBoard.NoPendingDraw.selector);
        m.triggerSafeSettle(); // 只在随机数还没到时有效
        vm.expectRevert(MonthBoard.NoPendingDraw.selector);
        m.retryDraw();
        vm.prank(users[0]);
        m.finalizePrizes(); // 运营地址 3 天不执行，参与者兜底开奖
        assertTrue(m.prizesDrawn());
    }

    // =====================================================================
    // 10（中）交接成本价：不成立
    // =====================================================================

    /// @dev v2（项目方 2026-10-22）：旧月局在新月局的收购拍卖里当普通卖家，按新局当前收购价成交，最低单价
    ///      ⌈成本价 ÷ 算力⌉，所以成交额不低于成本价；新局记录的成本价 = 实际付款。只能交接给同一工厂的月局。
    function test_TC10_RelayAtReceiverBuyPriceNeverBelowCost() public {
        (MonthBoard m,) = _monthMining(false);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        vm.expectRevert(MonthBoard.NotMonthBoard.selector);
        sales.relay(address(m), 0, address(0xE111));
        MonthBoard r = _monthBoard();
        if (block.timestamp >= r.recruitDeadline()) {
            r.closeRecruitment();
            r = _monthBoard();
        }
        _fillMonth(r);
        uint256 cost = m.machine(0).cost;
        uint256 paid = _relayWhenPriced(m, 0, r);
        assertGe(paid, cost, "never below cost");
        assertEq(r.machine(0).cost, paid, "receiver cost basis = price it paid");
    }

    // =====================================================================
    // 11 / 17（中 / 低）TWAP 读不出来时兑换暂停：不成立（设计如此）
    // =====================================================================

    /// @dev 预言机 revert 时回购 / 领回馈整笔回滚、资金不动，分账照常；恢复后照常兑换
    function test_TC11_UnavailableTwapPausesSwapsWithoutLoss() public {
        _mintTransistors(1_000);
        splitter.distribute();
        uint256 pool0 = splitter.buybackPool();
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(IBemPriceOracle.quoteBemOut.selector), "OLD");
        vm.expectRevert(bytes("OLD"));
        splitter.buyback();
        assertEq(splitter.buybackPool(), pool0, "nothing spent");
        _mintTransistors(1_000);
        assertGt(splitter.distribute(), 0, "distribution does not need the oracle");
        vm.clearMockedCalls();
        assertGt(splitter.buyback(), 0);
    }

    // =====================================================================
    // 12（中）VRF 适配器吞掉消费方 revert：不成立
    // =====================================================================

    /// @dev 协调器的回调不能失败（Chainlink 不会重发），适配器吞掉主板回调的 revert 并记 success = false；
    ///      同一个请求再回调直接返回。主板侧靠 retryDraw（24 小时）重新请求
    function test_TC12_AdapterSwallowsConsumerRevert() public {
        MockVRFCoordinatorV2Plus coord = new MockVRFCoordinatorV2Plus();
        AuditRegistryStub reg = new AuditRegistryStub();
        ChainlinkVRFAdapter adapter =
            new ChainlinkVRFAdapter(address(coord), bytes32(0), 1, 3, 750_000, true, address(reg));
        AuditRevertingConsumer c = new AuditRevertingConsumer();
        c.setAdapter(adapter);
        uint256 id = c.request();
        vm.expectEmit(true, true, false, true, address(adapter));
        emit ChainlinkVRFAdapter.RandomnessDelivered(id, address(c), false);
        coord.fulfill(id, 1); // 不 revert
        assertEq(adapter.consumerOf(id), address(0));
        coord.fulfill(id, 2); // 已处理：直接返回
    }

    // =====================================================================
    // 13（低）distribute 的 fromSlot + count 溢出：不成立（只影响那一笔调用）
    // =====================================================================

    function test_TC13_HugeDistributeCountOnlyRevertsThatCall() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        address[] memory users = _fillMonth(m);
        vm.warp(m.prepEnd());
        m.sync();
        // v2：分批推送移到 MonthMachineSales，count 先截到插槽数，超大的 count 也不会溢出
        sales.distribute(address(m), 1, type(uint256).max);
        sales.distribute(address(m), type(uint256).max, type(uint256).max); // 起点超出范围：什么都不做
        sales.distribute(address(m), 1, 1_000_000); // 正常的批量参数照常工作
        assertEq(_mOwed(m, users[0]), 0);
    }

    // =====================================================================
    // 15（低）createCPU 的 deployFee 不足：不成立（部署失败即止，脚本按链上 deployFee 付款）
    // =====================================================================

    function test_TC15_SplitterWithoutDeployFeeFailsSafely() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.boardFactory = address(0xFAC7);
        uint256 fee = tapeout.deployFee();
        vm.expectRevert();
        new GenesisSplitter{value: fee - 1}(sp);
        GenesisSplitter ok = new GenesisSplitter{value: fee}(sp);
        assertEq(ok.boardFactory(), address(0xFAC7));
    }

    // =====================================================================
    // 16（低）月局工厂把全部余额当滚存：不成立
    // =====================================================================

    /// @dev 工厂收到的 BEM 只有两种来源：月局退回的回馈资本，和别人直接转进来的。后者并入下一块开局的月局的回馈资本，
    ///      最终同样按"本金 → 回馈 → 超额"处理，不会丢，也不会卡在工厂里
    function test_TC16_DonationToFactoryBecomesNextBoardsSubsidyCapital() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        bem.mint(address(monthFactory), 3 * BEM_1);
        _fillMonth(m);
        assertEq(m.subsidyCapital(), 3 * BEM_1);
        assertEq(m.budget(), m.totalStake() + 3 * BEM_1);
        assertEq(bem.balanceOf(address(monthFactory)), 0);
    }

    // =====================================================================
    // 18（低）克隆初始化：不成立
    // =====================================================================

    function test_TC18_ClonesAreFreshAndImplementationsCannotBeInitialized() public {
        TapeBoard b = _startGenesis();
        TapeBoard impl = TapeBoard(factory.boardImplementation());
        vm.expectRevert(TapeBoard.OnlyFactory.selector);
        impl.initialize(1, 500 * BEM_1, BEM_1, 20 * BEM_1);
        vm.prank(address(factory));
        vm.expectRevert(TapeBoard.AlreadyInitialized.selector);
        b.initialize(1, 500 * BEM_1, BEM_1, 20 * BEM_1);
        MonthBoard mImpl = MonthBoard(monthFactory.boardImplementation());
        vm.expectRevert(MonthBoard.OnlyFactory.selector);
        mImpl.initialize(1, 100 * BEM_1, 0.2e8, 4 * BEM_1);
    }

    // =====================================================================
    // 19（低）owed 和实际可领不一致：不成立
    // =====================================================================

    /// @dev 结算前 accShare = 0、credit 从不记账，所以 owed = 0，withdraw 也领不到；结算后 withdraw 先 sweep，
    ///      owed 不含尚未 sweep 的新到账（只会少报，不会多报）
    function test_TC19_OwedNeverExceedsWithdrawable() public {
        (MonthBoard m, address[] memory users) = _monthMining(false);
        address u = users[0];
        assertEq(_mOwed(m, u), 0, "mining: nothing claimable");
        uint256 sl_ = _slot(m, u);
        vm.expectRevert(MonthBoard.NothingToWithdraw.selector);
        m.withdraw(sl_);
        _yield2(m, 10 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        assertEq(_mOwed(m, u), 0, "drawing: nothing claimable");
        rng.fulfill(m.pendingRequestId(), 5);
        m.finalizePrizes();
        uint256 shown = _mOwed(m, u);
        _yield2(m, 4 * BEM_1); // 结算阶段的新产出（还没 sweep）
        m.harvest();
        uint256 before = bem.balanceOf(u);
        uint256 got = _mWithdraw(m, u);
        assertEq(bem.balanceOf(u) - before, got);
        assertGe(got, shown, "owed never over-reports");
    }
}
