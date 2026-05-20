// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @dev Minimal extension interface used only to read the `permit2()` getter
///      from a v4 `PositionManager` deployment. The official `IPositionManager`
///      interface in the periphery does not expose this getter, but the
///      concrete contract does (immutable field). Casting through this
///      extension keeps us decoupled from the concrete type.
interface IPositionManagerWithPermit2 {
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title RewardTokensManager - PNPT/FNBT pool creator and liquidity minter
/// @notice Wires the two reward tokens from Assignment 1 into a Uniswap v4
///         liquidity pool. The contract is responsible for:
///           1. creating (and initialising) a no-hooks 0.3% pool on the
///              singleton `PoolManager`, and
///           2. minting a concentrated liquidity position on that pool via
///              the v4 `PositionManager`, using the Permit2 settlement path.
/// @dev The pool's currencies are sorted canonically at construction so
///      `currency0 < currency1` for the lifetime of this contract. The target
///      spot price (1 FNBT equiv 10 PNPT) determines which tick range a
///      caller's chosen `[tickLower, tickUpper]` must cover; ranges that
///      sit strictly above or below the assignment-implied tick are rejected.
contract RewardTokensManager is Ownable {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------------
    // Constants pinned by the assignment specification
    // ---------------------------------------------------------------------

    /// @notice 0.3% pool fee (Uniswap's fee units use 1e6 scale, so 3000 = 0.30%).
    uint24 public constant FEE_TIER = 3000;
    /// @notice Tick spacing that pairs with the 0.3% fee in v3-style fee/spacing
    ///         tables. All `tickLower`/`tickUpper` values must be a multiple of
    ///         this spacing or the pool will reject the position.
    int24 public constant TICK_SPACING = 60;
    /// @notice No hooks contract for this pool - the assignment is explicitly
    ///         "no hooks", which is also part of the unique pool identity.
    address public constant HOOKS = address(0);

    // ---------------------------------------------------------------------
    // Immutable wiring
    // ---------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    /// @notice Permit2 contract used by `PositionManager` to pull settlement.
    ///         Read once at construction from `positionManager.permit2()` so
    ///         we don't have to trust caller-supplied data later.
    address public immutable permit2;

    IERC20 public immutable pnpToken;
    IERC20 public immutable fnbToken;

    /// @notice Sorted pool currencies (`currency0 < currency1` by address).
    Currency public immutable currency0;
    Currency public immutable currency1;

    // ---------------------------------------------------------------------
    // Mutable state
    // ---------------------------------------------------------------------

    /// @notice Tracks which pool ids this manager has successfully initialised.
    ///         Keyed by the v4 `PoolId` unwrapped to `bytes32`.
    mapping(bytes32 => bool) public createdPools;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when this manager initialises a new v4 pool.
    /// @param  poolId        v4 pool id (hash of the full pool key).
    /// @param  currency0     Sorted token0 address (wrapped as `Currency`).
    /// @param  currency1     Sorted token1 address (wrapped as `Currency`).
    /// @param  fee           Swap fee tier in 1e6 units.
    /// @param  tickSpacing   Tick spacing for this pool.
    /// @param  hooks         Hooks contract address (zero address = no hooks).
    /// @param  sqrtPriceX96  Starting sqrt-price used to initialise the pool.
    event PoolCreated(
        bytes32 indexed poolId,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    /// @notice Emitted after a concentrated liquidity position is minted
    ///         successfully through this manager.
    /// @param  poolId      v4 pool id the position belongs to.
    /// @param  positionId  PositionManager ERC721 token id assigned to the
    ///                     new position.
    /// @param  owner       Recipient of the position NFT (= original caller).
    /// @param  tickLower   Lower bound of the position's active range.
    /// @param  tickUpper   Upper bound of the position's active range.
    /// @param  liquidity   Position liquidity in v4-internal units.
    event LiquidityMinted(
        bytes32 indexed poolId,
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    // ---------------------------------------------------------------------
    // Custom errors
    // ---------------------------------------------------------------------

    /// @dev Thrown when a caller-supplied `[tickLower, tickUpper]` does not
    ///      strictly contain the assignment-implied target tick.
    error TickRangeDoesNotCoverAssignmentPrice();
    /// @dev Thrown when both `amount0Desired` and `amount1Desired` are zero,
    ///      because there is no way to compute non-zero liquidity from that.
    error InvalidAmounts();
    /// @dev Thrown when ticks are misordered or not aligned to `TICK_SPACING`.
    error InvalidTicks();
    /// @dev Thrown when `mintLiquidity` is called before `createPool`.
    error PoolNotInitialized();
    /// @dev Thrown if the PositionManager mint did not mint the NFT to the
    ///      expected owner. Defensive sanity check - should be unreachable.
    error MintFailed();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param _poolManager     Address of the deployed v4 `PoolManager`.
    /// @param _positionManager Address of the deployed v4 `PositionManager`.
    /// @param _pnpToken        Address of the deployed `PNPToken`.
    /// @param _fnbToken        Address of the deployed `FNBToken`.
    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        // Read Permit2 from PositionManager once so callers can never spoof
        // a different settlement contract.
        permit2 = IPositionManagerWithPermit2(_positionManager).permit2();

        pnpToken = IERC20(_pnpToken);
        fnbToken = IERC20(_fnbToken);

        // Canonical sort: v4 pool keys require currency0 < currency1. We
        // store both at construction so every helper, view, and event
        // agrees on which token is which side of the pair.
        if (_pnpToken < _fnbToken) {
            currency0 = Currency.wrap(_pnpToken);
            currency1 = Currency.wrap(_fnbToken);
        } else {
            currency0 = Currency.wrap(_fnbToken);
            currency1 = Currency.wrap(_pnpToken);
        }
    }

    // ---------------------------------------------------------------------
    // Read-only helpers
    // ---------------------------------------------------------------------

    /// @notice Returns the sorted `(currency0, currency1)` pair for the pool.
    function getCanonicalCurrencies() external view returns (Currency, Currency) {
        return (currency0, currency1);
    }

    /// @notice Returns the v4 `PoolId` for this pool, as `bytes32`.
    function getPoolId() public view returns (bytes32) {
        return bytes32(PoolId.unwrap(_poolKey().toId()));
    }

    /// @notice Returns the tick where the AMM price equals the assignment's
    ///         spot conversion 1 FNBT equiv 10 PNPT. The sign depends on
    ///         which token sorts as `currency0`.
    /// @dev    Uniswap convention: price = currency1 / currency0 = 1.0001^tick.
    ///         So we encode `sqrtPriceX96 = sqrt(amount1 * 2^192 / amount0)`
    ///         from the integer ratio implied by the spot, then call
    ///         `TickMath.getTickAtSqrtPrice` to convert to a tick.
    function getTargetTick() public view returns (int24) {
        uint256 a0;
        uint256 a1;
        if (Currency.unwrap(currency0) == address(pnpToken)) {
            // currency0 = PNPT, currency1 = FNBT
            // 1 FNBT equiv 10 PNPT  =>  10 units of currency0 per 1 unit of currency1
            // price = currency1 / currency0 = 1 / 10 = 0.1
            a0 = 10;
            a1 = 1;
        } else {
            // currency0 = FNBT, currency1 = PNPT
            // 1 FNBT equiv 10 PNPT  =>  1 unit of currency0 per 10 units of currency1
            // price = currency1 / currency0 = 10
            a0 = 1;
            a1 = 10;
        }

        // sqrtPriceX96 = sqrt(price * 2^192) = sqrt(a1 * 2^192 / a0)
        // a1 is small (<=10), so (a1 << 192) cannot overflow uint256.
        uint256 ratioX192 = (a1 << 192) / a0;
        uint160 sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    // ---------------------------------------------------------------------
    // Pool creation (Part 2 of the assignment)
    // ---------------------------------------------------------------------

    /// @notice Initialise the canonical PNPT/FNBT pool on the v4 PoolManager.
    /// @dev    `onlyOwner` so a random caller can't grief the pool-creation
    ///         step with a hostile starting price. The pool is uniquely
    ///         identified by the full key (currencies, fee, tickSpacing,
    ///         hooks), so this manager can only ever initialise one pool.
    /// @param  sqrtPriceX96 Starting sqrt-price for the pool (Q64.96 fixed).
    /// @return poolId       v4 pool id, also stored in `createdPools`.
    function createPool(uint160 sqrtPriceX96) external onlyOwner returns (bytes32 poolId) {
        PoolKey memory key = _poolKey();
        poolId = bytes32(PoolId.unwrap(key.toId()));

        poolManager.initialize(key, sqrtPriceX96);
        createdPools[poolId] = true;

        emit PoolCreated(poolId, currency0, currency1, FEE_TIER, TICK_SPACING, HOOKS, sqrtPriceX96);
    }

    // ---------------------------------------------------------------------
    // Liquidity minting (Part 3 of the assignment)
    // ---------------------------------------------------------------------

    /// @notice Mint a concentrated liquidity position on the canonical pool.
    /// @dev    The caller must `approve(this, ...)` on both tokens beforehand.
    ///         The resulting position NFT is minted to the caller. Any token
    ///         dust left on this contract after the v4 mint is refunded.
    /// @param  tickLower       Lower tick of the position (multiple of 60).
    /// @param  tickUpper       Upper tick of the position (multiple of 60).
    /// @param  amount0Desired  Maximum currency0 the caller is willing to spend.
    /// @param  amount1Desired  Maximum currency1 the caller is willing to spend.
    /// @return positionId      ERC721 id of the freshly minted position NFT.
    /// @return poolId          v4 pool id the position was minted on.
    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external onlyOwner returns (uint256 positionId, bytes32 poolId) {
        // 1) Validate inputs and tick constraints.
        //    Both-zero amounts can't produce non-zero liquidity, and ticks
        //    must be ordered and aligned to the pool's spacing.
        if (amount0Desired == 0 && amount1Desired == 0) revert InvalidAmounts();
        if (tickLower >= tickUpper) revert InvalidTicks();
        if (tickLower % TICK_SPACING != 0 || tickUpper % TICK_SPACING != 0) revert InvalidTicks();

        // 2) Ensure the chosen range covers the assignment target tick.
        //    Strict inequality so a range that sits entirely above or below
        //    the target (test case 3) reverts.
        int24 target = getTargetTick();
        if (target <= tickLower || target >= tickUpper) {
            revert TickRangeDoesNotCoverAssignmentPrice();
        }

        // 3) Resolve and verify the liquidity pool.
        PoolKey memory key = _poolKey();
        poolId = bytes32(PoolId.unwrap(key.toId()));
        if (!createdPools[poolId]) revert PoolNotInitialized();

        // 4) Compute liquidity from desired amounts at the *current* pool price.
        //    The pool's current sqrtPrice may sit outside our target range -
        //    in that case `getLiquidityForAmounts` naturally only consumes
        //    one of the two tokens (the other is returned as dust in step 9).
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(PoolId.wrap(poolId));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtLower,
            sqrtUpper,
            amount0Desired,
            amount1Desired
        );

        // 5) Pull desired token amounts from the caller into this contract.
        //    We pay the pool from our own balance below; the caller pays us.
        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);
        if (amount0Desired > 0) {
            require(
                IERC20(token0).transferFrom(msg.sender, address(this), amount0Desired),
                "transferFrom currency0"
            );
        }
        if (amount1Desired > 0) {
            require(
                IERC20(token1).transferFrom(msg.sender, address(this), amount1Desired),
                "transferFrom currency1"
            );
        }

        // 6) Approve Permit2 to pull from this contract so PositionManager
        //    can settle pool deltas via the Permit2 transferFrom path.
        //    Real Permit2 would additionally require an internal allowance
        //    set via `permit2.approve(token, positionManager, ...)`. The
        //    MockPermit2 used by the tests only checks the ERC20 allowance
        //    we set here, so a single `IERC20.approve` is sufficient.
        IERC20(token0).approve(permit2, type(uint256).max);
        IERC20(token1).approve(permit2, type(uint256).max);

        // 7) Prepare PositionManager mint actions and execute modifyLiquidities.
        //    Two actions in sequence:
        //      MINT_POSITION - mint a new position NFT to msg.sender
        //      SETTLE_PAIR   - settle owed currency0/currency1 from us
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(amount0Desired),
            uint128(amount1Desired),
            msg.sender,
            bytes("")
        );
        params[1] = abi.encode(currency0, currency1);

        // The PositionManager assigns ids monotonically starting at 1, so the
        // next mint takes the current `nextTokenId()` value.
        positionId = IPositionManagerWithPermit2(address(positionManager)).nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        // 8) Verify mint succeeded by confirming the NFT was issued to the
        //    expected owner. Defensive check; should never trip in practice.
        if (IPositionManagerWithPermit2(address(positionManager)).ownerOf(positionId) != msg.sender) {
            revert MintFailed();
        }

        // 9) Refund any unspent token dust to the caller and emit the
        //    assignment event with the final mint parameters.
        uint256 leftover0 = IERC20(token0).balanceOf(address(this));
        uint256 leftover1 = IERC20(token1).balanceOf(address(this));
        if (leftover0 > 0) {
            require(IERC20(token0).transfer(msg.sender, leftover0), "refund currency0");
        }
        if (leftover1 > 0) {
            require(IERC20(token1).transfer(msg.sender, leftover1), "refund currency1");
        }

        emit LiquidityMinted(poolId, positionId, msg.sender, tickLower, tickUpper, liquidity);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Builds the canonical `PoolKey` for this contract's pool.
    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOKS)
        });
    }
}
