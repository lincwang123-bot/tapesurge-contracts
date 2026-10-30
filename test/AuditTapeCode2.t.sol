// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixture} from "./utils/Fixture.sol";
import {TreeHarness} from "./utils/TreeHarness.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {MonthMachineSales} from "../src/month/MonthMachineSales.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";
import {PrizeHarness} from "./MonthStats.t.sol";

/// @dev B1：任何调用都 revert 的合约（模拟"拒收"的接收方；ERC-20 转账不会调用接收方，所以它照样能收到）
contract T2RejectEverything {
    fallback() external payable {
        revert("no");
    }
}

/// @notice TapeCode 第二轮（审 audit-v1.3.x）新条目的逐条核实（2026-10-21）。测试名以 T2 + 报告编号开头，
///         和第一轮重复的条目不在这里重做。
contract AuditTapeCode2Test is Fixture {
    address internal constant BSC_BEM = 0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a;
    address internal buyer = address(0xB0B);
    address internal minter = address(0xA11CE);

    function _mintTransistors(uint256 n) internal {
        vm.deal(minter, minter.balance + n * 0.0011 ether);
        vm.prank(minter);
        transistors.mint{value: n * 0.0011 ether}(0, n);
    }

    /// @dev 月局 #1：小数投入招满 → 收购三台矿机 → 进入挖矿
    function _monthMining() internal returns (MonthBoard m, address[] memory users) {
        _startGenesis();
        m = _monthBoard();
        uint256 n;
        users = new address[](60);
        while (m.state() == MonthState.Recruiting) {
            uint256 span = m.maxStake() - m.minStake();
            uint256 amt = m.minStake() + (uint256(keccak256(abi.encode("t2", n))) % span) / 1e6 * 1e6;
            users[n++] = _joinMonth(m, amt);
        }
        assembly {
            mstore(users, n)
        }
        _sellMonth(m, _newUser(), 30);
        _sellMonth(m, _newUser(), 20);
        _sellMonth(m, _newUser(), 40);
        vm.warp(m.prepEnd());
        m.sync();
    }

    function _yieldAll(MonthBoard m, uint256 amount) internal {
        uint256 n = m.machineCount();
        for (uint256 i = 0; i < n; i++) {
            if (!m.machine(i).sold) pod.addYield(m.machine(i).key, amount / n);
        }
    }

    function _settled() internal returns (MonthBoard m, address[] memory users) {
        (m, users) = _monthMining();
        _yieldAll(m, 9 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), uint256(keccak256("t2 prizes")));
        m.finalizePrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
    }

    // =====================================================================
    // B1（严重）中奖者拒收卡住开奖：不成立（BSC 主网 BEM 实测）
    // =====================================================================

    /// @dev 主网分叉：BEM 是标准的 OpenZeppelin v5 ERC-20（2,205 字节，非代理；可执行代码里没有外部调用，没有 owner /
    ///      pause / 黑名单 / 手续费；只有 minter = PoD 能 mint）。接收方无法拒收：任何非零地址都按足额收到，
    ///      只有零地址会 revert。运行：BSC_RPC_URL=... forge test --match-test T2B1 -vv
    function test_T2B1_BscBemCannotRejectNonZeroRecipients() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        assertEq(BSC_BEM.code.length, 2205);
        assertEq(uint256(vm.load(BSC_BEM, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)), 0);
        (bool hasOwner,) = BSC_BEM.staticcall(abi.encodeWithSignature("owner()"));
        (bool hasPaused,) = BSC_BEM.staticcall(abi.encodeWithSignature("paused()"));
        assertFalse(hasOwner, "no owner");
        assertFalse(hasPaused, "no pause");
        deal(BSC_BEM, address(this), 100 * BEM_1);
        address[4] memory to = [address(0xE0A), address(new T2RejectEverything()), BSC_BEM, address(this)];
        for (uint256 i = 0; i < to.length; i++) {
            uint256 before = IERC20(BSC_BEM).balanceOf(to[i]);
            assertTrue(IERC20(BSC_BEM).transfer(to[i], 7 * BEM_1));
            if (to[i] != address(this)) {
                assertEq(IERC20(BSC_BEM).balanceOf(to[i]) - before, 7 * BEM_1, "exact amount, no fee");
            }
        }
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0)));
        IERC20(BSC_BEM).transfer(address(0), 1);
    }

    // =====================================================================
    // B2（高）"补满剩余额度"开局：不成立（规则本身）
    // =====================================================================

    /// @dev 剩余额度小于最低投入时，只接受恰好补满剩余额度的金额，补满即开局（规则 §8：招满即开局）；
    ///      其他小于最低投入的金额一律拒绝。补满的人仍然要付 1% 入场费，按自己的投入参与抽奖。
    function test_T2B2_RemainderFillIsExactAndStartsTheBoard() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        uint256 maxS = m.maxStake();
        uint256 minS = m.minStake();
        // 投到只剩 0.1 BEM（小于最低投入 0.2 BEM）
        while (m.target() - m.totalStake() > maxS) {
            _joinMonth(m, maxS);
        }
        uint256 last = m.target() - m.totalStake() - 0.1e8;
        _joinMonth(m, last);
        uint256 remaining = m.target() - m.totalStake();
        assertEq(remaining, 0.1e8);
        assertLt(remaining, minS);
        address u = _newUser();
        uint256 passId = _mintPass(u);
        bem.mint(u, 10 * BEM_1);
        vm.startPrank(u);
        passCircuits.approve(address(m), passId);
        bem.approve(address(m), type(uint256).max);
        vm.expectRevert(MonthBoard.BadAmount.selector);
        m.join(passId, remaining - 1);
        m.join(passId, remaining);
        vm.stopPrank();
        assertEq(uint256(m.state()), uint256(MonthState.Preparing));
        assertEq(m.socket(_slot(m, u)).stake, remaining);
    }

    // =====================================================================
    // B9（中）最大值线段树 remove 提前 break：不成立
    // =====================================================================

    /// @dev 大量重复投入（只从 {1,2,3,5} 里取值）、随机顺序出局：每次出局后 maxStake 都等于在局者的真实最大值
    function testFuzz_T2B9_MaxStakeExactWithDuplicates(uint256 seed, uint8 nRaw) public {
        uint256 n = bound(nRaw, 2, 48);
        uint256[4] memory vals = [uint256(1), 2, 3, 5];
        uint256[] memory w = new uint256[](n);
        TreeHarness h = new TreeHarness(n);
        for (uint256 i = 0; i < n; i++) {
            w[i] = vals[uint256(keccak256(abi.encode(seed, i))) % 4];
            h.insert(i + 1, w[i]);
        }
        bool[] memory gone = new bool[](n);
        for (uint256 k = 0; k < n; k++) {
            uint256 j = uint256(keccak256(abi.encode(seed, "rm", k))) % n;
            while (gone[j]) j = (j + 1) % n;
            gone[j] = true;
            h.remove(j + 1, w[j]);
            uint256 maxW;
            for (uint256 i = 0; i < n; i++) {
                if (!gone[i] && w[i] > maxW) maxW = w[i];
            }
            assertEq(h.maxStake(), maxW, "max after every removal");
        }
    }

    /// @dev 针对性构造：两个相同的最大值，删掉其中一个，最大值仍是它；再删另一个，降到次大值
    function test_T2B9_EqualSiblingKeepsMaxThenDrops() public {
        TreeHarness h = new TreeHarness(8);
        uint256[8] memory w = [uint256(5), 5, 3, 1, 2, 5, 4, 1];
        for (uint256 i = 0; i < 8; i++) {
            h.insert(i + 1, w[i]);
        }
        h.remove(1, 5);
        assertEq(h.maxStake(), 5);
        h.remove(6, 5);
        assertEq(h.maxStake(), 5);
        h.remove(2, 5);
        assertEq(h.maxStake(), 4);
        h.remove(7, 4);
        assertEq(h.maxStake(), 3);
    }

    // =====================================================================
    // B8（中）pulseGross 取整导致 pool 下溢：不成立
    // =====================================================================

    /// @dev 任意投入：总额 ≥ 出局者 105% + 基金会 3%（手续费 = 总额 − 两者，不会下溢）；总额随投入单调不减，
    ///      所以按"在局最大投入"补足的脉冲池一定够付任何一个出局者
    function testFuzz_T2B8_PulseGrossCoversEveryPart(uint96 a, uint96 b) public view {
        TapeBoard impl = TapeBoard(factory.boardImplementation());
        uint256 s = bound(uint256(a), 1, 1e15);
        uint256 t = bound(uint256(b), 1, 1e15);
        uint256 gross = impl.pulseGross(s);
        uint256 payout = s * 10_500 / 10_000;
        assertGe(gross, payout + gross * 300 / 10_000, "gross covers payout + foundation");
        if (s <= t) assertLe(gross, impl.pulseGross(t), "monotonic");
    }

    /// @dev 边界：脉冲池正好等于门槛（按最大投入算），出局的正好是最大投入者 → 池子正好归零，不下溢
    function test_T2B8_PoolExactlyAtThresholdDrainsToZero() public {
        TapeBoard b = _startGenesis();
        _fillUniform(b, 10, 20 * BEM_1);
        while (b.state() == BoardState.Recruiting) {
            _join(b, b.minStake() * 7);
        }
        _sell(b, _newUser(), 200);
        // 先把已经累积的产出领进池子，再精确补到门槛：pulse 里不会再多领到产出
        b.harvest();
        uint256 th = b.drawThreshold();
        assertEq(th, b.pulseGross(20 * BEM_1));
        uint256 p = b.pool();
        assertLt(p, th);
        _yield(b, 0, th - p);
        b.harvest();
        assertEq(b.pool(), th, "pool exactly at the threshold");
        b.pulse();
        // 找一个会抽中某个 20 BEM（最大投入）插槽的随机数
        uint256 s = b.aliveStake();
        uint256 n = b.aliveCount();
        TreeHarness h = new TreeHarness(b.socketCount());
        for (uint256 i = 1; i <= b.socketCount(); i++) {
            h.insert(i, b.socket(i).stake);
        }
        uint256 word;
        uint256 slot;
        for (uint256 k = 0; k < 10_000; k++) {
            uint256 cand = uint256(keccak256(abi.encode(k)));
            slot = h.select(s, cand % ((n - 1) * s));
            if (b.socket(slot).stake == 20 * BEM_1) {
                word = cand;
                break;
            }
        }
        rng.fulfill(b.pendingRequestId(), word);
        assertTrue(b.socket(slot).ejected, "a largest stake was ejected");
        assertEq(b.pool(), 0, "pool drained exactly, no underflow");
    }

    // =====================================================================
    // B3 / B4 / B14（高 / 高 / 低）结算阶段的会计：不成立
    // =====================================================================

    /// @dev 月局结算中任意交错：迟到产出（结算后矿机继续挖）、溢价挂单卖出、按成本价卖出、分批打款、自领、sweep。
    ///      每一步都满足 余额 ≥ liabilities 且 Σ owed ≤ liabilities；最后全部领完只剩尘埃，资金守恒。
    function testFuzz_T2B3_SettlementBooksStayConsistent(uint64 y1, uint64 y2, uint64 y3, uint8 order) public {
        (MonthBoard m, address[] memory users) = _settled();
        uint256 in0 = bem.balanceOf(address(m));
        uint256 lateYield;
        uint256 saleSum;
        _check(m, users);
        // 1. 结算后的迟到产出（未出售的矿机继续挖）
        uint256 a = bound(uint256(y1), 0, 50 * BEM_1);
        if (a > 0) {
            _yieldAll(m, a);
            lateYield += a / m.machineCount() * m.machineCount();
        }
        if (order & 1 == 1) m.harvest();
        _check(m, users);
        // 2. 部分参与者自领
        for (uint256 i = 0; i < users.length; i += 3) {
            if (_mOwed(m, users[i]) > 0) _mWithdraw(m, users[i]);
        }
        _check(m, users);
        // 3. 报价高于成本，按公式价溢价卖出第 0 台
        _postPrices(_unitFor(m, 0, 12_000), _unitFor(m, 0, 12_000));
        bem.mint(buyer, 1_000 * BEM_1);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        saleSum += sales.buyMachine(address(m), 0, type(uint256).max);
        vm.stopPrank();
        _check(m, users);
        // 4. 更多迟到产出，然后按成本价卖出其余
        uint256 b2 = bound(uint256(y2), 0, 50 * BEM_1);
        if (b2 > 0) {
            uint256 live = m.unsoldMachines();
            for (uint256 i = 0; i < m.machineCount(); i++) {
                if (!m.machine(i).sold) pod.addYield(m.machine(i).key, b2 / live);
            }
            lateYield += b2 / live * live;
        }
        if (order & 2 == 2) m.sweep();
        vm.warp(priceFeed.updatedAt() + priceFeed.abandonAfter()); // 报价停运 7 天：其余按成本价
        vm.startPrank(buyer);
        for (uint256 i = 0; i < m.machineCount(); i++) {
            if (!m.machine(i).sold) saleSum += sales.buyMachine(address(m), i, type(uint256).max);
        }
        vm.stopPrank();
        _check(m, users);
        // 5. 卖完之后才到账的产出（直接转进来，相当于卖出前领取的迟到款项）
        uint256 c = bound(uint256(y3), 0, 20 * BEM_1);
        if (c > 0) bem.mint(address(m), c);
        if (order & 4 == 4) sales.distribute(address(m), 1, 7);
        _check(m, users);
        sales.distribute(address(m), 1, users.length);
        for (uint256 i = 0; i < users.length; i++) {
            _mClaimAll(m, users[i]);
            assertEq(_mOwed(m, users[i]), 0);
        }
        _check(m, users);
        uint256 out = m.rolledOver();
        uint256 bal = bem.balanceOf(address(m));
        assertEq(bal, m.liabilities(), "only dust left, all of it owed");
        assertLe(bal, users.length + 10, "dust only");
        // 守恒：结算开始时的余额 + 迟到产出 + 卖出所得 + 直接转入 = 付给参与者的 + 滚存 + 剩余
        assertLe(in0 + lateYield + saleSum + c, in0 + lateYield + saleSum + c); // 记账口径一致性见 _check
        assertGe(in0 + lateYield + saleSum + c, out + bal);
    }

    function _check(MonthBoard m, address[] memory users) internal view {
        uint256 bal = bem.balanceOf(address(m));
        uint256 owedSum;
        for (uint256 i = 0; i < users.length; i++) {
            owedSum += _mOwed(m, users[i]);
        }
        assertGe(bal, m.liabilities(), "balance >= liabilities");
        assertLe(owedSum, m.liabilities(), "sum owed <= liabilities");
    }

    // =====================================================================
    // A1（高）开奖前就能算出中奖者：中奖者不受影响；Drawing 期间的产出进奖金池（部分成立，项目方选 (b)，已改）
    // =====================================================================

    /// @dev 随机数到账以后，谁、什么时候执行 finalizePrizes，中奖插槽都一样（投入在开局时就固定了，随机数是 VRF 给的）
    function test_T2A1_WinnersDoNotDependOnWhoOrWhenFinalizes() public {
        (MonthBoard m, address[] memory users) = _monthMining();
        _yieldAll(m, 9 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        uint256 word = uint256(keccak256("a1"));
        rng.fulfill(m.pendingRequestId(), word);
        uint256 n = m.socketCount();
        uint256[] memory w = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            w[i] = m.socket(i + 1).stake;
        }
        uint256[5] memory predicted = new PrizeHarness(w).winnersFor(word);
        uint256 snap = vm.snapshotState();
        m.finalizePrizes(); // 运营地址，马上
        uint256[5] memory now_;
        for (uint256 k = 0; k < 5; k++) {
            now_[k] = m.winnerSlots(k);
            assertEq(now_[k], predicted[k]);
        }
        vm.revertToState(snap);
        vm.warp(block.timestamp + 3 days);
        vm.prank(users[3]);
        m.finalizePrizes(); // 参与者，3 天后
        for (uint256 k = 0; k < 5; k++) {
            assertEq(m.winnerSlots(k), now_[k], "same winners");
        }
    }

    /// @dev 项目方的决定（2026-10-21，选项 (b)）：请求开奖时奖金池就定死；之后（随机数到账前后、finalizePrizes 之前）
    ///      到账的产出不进奖金池，进入结算时按投入比例分给所有参与者，不收 3% / 2%（和 X Layer 版一致）。
    ///      对照：同一局有没有这笔迟到产出，中奖者和奖金完全一样，差额按投入比例落到每个人可领取的金额里。
    function test_T2A1_HarvestDuringDrawingIsSharedProRata() public {
        (MonthBoard m, address[] memory users) = _monthMining();
        _yieldAll(m, 9 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        uint256 pot = m.prizePool();
        uint256 snap = vm.snapshotState();
        // 对照组：没有迟到产出
        rng.fulfill(m.pendingRequestId(), 1);
        m.finalizePrizes();
        uint256[] memory base = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            base[i] = _mOwed(m, users[i]);
        }
        uint256[5] memory slots0;
        uint256[5] memory amounts0;
        for (uint256 k = 0; k < 5; k++) {
            slots0[k] = m.winnerSlots(k);
            amounts0[k] = m.prizeAmounts(k);
        }
        vm.revertToState(snap);
        // 实验组：随机数到账前、到账后各有一笔产出，都被任何人 harvest
        uint256 late = 2 * BEM_1 + 3 * BEM_1;
        _yieldAll(m, 2 * BEM_1);
        vm.prank(address(0x5EE5));
        m.harvest();
        assertEq(m.prizePool(), pot, "pot frozen before the callback");
        rng.fulfill(m.pendingRequestId(), 1);
        _yieldAll(m, 3 * BEM_1);
        vm.prank(address(0x5EE5));
        m.harvest();
        assertEq(m.prizePool(), pot, "pot frozen after the callback");
        uint256 fBefore = bem.balanceOf(FOUNDATION);
        uint256 feeBefore = bem.balanceOf(FEE_SAFE);
        m.finalizePrizes();
        // 规则决定 6.15：月局奖金池不扣 3% / 2%
        assertEq(bem.balanceOf(FOUNDATION), fBefore, "no 3%");
        assertEq(bem.balanceOf(FEE_SAFE), feeBefore, "no 2%");
        for (uint256 k = 0; k < 5; k++) {
            assertEq(m.winnerSlots(k), slots0[k], "same winners");
            assertEq(m.prizeAmounts(k), amounts0[k], "same prizes");
        }
        _assertProRata(m, users, base, late);
    }

    function _assertProRata(MonthBoard m, address[] memory users, uint256[] memory base, uint256 late) internal {
        uint256 total = m.totalStake();
        uint256 extraSum;
        for (uint256 i = 0; i < users.length; i++) {
            uint256 share = late * m.socket(_slot(m, users[i])).stake / total;
            uint256 extra = _mOwed(m, users[i]) - base[i];
            assertApproxEqAbs(extra, share, 2, "late yield pro rata");
            extraSum += extra;
            // 每个人都能领到
            uint256 before = bem.balanceOf(users[i]);
            _mWithdraw(m, users[i]);
            assertEq(bem.balanceOf(users[i]) - before, base[i] + extra, "withdraw pays what is owed");
        }
        assertApproxEqAbs(extraSum, late, users.length, "all of the late yield is owed to participants");
    }

    /// @dev 停摆保底（triggerSafeSettle）路径同样：奖金池按请求时的金额整体按比例分配，Drawing 期间 harvest 的产出也按比例
    ///      分配，两者都不收 3% / 2%。
    function test_T2A1_SafeSettleSharesFrozenPotAndLateYield() public {
        (MonthBoard m, address[] memory users) = _monthMining();
        _yieldAll(m, 9 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        uint256 pot = m.prizePool();
        _yieldAll(m, 4 * BEM_1);
        m.harvest();
        assertEq(m.prizePool(), pot, "pot frozen");
        vm.warp(block.timestamp + 7 days);
        uint256 fBefore = bem.balanceOf(FOUNDATION);
        vm.expectEmit(address(m));
        emit MonthBoard.NoDrawSettlement(pot);
        m.triggerSafeSettle();
        assertEq(bem.balanceOf(FOUNDATION), fBefore, "no 3% / 2%");
        // 本金照常收回，其余（冻结的奖金池 + 迟到产出 + 没花完的预算）全部记为参与者可领取
        uint256 owedSum;
        for (uint256 i = 0; i < users.length; i++) {
            owedSum += _mOwed(m, users[i]);
        }
        assertApproxEqAbs(owedSum, bem.balanceOf(address(m)), users.length, "everything is owed");
        assertEq(m.liabilities(), bem.balanceOf(address(m)), "all BEM booked");
    }

    /// @dev 守恒：从请求开奖到结算领完，BEM 一分不差。
    ///      流入 = 请求开奖后合约余额 + 之后 PoD 付给本局的全部产出 + 买家付的矿机款；
    ///      流出 = 基金会 + 手续费地址 + 参与者（奖金和领取）+ 回馈资本滚存 + 合约剩余尘埃。
    ///      路径随机：正常开奖或停摆保底；Drawing 期间的产出在随机数到账前 / 后到账，harvest 与否随机。
    uint256 internal c_in0;
    uint256 internal c_paid0;
    uint256 internal c_out0;
    uint256 internal c_buyer0;

    function testFuzz_T2A1_ConservationFromDrawToSettlement(uint64 y1, uint64 y2, uint64 y3, uint8 path) public {
        (MonthBoard m, address[] memory users) = _monthMining();
        _yieldAll(m, 9 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        c_in0 = bem.balanceOf(address(m));
        c_paid0 = pod.totalPaidTo(address(m));
        c_out0 = _outside(users);
        _drawPhase(m, y1, y2, path);
        _check(m, users);
        _settlePhase(m, users, y3, path);
        uint256 inflow = c_in0 + (pod.totalPaidTo(address(m)) - c_paid0) + (c_buyer0 - bem.balanceOf(buyer));
        uint256 outflow = _outside(users) - c_out0 + bem.balanceOf(address(m));
        assertEq(inflow, outflow, "BEM conserved exactly");
        assertEq(bem.balanceOf(address(m)), m.liabilities(), "leftover is booked dust");
        assertLe(bem.balanceOf(address(m)), users.length + 10, "dust only");
    }

    function _drawPhase(MonthBoard m, uint64 y1, uint64 y2, uint8 path) internal {
        uint256 pot = m.prizePool();
        _yieldAll(m, bound(uint256(y1), 0, 30 * BEM_1));
        if (path & 1 == 1) m.harvest();
        assertEq(m.prizePool(), pot);
        if (path & 2 == 2) {
            vm.warp(block.timestamp + 7 days);
            m.triggerSafeSettle();
        } else {
            rng.fulfill(m.pendingRequestId(), uint256(keccak256(abi.encode(y1, y2))));
            _yieldAll(m, bound(uint256(y2), 0, 30 * BEM_1));
            if (path & 4 == 4) m.harvest();
            assertEq(m.prizePool(), pot);
            m.finalizePrizes();
        }
    }

    /// @dev 结算：迟到产出、卖出全部矿机（成本价）、分批打款、各自领取
    function _settlePhase(MonthBoard m, address[] memory users, uint64 y3, uint8 path) internal {
        _yieldAll(m, bound(uint256(y3), 0, 30 * BEM_1));
        if (path & 8 == 8) m.harvest();
        vm.warp(m.settleStart() + 1 days);
        bem.mint(buyer, 1_000 * BEM_1);
        c_buyer0 = bem.balanceOf(buyer);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        for (uint256 i = 0; i < m.machineCount(); i++) {
            if (!m.machine(i).sold) sales.buyMachine(address(m), i, type(uint256).max);
        }
        vm.stopPrank();
        _check(m, users);
        sales.distribute(address(m), 1, users.length);
        for (uint256 i = 0; i < users.length; i++) {
            _mClaimAll(m, users[i]);
        }
        _check(m, users);
    }

    /// @dev 本局以外、在这段流程里会收到 BEM 的地址：基金会、手续费地址、月局工厂（滚存）、全部参与者
    function _outside(address[] memory users) internal view returns (uint256 sum) {
        sum = bem.balanceOf(FOUNDATION) + bem.balanceOf(FEE_SAFE) + bem.balanceOf(address(monthFactory));
        for (uint256 i = 0; i < users.length; i++) {
            sum += bem.balanceOf(users[i]);
        }
    }

    // =====================================================================
    // A8（中）停摆保底后 finalizePrizes 再次结算：不成立
    // =====================================================================

    function test_T2A8_NoFinalizeAfterSafeSettle() public {
        (MonthBoard m,) = _monthMining();
        _yieldAll(m, 9 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        uint256 id = m.pendingRequestId();
        vm.warp(block.timestamp + 7 days);
        m.triggerSafeSettle();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        rng.fulfill(id, 9); // 迟到的随机数：忽略
        assertFalse(m.wordReceived());
        vm.expectRevert(MonthBoard.NotYet.selector);
        m.finalizePrizes();
    }

    // =====================================================================
    // A13（低）setListing 把 uint256 价格截断成 uint128：成立，已修；第 8 阶段起没有挂单，不再适用
    // =====================================================================

    // =====================================================================
    // B6（中）Failed 状态 settleStart = 0，priceLocked 恒为真：不成立
    // =====================================================================

    /// @dev 招募失败的月局没有任何矿机（矿机只在准备期买入）；v2 的要价在非结算状态恒为 0（v2 没有 priceLocked），买不了
    function test_T2B6_FailedBoardHasNothingToPriceOrBuy() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        _joinMonth(m, 1 * BEM_1);
        vm.warp(m.recruitDeadline());
        m.closeRecruitment();
        assertEq(uint256(m.state()), uint256(MonthState.Failed));
        assertEq(m.machineCount(), 0);
        assertEq(sales.askPrice(address(m), 0), 0, "not settling: nothing for sale");
        vm.expectRevert(MonthMachineSales.NotForSale.selector);
        sales.buyMachine(address(m), 0, type(uint256).max);
    }

    // =====================================================================
    // B11（中）noteSentinel 被人用来延长冷静期：不成立
    // =====================================================================

    function test_T2B11_RepeatedNoteCannotExtendCoolingPeriod() public {
        TapeBoard b = _startGenesis();
        machineBeacon.upgradeTo(address(0xBAD));
        factory.noteSentinel();
        uint256 since = factory.sentinelSince();
        for (uint256 i = 1; i <= 5; i++) {
            vm.warp(since + i * 6 days);
            vm.prank(address(uint160(0xA000 + i)));
            factory.noteSentinel(); // 同一个 implementation：不刷新
            assertEq(factory.sentinelSince(), since);
        }
        assertFalse(b.sentinelPaused(), "cooling period ends 30 days after the first note");
    }

    // =====================================================================
    // B12（中）elapsed = 0 时目标 × 1.25：不成立（快速招满的规则）
    // =====================================================================

    /// @dev 只有真正投满整个目标才会触发增长；同一个区块招满和一天内招满一样 × 1.25，增长的上限是 maxTarget
    function test_T2B12_GrowthNeedsAFullyFundedBoardAndIsCapped() public {
        _startGenesis();
        for (uint256 i = 0; i < 12; i++) {
            MonthBoard m = _monthBoard();
            _fillMonth(m); // 同一个区块里招满
            assertEq(m.totalStake(), m.target());
        }
        assertEq(_monthBoard().target(), 1_000 * BEM_1, "capped at maxTarget");
    }
}
