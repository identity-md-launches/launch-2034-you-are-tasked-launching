// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20TLaunch} from "../../src/ERC20TLaunch.sol";
import {IERC20TFactory} from "../../src/interfaces/IERC20TFactory.sol";

/// @dev Fault injection only: impersonates a malicious factory callback to a contract owner.
contract ReentryProbe {
    error GuardObserved();
    error GuardMissing();

    function execute(ERC20TLaunch app) external {
        app.launch(540_540_540_540, block.timestamp, false);
    }

    function createAndLaunchAtPrice(IERC20TFactory.TokenConfig calldata config, uint16, uint256)
        external
        returns (address)
    {
        ReentryProbe(config.owner).callback(ERC20TLaunch(msg.sender));
        revert GuardMissing();
    }

    function callback(ERC20TLaunch app) external {
        require(msg.sender == app.FACTORY(), "factory only");
        try app.launch(540_540_540_540, block.timestamp, false) {
            revert GuardMissing();
        } catch (bytes memory reason) {
            if (keccak256(reason) != keccak256(abi.encodeWithSelector(ERC20TLaunch.AlreadyLaunched.selector)))
            {
                revert GuardMissing();
            }
            // Carry evidence out of the reverted call without relying on reverted storage or logs.
            revert GuardObserved();
        }
    }
}
