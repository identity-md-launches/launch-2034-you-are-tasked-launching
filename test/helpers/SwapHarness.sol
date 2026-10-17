// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "../../src/interfaces/IERC20T.sol";

interface ITestToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ITestPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// @dev Test-only swap callback. Not a deployed application or frontend router.
contract SwapHarness {
    ITestPoolManager private immutable manager;

    constructor(address manager_) {
        manager = ITestPoolManager(manager_);
    }

    function trade(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut)
    {
        return abi.decode(manager.unlock(abi.encode(key, zeroForOne, amountIn, minOut)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 minOut) =
            abi.decode(data, (PoolKey, bool, uint256, uint256));
        int256 delta = manager.swap(
            key,
            ITestPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            ""
        );
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        int128 output = zeroForOne ? amount1 : amount0;
        require(output > 0 && uint128(output) >= minOut, "slippage");
        _settle(key.currency0, amount0);
        _settle(key.currency1, amount1);
        return abi.encode(uint256(uint128(output)));
    }

    function _settle(address currency, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            require(ITestToken(currency).transfer(address(manager), uint128(-delta)), "transfer");
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }
}
