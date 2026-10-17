// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20TLaunch} from "../src/ERC20TLaunch.sol";
import {IERC20T, IERC20THook, IPositionManager, PoolKey} from "../src/interfaces/IERC20T.sol";
import {IERC20TFactory} from "../src/interfaces/IERC20TFactory.sol";
import {MainnetState} from "./fixtures/MainnetState.sol";
import {SwapHarness, ITestToken} from "./helpers/SwapHarness.sol";

interface IPositionTransfer {
    function transferFrom(address from, address to, uint256 id) external;
    function approve(address spender, uint256 id) external;
}

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @notice Edge inputs and postcondition failure paths of the one-use launch adapter, pinned as
///         plain unit tests beside the fuzzed ones: the price bounds, the deadline window boundary,
///         the exact event, every postcondition the adapter rejects, and what the lock really locks.
contract ERC20TLaunchEdgesTest is MainnetState {
    address internal constant OWNER = 0x3d6a89C8751a45DD577a4C1F3b34E71C58236193;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant PRICE = 540_540_540_540;

    event Launched(
        address indexed token,
        bytes32 indexed poolId,
        address indexed owner,
        uint256 positionId,
        uint256 requestedPriceX18,
        bool firstFactoryToken
    );

    ERC20TLaunch internal app;

    function setUp() public {
        loadMainnetState();
        app = new ERC20TLaunch(OWNER);
    }

    // ---------------------------------------------------------------- price bounds

    function test_priceLowerBoundOneWeiLaunches() public {
        address created = _launch(1, false);
        _assertConserved(created);
        assertEq(IPositionManager(app.POSITION_MANAGER()).ownerOf(app.positionId()), DEAD);
    }

    function test_priceUpperBoundOneIMDLaunches() public {
        address created = _launch(1e18, false);
        _assertConserved(created);
        assertEq(app.requestedPriceX18(), 1e18);
    }

    function test_priceJustAboveUpperBoundRejected() public {
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidPrice.selector);
        app.launch(1e18 + 1, block.timestamp, false);
    }

    function test_priceMaxUintRejectedBeforeAnyExternalCall() public {
        uint64 nonce = vm.getNonce(app.FACTORY());
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidPrice.selector);
        app.launch(type(uint256).max, block.timestamp, false);
        assertEq(vm.getNonce(app.FACTORY()), nonce);
    }

    // ---------------------------------------------------------------- deadline window

    function test_deadlineAtExactlyThirtyMinutesAccepted() public {
        vm.prank(OWNER);
        app.launch(PRICE, block.timestamp + 30 minutes, false);
        assertEq(uint256(app.status()), 2);
    }

    function test_deadlineOneSecondPastThirtyMinutesRejected() public {
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidDeadline.selector);
        app.launch(PRICE, block.timestamp + 30 minutes + 1, false);
    }

    function test_zeroDeadlineRejected() public {
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidDeadline.selector);
        app.launch(PRICE, 0, false);
    }

    function test_maxDeadlineRejected() public {
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidDeadline.selector);
        app.launch(PRICE, type(uint256).max, false);
    }

    function testFuzz_deadlineInsideWindowAccepted(uint256 delaySeed) public {
        uint256 delay = bound(delaySeed, 0, 30 minutes);
        vm.prank(OWNER);
        app.launch(PRICE, block.timestamp + delay, false);
        assertEq(uint256(app.status()), 2);
    }

    function testFuzz_deadlineOutsideWindowRejected(uint256 delaySeed, bool past) public {
        uint256 deadline;
        if (past) {
            deadline = bound(delaySeed, 0, block.timestamp - 1);
        } else {
            deadline = bound(delaySeed, block.timestamp + 30 minutes + 1, type(uint256).max);
        }
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidDeadline.selector);
        app.launch(PRICE, deadline, false);
    }

    function testFuzz_anyOtherChainRejected(uint256 chainSeed) public {
        uint256 chain = bound(chainSeed, 2, type(uint64).max);
        vm.chainId(chain);
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.WrongChain.selector);
        app.launch(PRICE, block.timestamp, false);
        assertEq(uint256(app.status()), 0);
    }

    // ---------------------------------------------------------------- receipt

    function test_launchedEventCarriesTheExactReceipt() public {
        address predicted = vm.computeCreateAddress(app.FACTORY(), vm.getNonce(app.FACTORY()));
        uint256 id = IPositionManager(app.POSITION_MANAGER()).nextTokenId();
        (address c0, address c1) = predicted < app.IMD() ? (predicted, app.IMD()) : (app.IMD(), predicted);
        bytes32 expectedPoolId = keccak256(
            abi.encode(PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: app.HOOK()}))
        );
        vm.expectEmit(true, true, true, true, address(app));
        emit Launched(predicted, expectedPoolId, OWNER, id, PRICE, false);
        address created = _launch(PRICE, false);
        assertEq(created, predicted);
        assertEq(app.poolId(), expectedPoolId);
        assertEq(app.positionId(), id);
    }

    function test_launchReturnsTheRecordedToken() public {
        vm.prank(OWNER);
        address created = app.launch(PRICE, block.timestamp + 1, false);
        assertEq(created, app.token());
        assertTrue(created != address(0));
    }

    function test_notRequiringFirstStillRecordsFirstWhenSlotIsEmpty() public {
        address first = app.firstTokenAddress();
        vm.etch(first, "");
        vm.resetNonce(first);
        vm.setNonceUnsafe(app.FACTORY(), 2);
        address created = _launch(PRICE, false);
        assertEq(created, first);
        assertTrue(app.wasFirst());
    }

    function test_tokenConfigIsExactlyTheBrief() public view {
        IERC20TFactory.TokenConfig memory c = app.tokenConfig();
        assertEq(c.name, "erc20t");
        assertEq(c.symbol, "ERC20T");
        assertEq(c.totalSupply, 1_000_000_000 ether);
        assertEq(c.liquiditySupply, 950_000_000 ether);
        assertEq(c.owner, OWNER);
        assertEq(c.hook, 0xed9A04Fa6693e754661A22502524DF9b1857e544);
        assertEq(c.quoteToken, 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(c.positionManager, 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        assertEq(c.permit2, 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        assertEq(c.restingTaxBps, 100);
        assertEq(c.feeRecipient, OWNER);
        assertEq(c.launchTaxBps, 9900);
        assertEq(c.taxDecayIntervalSeconds, 60);
        assertEq(c.feeDecayRecipient, OWNER);
        assertEq(app.CREATOR_BPS(), 500);
        assertEq(uint256(app.CREATOR_BPS()) * c.totalSupply / 10_000, app.CREATOR_SUPPLY());
        assertEq(app.FACTORY(), 0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173);
    }

    function test_constructorRejectsItsOwnAddressAsOwner() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(ERC20TLaunch.InvalidOwner.selector);
        new ERC20TLaunch(predicted);
    }

    // ---------------------------------------------------------------- dependency configuration

    function test_protocolFeeShareChangeRejected() public {
        address hook = app.HOOK();
        vm.mockCall(hook, abi.encodeWithSignature("PROTOCOL_FEE_BPS()"), abi.encode(uint16(16)));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, hook));
        app.launch(PRICE, block.timestamp, false);
    }

    function test_quoteTokenNoLongerAnExternalBaseRejected() public {
        address hook = app.HOOK();
        vm.mockCall(
            hook, abi.encodeWithSignature("externalBases(address)", app.IMD()), abi.encode(false, true)
        );
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, hook));
        app.launch(PRICE, block.timestamp, false);
    }

    function test_conversionRouteHookOrSpacingChangeRejected() public {
        address hook = app.HOOK();
        PoolKey memory route = IERC20THook(hook).externalBasePool(app.IMD());
        PoolKey memory changedHook = route;
        changedHook.hooks = address(0xBEEF);
        vm.mockCall(
            hook, abi.encodeWithSignature("externalBasePool(address)", app.IMD()), abi.encode(changedHook)
        );
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, hook));
        app.launch(PRICE, block.timestamp, false);
        vm.clearMockedCalls();

        PoolKey memory changedSpacing = route;
        changedSpacing.tickSpacing = 10;
        vm.mockCall(
            hook, abi.encodeWithSignature("externalBasePool(address)", app.IMD()), abi.encode(changedSpacing)
        );
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, hook));
        app.launch(PRICE, block.timestamp, false);
        vm.clearMockedCalls();

        PoolKey memory changedQuote = route;
        changedQuote.currency1 = address(0xBEEF);
        vm.mockCall(
            hook, abi.encodeWithSignature("externalBasePool(address)", app.IMD()), abi.encode(changedQuote)
        );
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC20TLaunch.DependencyChanged.selector, hook));
        app.launch(PRICE, block.timestamp, false);
    }

    function test_dependencyCheckIsFreeOfSideEffectsAndPublic() public view {
        app.checkDependencies();
        assertEq(uint256(app.status()), 0);
    }

    // ---------------------------------------------------------------- postcondition failure paths

    function test_positionIdDriftRollsBack() public {
        address pm = app.POSITION_MANAGER();
        uint256 id = IPositionManager(pm).nextTokenId();
        // Mocked to a constant, so the manager appears not to have minted the expected position.
        vm.mockCall(pm, abi.encodeWithSignature("nextTokenId()"), abi.encode(id));
        address predicted = _nextToken();
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.PositionNotLocked.selector);
        app.launch(PRICE, block.timestamp, false);
        assertEq(predicted.code.length, 0);
        assertEq(uint256(app.status()), 0);
    }

    function test_positionForAnotherPoolRollsBack() public {
        address pm = app.POSITION_MANAGER();
        uint256 id = IPositionManager(pm).nextTokenId();
        PoolKey memory other = PoolKey({
            currency0: address(0),
            currency1: app.IMD(),
            fee: 10000,
            tickSpacing: 60,
            hooks: app.IMD_ETH_HOOK()
        });
        vm.mockCall(
            pm, abi.encodeWithSignature("getPoolAndPositionInfo(uint256)", id), abi.encode(other, uint256(0))
        );
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidLaunchResult.selector);
        app.launch(PRICE, block.timestamp, false);
        assertEq(uint256(app.status()), 0);
    }

    function test_tokenReportingAnotherRestingTaxRollsBack() public {
        _mockOnFutureToken(abi.encodeWithSignature("restingTaxBps()"), abi.encode(uint16(50)));
        _expectInvalidLaunchResult();
    }

    function test_tokenReportingNotLaunchedRollsBack() public {
        _mockOnFutureToken(abi.encodeWithSignature("launched()"), abi.encode(false));
        _expectInvalidLaunchResult();
    }

    function test_tokenReportingAnotherOwnerRollsBack() public {
        _mockOnFutureToken(abi.encodeWithSignature("owner()"), abi.encode(address(0xBEEF)));
        _expectInvalidLaunchResult();
    }

    function test_tokenReportingWrongLaunchTaxRollsBack() public {
        _mockOnFutureToken(abi.encodeWithSignature("taxBps()"), abi.encode(uint16(9800)));
        _expectInvalidLaunchResult();
    }

    function test_tokenReportingWrongSymbolRollsBack() public {
        _mockOnFutureToken(abi.encodeWithSignature("symbol()"), abi.encode("ERC20"));
        _expectInvalidLaunchResult();
    }

    function test_tokenReportingAnotherFeeRecipientRollsBack() public {
        _mockOnFutureToken(abi.encodeWithSignature("feeRecipient()"), abi.encode(address(0xBEEF)));
        _expectInvalidLaunchResult();
    }

    function test_tokenReportingExcessDustRollsBack() public {
        address predicted = _nextToken();
        _mockOnFutureToken(
            abi.encodeWithSignature("balanceOf(address)", predicted), abi.encode(app.MAX_LIQUIDITY_DUST() + 1)
        );
        _expectInvalidLaunchResult();
    }

    function test_tokenReportingInflatedSupplyRollsBack() public {
        _mockOnFutureToken(abi.encodeWithSignature("totalSupply()"), abi.encode(app.TOTAL_SUPPLY() + 1));
        _expectInvalidLaunchResult();
    }

    function test_tokenReportingSixDecimalsRollsBack() public {
        _mockOnFutureToken(abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        _expectInvalidLaunchResult();
    }

    // ---------------------------------------------------------------- what the lock locks

    function test_ownerCannotMoveOrApproveTheLockedPosition() public {
        _launch(PRICE, false);
        IPositionTransfer pm = IPositionTransfer(app.POSITION_MANAGER());
        uint256 id = app.positionId();
        vm.startPrank(OWNER);
        vm.expectRevert();
        pm.transferFrom(DEAD, OWNER, id);
        vm.expectRevert();
        pm.approve(OWNER, id);
        vm.stopPrank();
        assertEq(IPositionManager(address(pm)).ownerOf(id), DEAD);
    }

    /// @dev The creator's unvested 5% is immediately movable by the owner and sellable into the pool
    ///      once the market holds quote token.
    function test_creatorAllocationIsLiquidAndSellable() public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        SwapHarness seller = new SwapHarness(app.POOL_MANAGER());
        vm.prank(OWNER);
        ITestToken(address(t)).transfer(address(seller), 10_000_000 ether);
        assertEq(t.balanceOf(OWNER), app.CREATOR_SUPPLY() - 10_000_000 ether);
        PoolKey memory key = t.poolKey();

        SwapHarness buyer = new SwapHarness(app.POOL_MANAGER());
        deal(app.IMD(), address(buyer), 10 ether);
        assertGt(buyer.trade(key, app.IMD() < address(t), 10 ether, 1), 0);

        uint256 quoteBefore = ITestToken(app.IMD()).balanceOf(address(seller));
        uint256 got = seller.trade(key, address(t) < app.IMD(), 1_000_000 ether, 1);
        assertGt(got, 0);
        assertEq(ITestToken(app.IMD()).balanceOf(address(seller)), quoteBefore + got);
        // Exact-input sells fill only as far as the pool's IMD allows, so part of the input can stay.
        assertLt(t.balanceOf(address(seller)), 10_000_000 ether);
        assertGe(t.balanceOf(address(seller)), 9_000_000 ether);
    }

    function test_supplyIsBurnableByAnyHolder() public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        vm.prank(OWNER);
        IBurnable(address(t)).burn(1 ether);
        assertEq(t.totalSupply(), app.TOTAL_SUPPLY() - 1 ether);
        assertEq(t.balanceOf(OWNER), app.CREATOR_SUPPLY() - 1 ether);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        IBurnable(address(t)).burn(1);
    }

    /// @dev Observed behaviour of the captured token implementation, pinned so a change is noticed.
    ///      It is reported in the findings as an undisclosed property, not asserted as desired:
    ///      a buyer cannot transfer bought tokens to another ordinary address, before or after the
    ///      tax decay, while transfers to the owner succeed.
    function test_observedHolderToHolderTransfersAreRejectedByTheTokenImplementation() public {
        IERC20T t = IERC20T(_launch(PRICE, false));
        SwapHarness buyer = new SwapHarness(app.POOL_MANAGER());
        deal(app.IMD(), address(buyer), 2 ether);
        uint256 bought = buyer.trade(t.poolKey(), app.IMD() < address(t), 2 ether, 1);
        assertGt(bought, 0);
        vm.prank(address(buyer));
        vm.expectRevert(bytes4(0x2f352531));
        ITestToken(address(t)).transfer(address(0xCAFE), 1);
        vm.warp(block.timestamp + 98 minutes);
        vm.prank(address(buyer));
        vm.expectRevert(bytes4(0x2f352531));
        ITestToken(address(t)).transfer(address(0xCAFE), 1);
        vm.prank(address(buyer));
        assertTrue(ITestToken(address(t)).transfer(OWNER, 1));
        assertEq(t.balanceOf(OWNER), app.CREATOR_SUPPLY() + 1);
    }

    function test_lookalikeTokenFromAStrangerDoesNotTouchTheAdapter() public {
        IERC20TFactory.TokenConfig memory config = app.tokenConfig();
        vm.prank(address(0xBEEF));
        address lookalike = IERC20TFactory(app.FACTORY()).createAndLaunchAtPrice(config, 500, PRICE);
        assertEq(IERC20T(lookalike).owner(), OWNER);
        assertEq(uint256(app.status()), 0);
        assertEq(app.token(), address(0));
        address created = _launch(PRICE, false);
        assertTrue(created != lookalike);
        assertEq(app.token(), created);
        assertEq(IERC20T(created).balanceOf(OWNER), app.CREATOR_SUPPLY());
    }

    function test_launchGasFitsComfortablyInABlock() public {
        vm.prank(OWNER);
        uint256 before = gasleft();
        app.launch(PRICE, block.timestamp, false);
        assertLt(before - gasleft(), 5_000_000);
    }

    // ---------------------------------------------------------------- helpers

    function _launch(uint256 price, bool first) internal returns (address) {
        vm.prank(OWNER);
        return app.launch(price, block.timestamp + 300, first);
    }

    function _nextToken() internal view returns (address) {
        return vm.computeCreateAddress(app.FACTORY(), vm.getNonce(app.FACTORY()));
    }

    /// @dev mockCall injects code into an absent account; remove it so the factory's CREATE stays real
    ///      and only the mocked view answers differ on the freshly created token.
    function _mockOnFutureToken(bytes memory data, bytes memory result) internal {
        address predicted = _nextToken();
        vm.mockCall(predicted, data, result);
        vm.etch(predicted, "");
        vm.resetNonce(predicted);
    }

    function _expectInvalidLaunchResult() internal {
        address predicted = _nextToken();
        vm.prank(OWNER);
        vm.expectRevert(ERC20TLaunch.InvalidLaunchResult.selector);
        app.launch(PRICE, block.timestamp, false);
        assertEq(predicted.code.length, 0);
        assertEq(uint256(app.status()), 0);
        assertEq(app.token(), address(0));
    }

    function _assertConserved(address created) internal view {
        IERC20T t = IERC20T(created);
        uint256 dust = t.balanceOf(created);
        assertLe(dust, app.MAX_LIQUIDITY_DUST());
        assertEq(t.balanceOf(OWNER), app.CREATOR_SUPPLY());
        assertEq(t.balanceOf(app.POOL_MANAGER()) + dust, app.LIQUIDITY_SUPPLY());
        assertEq(t.totalSupply(), app.TOTAL_SUPPLY());
        assertGt(IPositionManager(app.POSITION_MANAGER()).getPositionLiquidity(app.positionId()), 0);
    }
}
