// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IERC20T {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function owner() external view returns (address);
    function hook() external view returns (address);
    function quoteToken() external view returns (address);
    function poolManager() external view returns (address);
    function positionManager() external view returns (address);
    function permit2() external view returns (address);
    function launched() external view returns (bool);
    function launchedAt() external view returns (uint64);
    function restingTaxBps() external view returns (uint16);
    function launchTaxBps() external view returns (uint16);
    function taxBps() external view returns (uint16);
    function TAX_DECAY_STEP_BPS() external view returns (uint16);
    function taxDecayIntervalSeconds() external view returns (uint32);
    function feeRecipient() external view returns (address);
    function feeDecayRecipient() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
}

interface IPositionManager {
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
}

interface IERC20THook {
    function protocolFeeRecipient() external view returns (address);
    function PROTOCOL_FEE_BPS() external view returns (uint16);
    function externalBases(address base) external view returns (bool, bool);
    function externalBasePool(address base) external view returns (PoolKey memory);
}
