// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TapeSurgeDefaults} from "../script/TapeSurgeDefaults.sol";
import {MarketPriceFeed} from "../src/MarketPriceFeed.sol";
import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ITapeOutFactory, ITransistors, ICircuits, IBeacon} from "../src/interfaces/ITapeOut.sol";
import {IPoD} from "../src/interfaces/IPoD.sol";
import {PoDReader} from "../src/libraries/PoDReader.sol";
import {BoardFactory} from "../src/BoardFactory.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {TapeBoard} from "../src/TapeBoard.sol";
import {MachineRules} from "../src/MachineRules.sol";
import {MonthPositions} from "../src/month/MonthPositions.sol";
import {BoardState} from "../src/interfaces/ITapeBoard.sol";
import {MockRandomSource} from "../src/mocks/MockRandom.sol";
import {MockRouter, MockPriceOracle} from "../src/mocks/MockSwap.sol";

/// @notice 模拟分账合约：由合约调用 createCPU，然后自己 withdraw。
contract CreatorProbe {
    address public transistors;
    address public circuits;

    function create(address factory) external payable {
        (transistors, circuits) = ITapeOutFactory(factory).createCPU{value: msg.value}(
            "TapeSurge Genesis", "SURGE", "fork probe", 66_666, 0.001 ether
        );
    }

    function pull() external {
        ITransistors(transistors).withdraw();
    }

    receive() external payable {}
}

/// @notice BSC 主网分叉的只读测试：在本地分叉的主网状态上验证接口假设，不向链上发送任何交易。
///         运行：BSC_RPC_URL=https://bsc-dataseed.bnbchain.org forge test --match-contract ForkBSCTest -vv
///         没有设置 BSC_RPC_URL 时全部跳过。
contract ForkBSCTest is Test {
    address internal constant TAPEOUT_FACTORY = 0x68224F668083c29e9800Be2a646d42d18cedF7e2;
    address internal constant POD = 0x7E2E0DC66a3bD9103E69b766afA62d9f7b697b46;
    address internal constant CIRC = 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C;
    address internal constant CIRC_BEACON = 0xf8D6d8EB894d6971c8976Ad8b4971cbEFE028156;
    address internal constant BEM = 0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a;
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    bytes internal constant PASS_NETLIST = hex"0000000200000300000002000004000000030000040000000500000600000004000004";
    bytes32 internal constant PASS_HASH = 0xfffa29f1e30fa6438ba0e6ebd40ef157b53d0eff3f21cc4bc46942e27cb32ca0;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blockNo = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (blockNo == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNo);
        forked = true;
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev 由合约调用 createCPU：creator = 调用合约；有人铸造后 owed 记在 creator 名下；creator 调 withdraw 收到 BNB。
    function test_Fork_ContractBecomesCreatorAndWithdrawPaysCaller() public onlyFork {
        CreatorProbe probe = new CreatorProbe();
        uint256 fee = ITapeOutFactory(TAPEOUT_FACTORY).deployFee();
        console2.log("deployFee (wei)", fee);
        probe.create{value: fee}(TAPEOUT_FACTORY);
        ITransistors t = ITransistors(probe.transistors());
        assertEq(t.creator(), address(probe), "creator is the calling contract");
        assertEq(t.supplyCap(), 66_666);

        address user = address(0x5EED);
        vm.deal(user, 1 ether);
        vm.prank(user);
        t.mint{value: 5 * 0.0011 ether}(0, 5);
        assertEq(t.minted(), 5, "minted() counts transistors");
        assertEq(t.owed(address(probe)), 0.005 ether, "owed(creator) = mintPrice x amount");

        uint256 before = address(probe).balance;
        probe.pull();
        assertEq(address(probe).balance - before, 0.005 ether, "withdraw pays the creator (caller)");

        // 用标准网表流片通行证：网表哈希一致，eval(0x03) = 0x02（1 + 1 = 2）
        ICircuits c = ICircuits(probe.circuits());
        vm.recordLogs();
        vm.prank(user);
        (bool ok,) = address(c).call{value: 0.0002 ether}(abi.encodeCall(ICircuits.tapeout, (PASS_NETLIST, 2, 2)));
        assertTrue(ok, "tapeout");
        uint256 passId = _mintedId(vm.getRecordedLogs(), address(c));
        assertEq(c.ownerOf(passId), user);
        assertEq(keccak256(c.netlist(passId)), PASS_HASH, "netlist hash");
        assertEq(c.eval(passId, hex"03"), hex"02", "half adder 1+1=2");
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = c.circuitInfo(passId);
        console2.log("circuitInfo", nIn, nOut);
        console2.log("            ", nState, gates);

        // 创世电路合约是不是 Beacon 代理、用的是哪个信标（升级哨兵要监控）
        address passBeacon = address(uint160(uint256(vm.load(address(c), BEACON_SLOT))));
        console2.log("pass circuits beacon", passBeacon);
        console2.log("machine circuits beacon", address(uint160(uint256(vm.load(CIRC, BEACON_SLOT)))));
        if (passBeacon != address(0)) assertTrue(IBeacon(passBeacon).implementation() != address(0));
    }

    /// @dev getMiner 的字段位置（PoDReader 的推断）与官方矿机一致。
    function test_Fork_GetMinerLayout() public onlyFork {
        bytes32 key = IPoD(POD).minerKey(CIRC, 10901);
        (bool ok, PoDReader.MinerView memory m) = PoDReader.tryRead(POD, key, CIRC, 10901);
        assertTrue(ok);
        assertEq(m.circuits, CIRC);
        assertEq(m.circuitId, 10901);
        assertGt(m.weight, 0);
        assertTrue(m.mining);
        assertTrue(m.verified);
        assertGt(m.since, 1_750_000_000);
        assertLt(m.since, block.timestamp);
        console2.log("weight", m.weight, "since", m.since);
        (bool ok2, uint256 perDay) = PoDReader.tryUnitYieldPerDay(POD, 9_900);
        assertTrue(ok2);
        console2.log("unit yield per day (BEM units)", perDay, "x365 =", perDay * 365);
        assertApproxEqRel(perDay * 365, 1.65e8, 0.15e18);
        assertEq(IBeacon(CIRC_BEACON).implementation() != address(0), true);
    }

    /// @dev 矿机转给合约后：claim（任何人可调）把产出付给新持有者，原主人不再收到；转账不会停止挖矿。
    ///      注意：分叉上 pending() 不会随 vm.warp 增长（PoD 的累计量要有交易才更新），所以直接比较 claim 前后的余额。
    function test_Fork_TransferredMachineYieldGoesToNewHolder() public onlyFork {
        uint256 id = 10901;
        bytes32 key = IPoD(POD).minerKey(CIRC, id);
        address owner = IERC721(CIRC).ownerOf(id);
        CreatorProbe holder = new CreatorProbe();
        // 先替原主人领走旧产出（主板 sellMachine 也是这样做）
        uint256 o0 = IERC20(BEM).balanceOf(owner);
        uint256 oldPending = IPoD(POD).pending(key);
        IPoD(POD).claim(key);
        // pending() 是下限：claim 时 PoD 先把累计量更新到当前时间
        assertGe(IERC20(BEM).balanceOf(owner) - o0, oldPending, "old yield paid to old owner");

        vm.prank(owner);
        IERC721(CIRC).transferFrom(owner, address(holder), id);
        (, PoDReader.MinerView memory m) = PoDReader.tryRead(POD, key, CIRC, id);
        assertTrue(m.mining && m.verified, "transfer does not stop mining");

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 28_800);
        uint256 o1 = IERC20(BEM).balanceOf(owner);
        uint256 h0 = IERC20(BEM).balanceOf(address(holder));
        IPoD(POD).claim(key);
        uint256 got = IERC20(BEM).balanceOf(address(holder)) - h0;
        console2.log("holder got after 1 day (BEM units)", got);
        assertEq(IERC20(BEM).balanceOf(owner), o1, "old owner gets nothing");
        assertGt(got, 0, "new holder gets the yield");
        // 新持有者是合约，也能 stop
        vm.prank(address(holder));
        IPoD(POD).stop(key);
    }

    /// @dev 整套系统部署在主网分叉上：真实 TapeOut 工厂 / PoD / BEM / 电路合约，只有路由、预言机、随机数用 Mock。
    function test_Fork_FullSystemOnMainnetState() public onlyFork {
        address wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        address usdt = 0x55d398326f99059fF775485246999027B3197955;
        MockRandomSource rng = new MockRandomSource();
        MockRouter router = new MockRouter(wbnb, BEM, 2_193_000_000);
        MockPriceOracle oracle = new MockPriceOracle(2_193_000_000);

        BoardFactory.Params memory p;
        GenesisSplitter.Params memory sp = GenesisSplitter.Params({
            boardFactory: address(0), // 部署前填入预先算好的 BoardFactory 地址
            tapeoutFactory: TAPEOUT_FACTORY,
            cpuName: "TapeSurge Genesis",
            cpuSymbol: "SURGE",
            cpuStory: "fork integration",
            transistorSupply: 66_666,
            mintPrice: 0.001 ether,
            foundation: 0x04B649076a11819EF7AdA36e02DD55e0923550Ee,
            project: 0x6ea5FfB01378a1E5ce55C8A119A90a87e542C995,
            buybackBps: 4_000,
            projectBps: 1_000,
            foundationBps: 2_000,
            bucketBps: [uint256(1_000), 800, 500, 400, 300],
            bem: BEM,
            wbnb: wbnb,
            router: address(router),
            swapPath: abi.encodePacked(wbnb, uint24(100), usdt, uint24(10_000), BEM),
            oracle: address(oracle),
            maxSwapPerCall: 1 ether,
            minSwapInterval: 1 hours,
            maxSlippageBps: 300
        });
        TapeBoard.Config memory c;
        c.bem = BEM;
        c.pod = POD;
        c.machineRules = address(new MachineRules(POD, TAPEOUT_FACTORY, CIRC));
        c.machineBeacon = CIRC_BEACON;
        c.passBeacon = CIRC_BEACON; // 分叉测试显示创世电路合约与官方电路合约共用同一个信标
        c.passNetlistHash = PASS_HASH;
        c.foundation = 0x04B649076a11819EF7AdA36e02DD55e0923550Ee;
        c.feeRecipient = 0x6ea5FfB01378a1E5ce55C8A119A90a87e542C995;
        c.randomSource = address(rng);
        c.entryFeeBps = 100;
        c.recruitDuration = 7 days;
        c.minStartBps = 6_000;
        c.buyStartBps = 5_000;
        c.buyStepBps = 500;
        c.buyStepInterval = 6 hours;
        c.buyCapDays = 365;
        c.buyMaxPrice = 3e8;
        c.buyRoundDuration = 7 days;
        c.verifiedShareBps = 9_900;
        c.minMachineWeight = 10;
        c.maxMachineWeight = 300;
        c.maxMachines = 100;
        c.minMachineAge = 7 days;
        c.sellStartBps = 15_000;
        c.sellFloorBps = 6_000;
        c.maxDuration = 730 days;
        c.vrfRetryDelay = 1 days;
        c.vrfSafeExitDelay = 7 days;
        c.operatorGrace = 3 days;
        c.claimWindow = 365 days;
        c.sentinelResumeDelay = 30 days;
        p.board = c;
        p.targets = BoardFactory.TargetRules({
            initialTarget: 500e8,
            minTarget: 100e8,
            maxTarget: 1_000e8,
            rounding: 1e8,
            minStakeBps: 20,
            maxStakeBps: 400,
            fastFillWindow: 2 days,
            growBps: 12_500,
            partialBps: 7_500,
            failBps: 5_000
        });
        p.genesisMintThreshold = 10_000;
        p.genesisDelay = 7 days;
        p.initialOperator = address(this);
        // 规则决定 6.37：主板只认 MarketTrader；本测试由测试合约自己扮演它（真实持有人先把矿机转过来）
        p.board.trader = address(this);

        // 持仓凭证（rc6 起标准局加入时铸造）n、报价合约 n + 1、分账合约 n + 2、BoardFactory n + 3；卖矿单例本测试用不到
        address bf = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        p.board.positions = address(new MonthPositions(bf, bf));
        p.board.priceFeed =
            address(new MarketPriceFeed(bf, TapeSurgeDefaults.feedParams(TapeSurgeDefaults.FEED_ABANDON_AFTER)));
        p.board.sales = address(0x5D5A);
        // 分账合约先单独部署（boardFactory = 紧接着部署的 BoardFactory），BoardFactory 部署时核对
        sp.boardFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        p.splitter = address(new GenesisSplitter{value: ITapeOutFactory(TAPEOUT_FACTORY).deployFee()}(sp));
        BoardFactory f = new BoardFactory(p);
        ITransistors t = f.transistors();
        assertEq(t.creator(), address(f.splitter()), "splitter is creator on mainnet factory");
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 7 * 28_800);
        // 开局前必须报过价（全局审计 G-1）：先报一次，开局后恢复成"从没报过价"，本测试沿用默认曲线收购
        MarketPriceFeed(p.board.priceFeed).post(1, 1);
        TapeBoard b = TapeBoard(f.startGenesis());
        vm.store(p.board.priceFeed, bytes32(uint256(0)), bytes32(0)); // bid
        vm.store(p.board.priceFeed, bytes32(uint256(1)), bytes32(0)); // ask
        vm.store(p.board.priceFeed, bytes32(uint256(2)), bytes32(0)); // updatedAt
        vm.store(p.board.priceFeed, bytes32(uint256(6)), bytes32(0)); // liveAt

        ICircuits pc = ICircuits(f.passCircuits());
        for (uint256 i = 0; i < 25; i++) {
            address u = address(uint160(0xF0000 + i));
            vm.deal(u, 1 ether);
            deal(BEM, u, 30e8);
            vm.startPrank(u);
            t.mint{value: 5 * 0.0011 ether}(0, 5);
            vm.recordLogs();
            (bool ok,) = address(pc).call{value: 0.0002 ether}(abi.encodeCall(ICircuits.tapeout, (PASS_NETLIST, 2, 2)));
            require(ok, "tapeout");
            uint256 passId = _mintedId(vm.getRecordedLogs(), address(pc));
            IERC721(address(pc)).approve(address(b), passId);
            IERC20(BEM).approve(address(b), type(uint256).max);
            b.join(passId, 20e8);
            vm.stopPrank();
        }
        assertEq(uint256(b.state()), uint256(BoardState.Active), "filled with real passes");
        console2.log("buy price cap (BEM units / weight)", b.buyPriceCap());

        // 收购一台真实矿机
        uint256 id = 10901;
        address owner = IERC721(CIRC).ownerOf(id);
        (, uint256 w) = MachineRules(b.MACHINE_RULES()).check(CIRC, id, 0, type(uint256).max, 0);
        uint256 spent = w * b.buyPrice();
        vm.prank(owner);
        IERC721(CIRC).transferFrom(owner, address(this), id);
        IERC721(CIRC).approve(address(b), id);
        uint256 paid = b.sellMachine(CIRC, id, spent);
        assertEq(paid, spent);
        console2.log("paid for #10901 (BEM units)", paid);
        assertEq(IERC721(CIRC).ownerOf(id), address(b));
        assertEq(IERC20(BEM).balanceOf(address(b)), 500e8 - paid);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 28_800);
        uint256 got = b.harvest();
        console2.log("harvested after 1 day (BEM units)", got);
        assertGt(got, 0, "board earns PoD yield");
        assertEq(b.pool(), got);
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
}
