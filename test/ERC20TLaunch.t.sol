// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20TLaunch} from "../src/ERC20TLaunch.sol";
import {IERC20T, IERC20THook, IPositionManager, PoolKey} from "../src/interfaces/IERC20T.sol";
import {IERC20TFactory} from "../src/interfaces/IERC20TFactory.sol";
import {MainnetState} from "./fixtures/MainnetState.sol";
import {Vm} from "forge-std/Vm.sol";
import {SwapHarness} from "./helpers/SwapHarness.sol";
import {ReentryProbe} from "./helpers/ReentryProbe.sol";
import {HolderProbe} from "./helpers/HolderProbe.sol";

interface ITokenOwnerControls {
    function setTaxBps(uint16 bps) external;
    function setFeeRecipient(address recipient) external;
    function setFeeDecayRecipient(address recipient) external;
    function setDistributors(address[] calldata accounts, bool allowed) external;
    function setUseGlobalDistributors(bool enabled) external;
    function isDistributor(address account) external view returns (bool);
    function isLocalDistributor(address account) external view returns (bool);
    function useGlobalDistributors() external view returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address holder, address spender) external view returns (uint256);
}

contract ERC20TLaunchTest is MainnetState {
    address internal constant OWNER = 0x3d6a89C8751a45DD577a4C1F3b34E71C58236193;
    uint256 internal constant PRICE = 540_540_540_540;
    // InvalidTransfer(): the implementation's transfer-policy error.
    bytes4 internal constant INVALID_TRANSFER = 0x2f352531;
    ERC20TLaunch internal app;

    function setUp() public {
        loadMainnetState();
        app = new ERC20TLaunch(OWNER);
    }

    function test_realMainnetLaunchAndLock() public {
        address created = _launch(PRICE, false);
        assertEq(IERC20T(created).owner(), OWNER);
        assertEq(IERC20T(created).balanceOf(OWNER), 50_000_000 ether);
        assertEq(
            IERC20T(created).balanceOf(app.POOL_MANAGER()) + IERC20T(created).balanceOf(created),
            950_000_000 ether
        );
        assertEq(uint256(app.status()), uint256(ERC20TLaunch.Status.Launched));
        assertEq(IPositionManager(app.POSITION_MANAGER()).ownerOf(app.positionId()), address(uint160(0xdead)));
        assertGt(IPositionManager(app.POSITION_MANAGER()).getPositionLiquidity(app.positionId()), 0);
        assertFalse(app.wasFirst());
        assertEq(app.launchBlock(), block.number);
        assertEq(app.launchedAt(), block.timestamp);
        assertEq(app.requestedPriceX18(), PRICE);
        assertEq(created.balance, 0);
        assertEq(address(app).balance, 0);
        assertEq(IERC20T(created).balanceOf(address(app)), 0);
        assertEq(IERC20T(created).balanceOf(app.FACTORY()), 0);
        _assertConfig(created);
    }

    function test_factoryMatchesRequestedConfig() public {
        IERC20TFactory.TokenConfig memory config = app.tokenConfig();
        address factory = app.FACTORY();
        vm.prank(OWNER);
        address created = IERC20TFactory(factory).createAndLaunchAtPrice(config, 500, 540_540_540_540);
        IERC20T t = IERC20T(created);
        assertEq(t.balanceOf(app.POOL_MANAGER()) + t.balanceOf(created), app.LIQUIDITY_SUPPLY());
        assertLe(t.balanceOf(created), app.MAX_LIQUIDITY_DUST());
        assertTrue(t.launched());
        _assertConfig(created);
    }

    function test_selectorMatchesObservedMainnetCalldata() public pure {
        assertEq(IERC20TFactory.createAndLaunchAtPrice.selector, bytes4(0xfe30ec00));
    }

    function test_onlyOwnerMayLaunch() public {
        vm.expectRevert(ERC20TLaunch.Unauthorized.selector);
        app.launch(PRICE, block.timestamp, false);
        assertEq(uint256(app.status()), 0);
    }

    function testFuzz_nonOwnerCannotLaunch(address caller) public {
        vm.assume(caller != OWNER);
        vm.prank(caller);
        vm.expectRevert(ERC20TLaunch.Unauthorized.selector);
        app.launch(PRICE, block.timestamp, false);
    }

    function test_wrongChain() public {
        vm.chainId(31337);
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.WrongChain.selector);
        app.launch(PRICE, block.timestamp, false);
    }

    function test_rejectsSecondLaunch() public {
        address created = _launch(PRICE, false);
        uint64 nonceBefore = vm.getNonce(app.FACTORY());
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.AlreadyLaunched.selector);
        app.launch(PRICE, block.timestamp, false);
        assertEq(app.token(), created);
        assertEq(vm.getNonce(app.FACTORY()), nonceBefore);
    }

    function test_expiredDeadline() public {
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidDeadline.selector);
        app.launch(PRICE, block.timestamp - 1, false);
    }

    function test_distantDeadline() public {
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidDeadline.selector);
        app.launch(PRICE, block.timestamp + 1801, false);
    }

    function test_deadlineBoundaryAccepted() public {
        vm.prank(OWNER);
        app.launch(PRICE, block.timestamp, false);
        assertEq(uint256(app.status()), 2);
    }

    function testFuzz_invalidPrices(uint256 price) public {
        vm.assume(price == 0 || price > 1e18);
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidPrice.selector);
        app.launch(price, block.timestamp, false);
    }

    function test_zeroPrice() public {
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidPrice.selector);
        app.launch(0, block.timestamp, false);
    }

    function test_failsClosedIfAnyDependencyChanges() public {
        address[8] memory dependencies = [
            app.FACTORY(),
            app.IMPLEMENTATION(),
            app.HOOK(),
            app.POSITION_MANAGER(),
            app.POOL_MANAGER(),
            app.PERMIT2(),
            app.IMD(),
            app.IMD_ETH_HOOK()
        ];
        for (uint256 i; i < dependencies.length; i++) {
            bytes memory original = dependencies[i].code;
            vm.etch(dependencies[i], hex"00");
            vm.prank(OWNER);
            vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, dependencies[i]));
            app.launch(PRICE, block.timestamp, false);
            assertEq(uint256(app.status()), 0);
            vm.etch(dependencies[i], original);
        }
    }

    function test_wrongImplementationReferenceRejected() public {
        address factory = app.FACTORY();
        vm.mockCall(factory, abi.encodeWithSignature("implementation()"), abi.encode(OWNER));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, factory));
        app.launch(PRICE, block.timestamp, false);
    }

    function test_wrongIMDDecimalsRejected() public {
        address imd = app.IMD();
        vm.mockCall(imd, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, imd));
        app.launch(PRICE, block.timestamp, false);
    }

    function test_unconfiguredProtocolRecipientRejected() public {
        address hook = app.HOOK();
        vm.mockCall(hook, abi.encodeWithSignature("protocolFeeRecipient()"), abi.encode(address(0)));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, hook));
        app.launch(PRICE, block.timestamp, false);
    }

    function test_disabledFeeConversionRouteRejected() public {
        address hook = app.HOOK();
        vm.mockCall(
            hook, abi.encodeWithSignature("externalBases(address)", app.IMD()), abi.encode(true, false)
        );
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, hook));
        app.launch(PRICE, block.timestamp, false);
    }

    function test_changedFeeConversionPoolRejected() public {
        address hook = app.HOOK();
        PoolKey memory route = IERC20THook(hook).externalBasePool(app.IMD());
        route.fee = 3000;
        vm.mockCall(hook, abi.encodeWithSignature("externalBasePool(address)", app.IMD()), abi.encode(route));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, hook));
        app.launch(PRICE, block.timestamp, false);
    }

    function test_strictFirstRejectsExistingTokenWithoutSideEffects() public {
        assertEq(app.firstTokenAddress(), 0xBBe9d1EcBae3D811642f3DFFDF8bC5Ae8ea4514f);
        assertFalse(app.firstSlotAvailable());
        uint64 nonceBefore = vm.getNonce(app.FACTORY());
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.FirstSlotTaken.selector);
        app.launch(PRICE, block.timestamp, true);
        assertEq(uint256(app.status()), 0);
        assertEq(vm.getNonce(app.FACTORY()), nonceBefore);
    }

    function test_firstLaunchOnAnUnusedFactoryState() public {
        address first = app.firstTokenAddress();
        vm.etch(first, "");
        vm.resetNonce(first);
        vm.setNonceUnsafe(app.FACTORY(), 2);
        assertTrue(app.firstSlotAvailable());
        assertEq(_launch(PRICE, true), first);
        assertTrue(app.wasFirst());
        assertFalse(app.firstSlotAvailable());
    }

    function test_firstProbeAloneCannotMislabelLaterNonce() public {
        address first = app.firstTokenAddress();
        vm.etch(first, "");
        vm.resetNonce(first);
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidLaunchResult.selector);
        app.launch(PRICE, block.timestamp, true);
        assertEq(uint256(app.status()), 0);
    }

    function test_factoryFailureRollsBackAndCanRetry() public {
        address factory = app.FACTORY();
        vm.mockCallRevert(
            factory, abi.encodePacked(IERC20TFactory.createAndLaunchAtPrice.selector), "factory failure"
        );
        vm.prank(OWNER);
        vm.expectRevert(bytes("factory failure"));
        app.launch(PRICE, block.timestamp, false);
        assertEq(uint256(app.status()), 0);
        assertEq(app.token(), address(0));
        vm.clearMockedCalls();
        _launch(PRICE, false);
    }

    function test_ownerCallbackCannotReenterLaunch() public {
        ReentryProbe callbackOwner = new ReentryProbe();
        ERC20TLaunch target = new ERC20TLaunch(address(callbackOwner));
        vm.mockFunction(
            target.FACTORY(),
            address(callbackOwner),
            abi.encodePacked(IERC20TFactory.createAndLaunchAtPrice.selector)
        );
        vm.expectRevert(ReentryProbe.GuardObserved.selector);
        callbackOwner.execute(target);
        assertEq(uint256(target.status()), 0);
        assertEq(target.token(), address(0));
    }

    function test_factoryReturningAnEOAFailsAtomically() public {
        vm.mockCall(
            app.FACTORY(), abi.encodePacked(IERC20TFactory.createAndLaunchAtPrice.selector), abi.encode(OWNER)
        );
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidLaunchResult.selector);
        app.launch(PRICE, block.timestamp, false);
        assertEq(uint256(app.status()), 0);
    }

    function test_missingCreatorAllocationRollsBackCreation() public {
        address predicted = _nextToken();
        vm.mockCall(predicted, abi.encodeWithSignature("balanceOf(address)", OWNER), abi.encode(uint256(1)));
        // mockCall injects code into an absent account; remove it so CREATE itself remains real.
        vm.etch(predicted, "");
        vm.resetNonce(predicted);
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidLaunchResult.selector);
        app.launch(PRICE, block.timestamp, false);
        assertEq(predicted.code.length, 0);
        assertEq(uint256(app.status()), 0);
    }

    function test_unlockedPositionRollsBackCreation() public {
        address pm = app.POSITION_MANAGER();
        uint256 id = IPositionManager(pm).nextTokenId();
        address predicted = _nextToken();
        vm.mockCall(pm, abi.encodeWithSignature("ownerOf(uint256)", id), abi.encode(OWNER));
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.PositionNotLocked.selector);
        app.launch(PRICE, block.timestamp, false);
        assertEq(predicted.code.length, 0);
        assertEq(IPositionManager(pm).nextTokenId(), id);
    }

    function test_emptyPositionRollsBackCreation() public {
        address pm = app.POSITION_MANAGER();
        uint256 id = IPositionManager(pm).nextTokenId();
        vm.mockCall(pm, abi.encodeWithSignature("getPositionLiquidity(uint256)", id), abi.encode(uint128(0)));
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.PositionNotLocked.selector);
        app.launch(PRICE, block.timestamp, false);
        assertEq(uint256(app.status()), 0);
    }

    function testFuzz_pricesConserveSupply(uint256 priceSeed) public {
        uint256 price = bound(priceSeed, 1, 1e18);
        address created = _launch(price, false);
        IERC20T t = IERC20T(created);
        uint256 dust = t.balanceOf(created);
        assertLe(dust, app.MAX_LIQUIDITY_DUST());
        assertEq(t.balanceOf(OWNER) + t.balanceOf(app.POOL_MANAGER()) + dust, t.totalSupply());
        assertEq(t.totalSupply(), 1_000_000_000 ether);
    }

    function testFuzz_reverseOrderPricesConserveSupply(uint256 priceSeed) public {
        _useTokenOrder(false);
        address created = _launch(bound(priceSeed, 1, 1e18), false);
        IERC20T t = IERC20T(created);
        assertEq(t.balanceOf(OWNER) + t.balanceOf(app.POOL_MANAGER()) + t.balanceOf(created), t.totalSupply());
        assertLe(t.balanceOf(created), app.MAX_LIQUIDITY_DUST());
    }

    function test_bothCurrencySortOrdersLaunch() public {
        _useTokenOrder(false);
        address created = _launch(PRICE, false);
        assertGt(uint160(created), uint160(app.IMD()));
        assertEq(IERC20T(created).poolKey().currency0, app.IMD());
    }

    function test_taxDecayExactBoundaries() public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        uint256 start = block.timestamp;
        assertEq(t.taxBps(), 9900);
        vm.warp(start + 59);
        assertEq(t.taxBps(), 9900);
        vm.warp(start + 60);
        assertEq(t.taxBps(), 9800);
        vm.warp(start + 119);
        assertEq(t.taxBps(), 9800);
        vm.warp(start + 120);
        assertEq(t.taxBps(), 9700);
        vm.warp(start + 97 * 60);
        assertEq(t.taxBps(), 200);
        vm.warp(start + 98 * 60 - 1);
        assertEq(t.taxBps(), 200);
        vm.warp(start + 98 * 60);
        assertEq(t.taxBps(), 100);
        vm.warp(start + 10 * 365 days);
        assertEq(t.taxBps(), 100);
    }

    function testFuzz_taxDecayNeverUnderflows(uint32 elapsed) public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        vm.warp(block.timestamp + elapsed);
        uint256 steps = uint256(elapsed) / 60;
        assertEq(t.taxBps(), steps >= 98 ? 100 : 9900 - steps * 100);
    }

    function test_cannotSendEtherToLaunch() public {
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        (bool ok,) = address(app).call{value: 1}(abi.encodeCall(app.launch, (PRICE, block.timestamp, false)));
        assertFalse(ok);
        assertEq(address(app).balance, 0);
    }

    function test_initialPriceWithinOneTickSpacingOfRequestedQuotePrice() public {
        _assertOpeningPrice();
    }

    function test_reverseCurrencyOrderInitialPrice() public {
        _useTokenOrder(false);
        _assertOpeningPrice();
    }

    function _assertOpeningPrice() internal {
        vm.recordLogs();
        address created = _launch(PRICE, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == app.POOL_MANAGER() && logs[i].topics[0] == topic) {
                (,,, uint160 sqrtPrice,) = abi.decode(logs[i].data, (uint24, int24, address, uint160, int24));
                uint256 ratio = (uint256(sqrtPrice) * 1e18 / (1 << 96)) * sqrtPrice / (1 << 96);
                uint256 actual = created < app.IMD() ? ratio : 1e36 / ratio;
                assertApproxEqRel(actual, PRICE, 0.0061 ether);
                assertEq(logs[i].topics[1], app.poolId());
                found = true;
            }
        }
        assertTrue(found, "pool initialization event missing");
    }

    function test_actualBuyAndSellAgainstMainnetPoolAndHook() public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        SwapHarness router = new SwapHarness(app.POOL_MANAGER());
        address quote = app.IMD();
        deal(quote, address(router), 10 ether);
        address protocol = IERC20THook(app.HOOK()).protocolFeeRecipient();
        uint256 ownerETH = OWNER.balance;
        uint256 protocolETH = protocol.balance;
        vm.recordLogs();
        uint256 output = router.trade(t.poolKey(), quote < address(t), 1 ether, 1);
        uint256 grossOutput =
            _grossSwapOutput(vm.getRecordedLogs(), app.poolId(), address(router), quote < address(t));
        assertEq(output, grossOutput - grossOutput * 9900 / 10000);
        _assertETHFeeSplit(ownerETH, protocolETH, protocol, 9900);
        assertGt(output, 0);
        assertEq(t.balanceOf(address(router)), output);
        assertEq(IERC20T(quote).balanceOf(address(router)), 9 ether);
        // The token inventory plus owner's fixed allocation and rounding dust is conserved after a real buy.
        assertEq(
            t.balanceOf(address(router)) + t.balanceOf(app.POOL_MANAGER()) + t.balanceOf(OWNER)
                + t.balanceOf(address(t)),
            t.totalSupply()
        );
        vm.warp(block.timestamp + 98 minutes);
        uint256 quoteBefore = IERC20T(quote).balanceOf(address(router));
        ownerETH = OWNER.balance;
        protocolETH = protocol.balance;
        vm.recordLogs();
        uint256 returned = router.trade(t.poolKey(), address(t) < quote, output / 2, 1);
        grossOutput =
            _grossSwapOutput(vm.getRecordedLogs(), app.poolId(), address(router), address(t) < quote);
        assertEq(returned, grossOutput - grossOutput * 100 / 10000);
        _assertETHFeeSplit(ownerETH, protocolETH, protocol, 100);
        assertGt(returned, 0);
        assertEq(IERC20T(quote).balanceOf(address(router)), quoteBefore + returned);
        assertEq(t.taxBps(), 100);
    }

    function _assertETHFeeSplit(uint256 ownerBefore, uint256 protocolBefore, address protocol, uint256 taxBps)
        internal
        view
    {
        uint256 ownerPaid = OWNER.balance - ownerBefore;
        uint256 protocolPaid = protocol.balance - protocolBefore;
        assertGt(ownerPaid, 0);
        assertGt(protocolPaid, 0);
        // The 15 bps share comes out of the token tax, rather than being added to the trader's rate.
        assertEq(protocolPaid, (ownerPaid + protocolPaid) * 15 / taxBps);
    }

    function _grossSwapOutput(Vm.Log[] memory logs, bytes32 id, address router, bool zeroForOne)
        internal
        pure
        returns (uint256)
    {
        bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].topics[0] == topic && logs[i].topics[1] == id
                    && logs[i].topics[2] == bytes32(uint256(uint160(router)))
            ) {
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                int128 amountOut = zeroForOne ? amount1 : amount0;
                assertGt(amountOut, 0);
                return uint256(uint128(amountOut));
            }
        }
        revert("swap event missing");
    }

    function test_tradeSlippageFailureLeavesFundsUnchanged() public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        SwapHarness router = new SwapHarness(app.POOL_MANAGER());
        address quote = app.IMD();
        deal(quote, address(router), 10 ether);
        PoolKey memory key = t.poolKey();
        vm.expectRevert(bytes("slippage"));
        router.trade(key, quote < address(t), 1 ether, type(uint128).max);
        assertEq(IERC20T(quote).balanceOf(address(router)), 10 ether);
        assertEq(t.balanceOf(address(router)), 0);
    }

    function test_underlyingOwnerPowersRemainAndAreDocumented() public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        ITokenOwnerControls controls = ITokenOwnerControls(address(t));
        vm.expectRevert();
        controls.setTaxBps(50);
        vm.prank(OWNER);
        vm.expectRevert(bytes4(0x07c60155)); // TaxDecayActive(): owner cannot edit tax during decay.
        controls.setTaxBps(50);
        vm.warp(block.timestamp + 98 minutes);
        vm.startPrank(OWNER);
        controls.setTaxBps(50);
        assertEq(t.restingTaxBps(), 50);
        vm.expectRevert();
        controls.setTaxBps(29);
        vm.expectRevert();
        controls.setTaxBps(501);
        controls.setFeeRecipient(address(this));
        controls.setFeeDecayRecipient(address(this));
        vm.stopPrank();
        assertEq(t.feeRecipient(), address(this));
        assertEq(t.feeDecayRecipient(), address(this));
        vm.warp(block.timestamp + 100 minutes);
        assertEq(t.taxBps(), 50);
    }

    function test_transferPolicySelectorsMatchTheVerifiedImplementation() public pure {
        // Signatures from the implementation's verified source; selectors are in its runtime dispatcher.
        assertEq(ITokenOwnerControls.setDistributors.selector, bytes4(0xb12d85ca));
        assertEq(ITokenOwnerControls.setUseGlobalDistributors.selector, bytes4(0xc82d2bbf));
        assertEq(ITokenOwnerControls.isDistributor.selector, bytes4(0x8f0c86fa));
        assertEq(ITokenOwnerControls.isLocalDistributor.selector, bytes4(0x997fe757));
        assertEq(ITokenOwnerControls.useGlobalDistributors.selector, bytes4(0xc174c40f));
    }

    function test_directWalletTransfersSucceedDuringAndAfterDecay() public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        ITokenOwnerControls token = ITokenOwnerControls(address(t));
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        // A transfer from or to the owner always passes.
        vm.prank(OWNER);
        assertTrue(token.transfer(alice, 1_000 ether));
        // A wallet sending its own balance in its own transaction passes while the launch tax is 99%.
        assertEq(t.taxBps(), 9900);
        vm.prank(alice, alice);
        assertTrue(token.transfer(bob, 400 ether));
        assertEq(t.balanceOf(bob), 400 ether);
        vm.warp(block.timestamp + 98 minutes);
        assertEq(t.taxBps(), 100);
        vm.prank(bob, bob);
        assertTrue(token.transfer(alice, 100 ether));
        assertEq(t.balanceOf(alice), 700 ether);
        assertEq(t.balanceOf(bob), 300 ether);
        // Wallet-to-wallet transfers are untaxed; the tax applies to pool swaps only.
        assertEq(t.balanceOf(alice) + t.balanceOf(bob), 1_000 ether);
    }

    function test_holderTransfersThroughSpendersOrContractsRevertWithInvalidTransfer() public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        ITokenOwnerControls token = ITokenOwnerControls(address(t));
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        HolderProbe custody = new HolderProbe();
        vm.prank(OWNER);
        token.transfer(alice, 1_000 ether);
        vm.prank(OWNER);
        token.transfer(address(custody), 1_000 ether);
        // A spender cannot move a holder's balance, even with an allowance.
        vm.prank(alice);
        token.approve(bob, 500 ether);
        assertEq(token.allowance(alice, bob), 500 ether);
        vm.prank(bob, bob);
        vm.expectRevert(INVALID_TRANSFER);
        token.transferFrom(alice, bob, 500 ether);
        // A holder that has code cannot send to a wallet.
        vm.expectRevert(INVALID_TRANSFER);
        custody.sendTokens(address(t), bob, 1 ether);
        // A wallet cannot send to code that is not the owner, the pool or an approved distributor.
        vm.prank(alice, alice);
        vm.expectRevert(INVALID_TRANSFER);
        token.transfer(address(custody), 1 ether);
        // A wallet call relayed by another account (tx.origin differs) is not a direct wallet call.
        vm.prank(alice);
        vm.expectRevert(INVALID_TRANSFER);
        token.transfer(bob, 1 ether);
        // The same policy holds after the launch tax has fully decayed.
        vm.warp(block.timestamp + 98 minutes);
        vm.expectRevert(INVALID_TRANSFER);
        custody.sendTokens(address(t), bob, 1 ether);
        vm.prank(bob, bob);
        vm.expectRevert(INVALID_TRANSFER);
        token.transferFrom(alice, bob, 500 ether);
        assertEq(t.balanceOf(alice), 1_000 ether);
        assertEq(t.balanceOf(address(custody)), 1_000 ether);
        assertEq(t.balanceOf(bob), 0);
    }

    function test_ownerCanApproveAndRevokeDistributorContracts() public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        ITokenOwnerControls token = ITokenOwnerControls(address(t));
        address bob = makeAddr("bob");
        HolderProbe distributor = new HolderProbe();
        address[] memory accounts = new address[](1);
        accounts[0] = address(distributor);
        vm.prank(OWNER);
        token.transfer(address(distributor), 1_000 ether);
        // The implementation opts every new token into the hook owner's shared registry.
        assertTrue(token.useGlobalDistributors());
        assertFalse(token.isDistributor(address(distributor)));
        vm.expectRevert();
        token.setDistributors(accounts, true);
        vm.prank(OWNER);
        token.setDistributors(accounts, true);
        assertTrue(token.isLocalDistributor(address(distributor)));
        assertTrue(token.isDistributor(address(distributor)));
        assertTrue(distributor.sendTokens(address(t), bob, 10 ether));
        assertEq(t.balanceOf(bob), 10 ether);
        // Approved code can also pull from a wallet that granted it an allowance.
        vm.prank(bob);
        token.approve(address(distributor), 10 ether);
        assertTrue(distributor.pullTokens(address(t), bob, address(distributor), 4 ether));
        assertEq(t.balanceOf(bob), 6 ether);
        vm.prank(OWNER);
        token.setDistributors(accounts, false);
        assertFalse(token.isDistributor(address(distributor)));
        vm.expectRevert(INVALID_TRANSFER);
        distributor.sendTokens(address(t), bob, 1 ether);
        // Only code can be approved; a wallet cannot become a distributor.
        address[] memory wallets = new address[](1);
        wallets[0] = bob;
        vm.prank(OWNER);
        vm.expectRevert();
        token.setDistributors(wallets, true);
        // The owner can opt out of the shared registry.
        vm.expectRevert();
        token.setUseGlobalDistributors(false);
        vm.prank(OWNER);
        token.setUseGlobalDistributors(false);
        assertFalse(token.useGlobalDistributors());
    }

    function _launch(uint256 price, bool first) internal returns (address) {
        vm.prank(OWNER);
        return app.launch(price, block.timestamp + 300, first);
    }

    function _nextToken() internal view returns (address) {
        return vm.computeCreateAddress(app.FACTORY(), vm.getNonce(app.FACTORY()));
    }

    function _useTokenOrder(bool tokenIsCurrency0) internal {
        for (uint64 nonce = 5; nonce < 100; nonce++) {
            address candidate = vm.computeCreateAddress(app.FACTORY(), nonce);
            if ((candidate < app.IMD()) == tokenIsCurrency0 && candidate.code.length == 0) {
                vm.setNonceUnsafe(app.FACTORY(), nonce);
                return;
            }
        }
        revert("no candidate");
    }

    function _assertConfig(address created) internal view {
        IERC20T t = IERC20T(created);
        assertEq(t.name(), "erc20t");
        assertEq(t.symbol(), "ERC20T");
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), app.TOTAL_SUPPLY());
        assertEq(t.owner(), OWNER);
        assertEq(t.feeRecipient(), OWNER);
        assertEq(t.feeDecayRecipient(), OWNER);
        assertEq(t.restingTaxBps(), 100);
        assertEq(t.launchTaxBps(), 9900);
        assertEq(t.taxBps(), 9900);
        assertEq(t.TAX_DECAY_STEP_BPS(), 100);
        assertEq(t.taxDecayIntervalSeconds(), 60);
        assertEq(t.hook(), app.HOOK());
        assertEq(t.quoteToken(), app.IMD());
        assertEq(t.poolManager(), app.POOL_MANAGER());
        assertEq(t.positionManager(), app.POSITION_MANAGER());
        assertEq(t.permit2(), app.PERMIT2());
    }
}
