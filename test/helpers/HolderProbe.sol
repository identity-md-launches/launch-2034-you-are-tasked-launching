// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IHolderToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Test-only token holder that has code. It stands in for a multisig, router or custody
///      contract holding ERC20T. It is never deployed by the launch.
contract HolderProbe {
    function sendTokens(address token, address to, uint256 amount) external returns (bool) {
        return IHolderToken(token).transfer(to, amount);
    }

    function pullTokens(address token, address from, address to, uint256 amount) external returns (bool) {
        return IHolderToken(token).transferFrom(from, to, amount);
    }
}
