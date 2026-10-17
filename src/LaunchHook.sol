// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title LaunchHook
/// @notice Uniswap v4 pool hook for a token launch:
///   - launch guard: the first `guardSwaps` trader swaps after initialization may each buy at most
///     `maxBuy` tokens, so block-zero snipers cannot take more than the launch bundle does. Swaps
///     initiated by the launch initializer (the seed buy) are exempt and not counted;
///   - dev fee: `devFeePips` (1e6 = 100%) of the ETH side of every swap accrues inside the
///     PoolManager as ERC-6909 claims of this hook and is paid to `dev` by `collect()`;
///   - platform fee: `platformFeePips` of the same ETH side on top of the dev fee (rounded up), the
///     launch platform's share; accrued separately and paid only to `platformRecipient` through
///     `collectPlatform()`. 0 / address(0) disables it (self-hosted launch);
///   - exactly one pool: the hook rejects initialization with any other key.
contract LaunchHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint256 private constant ETH_ID = 0;
    uint24 private constant PIPS = 1_000_000;

    IPoolManager public immutable poolManager;
    address public immutable dev;
    uint24 public immutable devFeePips;
    uint256 public immutable guardSwaps;
    uint256 public immutable maxBuy;
    /// @notice Platform share in pips (1e6 = 100 %) of the gross ETH amount of every swap, on top of the dev fee; 0 = none.
    uint24 public immutable platformFeePips;
    /// @notice The only recipient of the platform share; the payout is permissionless.
    address public immutable platformRecipient;

    PoolKey private _key;
    PoolId public poolId;
    /// @notice Contract that initialized the pool (the Seeder); its own swaps bypass the guard.
    address public seeder;
    uint256 public swapCount; // every swap, including the seed buy
    uint256 public guardedSwaps; // trader swaps only; the first `guardSwaps` of them are capped
    uint256 public owed; // accrued dev fee in ETH (claims)
    uint256 public platformOwed; // accrued platform share in ETH (claims)
    uint64 public launchedAt;

    error NotPoolManager();
    error WrongPool();
    error HookNotImplemented();
    error LaunchBuyTooLarge(uint256 got, uint256 cap);
    error NothingToCollect();
    error InvalidFeeConfig();

    event Collected(address indexed dev, uint256 amount);
    event PlatformCollected(address indexed recipient, uint256 amount);
    event FeesAccrued(bool isBuy, uint256 grossNative, uint256 devFee, uint256 platformFee);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(
        IPoolManager poolManager_,
        address token,
        address dev_,
        uint24 devFeePips_,
        uint256 guardSwaps_,
        uint256 maxBuy_,
        uint24 lpFee,
        int24 tickSpacing,
        uint24 platformFeePips_,
        address platformRecipient_
    ) {
        if (uint256(devFeePips_) + platformFeePips_ >= PIPS) revert InvalidFeeConfig();
        if ((platformFeePips_ == 0) != (platformRecipient_ == address(0))) revert InvalidFeeConfig();
        poolManager = poolManager_;
        dev = dev_;
        devFeePips = devFeePips_;
        guardSwaps = guardSwaps_;
        maxBuy = maxBuy_;
        platformFeePips = platformFeePips_;
        platformRecipient = platformRecipient_;
        // ETH (address 0) is always currency0: it sorts below any token address
        _key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
        poolId = _key.toId();
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ───────────────────────── initialize ─────────────────────────

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external override onlyPoolManager returns (bytes4) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        seeder = sender;
        launchedAt = uint64(block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    // ───────────────────────── swap ─────────────────────────

    /// @dev ETH (currency0) is the specified side when exactInput == zeroForOne; then the fee is taken here.
    function _nativeSpecified(SwapParams calldata p) private pure returns (bool) {
        return (p.amountSpecified < 0) == p.zeroForOne;
    }

    /// @dev Combined rate (dev + platform) in pips.
    function _totalPips() private view returns (uint256) {
        return uint256(devFeePips) + platformFeePips;
    }

    /// @dev Fee split: gross is the full ETH amount of the trade (for exact-out, net + fee).
    ///      The platform share is taken from gross rounded up; dev gets the remainder of the total.
    function _split(uint256 amount, bool exactIn)
        private
        view
        returns (uint256 gross, uint256 devFee, uint256 platformFee)
    {
        uint256 total = _totalPips();
        gross = exactIn ? amount : (amount * PIPS) / (PIPS - total);
        uint256 totalFee = exactIn ? (gross * total) / PIPS : gross - amount;
        if (platformFeePips != 0) {
            platformFee = (gross * platformFeePips + PIPS - 1) / PIPS;
            if (platformFee > totalFee) platformFee = totalFee;
        }
        devFee = totalFee - platformFee;
    }

    /// @notice Fee quote for an ETH amount: gross, dev share and platform share.
    function quoteFees(uint256 amount, bool exactIn)
        external
        view
        returns (uint256 gross, uint256 devFee, uint256 platformFee)
    {
        return _split(amount, exactIn);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        uint256 fee;
        if (_nativeSpecified(params)) {
            bool exactIn = params.amountSpecified < 0;
            uint256 requested = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            (uint256 gross, uint256 devFee, uint256 platformFee) = _split(requested, exactIn);
            fee = devFee + platformFee;
            _credit(devFee, platformFee);
            emit FeesAccrued(params.zeroForOne, gross, devFee, platformFee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(address sender, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        ++swapCount;
        bool buy = params.zeroForOne;
        // launch guard: the initializer's seed buy is exempt; the next `guardSwaps` trader buys are capped
        if (sender != seeder) {
            uint256 n = ++guardedSwaps;
            uint256 tokenAmount =
                delta.amount1() < 0 ? uint256(-int256(delta.amount1())) : uint256(int256(delta.amount1()));
            if (buy && n <= guardSwaps && tokenAmount > maxBuy) revert LaunchBuyTooLarge(tokenAmount, maxBuy);
        }
        int128 hookFee = 0;
        if (!_nativeSpecified(params)) {
            bool exactIn = params.amountSpecified < 0;
            uint256 ethAmount =
                delta.amount0() < 0 ? uint256(-int256(delta.amount0())) : uint256(int256(delta.amount0()));
            (uint256 gross, uint256 devFee, uint256 platformFee) = _split(ethAmount, exactIn);
            uint256 fee = devFee + platformFee;
            _credit(devFee, platformFee);
            emit FeesAccrued(buy, gross, devFee, platformFee);
            hookFee = fee.toInt128();
        }
        return (IHooks.afterSwap.selector, hookFee);
    }

    /// @dev Both shares stay inside the PoolManager as ETH claims of the hook: a swap never depends on the recipients.
    function _credit(uint256 devFee, uint256 platformFee) private {
        uint256 total = devFee + platformFee;
        if (total == 0) return;
        poolManager.mint(address(this), ETH_ID, total);
        owed += devFee;
        platformOwed += platformFee;
    }

    /// @notice Pay the accrued dev fee to dev. Anyone may call; the funds only ever go to dev.
    function collect() external returns (uint256 amount) {
        amount = owed;
        if (amount == 0) revert NothingToCollect();
        owed = 0;
        poolManager.unlock(abi.encode(dev, amount));
    }

    /// @notice Pay the platform share to platformRecipient. Anyone may call.
    function collectPlatform() external returns (uint256 amount) {
        amount = platformOwed;
        if (amount == 0) revert NothingToCollect();
        platformOwed = 0;
        poolManager.unlock(abi.encode(platformRecipient, amount));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), ETH_ID, amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, recipient, amount);
        if (recipient == dev) emit Collected(recipient, amount);
        else emit PlatformCollected(recipient, amount);
        return "";
    }

    // ───────────────────────── unused hooks ─────────────────────────

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
