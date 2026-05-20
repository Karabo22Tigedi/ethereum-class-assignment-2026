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

// The IPositionManager interface from the v4 periphery does not expose
// permit2() or the token id helpers, but the deployed PositionManager
// contract does. This small extension interface lets us call those
// getters without having to import the full concrete contract.
interface IPositionManagerWithPermit2 {
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

// RewardTokensManager handles both parts of the v4 assignment in one
// place: it creates the PNPT / FNBT pool on the PoolManager, and it
// mints a concentrated liquidity position on that pool through the
// PositionManager.
//
// Pool parameters from the wiki:
//   fee tier     0.3%  (3000 in v4 fee units)
//   tickSpacing  60
//   hooks        address(0)
//
// The two currencies are sorted at construction time so currency0 is
// always the lower address, which is what v4 pool keys require.
contract RewardTokensManager is Ownable {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint24 public constant FEE_TIER = 3000;
    int24 public constant TICK_SPACING = 60;
    address public constant HOOKS = address(0);

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    // Read once from the PositionManager at construction. Storing it
    // here means a caller cannot pass in some other settlement
    // contract later on.
    address public immutable permit2;

    IERC20 public immutable pnpToken;
    IERC20 public immutable fnbToken;

    // Sorted pool currencies, currency0 < currency1 by address.
    Currency public immutable currency0;
    Currency public immutable currency1;

    // Tracks which pool ids this manager has already initialised.
    mapping(bytes32 => bool) public createdPools;

    event PoolCreated(
        bytes32 indexed poolId,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    event LiquidityMinted(
        bytes32 indexed poolId,
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    error TickRangeDoesNotCoverAssignmentPrice();
    error InvalidAmounts();
    error InvalidTicks();
    error PoolNotInitialized();
    error MintFailed();

    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        permit2 = IPositionManagerWithPermit2(_positionManager).permit2();

        pnpToken = IERC20(_pnpToken);
        fnbToken = IERC20(_fnbToken);

        // v4 pool keys require currency0 < currency1, so figure out the
        // ordering here once and reuse it everywhere else.
        if (_pnpToken < _fnbToken) {
            currency0 = Currency.wrap(_pnpToken);
            currency1 = Currency.wrap(_fnbToken);
        } else {
            currency0 = Currency.wrap(_fnbToken);
            currency1 = Currency.wrap(_pnpToken);
        }
    }

    // Returns the sorted currency pair for this pool.
    function getCanonicalCurrencies() external view returns (Currency, Currency) {
        return (currency0, currency1);
    }

    // Returns the v4 pool id (as bytes32) for the pool this contract
    // is responsible for.
    function getPoolId() public view returns (bytes32) {
        return bytes32(PoolId.unwrap(_poolKey().toId()));
    }

    // Returns the tick where the AMM price matches the wiki spot ratio
    // of 1 FNBT to 10 PNPT. The sign of the tick depends on which
    // token sorted as currency0.
    //
    // Uniswap defines price as price = currency1 / currency0 = 1.0001 ^ tick.
    // From the integer ratio we build a sqrtPriceX96 and then convert
    // it to a tick using TickMath.
    function getTargetTick() public view returns (int24) {
        uint256 a0;
        uint256 a1;
        if (Currency.unwrap(currency0) == address(pnpToken)) {
            // currency0 = PNPT, currency1 = FNBT.
            // 1 FNBT = 10 PNPT, so 10 units of currency0 buy 1 of currency1.
            // price = currency1 / currency0 = 1 / 10.
            a0 = 10;
            a1 = 1;
        } else {
            // currency0 = FNBT, currency1 = PNPT.
            // 1 unit of currency0 buys 10 units of currency1.
            // price = currency1 / currency0 = 10.
            a0 = 1;
            a1 = 10;
        }

        // sqrtPriceX96 = sqrt(price * 2^192) = sqrt((a1 * 2^192) / a0).
        // a1 is at most 10 so shifting by 192 cannot overflow uint256.
        uint256 ratioX192 = (a1 << 192) / a0;
        uint160 sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    // createPool initialises the PNPT / FNBT pool on the v4 PoolManager.
    // onlyOwner is used here because the starting price has to be set
    // once and we do not want some random caller to lock the pool in
    // at a hostile sqrt price before the owner gets a chance.
    function createPool(uint160 sqrtPriceX96) external onlyOwner returns (bytes32 poolId) {
        PoolKey memory key = _poolKey();
        poolId = bytes32(PoolId.unwrap(key.toId()));

        poolManager.initialize(key, sqrtPriceX96);
        createdPools[poolId] = true;

        emit PoolCreated(poolId, currency0, currency1, FEE_TIER, TICK_SPACING, HOOKS, sqrtPriceX96);
    }

    // mintLiquidity adds a concentrated liquidity position to the pool
    // created above. The caller has to approve this contract on both
    // tokens before calling. onlyOwner is used so only the deployer
    // can spend the contract allowance and receive the position NFT.
    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external onlyOwner returns (uint256 positionId, bytes32 poolId) {
        // 1) Validate user inputs and tick constraints.
        // Two zero amounts cannot give a non zero liquidity, and the
        // ticks have to be ordered and aligned to TICK_SPACING.
        if (amount0Desired == 0 && amount1Desired == 0) revert InvalidAmounts();
        if (tickLower >= tickUpper) revert InvalidTicks();
        if (tickLower % TICK_SPACING != 0 || tickUpper % TICK_SPACING != 0) revert InvalidTicks();

        // 2) Make sure the chosen range covers the target tick implied
        // by the wiki spot rate (1 FNBT = 10 PNPT). Strict inequality,
        // so a range that sits entirely above or below the target tick
        // is rejected.
        int24 target = getTargetTick();
        if (target <= tickLower || target >= tickUpper) {
            revert TickRangeDoesNotCoverAssignmentPrice();
        }

        // 3) Resolve the pool id from the pool key and check that the
        // pool was already initialised through createPool().
        PoolKey memory key = _poolKey();
        poolId = bytes32(PoolId.unwrap(key.toId()));
        if (!createdPools[poolId]) revert PoolNotInitialized();

        // 4) Compute liquidity from the desired amounts at the current
        // pool price. If the current sqrtPrice is outside the chosen
        // range, getLiquidityForAmounts will end up only consuming one
        // of the two tokens, and step 9 below refunds the other.
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

        // 5) Pull the desired token amounts from the caller into this
        // contract. We then settle the pool from our own balance below.
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

        // 6) Approve Permit2 on both tokens so the PositionManager can
        // settle whatever currency deltas the mint ends up owing. The
        // v4 PositionManager uses Permit2 as its settlement path.
        IERC20(token0).approve(permit2, type(uint256).max);
        IERC20(token1).approve(permit2, type(uint256).max);

        // 7) Build the action sequence for modifyLiquidities:
        //   MINT_POSITION  creates the new position NFT for msg.sender
        //   SETTLE_PAIR    pays the owed currency0 and currency1
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

        // PositionManager hands out token ids starting at 1 and bumps
        // its counter on every mint, so the next id is just the
        // current value of nextTokenId().
        positionId = IPositionManagerWithPermit2(address(positionManager)).nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        // 8) Verify mint succeeded. If the NFT did not end up with the
        // expected owner something has gone badly wrong.
        if (IPositionManagerWithPermit2(address(positionManager)).ownerOf(positionId) != msg.sender) {
            revert MintFailed();
        }

        // 9) Send any leftover tokens back to the caller and emit the
        // event the assignment asks for.
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

    // Builds the PoolKey for the PNPT / FNBT pool. Used in both
    // createPool and mintLiquidity so the same key is always produced.
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
