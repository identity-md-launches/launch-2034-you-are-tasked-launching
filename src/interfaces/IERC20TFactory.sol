// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice ABI matched to mainnet calldata and exercised against the pinned deployed runtime.
interface IERC20TFactory {
    struct TokenConfig {
        string name;
        string symbol;
        uint256 totalSupply;
        uint256 liquiditySupply;
        address owner;
        address hook;
        address quoteToken;
        address positionManager;
        address permit2;
        uint16 restingTaxBps;
        address feeRecipient;
        uint16 launchTaxBps;
        uint32 taxDecayIntervalSeconds;
        address feeDecayRecipient;
    }

    function implementation() external view returns (address);

    /// @param priceX18 IMD per ERC20T, scaled by 1e18 (both tokens have 18 decimals).
    function createAndLaunchAtPrice(TokenConfig calldata config, uint16 creatorBps, uint256 priceX18)
        external
        payable
        returns (address token);
}
