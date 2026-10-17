// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20TLaunch} from "../../src/ERC20TLaunch.sol";
import {IERC20T} from "../../src/interfaces/IERC20T.sol";
import {SwapHarness, ITestToken} from "./SwapHarness.sol";

/// @dev Read-only RPC state-override probe used only to discover the actual swap access list.
///      It is never deployed or broadcast. capture-fixture.mjs temporarily supplies its runtime
///      at the designated owner's account in eth_call / eth_createAccessList.
contract LaunchAndTradeProbe {
    receive() external payable {}

    function probe() external returns (address token, uint256 bought, uint256 soldFor) {
        ERC20TLaunch app = new ERC20TLaunch(address(this));
        token = app.launch(540_540_540_540, block.timestamp + 300, false);
        SwapHarness router = new SwapHarness(app.POOL_MANAGER());
        address quote = app.IMD();
        require(ITestToken(quote).transfer(address(router), 10 ether));
        bought = router.trade(IERC20T(token).poolKey(), quote < token, 1 ether, 1);
        soldFor = router.trade(IERC20T(token).poolKey(), token < quote, bought / 2, 1);
    }
}
