// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {Fixture} from "./utils/Fixture.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MonthBoard} from "../src/MonthBoard.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {MonthFactory} from "../src/MonthFactory.sol";
import {MonthState} from "../src/interfaces/IMonthBoard.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";
import {IPoD} from "../src/interfaces/IPoD.sol";
import {PoDReader} from "../src/libraries/PoDReader.sol";
import {TapeSurgeDefaults} from "../script/TapeSurgeDefaults.sol";

/// @title TapeCode 第三轮（审 audit-v1.4）逐条核实
/// @dev 测试名 T3 + 条目编号。第 1 条的主网实测（真实 PoD claimMany 100 台）需要 BSC_RPC_URL，没设置时跳过。
contract AuditTapeCode3Test is Fixture {
    address internal constant BSC_POD = 0x7E2E0DC66a3bD9103E69b766afA62d9f7b697b46;
    address internal constant BSC_CIRC = 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C;

    /// @dev 标准局目标 5,000 BEM（单人 10–200 BEM），月局目标 5,000 BEM：预算足够买满 100 台最小算力矿机
    function _bigSystem() internal {
        BoardFactory.Params memory p = defaultParams();
        p.targets.initialTarget = 5_000 * BEM_1;
        p.targets.maxTarget = 5_000 * BEM_1;
        MonthFactory.Params memory mp = defaultMonthParams();
        mp.targets.initialTarget = 5_000 * BEM_1;
        mp.targets.maxTarget = 5_000 * BEM_1;
        _deploySystem(p, mp);
    }

    /// @dev 标准局：25 人各 200 BEM 招满，收购 100 台矿机（每台算力 10）
    function _hundredMachineBoard() internal returns (TapeBoard b) {
        _bigSystem();
        b = _startGenesis();
        _fillUniform(b, 25, 200 * BEM_1);
        assertEq(uint256(b.state()), uint256(BoardState.Active));
        address seller = _newUser();
        for (uint256 i = 0; i < 100; i++) {
            _sell(b, seller, 10);
        }
        assertEq(b.machineCount(), 100);
    }

    // =====================================================================
    // 1（高）_claimYield 一次处理全部矿机：gas 有上界（≤ 100 台），回调里不领取产出
    // =====================================================================

    /// @dev 100 台矿机（部署上限）时 harvest / pulse / VRF 回调的 gas（mock PoD）。
    ///      回调只做"选人 + 出局推送 + 退通行证"，不调用 _claimYield；只剩硅王时的终局由 pulse 发起，不在回调里。
    function test_T3_01_HundredMachineGas() public {
        TapeBoard b = _hundredMachineBoard();
        for (uint256 i = 0; i < 100; i++) {
            _yield(b, i, BEM_1 / 100);
        }
        uint256 g = gasleft();
        b.harvest();
        uint256 harvestGas = g - gasleft();
        // claimMany 失败时逐台领取（最坏路径）
        for (uint256 i = 0; i < 100; i++) {
            _yield(b, i, BEM_1 / 100);
        }
        pod.setClaimManyReverts(true);
        g = gasleft();
        b.harvest();
        uint256 fallbackGas = g - gasleft();
        pod.setClaimManyReverts(false);

        _topUpPool(b);
        for (uint256 i = 0; i < 100; i++) {
            _yield(b, i, BEM_1 / 100);
        }
        g = gasleft();
        b.pulse();
        uint256 pulseGas = g - gasleft();
        uint256 id = b.pendingRequestId();
        // 回调期间如果调用了 PoD.claim / claimMany，矿机上的待领产出会被领走：用它来证明回调不领取产出
        _yield(b, 0, 7);
        uint256 pendingBefore = pod.pending(b.machine(0).key);
        g = gasleft();
        rng.fulfill(id, 12_345);
        uint256 callbackGas = g - gasleft();
        assertEq(pod.pending(b.machine(0).key), pendingBefore, "callback does not claim yield");
        assertEq(b.aliveCount(), 24, "one ejected");

        console2.log("REPORT T3-1 harvest 100 machines (claimMany)", harvestGas);
        console2.log("REPORT T3-1 harvest 100 machines (per-claim fallback)", fallbackGas);
        console2.log("REPORT T3-1 pulse 100 machines (harvest + VRF request)", pulseGas);
        console2.log("REPORT T3-1 VRF callback (eject), 100 machines", callbackGas);
        assertLt(callbackGas, 750_000, "callback below the 750k limit");
        assertLt(fallbackGas, 15_000_000, "worst-case harvest far below the BSC block gas limit");
        assertLt(pulseGas, 15_000_000);
    }

    /// @dev 月局 100 台矿机：drawPrizes（先领取再请求随机数）的 gas；月局回调只记随机数。
    function test_T3_01_MonthHundredMachineDrawGas() public {
        _bigSystem();
        _startGenesis();
        MonthBoard m = _monthBoard();
        _fillMonth(m);
        address seller = _newUser();
        for (uint256 i = 0; i < 100; i++) {
            _sellMonth(m, seller, 10);
        }
        assertEq(m.machineCount(), 100);
        vm.warp(m.prepEnd());
        m.sync();
        for (uint256 i = 0; i < 100; i++) {
            pod.addYield(m.machine(i).key, BEM_1 / 100);
        }
        vm.warp(m.miningEnd());
        pod.setClaimManyReverts(true); // 最坏路径
        uint256 g = gasleft();
        m.drawPrizes();
        uint256 drawGas = g - gasleft();
        uint256 id = m.pendingRequestId();
        g = gasleft();
        rng.fulfill(id, 1);
        uint256 callbackGas = g - gasleft();
        console2.log("REPORT T3-1 month drawPrizes 100 machines (per-claim fallback)", drawGas);
        console2.log("REPORT T3-1 month VRF callback", callbackGas);
        assertLt(callbackGas, 150_000);
        assertLt(drawGas, 15_000_000);
    }

    /// @dev 主网分叉：真实 PoD 上 100 台真实在挖矿机的 claimMany / 逐台 claim 的 gas（claim 任何人可调，产出付给持有者）。
    ///      运行：BSC_RPC_URL=... forge test --match-test T3_01_Fork -vv
    function test_T3_01_Fork_RealPoDClaim100() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        bytes32[] memory keys = new bytes32[](100);
        uint256 n;
        for (uint256 id = 10_900; id < 13_000 && n < 100; id++) {
            bytes32 key = IPoD(BSC_POD).minerKey(BSC_CIRC, id);
            (bool ok, PoDReader.MinerView memory mv) = PoDReader.tryRead(BSC_POD, key, BSC_CIRC, id);
            if (ok && mv.verified && mv.mining) keys[n++] = key;
        }
        assertEq(n, 100, "found 100 mining machines");
        vm.warp(block.timestamp + 1 days); // 每台都有一天的待领产出
        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        IPoD(BSC_POD).claimMany(keys);
        uint256 manyGas = g - gasleft();
        vm.revertToState(snap);
        g = gasleft();
        for (uint256 i = 0; i < 100; i++) {
            try IPoD(BSC_POD).claim(keys[i]) {} catch {}
        }
        uint256 loopGas = g - gasleft();
        console2.log("REPORT T3-1 fork block gas limit", block.gaslimit);
        console2.log("REPORT T3-1 fork real PoD claimMany(100)", manyGas);
        console2.log("REPORT T3-1 fork real PoD claim x100 (fallback)", loopGas);
        assertLt(loopGas, block.gaslimit / 4, "worst case well below the block gas limit");
    }

    // =====================================================================
    // 2（高）relayMachine 先转 NFT 再付款；isBoard 只看 numberOf：不成立
    // =====================================================================

    /// @dev 月局都是 MonthFactory 用 Clones.clone（CREATE，地址按工厂 nonce 递增，不会复用）复制同一个实现，
    ///      实现地址是工厂构造时 new 出来的 immutable；numberOf 只在 _open 里写。招募失败后重开得到的是新地址，
    ///      失败的那块仍然登记为月局，但不在准备期，它的 sellMachine revert，整笔交接回滚（NFT 留在出让方）。
    function test_T3_02_RelayReceiverIsAlwaysAFactoryCloneAndFailureRollsBack() public {
        (MonthBoard m,) = _settledMonth();
        // 第 2 块月局招募失败 → 工厂重开同一编号，新地址
        MonthBoard failed = _monthBoard();
        vm.warp(failed.recruitDeadline());
        failed.closeRecruitment();
        assertEq(uint256(failed.state()), uint256(MonthState.Failed));
        MonthBoard reopened = _monthBoard();
        assertTrue(address(reopened) != address(failed), "reopen deploys a new clone");
        assertEq(monthFactory.numberOf(address(reopened)), monthFactory.numberOf(address(failed)));
        // 两块都是 EIP-1167 最小代理，指向同一个 immutable 实现
        address impl = monthFactory.boardImplementation();
        bytes memory expected = abi.encodePacked(hex"363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3");
        assertEq(address(failed).code, expected);
        assertEq(address(reopened).code, expected);
        // 交接给失败的那块：整笔回滚
        uint256 circuitId = m.machine(0).circuitId;
        vm.expectRevert(MonthBoard.BuyRoundInactive.selector);
        sales.relay(address(m), 0, address(failed));
        assertEq(machines.ownerOf(circuitId), address(m), "NFT stays with the sender");
        assertFalse(m.machine(0).sold);
        // 交接给不是月局的地址：直接拒绝
        vm.expectRevert(MonthBoard.NotMonthBoard.selector);
        sales.relay(address(m), 0, address(0xBAD));
        // 交接给重开后、招满在准备期的那块：成功（v2：按接手方的收购价成交，且不低于成本价）
        _fillMonth(reopened);
        uint256 cost = m.machine(0).cost;
        uint256 budgetBefore = reopened.budget();
        uint256 paid = _relayWhenPriced(m, 0, reopened);
        assertEq(machines.ownerOf(circuitId), address(reopened));
        assertGe(paid, cost);
        assertEq(reopened.budget(), budgetBefore - paid, "receiver paid exactly the price");
    }

    function _settledMonth() internal returns (MonthBoard m, address[] memory users) {
        _startGenesis();
        m = _monthBoard();
        users = _fillMonth(m);
        address seller = _newUser();
        _sellMonth(m, seller, 30);
        _sellMonth(m, seller, 20);
        vm.warp(m.prepEnd());
        m.sync();
        for (uint256 i = 0; i < m.machineCount(); i++) {
            pod.addYield(m.machine(i).key, BEM_1);
        }
        vm.warp(m.miningEnd());
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), 3);
        m.finalizePrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
    }

    // =====================================================================
    // 3（高）/ 6（中）totalStake == 0 时除零：不成立（开局 / 结算时 totalStake 一定 > 0）
    // =====================================================================

    /// @dev 标准局开局要求 ≥ 2 人且 totalStake ≥ 目标 × minStartBps（构造函数要求 minStartBps > 0；
    ///      initialize 要求 minStake > 0），所以 Active 时 totalStake > 0；投入不会减少（出局只减 aliveStake）。
    ///      异常结局 proRataStake = totalStake > 0，priorityStake = aliveStake ≥ 1 人的投入 > 0。
    function test_T3_03_TotalStakeIsPositiveOnEveryEndPath() public {
        TapeBoard b = _startGenesis();
        uint256 minS = b.minStake();
        assertGt(minS, 0);
        _join(b, minS);
        vm.warp(b.recruitDeadline());
        b.closeRecruitment(); // 1 人：不开局，招募失败
        assertEq(uint256(b.state()), uint256(BoardState.Failed));

        b = _board();
        _fillUniform(b, 2, b.maxStake());
        vm.warp(b.recruitDeadline());
        b.closeRecruitment();
        assertEq(uint256(b.state()), uint256(BoardState.Failed), "below 60%: no start");

        b = _board();
        address[] memory us = _fillUniform(b, b.target() / b.maxStake(), b.maxStake());
        assertEq(uint256(b.state()), uint256(BoardState.Active));
        assertGt(b.totalStake(), 0);
        _sell(b, _newUser(), 10);
        // 最长期限 2 年到期（expire；triggerSafeExit 走同一分支）：proRataStake = totalStake，priorityStake = aliveStake
        vm.warp(b.startedAt() + 730 days);
        b.expire();
        assertEq(uint256(b.state()), uint256(BoardState.Liquidating));
        assertEq(b.proRataStake(), b.totalStake());
        assertGt(b.priorityStake(), 0);
        bem.mint(address(b), 5 * BEM_1);
        b.sweep(); // 分配不会除零
        assertGt(_owedOf(b, us[0]), 0);
    }

    /// @dev 月局：开局要求 totalStake ≥ 目标 × minStartBps（> 0）；没开局的局只会进入 Failed（退款路径不按比例分），
    ///      所以 _shareIncome 只会在 totalStake > 0 时运行。没买到矿机直接结算的边界也一样。
    function test_T3_06_MonthSettlementWithoutMachinesHasPositiveStake() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        address[] memory users = _fillMonth(m);
        assertGt(m.totalStake(), 0);
        bem.mint(address(m), 3 * BEM_1); // 未记账的 BEM：进入结算时会被 _sweep 按比例分配
        vm.warp(m.prepEnd());
        m.sync(); // 一台矿机都没有 → 直接结算
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertEq(m.liabilities(), bem.balanceOf(address(m)));
        uint256 owedSum;
        for (uint256 i = 0; i < users.length; i++) {
            owedSum += _mOwed(m, users[i]);
        }
        assertApproxEqAbs(owedSum, bem.balanceOf(address(m)), users.length);
        // 招募失败的月局：totalStake 可以为 0，但只走退款，不调用 _shareIncome
        MonthBoard next = _monthBoard();
        vm.warp(next.recruitDeadline());
        next.closeRecruitment();
        assertEq(uint256(next.state()), uint256(MonthState.Failed));
        assertEq(next.totalStake(), 0);
        assertEq(next.liabilities(), 0);
    }

    // =====================================================================
    // 13（低）两种局的随机源：同一个 VRF 适配器，注册中心同时认两种局
    // =====================================================================

    function test_T3_13_BothBoardKindsShareOneRandomSource() public {
        TapeSurgeDefaults.Addresses memory a = defaultAddresses();
        BoardFactory.Params memory p = TapeSurgeDefaults.params(a);
        MonthFactory.Params memory mp = TapeSurgeDefaults.monthParams(a);
        assertEq(p.board.randomSource, a.randomSource);
        assertEq(mp.board.randomSource, a.randomSource, "deploy defaults: one adapter for both kinds");
        TapeBoard b = _startGenesis();
        MonthBoard m = _monthBoard();
        assertTrue(factory.isBoard(address(b)), "registry accepts standard boards");
        assertTrue(factory.isBoard(address(m)), "registry accepts month boards (via MonthFactory)");
        assertFalse(factory.isBoard(address(0xBAD)));
    }

    // =====================================================================
    // 12（低）构造参数边界：buyStartBps == 0、foundation == feeRecipient → 拒绝（已加，只在构造函数里）
    // =====================================================================

    function test_T3_12_ConstructorRejectsZeroStartPriceAndSharedRecipients() public {
        TapeSurgeDefaults.Addresses memory a = defaultAddresses();
        TapeBoard.Config memory c = TapeSurgeDefaults.params(a).board;
        c.buyStartBps = 0;
        vm.expectRevert(TapeBoard.BadConfig.selector);
        new TapeBoard(c);
        c = TapeSurgeDefaults.params(a).board;
        c.feeRecipient = c.foundation;
        vm.expectRevert(TapeBoard.BadConfig.selector);
        new TapeBoard(c);
        new TapeBoard(TapeSurgeDefaults.params(a).board); // 默认参数照常通过

        MonthBoard.Config memory mc = TapeSurgeDefaults.monthParams(a).board;
        mc.buyStartBps = 0;
        vm.expectRevert(MonthBoard.BadConfig.selector);
        new MonthBoard(mc);
        mc = TapeSurgeDefaults.monthParams(a).board;
        mc.feeRecipient = mc.foundation;
        vm.expectRevert(MonthBoard.BadConfig.selector);
        new MonthBoard(mc);
        new MonthBoard(TapeSurgeDefaults.monthParams(a).board);
    }

    // =====================================================================
    // 10 _push 的返回值解码：BSC BEM 的 transfer 总是返回 32 字节的 true（标准 OZ v5 ERC-20）
    // =====================================================================

    /// @dev 主网分叉：低层调用 BEM.transfer，返回值恰好 32 字节且为 true，所以 abi.decode(ret, (bool)) 不会 revert。
    function test_T3_10_Fork_BemTransferReturnsOneWordTrue() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        address bscBem = 0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a;
        deal(bscBem, address(this), 10 * BEM_1);
        (bool ok, bytes memory ret) =
            bscBem.call(abi.encodeWithSignature("transfer(address,uint256)", address(0xCAFE), BEM_1));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertTrue(abi.decode(ret, (bool)));
        (ok,) = bscBem.call(abi.encodeWithSignature("transfer(address,uint256)", address(0xCAFE), 100 * BEM_1));
        assertFalse(ok, "insufficient balance reverts (never returns false)");
    }
}
