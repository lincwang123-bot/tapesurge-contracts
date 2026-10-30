// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IMintableBEM {
    function mint(address to, uint256 amount) external;
}

/// @notice 仅用于测试 / 测试网：模拟 PoD 挖矿。
/// @dev 复现链上核实过的行为：
///      - key = minerKey(电路合约, 编号)；
///      - claim 任何人可调，产出付给 NFT **当前持有者**；
///      - stop / arm 只有当前持有者能调；
///      - getMiner 返回 22 个静态字，位置与主网实测一致（PoDReader）：[2] 任务号（0 = 未验证池）、[3] 基础算力、
///        [7] 处理器倍数、[8] 开挖时间、[9] 状态（1 在挖 / 3 已停）、[19] 已验证池权重（基础 × 倍数，停挖 / 未验证为 0）、
///        [20] 未验证池权重；产出按 [19] 累积；
///      - currentRate / totalVerifWeight 用来算"每单位权重的产出"（采购价上限）。
///      产出 = 手动注入（addYield）+ 按 权重 × 速率 × 时间 自动累积。
contract MockPoD {
    struct Miner {
        address circuits;
        uint256 circuitId;
        uint256 taskId;
        uint256 weight;
        bool mining;
        bool verified;
        address registrant;
        uint256 since;
        uint256 manual;
        uint256 bonus; // 最优加成（基础单位）
        uint256 accrued;
        uint256 lastAccrual;
    }

    IMintableBEM public immutable bem;
    /// @notice 每单位权重每天的产出（BEM 最小单位）。
    uint256 public ratePerWeightPerDay;
    bool public claimManyReverts;
    uint256 public totalVerifWeight;
    mapping(bytes32 => Miner) internal _miners;
    /// @notice 测试辅助：累计付给每个持有者的产出（用于资金守恒检查）
    mapping(address => uint256) public totalPaidTo;

    error Ownr();

    constructor(address bem_) {
        bem = IMintableBEM(bem_);
    }

    // ---------------- 与主网相同的接口 ----------------

    function minerKey(address circuits, uint256 id) public pure returns (bytes32) {
        return keccak256(abi.encode(circuits, id));
    }

    /// @notice 处理器倍数（测试辅助 setMultiplier 设置，默认 1）
    mapping(address => uint256) internal _multiplier;

    function getMiner(bytes32 key) external view returns (uint256[22] memory w) {
        Miner storage m = _miners[key];
        uint256 mult = processorMultiplier(m.circuits);
        w[0] = uint256(uint160(m.circuits));
        w[1] = m.circuitId;
        w[2] = m.verified ? m.taskId : 0;
        w[3] = m.weight;
        w[7] = mult;
        w[8] = m.since;
        w[9] = m.mining ? 1 : 3;
        w[10] = uint256(uint160(m.registrant));
        w[13] = m.weight;
        w[19] = m.mining && m.verified ? (m.weight + m.bonus) * mult : 0;
        w[20] = m.mining && !m.verified ? m.weight * mult : 0;
    }

    /// @notice 每秒总产出（BEM 最小单位）。默认与主网一致：每天 7,200 BEM。
    uint256 public currentRate = 8_333_333;

    function pending(bytes32 key) public view returns (uint256) {
        Miner storage m = _miners[key];
        return m.manual + m.accrued + _accruing(m);
    }

    function claim(bytes32 key) public {
        Miner storage m = _miners[key];
        _settle(m);
        uint256 amt = m.manual + m.accrued;
        m.manual = 0;
        m.accrued = 0;
        if (amt > 0) {
            address holder = IERC721(m.circuits).ownerOf(m.circuitId);
            totalPaidTo[holder] += amt;
            bem.mint(holder, amt);
        }
    }

    function claimMany(bytes32[] calldata keys) external {
        require(!claimManyReverts, "claimMany disabled");
        for (uint256 i = 0; i < keys.length; i++) {
            claim(keys[i]);
        }
    }

    function stop(bytes32 key) external {
        Miner storage m = _miners[key];
        if (IERC721(m.circuits).ownerOf(m.circuitId) != msg.sender) revert Ownr();
        _settle(m);
        m.mining = false;
    }

    function arm(address circuits, uint256 id) external {
        Miner storage m = _miners[minerKey(circuits, id)];
        if (IERC721(circuits).ownerOf(id) != msg.sender) revert Ownr();
        _settle(m);
        m.mining = true;
    }

    function processorMultiplier(address circuits) public view returns (uint256) {
        uint256 m = _multiplier[circuits];
        return m == 0 ? 1 : m;
    }

    // ---------------- 测试辅助 ----------------

    function register(address circuits, uint256 id, uint256 weight) external returns (bytes32 key) {
        key = minerKey(circuits, id);
        Miner storage m = _miners[key];
        m.circuits = circuits;
        m.circuitId = id;
        m.taskId = 1;
        m.weight = weight;
        m.mining = true;
        m.verified = true;
        m.registrant = IERC721(circuits).ownerOf(id);
        m.since = block.timestamp;
        m.lastAccrual = block.timestamp;
        totalVerifWeight += weight * processorMultiplier(circuits);
    }

    /// @notice 测试辅助：设置合集的处理器倍数（主网 Behemoth = 6）
    function setMultiplier(address circuits, uint256 m) external {
        _multiplier[circuits] = m;
    }

    /// @notice 测试辅助：设置最优加成（基础单位；PoD 按 (基础 + 加成) × 倍数 分产出）
    function setBonus(bytes32 key, uint256 bonus) external {
        Miner storage m = _miners[key];
        _settle(m);
        m.bonus = bonus;
    }

    /// @notice 测试辅助：改写 getMiner 返回的电路合约地址和编号（模拟字段错位 / 返回别的矿机）
    function setIdentity(bytes32 key, address circuits, uint256 id) external {
        _miners[key].circuits = circuits;
        _miners[key].circuitId = id;
    }

    /// @notice 测试辅助：设置开挖时间（模拟已经运行了多久）
    function setSince(bytes32 key, uint256 since) external {
        _miners[key].since = since;
    }

    function setCurrentRate(uint256 r) external {
        currentRate = r;
    }

    function setTotalVerifWeight(uint256 w) external {
        totalVerifWeight = w;
    }

    function addYield(bytes32 key, uint256 amount) external {
        _miners[key].manual += amount;
    }

    function setRate(uint256 perWeightPerDay) external {
        ratePerWeightPerDay = perWeightPerDay;
    }

    function setClaimManyReverts(bool v) external {
        claimManyReverts = v;
    }

    function setFlags(bytes32 key, bool mining, bool verified) external {
        Miner storage m = _miners[key];
        _settle(m);
        m.mining = mining;
        m.verified = verified;
    }

    /// @notice 模拟 PoD 挑战撤销：不再验证、不再挖矿
    function revoke(bytes32 key) external {
        Miner storage m = _miners[key];
        _settle(m);
        m.verified = false;
        m.mining = false;
    }

    /// @notice 模拟降级：权重下降
    function demote(bytes32 key, uint256 newWeight) external {
        Miner storage m = _miners[key];
        _settle(m);
        m.weight = newWeight;
    }

    function _accruing(Miner storage m) internal view returns (uint256) {
        if (!m.mining || !m.verified || m.lastAccrual == 0) return 0;
        return (m.weight + m.bonus) * processorMultiplier(m.circuits) * ratePerWeightPerDay * (block.timestamp - m.lastAccrual)
            / 1 days;
    }

    function _settle(Miner storage m) internal {
        m.accrued += _accruing(m);
        m.lastAccrual = block.timestamp;
    }
}
