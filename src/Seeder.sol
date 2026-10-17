// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

interface ILaunchToken {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;
}

interface ILaunchHook {
    function poolKey() external view returns (PoolKey memory);
}

/// @title Seeder
/// @notice One-shot launch initializer. It receives the whole token supply and the launch ETH and, in a
///         single call: initializes the pool, places the supply as one token-only position (a curve from
///         tickLower up to the opening tick), optionally performs the seed buy (the first swap, routed
///         through the hook like any trader) and pairs the bought tokens with the remaining ETH in a
///         full-range position, burns leftover tokens and returns ETH dust to dev.
///         With msg.value == 0 only the token-only position is created: no seed buy and no ETH-side
///         liquidity, so the first buyers are the launch bundle itself.
///         Positions belong to lpOwner (0xdEaD = liquidity locked forever).
contract Seeder is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 public constant MIN_TICK_LOWER = -30_000;

    address public immutable dev;
    address public immutable lpOwner;
    IPositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;
    address public immutable factory;
    bool public ignited;

    struct IgniteParams {
        uint160 sqrtPriceX96; // opening price (token per ETH; ETH is currency0)
        int24 tickLower; // bottom of the token position, >= MIN_TICK_LOWER
        int24 tickUpper; // top of the token position; <= opening tick so it holds tokens only
        uint256 minTokensOut; // minimum tokens for the seed buy (0 when there is no seed buy)
        uint256 buyEth; // part of msg.value spent on the seed buy; the rest goes to the full-range position
    }

    error NotFactory();
    error NotPoolManager();
    error AlreadyIgnited();
    error InvalidParams();
    error InsufficientOutput();
    error PostconditionFailed();

    event Ignited(
        address indexed token,
        address indexed hook,
        uint256 indexed mainPositionId,
        uint256 fullRangeId,
        uint256 bought,
        uint256 burned,
        uint256 ethDust
    );

    constructor(address dev_, address lpOwner_, IPositionManager positionManager_, address factory_) {
        if (dev_ == address(0) || factory_ == address(0) || lpOwner_ == address(0)) revert InvalidParams();
        dev = dev_;
        lpOwner = lpOwner_;
        positionManager = positionManager_;
        poolManager = positionManager_.poolManager();
        factory = factory_;
    }

    function ignite(address token, address hook, IgniteParams calldata p)
        external
        payable
        returns (uint256 mainId, uint256 fullRangeId, uint256 bought)
    {
        if (msg.sender != factory) revert NotFactory();
        if (ignited) revert AlreadyIgnited();
        ignited = true;

        PoolKey memory key = ILaunchHook(hook).poolKey();
        bool seeded = msg.value != 0;
        // seeded: 0 < buyEth < msg.value (seed buy plus ETH-side liquidity); unseeded: no buy at all
        if (seeded ? (p.buyEth == 0 || p.buyEth >= msg.value) : (p.buyEth != 0 || p.minTokensOut != 0)) revert InvalidParams();
        if (Currency.unwrap(key.currency1) != token || p.tickLower < MIN_TICK_LOWER || p.tickLower >= p.tickUpper) {
            revert InvalidParams();
        }
        if (poolManager.initialize(key, p.sqrtPriceX96) < p.tickUpper) revert InvalidParams();

        // 1. the whole supply as one token-only position
        mainId = _mintTokenOnly(key, token, p.tickLower, p.tickUpper);

        uint256 ethUsed;
        if (seeded) {
            // 2. seed buy through the hook, like any trader
            bought = abi.decode(poolManager.unlock(abi.encode(key, p.buyEth)), (uint256));
            if (bought < p.minTokensOut) revert InsufficientOutput();

            // 3. remaining ETH plus the matching tokens as a full-range position
            (fullRangeId, ethUsed) = _mintFullRange(key, token, bought, msg.value - p.buyEth);
        }

        // 4. burn whatever is left here; ETH dust goes to dev
        uint256 burned = ILaunchToken(token).balanceOf(address(this));
        if (burned != 0) ILaunchToken(token).burn(burned);
        uint256 dust = address(this).balance;
        if (dust != 0) {
            (bool ok,) = dev.call{value: dust}("");
            if (!ok) revert PostconditionFailed();
        }
        if (
            ILaunchToken(token).balanceOf(address(this)) != 0 || address(this).balance != 0
                || ILaunchToken(token).balanceOf(address(poolManager)) != ILaunchToken(token).totalSupply()
        ) revert PostconditionFailed();
        emit Ignited(token, hook, mainId, fullRangeId, bought, burned, seeded ? msg.value - p.buyEth - ethUsed : 0);
    }

    /// @dev Seed buy: exactly buyEth in, tokens out, settled from this contract's balance.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint256 buyEth) = abi.decode(data, (PoolKey, uint256));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(buyEth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        uint256 owedEth = uint256(-int256(delta.amount0()));
        if (owedEth != buyEth) revert PostconditionFailed();
        poolManager.sync(key.currency0);
        poolManager.settle{value: buyEth}();
        uint256 bought = uint256(int256(delta.amount1()));
        poolManager.take(key.currency1, address(this), bought);
        return abi.encode(bought);
    }

    function _mintTokenOnly(PoolKey memory key, address token, int24 tickLower, int24 tickUpper)
        private
        returns (uint256 tokenId)
    {
        uint256 supply = ILaunchToken(token).balanceOf(address(this));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, supply);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        while (amount1 > supply) {
            --liquidity;
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
        tokenId = positionManager.nextTokenId();
        if (!ILaunchToken(token).transfer(address(positionManager), amount1)) revert PostconditionFailed();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, tickLower, tickUpper, uint256(liquidity), uint128(0), uint128(amount1), lpOwner, "");
        params[1] = abi.encode(key.currency1, amount1, false);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _mintFullRange(PoolKey memory key, address token, uint256 tokens, uint256 lpEth)
        private
        returns (uint256 tokenId, uint256 amount0)
    {
        // outermost ticks aligned to the pool's tickSpacing (otherwise TickMisaligned)
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, lpEth, tokens);
        uint256 amount1;
        (amount0, amount1) = _amounts(sqrtP, sqrtLower, sqrtUpper, liquidity);
        while (amount0 > lpEth || amount1 > tokens) {
            --liquidity;
            (amount0, amount1) = _amounts(sqrtP, sqrtLower, sqrtUpper, liquidity);
        }
        tokenId = positionManager.nextTokenId();
        if (!ILaunchToken(token).transfer(address(positionManager), amount1)) revert PostconditionFailed();
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, tickLower, tickUpper, uint256(liquidity), uint128(amount0), uint128(amount1), lpOwner, "");
        params[1] = abi.encode(key.currency0, amount0, false);
        params[2] = abi.encode(key.currency1, amount1, false);
        positionManager.modifyLiquidities{value: amount0}(abi.encode(actions, params), block.timestamp);
    }

    function _amounts(uint160 sqrtP, uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtUpper, liquidity, true);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtP, liquidity, true);
    }

    receive() external payable {}
}
