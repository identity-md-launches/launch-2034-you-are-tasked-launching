// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20TFactory} from "./interfaces/IERC20TFactory.sol";
import {IERC20T, IERC20THook, IPositionManager, PoolKey} from "./interfaces/IERC20T.sol";

/// @notice One-use owner-controlled launch of erc20t through Adam's existing mainnet factory.
/// @dev No assets, approvals, external calls or child deployments in the constructor.
///      Runtime fingerprints bind this adapter to the bytecode tested in test/fixtures.
contract ERC20TLaunch {
    address public constant FACTORY = 0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173;
    address public constant HOOK = 0xed9A04Fa6693e754661A22502524DF9b1857e544;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant IMPLEMENTATION = 0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe;
    // The hook converts collected IMD fees to native ETH through this existing route.
    address public constant IMD_ETH_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840;

    // This is the NFT recipient hardcoded by the existing ERC20T implementation,
    // not a substitute for an owner, recipient or missing configuration.
    address public constant LOCKED_POSITION_RECIPIENT = address(uint160(0xdead));
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CREATOR_SUPPLY = 50_000_000 ether;
    uint256 public constant LIQUIDITY_SUPPLY = TOTAL_SUPPLY - CREATOR_SUPPLY;
    // Uniswap's integer liquidity rounding can leave sub-microtoken dust in the token itself.
    uint256 public constant MAX_LIQUIDITY_DUST = 1e12;
    uint16 public constant CREATOR_BPS = 500;
    uint16 public constant RESTING_TAX_BPS = 100;
    uint16 public constant LAUNCH_TAX_BPS = 9900;
    uint16 public constant TAX_DECAY_STEP_BPS = 100;
    uint16 public constant PROTOCOL_FEE_BPS = 15;
    uint32 public constant TAX_DECAY_INTERVAL_SECONDS = 60;
    uint256 public constant MAX_DEADLINE_DELAY = 30 minutes;
    uint256 public constant MAX_PRICE_X18 = 1e18;
    // Indicative ~$3,000 FDV at the documented $5.55/IMD observation, not an oracle.
    uint256 public constant SUGGESTED_PRICE_X18 = 540_540_540_540;

    enum Status {
        Ready,
        Launching,
        Launched
    }

    address public immutable owner;
    Status public status;
    address public token;
    uint256 public positionId;
    bytes32 public poolId;
    uint256 public requestedPriceX18;
    uint256 public launchBlock;
    uint64 public launchedAt;
    bool public wasFirst;

    error InvalidOwner();
    error Unauthorized();
    error WrongChain();
    error AlreadyLaunched();
    error InvalidPrice();
    error InvalidDeadline();
    error FirstSlotTaken();
    error DependencyChanged(address dependency);
    error InvalidLaunchResult();
    error PositionNotLocked();

    event Launched(
        address indexed token,
        bytes32 indexed poolId,
        address indexed owner,
        uint256 positionId,
        uint256 requestedPriceX18,
        bool firstFactoryToken
    );

    constructor(address owner_) {
        if (owner_ == address(0) || owner_ == address(this) || owner_ == FACTORY) revert InvalidOwner();
        owner = owner_;
    }

    /// @notice Address of the factory's first possible clone (CREATE nonce 2).
    /// @dev Nonce 1 created its immutable implementation. Code hash is checked before using this fact.
    function firstTokenAddress() public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", FACTORY, hex"02")))));
    }

    /// @notice A first-slot probe, not an indexer or a claim about an unverified chain.
    function firstSlotAvailable() public view returns (bool) {
        return firstTokenAddress().code.length == 0;
    }

    function tokenConfig() public view returns (IERC20TFactory.TokenConfig memory) {
        return IERC20TFactory.TokenConfig({
            name: "erc20t",
            symbol: "ERC20T",
            totalSupply: TOTAL_SUPPLY,
            liquiditySupply: LIQUIDITY_SUPPLY,
            owner: owner,
            hook: HOOK,
            quoteToken: IMD,
            positionManager: POSITION_MANAGER,
            permit2: PERMIT2,
            restingTaxBps: RESTING_TAX_BPS,
            feeRecipient: owner,
            launchTaxBps: LAUNCH_TAX_BPS,
            taxDecayIntervalSeconds: TAX_DECAY_INTERVAL_SECONDS,
            feeDecayRecipient: owner
        });
    }

    /// @notice Atomically create the token, initialize the v4 pool and lock its single-sided position.
    /// @param requireFirst Reverts if any earlier token occupies the factory's first clone address.
    ///        Pass false only after reviewing the full factory event history; no ordinal is fabricated here.
    /// @dev Nonpayable: this launch spends no IMD/ETH principal and grants no user token allowances.
    function launch(uint256 priceX18, uint256 deadline, bool requireFirst)
        external
        returns (address created)
    {
        if (msg.sender != owner) revert Unauthorized();
        if (block.chainid != 1) revert WrongChain();
        if (status != Status.Ready) revert AlreadyLaunched();
        if (priceX18 == 0 || priceX18 > MAX_PRICE_X18) revert InvalidPrice();
        if (deadline < block.timestamp || deadline - block.timestamp > MAX_DEADLINE_DELAY) {
            revert InvalidDeadline();
        }
        checkDependencies();
        bool first = firstSlotAvailable();
        if (requireFirst && !first) revert FirstSlotTaken();

        status = Status.Launching;
        uint256 id = IPositionManager(POSITION_MANAGER).nextTokenId();
        created = IERC20TFactory(FACTORY).createAndLaunchAtPrice(tokenConfig(), CREATOR_BPS, priceX18);
        if (first && created != firstTokenAddress()) revert InvalidLaunchResult();
        _checkToken(created);
        bytes32 keyHash = _checkPosition(created, id);

        token = created;
        positionId = id;
        poolId = keyHash;
        requestedPriceX18 = priceX18;
        launchBlock = block.number;
        launchedAt = uint64(block.timestamp);
        wasFirst = first;
        status = Status.Launched;
        emit Launched(created, keyHash, owner, id, priceX18, first);
    }

    /// @notice Reject an absent or different dependency before the factory receives a call.
    function checkDependencies() public view {
        _checkCode(FACTORY, 0x474f926e1425178a191768de94d3a734dec4b8e8ba8095699e511e8275ab1867);
        _checkCode(IMPLEMENTATION, 0xd73decc05e33a0c746d08a72b5a8e1eb0ff4599dd557b45a7cc4462053862d38);
        _checkCode(HOOK, 0x6b744df4b886fa50c6c3af8e14837d660494b63f21118e661d17e5cc06017ba1);
        _checkCode(POSITION_MANAGER, 0x77e36c08b19959a30dde46dec9abe6208e371ff2f56884a56fe1e1a53615528b);
        _checkCode(POOL_MANAGER, 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293);
        _checkCode(PERMIT2, 0xc67d1657868aa5146eaf24fb879fb1fdec3d2d493b3683a61c9c2f4fb2851131);
        _checkCode(IMD, 0x79a1ae149d27d4aae006d4dd75cb834222c9623799bbf34359428aaf66fec3bf);
        _checkCode(IMD_ETH_HOOK, 0xdacaaedc2f955bb870db5e10b08eb9711e7909d4f8bd7463c67df58a8d4f9fb8);
        if (IERC20TFactory(FACTORY).implementation() != IMPLEMENTATION) revert DependencyChanged(FACTORY);
        if (IERC20T(IMD).decimals() != 18) revert DependencyChanged(IMD);
        if (
            IERC20THook(HOOK).protocolFeeRecipient() == address(0)
                || IERC20THook(HOOK).PROTOCOL_FEE_BPS() != PROTOCOL_FEE_BPS
        ) revert DependencyChanged(HOOK);
        (bool baseFlag, bool poolFlag) = IERC20THook(HOOK).externalBases(IMD);
        PoolKey memory route = IERC20THook(HOOK).externalBasePool(IMD);
        if (
            !baseFlag || !poolFlag || route.currency0 != address(0) || route.currency1 != IMD
                || route.fee != 10000 || route.tickSpacing != 60 || route.hooks != IMD_ETH_HOOK
        ) revert DependencyChanged(HOOK);
    }

    function _checkCode(address dependency, bytes32 expectedHash) private view {
        if (dependency.codehash != expectedHash) revert DependencyChanged(dependency);
    }

    function _checkToken(address created) private view {
        if (created.code.length == 0) revert InvalidLaunchResult();
        IERC20T t = IERC20T(created);
        uint256 dust = t.balanceOf(created);
        if (
            !t.launched() || t.owner() != owner || t.totalSupply() != TOTAL_SUPPLY || t.decimals() != 18
                || keccak256(bytes(t.name())) != keccak256("erc20t")
                || keccak256(bytes(t.symbol())) != keccak256("ERC20T") || t.balanceOf(owner) != CREATOR_SUPPLY
                || dust > MAX_LIQUIDITY_DUST || t.balanceOf(POOL_MANAGER) + dust != LIQUIDITY_SUPPLY
                || t.hook() != HOOK || t.quoteToken() != IMD || t.positionManager() != POSITION_MANAGER
                || t.permit2() != PERMIT2 || t.poolManager() != POOL_MANAGER
                || t.launchedAt() != block.timestamp || t.restingTaxBps() != RESTING_TAX_BPS
                || t.launchTaxBps() != LAUNCH_TAX_BPS || t.taxBps() != LAUNCH_TAX_BPS
                || t.TAX_DECAY_STEP_BPS() != TAX_DECAY_STEP_BPS
                || t.taxDecayIntervalSeconds() != TAX_DECAY_INTERVAL_SECONDS || t.feeRecipient() != owner
                || t.feeDecayRecipient() != owner
        ) revert InvalidLaunchResult();
    }

    function _checkPosition(address created, uint256 id) private view returns (bytes32 keyHash) {
        IPositionManager pm = IPositionManager(POSITION_MANAGER);
        if (
            pm.nextTokenId() != id + 1 || pm.ownerOf(id) != LOCKED_POSITION_RECIPIENT
                || pm.getPositionLiquidity(id) == 0
        ) revert PositionNotLocked();
        PoolKey memory key = IERC20T(created).poolKey();
        (PoolKey memory positionKey,) = pm.getPoolAndPositionInfo(id);
        (address c0, address c1) = created < IMD ? (created, IMD) : (IMD, created);
        keyHash = keccak256(abi.encode(key));
        if (
            key.currency0 != c0 || key.currency1 != c1 || key.fee != 0 || key.tickSpacing != 60
                || key.hooks != HOOK || keyHash != keccak256(abi.encode(positionKey))
        ) revert InvalidLaunchResult();
    }
}
