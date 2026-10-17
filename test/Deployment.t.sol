// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20TLaunch} from "../src/ERC20TLaunch.sol";

contract DeploymentTest is Test {
    address internal constant OWNER = 0x3d6a89C8751a45DD577a4C1F3b34E71C58236193;

    function test_constructorOnEmptyChainHasExplicitOwner() public {
        address deployingFactory = makeAddr("project deployment factory");
        vm.prank(deployingFactory);
        ERC20TLaunch app = new ERC20TLaunch(OWNER);
        assertEq(app.owner(), OWNER);
        assertTrue(app.owner() != deployingFactory);
        assertEq(app.token(), address(0));
        assertEq(uint256(app.status()), 0);
        assertEq(app.FACTORY().code.length, 0);
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(ERC20TLaunch.InvalidOwner.selector);
        new ERC20TLaunch(address(0));
    }

    function test_constructorRejectsInfrastructureAsOwner() public {
        vm.expectRevert(ERC20TLaunch.InvalidOwner.selector);
        new ERC20TLaunch(0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173);
    }

    function test_runtimeBoundedAndHasNoEscapeOpcodes() public {
        ERC20TLaunch app = new ERC20TLaunch(OWNER);
        bytes memory code = address(app).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
