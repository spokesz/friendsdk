// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { Treasury } from "../src/Treasury.sol";
import { ITreasury } from "../src/interfaces/ITreasury.sol";
import {
    MockActivationManager,
    MockGenerations,
    MockRF,
    MockUSDG
} from "./doubles/ExternalDoubles.sol";

/// @dev The registry views the Treasury reads, with per-(game, module) binding toggles.
contract StubRegistry {
    address public generations;

    struct Record {
        address currency;
        address funder;
        address developer;
        address operator;
    }

    address public owner;
    address public immutable rf;
    address public immutable usdg;
    mapping(uint256 gameId => Record) private _games;
    mapping(uint256 gameId => mapping(address module => bool)) public canCommit;
    mapping(uint256 gameId => mapping(address module => bool)) public isBound;

    constructor(address owner_, address rf_, address usdg_, address generations_) {
        generations = generations_;
        owner = owner_;
        rf = rf_;
        usdg = usdg_;
    }

    function setGame(
        uint256 gameId,
        address currency,
        address funder,
        address developer,
        address operator
    ) external {
        _games[gameId] = Record(currency, funder, developer, operator);
    }

    function setBinding(uint256 gameId, address module, bool committing, bool bound) external {
        canCommit[gameId][module] = committing;
        isBound[gameId][module] = bound;
    }

    function currencyOf(uint256 gameId) external view returns (address) {
        return _games[gameId].currency;
    }

    function recipientsOf(uint256 gameId)
        external
        view
        returns (address funder, address developer, address operator)
    {
        Record storage record = _games[gameId];
        return (record.funder, record.developer, record.operator);
    }
}

contract TreasuryTest is Test {
    uint256 internal constant RF_GAME = 1;
    uint256 internal constant USDG_GAME = 2;
    // USDG game without developer or operator recipients.
    uint256 internal constant BARE_GAME = 3;
    uint256 internal constant UNKNOWN_GAME = 99;
    uint256 internal constant FRIEND_A = 11;
    uint256 internal constant FRIEND_B = 22;
    uint256 internal constant SUPPLY = 1_000_000 ether;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MODULE = address(0x1001);
    address internal constant DRAINING = address(0x1002);
    address internal constant STRANGER = address(0x1003);
    address internal constant PAYER = address(0x2001);
    address internal constant FUNDER = address(0x3001);
    address internal constant DEV = address(0x3002);
    address internal constant OP = address(0x3003);
    address internal constant WALLET = address(0x4001);

    MockRF internal rf;
    MockUSDG internal usdg;
    MockGenerations internal generations;
    MockActivationManager internal manager;
    StubRegistry internal registry;
    Treasury internal treasury;

    // Ghost: tokens sent straight to the Treasury outside any primitive (I2).
    mapping(address currency => uint256) internal donations;

    struct Snap {
        uint256 balance;
        uint256 tFree;
        uint256 tReserved;
        uint256 tOwed;
        uint256 tCredit;
        uint256 tFees;
        uint256 rewards;
        uint256 lFree;
        uint256 lReserved;
        uint256 lOwed;
        uint256 lCredit;
    }

    function setUp() public {
        rf = new MockRF();
        generations = new MockGenerations(address(rf));
        rf.setGenerations(generations);
        usdg = new MockUSDG(6);
        manager = new MockActivationManager(address(rf));
        generations.setActivationManager(address(manager));
        registry = new StubRegistry(OWNER, address(rf), address(usdg), address(generations));
        treasury = new Treasury(address(registry), address(rf), address(usdg), address(generations));

        registry.setGame(RF_GAME, address(rf), FUNDER, DEV, OP);
        registry.setGame(USDG_GAME, address(usdg), FUNDER, DEV, OP);
        registry.setGame(BARE_GAME, address(usdg), FUNDER, address(0), address(0));
        for (uint256 g = 1; g <= 3; ++g) {
            registry.setBinding(g, MODULE, true, true);
            registry.setBinding(g, DRAINING, false, true);
        }

        rf.mint(PAYER, SUPPLY);
        usdg.mint(PAYER, SUPPLY);
        vm.startPrank(PAYER);
        rf.approve(address(treasury), type(uint256).max);
        usdg.approve(address(treasury), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _currencyOf(uint256 gameId) internal view returns (address) {
        return gameId == RF_GAME ? address(rf) : address(usdg);
    }

    function _snap(uint256 gameId) internal view returns (Snap memory s) {
        address currency = _currencyOf(gameId);
        s.balance = IERC20(currency).balanceOf(address(treasury));
        (s.tFree, s.tReserved, s.tOwed, s.tCredit, s.tFees) = treasury.totals(currency);
        s.rewards = treasury.rewardsPending();
        (s.lFree, s.lReserved, s.lOwed, s.lCredit) = treasury.ledgers(gameId);
    }

    function _delta(uint256 before, uint256 after_) internal pure returns (int256) {
        return SafeCast.toInt256(after_) - SafeCast.toInt256(before);
    }

    /// @dev Column-wise check of one primitive against the section 4.2 row: the game ledger and
    /// the currency totals move by the same amount, fees and rewards move as stated, and the
    /// token balance delta equals the sum of every column delta (I2 for one step).
    function _assertMove(
        Snap memory a,
        Snap memory b,
        int256 dFree,
        int256 dReserved,
        int256 dOwed,
        int256 dCredit,
        int256 dFees,
        int256 dRewards
    ) internal pure {
        assertEq(_delta(a.lFree, b.lFree), dFree, "ledger free");
        assertEq(_delta(a.lReserved, b.lReserved), dReserved, "ledger reserved");
        assertEq(_delta(a.lOwed, b.lOwed), dOwed, "ledger owed");
        assertEq(_delta(a.lCredit, b.lCredit), dCredit, "ledger credit");
        assertEq(_delta(a.tFree, b.tFree), dFree, "total free");
        assertEq(_delta(a.tReserved, b.tReserved), dReserved, "total reserved");
        assertEq(_delta(a.tOwed, b.tOwed), dOwed, "total owed");
        assertEq(_delta(a.tCredit, b.tCredit), dCredit, "total credit");
        assertEq(_delta(a.tFees, b.tFees), dFees, "fees");
        assertEq(_delta(a.rewards, b.rewards), dRewards, "rewards");
        assertEq(
            _delta(a.balance, b.balance),
            dFree + dReserved + dOwed + dCredit + dFees + dRewards,
            "balance conservation"
        );
    }

    function _assertUnchanged(Snap memory a, Snap memory b) internal pure {
        _assertMove(a, b, 0, 0, 0, 0, 0, 0);
    }

    /// @dev I1..I4 from Treasury state alone for one currency.
    function _assertInvariants(address currency) internal view {
        assertTrue(treasury.solvent(currency), "I1 solvent");
        assertEq(
            IERC20(currency).balanceOf(address(treasury)),
            treasury.backed(currency) + donations[currency],
            "I2 conservation"
        );
        uint256 free;
        uint256 reserved;
        uint256 owed;
        uint256 credit;
        for (uint256 g = 1; g <= 3; ++g) {
            if (_currencyOf(g) != currency) continue;
            (uint256 f, uint256 r, uint256 o, uint256 c) = treasury.ledgers(g);
            free += f;
            reserved += r;
            owed += o;
            credit += c;
            assertEq(
                treasury.creditOf(g, FRIEND_A) + treasury.creditOf(g, FRIEND_B), c, "I4 credit"
            );
        }
        (uint256 tf, uint256 tr, uint256 to, uint256 tc,) = treasury.totals(currency);
        assertEq(free, tf, "I3 free");
        assertEq(reserved, tr, "I3 reserved");
        assertEq(owed, to, "I3 owed");
        assertEq(credit, tc, "I3 credit");
    }

    function _legs(
        uint256 toFree,
        uint256 toReserved,
        uint256 dev,
        uint256 op,
        uint256 burn,
        uint256 rewards
    ) internal pure returns (ITreasury.Legs memory) {
        return ITreasury.Legs(toFree, toReserved, dev, op, burn, rewards);
    }

    function _fund(uint256 gameId, uint256 amount) internal {
        vm.prank(PAYER);
        treasury.fund(gameId, amount);
    }

    function _reserve(uint256 gameId, uint256 amount) internal {
        vm.prank(MODULE);
        treasury.reserve(gameId, amount);
    }

    function _deposit(uint256 gameId, uint256 friendId, uint256 amount) internal {
        vm.prank(MODULE);
        treasury.creditDeposit(gameId, friendId, PAYER, amount);
    }

    // ------------------------------------------------------------ constructor

    function testConstructorRejectsRegistryMismatch() public {
        StubRegistry other =
            new StubRegistry(OWNER, address(usdg), address(usdg), address(generations));
        vm.expectRevert(Treasury.InvalidConfiguration.selector);
        new Treasury(address(other), address(rf), address(usdg), address(generations));
        other = new StubRegistry(OWNER, address(rf), address(rf), address(generations));
        vm.expectRevert(Treasury.InvalidConfiguration.selector);
        new Treasury(address(other), address(rf), address(usdg), address(generations));
    }

    function testConstructorRejectsAddressesWithoutCode() public {
        vm.expectRevert(Treasury.InvalidConfiguration.selector);
        new Treasury(address(registry), address(rf), address(usdg), STRANGER);
        vm.expectRevert(Treasury.InvalidConfiguration.selector);
        new Treasury(STRANGER, address(rf), address(usdg), address(generations));
    }

    // ----------------------------------------------------------- role gating

    function testCollectRequiresCommittingModule() public {
        ITreasury.Legs memory legs = _legs(1 ether, 0, 0, 0, 0, 0);
        vm.prank(DRAINING);
        vm.expectRevert(Treasury.NotCommittingModule.selector);
        treasury.collect(RF_GAME, PAYER, legs);
        vm.prank(STRANGER);
        vm.expectRevert(Treasury.NotCommittingModule.selector);
        treasury.collect(RF_GAME, PAYER, legs);
    }

    function testCreditDepositRequiresCommittingModule() public {
        vm.prank(DRAINING);
        vm.expectRevert(Treasury.NotCommittingModule.selector);
        treasury.creditDeposit(RF_GAME, FRIEND_A, PAYER, 1 ether);
    }

    function testBoundPrimitivesRejectStranger() public {
        vm.startPrank(STRANGER);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.reserve(RF_GAME, 1);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.release(RF_GAME, 1);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.resolve(RF_GAME, 1, 0, 0, WALLET, 1);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.routeReserved(RF_GAME, 1, 0);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.payOwed(RF_GAME, WALLET, 1);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.creditWithdraw(RF_GAME, FRIEND_A, WALLET, 1);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.creditSpend(RF_GAME, FRIEND_A, 2, 1, 1);
        vm.stopPrank();
    }

    function testDrainingModuleKeepsEveryPrimitiveButCollectAndDeposit() public {
        _fund(RF_GAME, 100 ether);
        _deposit(RF_GAME, FRIEND_A, 10 ether);
        vm.startPrank(DRAINING);
        treasury.reserve(RF_GAME, 20 ether);
        treasury.release(RF_GAME, 5 ether);
        treasury.resolve(RF_GAME, 10 ether, 3 ether, 2 ether, WALLET, 1 ether);
        treasury.routeReserved(RF_GAME, 1 ether, 1 ether);
        treasury.payOwed(RF_GAME, WALLET, 3 ether);
        treasury.creditWithdraw(RF_GAME, FRIEND_A, WALLET, 4 ether);
        treasury.creditSpend(RF_GAME, FRIEND_A, 6 ether, 3 ether, 3 ether);
        vm.stopPrank();
        (uint256 free, uint256 reserved, uint256 owed, uint256 credit) = treasury.ledgers(RF_GAME);
        assertEq(free, 100 ether - 20 ether + 5 ether + 4 ether);
        assertEq(reserved, 20 ether - 5 ether - 8 ether - 2 ether);
        assertEq(owed, 0);
        assertEq(credit, 0);
        assertEq(rf.balanceOf(WALLET), 8 ether);
        _assertInvariants(address(rf));
    }

    function testWithdrawFreeRequiresRegistryOwner() public {
        _fund(RF_GAME, 1 ether);
        vm.prank(MODULE);
        vm.expectRevert(Treasury.NotRegistryOwner.selector);
        treasury.withdrawFree(RF_GAME, 1 ether);
        vm.prank(FUNDER);
        vm.expectRevert(Treasury.NotRegistryOwner.selector);
        treasury.withdrawFree(RF_GAME, 1 ether);
    }

    function testUnknownGameRejected() public {
        vm.prank(PAYER);
        vm.expectRevert(Treasury.UnknownGame.selector);
        treasury.fund(UNKNOWN_GAME, 1 ether);
        // Bound to a game the registry has no currency for: the module gate passes, the
        // currency lookup does not.
        registry.setBinding(UNKNOWN_GAME, MODULE, true, true);
        vm.startPrank(MODULE);
        vm.expectRevert(Treasury.UnknownGame.selector);
        treasury.reserve(UNKNOWN_GAME, 1);
        vm.expectRevert(Treasury.UnknownGame.selector);
        treasury.collect(UNKNOWN_GAME, PAYER, _legs(1, 0, 0, 0, 0, 0));
        vm.stopPrank();
        vm.prank(OWNER);
        vm.expectRevert(Treasury.UnknownGame.selector);
        treasury.withdrawFree(UNKNOWN_GAME, 1);
    }

    // ------------------------------------------------------------------ legs

    function testCollectRejectsBurnOrRewardsForUsdg() public {
        vm.startPrank(MODULE);
        vm.expectRevert(Treasury.UnsupportedLeg.selector);
        treasury.collect(USDG_GAME, PAYER, _legs(1e6, 0, 0, 0, 1, 0));
        vm.expectRevert(Treasury.UnsupportedLeg.selector);
        treasury.collect(USDG_GAME, PAYER, _legs(1e6, 0, 0, 0, 0, 1));
        vm.stopPrank();
    }

    function testRouteReservedAndCreditSpendRejectUsdg() public {
        _fund(USDG_GAME, 10e6);
        _reserve(USDG_GAME, 2e6);
        _deposit(USDG_GAME, FRIEND_A, 2e6);
        vm.startPrank(MODULE);
        vm.expectRevert(Treasury.UnsupportedLeg.selector);
        treasury.routeReserved(USDG_GAME, 1e6, 1e6);
        vm.expectRevert(Treasury.UnsupportedLeg.selector);
        treasury.creditSpend(USDG_GAME, FRIEND_A, 2e6, 1e6, 1e6);
        vm.stopPrank();
    }

    function testCollectRejectsFeeLegWithoutRecipient() public {
        vm.startPrank(MODULE);
        vm.expectRevert(Treasury.NoRecipient.selector);
        treasury.collect(BARE_GAME, PAYER, _legs(1e6, 0, 1, 0, 0, 0));
        vm.expectRevert(Treasury.NoRecipient.selector);
        treasury.collect(BARE_GAME, PAYER, _legs(1e6, 0, 0, 1, 0, 0));
        // Without fee legs the bare game collects normally.
        treasury.collect(BARE_GAME, PAYER, _legs(1e6, 0, 0, 0, 0, 0));
        vm.stopPrank();
        (uint256 free,,,) = treasury.ledgers(BARE_GAME);
        assertEq(free, 1e6);
    }

    function testCollectRejectsZeroTotal() public {
        vm.prank(MODULE);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.collect(RF_GAME, PAYER, _legs(0, 0, 0, 0, 0, 0));
    }

    function testCollectRfRoutesEveryLeg() public {
        ITreasury.Legs memory legs = _legs(50 ether, 20 ether, 6 ether, 2 ether, 12 ether, 10 ether);
        Snap memory a = _snap(RF_GAME);
        uint256 supply = rf.totalSupply();
        vm.expectEmit(address(treasury));
        emit Treasury.Collected(RF_GAME, PAYER, legs);
        vm.prank(MODULE);
        treasury.collect(RF_GAME, PAYER, legs);
        Snap memory b = _snap(RF_GAME);
        _assertMove(a, b, 50 ether, 20 ether, 0, 0, 8 ether, 10 ether);
        assertEq(rf.balanceOf(PAYER), SUPPLY - 100 ether, "payer charged the sum of legs");
        assertEq(rf.totalSupply(), supply - 12 ether, "burn leg burned");
        assertEq(treasury.feesOwed(address(rf), DEV), 6 ether);
        assertEq(treasury.feesOwed(address(rf), OP), 2 ether);
        _assertInvariants(address(rf));
    }

    function testCollectUsdgAccruesFeesWithoutTransfer() public {
        Snap memory a = _snap(USDG_GAME);
        vm.prank(MODULE);
        treasury.collect(USDG_GAME, PAYER, _legs(3_720_000, 0, 210_000, 70_000, 0, 0));
        Snap memory b = _snap(USDG_GAME);
        _assertMove(a, b, 3_720_000, 0, 0, 0, 280_000, 0);
        assertEq(usdg.balanceOf(DEV), 0, "developer not paid inline");
        assertEq(treasury.feesOwed(address(usdg), DEV), 210_000);
        assertEq(treasury.feesOwed(address(usdg), OP), 70_000);
        _assertInvariants(address(usdg));
    }

    // ------------------------------------------------- primitives, column-wise

    function testFundMovesFreeOnlyAndIsPermissionless() public {
        rf.mint(STRANGER, 5 ether);
        vm.prank(STRANGER);
        rf.approve(address(treasury), 5 ether);
        Snap memory a = _snap(RF_GAME);
        vm.expectEmit(address(treasury));
        emit Treasury.Funded(RF_GAME, STRANGER, 5 ether);
        vm.prank(STRANGER);
        treasury.fund(RF_GAME, 5 ether);
        _assertMove(a, _snap(RF_GAME), 5 ether, 0, 0, 0, 0, 0);
        vm.prank(STRANGER);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.fund(RF_GAME, 0);
        _assertInvariants(address(rf));
    }

    function testReserveMovesFreeToReserved() public {
        _fund(RF_GAME, 10 ether);
        Snap memory a = _snap(RF_GAME);
        vm.expectEmit(address(treasury));
        emit Treasury.Reserved(RF_GAME, 6 ether);
        _reserve(RF_GAME, 6 ether);
        _assertMove(a, _snap(RF_GAME), -6 ether, 6 ether, 0, 0, 0, 0);
        _assertInvariants(address(rf));
    }

    function testReserveRevertsInsufficientFree() public {
        _fund(RF_GAME, 10 ether);
        Snap memory a = _snap(RF_GAME);
        vm.prank(MODULE);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        treasury.reserve(RF_GAME, 10 ether + 1);
        vm.prank(MODULE);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.reserve(RF_GAME, 0);
        _assertUnchanged(a, _snap(RF_GAME));
    }

    function testReleaseMovesReservedToFree() public {
        _fund(RF_GAME, 10 ether);
        _reserve(RF_GAME, 6 ether);
        Snap memory a = _snap(RF_GAME);
        vm.expectEmit(address(treasury));
        emit Treasury.Released(RF_GAME, 6 ether);
        vm.prank(MODULE);
        treasury.release(RF_GAME, 6 ether);
        _assertMove(a, _snap(RF_GAME), 6 ether, -6 ether, 0, 0, 0, 0);
        _assertInvariants(address(rf));
    }

    function testReleaseRevertsInsufficientReserved() public {
        _fund(RF_GAME, 10 ether);
        _reserve(RF_GAME, 6 ether);
        Snap memory a = _snap(RF_GAME);
        vm.prank(MODULE);
        vm.expectRevert(Treasury.InsufficientReserved.selector);
        treasury.release(RF_GAME, 6 ether + 1);
        vm.prank(MODULE);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.release(RF_GAME, 0);
        _assertUnchanged(a, _snap(RF_GAME));
    }

    function testResolveSplitsReservationAcrossColumns() public {
        _fund(RF_GAME, 10 ether);
        _reserve(RF_GAME, 10 ether);
        Snap memory a = _snap(RF_GAME);
        vm.expectEmit(address(treasury));
        emit Treasury.Resolved(RF_GAME, 10 ether, 2 ether, 3 ether, WALLET, 4 ether);
        vm.prank(MODULE);
        treasury.resolve(RF_GAME, 10 ether, 2 ether, 3 ether, WALLET, 4 ether);
        _assertMove(a, _snap(RF_GAME), 1 ether, -7 ether, 2 ether, 0, 0, 0);
        assertEq(rf.balanceOf(WALLET), 4 ether);
        _assertInvariants(address(rf));
    }

    function testResolveKeepEverythingAndPayEverything() public {
        _fund(RF_GAME, 12 ether);
        _reserve(RF_GAME, 12 ether);
        // Breeds inline egg purchase: the whole reservation stays with the minted eggs.
        Snap memory a = _snap(RF_GAME);
        vm.prank(MODULE);
        treasury.resolve(RF_GAME, 6 ether, 0, 6 ether, address(0), 0);
        _assertUnchanged(a, _snap(RF_GAME));
        // Royale payout or refund: the whole reservation leaves as a payment.
        vm.prank(MODULE);
        treasury.resolve(RF_GAME, 6 ether, 0, 0, WALLET, 6 ether);
        _assertMove(a, _snap(RF_GAME), 0, -6 ether, 0, 0, 0, 0);
        assertEq(rf.balanceOf(WALLET), 6 ether);
        _assertInvariants(address(rf));
    }

    function testResolveRevertsInvalidResolutionAndInsufficientReserved() public {
        _fund(RF_GAME, 10 ether);
        _reserve(RF_GAME, 5 ether);
        Snap memory a = _snap(RF_GAME);
        vm.startPrank(MODULE);
        vm.expectRevert(Treasury.InvalidResolution.selector);
        treasury.resolve(RF_GAME, 5 ether, 2 ether, 2 ether, WALLET, 2 ether);
        vm.expectRevert(Treasury.InsufficientReserved.selector);
        treasury.resolve(RF_GAME, 5 ether + 1, 0, 0, WALLET, 0);
        vm.stopPrank();
        _assertUnchanged(a, _snap(RF_GAME));
    }

    function testResolveBlockedUsdgRecipientRevertsWholeAndKeepsReserved() public {
        _fund(USDG_GAME, 100e6);
        _reserve(USDG_GAME, 64e6);
        usdg.blockRecipient(WALLET);
        Snap memory a = _snap(USDG_GAME);
        vm.prank(MODULE);
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdg))
        );
        treasury.resolve(USDG_GAME, 64e6, 0, 0, WALLET, 32e6);
        _assertUnchanged(a, _snap(USDG_GAME));
        (, uint256 reserved,,) = treasury.ledgers(USDG_GAME);
        assertEq(reserved, 64e6, "reservation kept");
        // Retry with the same inputs once the recipient is accepted again.
        usdg.blockRecipient(address(0));
        vm.prank(MODULE);
        treasury.resolve(USDG_GAME, 64e6, 0, 0, WALLET, 32e6);
        _assertMove(a, _snap(USDG_GAME), 32e6, -64e6, 0, 0, 0, 0);
        assertEq(usdg.balanceOf(WALLET), 32e6);
        _assertInvariants(address(usdg));
    }

    function testRouteReservedBurnsAndAccrues() public {
        _fund(RF_GAME, 12 ether);
        _reserve(RF_GAME, 12 ether);
        Snap memory a = _snap(RF_GAME);
        uint256 supply = rf.totalSupply();
        vm.expectEmit(address(treasury));
        emit Treasury.ReservedRouted(RF_GAME, 1.2 ether, 1.2 ether);
        vm.prank(MODULE);
        treasury.routeReserved(RF_GAME, 1.2 ether, 1.2 ether);
        _assertMove(a, _snap(RF_GAME), 0, -2.4 ether, 0, 0, 0, 1.2 ether);
        assertEq(rf.totalSupply(), supply - 1.2 ether);
        vm.prank(MODULE);
        vm.expectRevert(Treasury.InsufficientReserved.selector);
        treasury.routeReserved(RF_GAME, 9.6 ether + 1, 0);
        _assertInvariants(address(rf));
    }

    function testPayOwedMovesOwedAndPays() public {
        _fund(RF_GAME, 10 ether);
        _reserve(RF_GAME, 6 ether);
        vm.prank(MODULE);
        treasury.resolve(RF_GAME, 6 ether, 1 ether, 0, address(0), 0);
        Snap memory a = _snap(RF_GAME);
        vm.expectEmit(address(treasury));
        emit Treasury.OwedPaid(RF_GAME, WALLET, 1 ether);
        vm.prank(MODULE);
        treasury.payOwed(RF_GAME, WALLET, 1 ether);
        _assertMove(a, _snap(RF_GAME), 0, 0, -1 ether, 0, 0, 0);
        assertEq(rf.balanceOf(WALLET), 1 ether);
        vm.startPrank(MODULE);
        vm.expectRevert(Treasury.InsufficientOwed.selector);
        treasury.payOwed(RF_GAME, WALLET, 1);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.payOwed(RF_GAME, WALLET, 0);
        vm.stopPrank();
        _assertInvariants(address(rf));
    }

    // ----------------------------------------------------------------- credit

    function testCreditDepositMovesCreditOnly() public {
        Snap memory a = _snap(RF_GAME);
        vm.expectEmit(address(treasury));
        emit Treasury.CreditDeposited(RF_GAME, FRIEND_A, PAYER, 10 ether);
        _deposit(RF_GAME, FRIEND_A, 10 ether);
        _assertMove(a, _snap(RF_GAME), 0, 0, 0, 10 ether, 0, 0);
        assertEq(treasury.creditOf(RF_GAME, FRIEND_A), 10 ether);
        vm.prank(MODULE);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.creditDeposit(RF_GAME, FRIEND_A, PAYER, 0);
        _assertInvariants(address(rf));
    }

    function testCreditWithdrawMovesCreditAndPays() public {
        _deposit(RF_GAME, FRIEND_A, 10 ether);
        _deposit(RF_GAME, FRIEND_B, 10 ether);
        Snap memory a = _snap(RF_GAME);
        vm.expectEmit(address(treasury));
        emit Treasury.CreditWithdrawn(RF_GAME, FRIEND_A, WALLET, 4 ether);
        vm.prank(MODULE);
        treasury.creditWithdraw(RF_GAME, FRIEND_A, WALLET, 4 ether);
        _assertMove(a, _snap(RF_GAME), 0, 0, 0, -4 ether, 0, 0);
        assertEq(rf.balanceOf(WALLET), 4 ether);
        assertEq(treasury.creditOf(RF_GAME, FRIEND_A), 6 ether);
        // The game ledger still holds 16 RF, but this Friend holds only 6.
        vm.startPrank(MODULE);
        vm.expectRevert(Treasury.InsufficientCredit.selector);
        treasury.creditWithdraw(RF_GAME, FRIEND_A, WALLET, 6 ether + 1);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.creditWithdraw(RF_GAME, FRIEND_A, WALLET, 0);
        vm.stopPrank();
        _assertInvariants(address(rf));
    }

    function testCreditSpendBurnsAndAccruesOnly() public {
        _fund(RF_GAME, 10 ether);
        _deposit(RF_GAME, FRIEND_A, 10 ether);
        Snap memory a = _snap(RF_GAME);
        uint256 supply = rf.totalSupply();
        vm.expectEmit(address(treasury));
        emit Treasury.CreditSpent(RF_GAME, FRIEND_A, 2 ether, 1 ether, 1 ether);
        vm.prank(MODULE);
        treasury.creditSpend(RF_GAME, FRIEND_A, 2 ether, 1 ether, 1 ether);
        _assertMove(a, _snap(RF_GAME), 0, 0, 0, -2 ether, 0, 1 ether);
        assertEq(rf.totalSupply(), supply - 1 ether);
        assertEq(treasury.creditOf(RF_GAME, FRIEND_A), 8 ether);
        vm.startPrank(MODULE);
        vm.expectRevert(Treasury.UnbalancedSpend.selector);
        treasury.creditSpend(RF_GAME, FRIEND_A, 2 ether, 1 ether, 2 ether);
        vm.expectRevert(Treasury.InsufficientCredit.selector);
        treasury.creditSpend(RF_GAME, FRIEND_A, 9 ether, 9 ether, 0);
        vm.stopPrank();
        _assertInvariants(address(rf));
    }

    // ------------------------------------------------------------ fees, rewards

    function testPayFeesPaysAndClears() public {
        vm.prank(MODULE);
        treasury.collect(USDG_GAME, PAYER, _legs(3_720_000, 0, 210_000, 70_000, 0, 0));
        Snap memory a = _snap(USDG_GAME);
        vm.expectEmit(address(treasury));
        emit Treasury.FeesPaid(address(usdg), DEV, 210_000);
        vm.prank(STRANGER);
        treasury.payFees(address(usdg), DEV);
        _assertMove(a, _snap(USDG_GAME), 0, 0, 0, 0, -210_000, 0);
        assertEq(usdg.balanceOf(DEV), 210_000);
        assertEq(treasury.feesOwed(address(usdg), DEV), 0);
        assertEq(treasury.feesOwed(address(usdg), OP), 70_000);
        vm.expectRevert(Treasury.NothingOwed.selector);
        treasury.payFees(address(usdg), DEV);
        _assertInvariants(address(usdg));
    }

    function testPayFeesBlockedRecipientKeepsLedger() public {
        vm.prank(MODULE);
        treasury.collect(USDG_GAME, PAYER, _legs(3_720_000, 0, 210_000, 70_000, 0, 0));
        usdg.blockRecipient(DEV);
        Snap memory a = _snap(USDG_GAME);
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdg))
        );
        treasury.payFees(address(usdg), DEV);
        _assertUnchanged(a, _snap(USDG_GAME));
        assertEq(treasury.feesOwed(address(usdg), DEV), 210_000);
        // A frozen fee recipient never blocks the next purchase.
        vm.prank(MODULE);
        treasury.collect(USDG_GAME, PAYER, _legs(3_720_000, 0, 210_000, 70_000, 0, 0));
        assertEq(treasury.feesOwed(address(usdg), DEV), 420_000);
        _assertInvariants(address(usdg));
    }

    function testForwardRewardsFundsCurrentManager() public {
        vm.prank(MODULE);
        treasury.collect(RF_GAME, PAYER, _legs(0, 0, 0, 0, 1 ether, 2.2 ether));
        Snap memory a = _snap(RF_GAME);
        vm.expectEmit(address(treasury));
        emit Treasury.RewardsForwarded(address(manager), 2.2 ether);
        vm.prank(STRANGER);
        treasury.forwardRewards();
        _assertMove(a, _snap(RF_GAME), 0, 0, 0, 0, 0, -2.2 ether);
        assertEq(manager.funded(address(rf)), 2.2 ether);
        assertEq(rf.allowance(address(treasury), address(manager)), 0);
        vm.expectRevert(Treasury.NothingOwed.selector);
        treasury.forwardRewards();
        _assertInvariants(address(rf));
    }

    function testForwardRewardsRetiredManagerKeepsPending() public {
        vm.prank(MODULE);
        treasury.collect(RF_GAME, PAYER, _legs(0, 0, 0, 0, 0, 2 ether));
        manager.setRetired(true);
        Snap memory a = _snap(RF_GAME);
        vm.expectRevert(Treasury.ManagerUnavailable.selector);
        treasury.forwardRewards();
        _assertUnchanged(a, _snap(RF_GAME));
        assertEq(treasury.rewardsPending(), 2 ether);
        _assertInvariants(address(rf));
    }

    function testForwardRewardsReplacedManager() public {
        vm.prank(MODULE);
        treasury.collect(RF_GAME, PAYER, _legs(0, 0, 0, 0, 0, 2 ether));
        // Replaced by an address without code: refused, balance intact.
        generations.setActivationManager(STRANGER);
        vm.expectRevert(Treasury.ManagerUnavailable.selector);
        treasury.forwardRewards();
        assertEq(treasury.rewardsPending(), 2 ether);
        // Replaced by a live manager: the accrued balance goes there.
        MockActivationManager successor = new MockActivationManager(address(rf));
        generations.setActivationManager(address(successor));
        treasury.forwardRewards();
        assertEq(successor.funded(address(rf)), 2 ether);
        assertEq(manager.funded(address(rf)), 0);
        assertEq(treasury.rewardsPending(), 0);
        _assertInvariants(address(rf));
    }

    // ------------------------------------------------------------ withdrawFree

    function testWithdrawFreeBoundedByFreeAndPaidToFunderOnly() public {
        _fund(RF_GAME, 10 ether);
        _reserve(RF_GAME, 6 ether);
        vm.prank(MODULE);
        treasury.resolve(RF_GAME, 6 ether, 1 ether, 3 ether, address(0), 0);
        _deposit(RF_GAME, FRIEND_A, 5 ether);
        // free 6, reserved 3, owed 1, credit 5.
        Snap memory a = _snap(RF_GAME);
        vm.startPrank(OWNER);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        treasury.withdrawFree(RF_GAME, 6 ether + 1);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.withdrawFree(RF_GAME, 0);
        vm.expectEmit(address(treasury));
        emit Treasury.FreeWithdrawn(RF_GAME, FUNDER, 6 ether);
        treasury.withdrawFree(RF_GAME, 6 ether);
        vm.stopPrank();
        Snap memory b = _snap(RF_GAME);
        _assertMove(a, b, -6 ether, 0, 0, 0, 0, 0);
        assertEq(rf.balanceOf(FUNDER), 6 ether, "paid to the recorded funder");
        assertEq(rf.balanceOf(OWNER), 0, "never to the owner");
        assertEq(b.lReserved, 3 ether);
        assertEq(b.lOwed, 1 ether);
        assertEq(b.lCredit, 5 ether);
        assertTrue(treasury.solvent(address(rf)));
        _assertInvariants(address(rf));
    }

    function testSolventAndBackedIgnoreDonations() public {
        _fund(RF_GAME, 10 ether);
        _reserve(RF_GAME, 4 ether);
        assertEq(treasury.backed(address(rf)), 10 ether);
        rf.mint(address(treasury), 3 ether);
        donations[address(rf)] += 3 ether;
        assertEq(treasury.backed(address(rf)), 10 ether, "donations are not ledger money");
        assertTrue(treasury.solvent(address(rf)));
        assertEq(treasury.backed(address(usdg)), 0);
        assertTrue(treasury.solvent(address(usdg)));
        _assertInvariants(address(rf));
    }

    // ------------------------------------------------------------------- fuzz

    /// @dev Random primitive sequences across all three games, reverts included: I1..I4 hold
    /// after every step from Treasury state alone.
    function testFuzzRandomPrimitiveSequenceKeepsInvariants(uint256[24] memory ops) public {
        for (uint256 i; i < ops.length; ++i) {
            _step(ops[i]);
            _assertInvariants(address(rf));
            _assertInvariants(address(usdg));
        }
    }

    function _step(uint256 w) internal {
        uint256 op = w % 14;
        uint256 gameId = 1 + (w >> 8) % 3;
        uint256 friendId = ((w >> 16) & 1) == 0 ? FRIEND_A : FRIEND_B;
        uint256 unit = gameId == RF_GAME ? 1 ether : 1e6;
        uint256 x = ((w >> 24) % 100) * unit;
        uint256 y = ((w >> 32) % 100) * unit;
        uint256 z = ((w >> 40) % 100) * unit;
        uint256 v = ((w >> 48) % 100) * unit;
        address currency = _currencyOf(gameId);
        if (op == 0) {
            vm.prank(PAYER);
            try treasury.fund(gameId, x) { } catch { }
        } else if (op == 1) {
            bool isRf = currency == address(rf);
            ITreasury.Legs memory legs = _legs(x, y, z, v, isRf ? x / 2 : 0, isRf ? y / 2 : 0);
            vm.prank(MODULE);
            try treasury.collect(gameId, PAYER, legs) { } catch { }
        } else if (op == 2) {
            vm.prank(MODULE);
            try treasury.reserve(gameId, x) { } catch { }
        } else if (op == 3) {
            vm.prank(DRAINING);
            try treasury.release(gameId, x) { } catch { }
        } else if (op == 4) {
            vm.prank(DRAINING);
            try treasury.resolve(gameId, x, y, z, WALLET, v) { } catch { }
        } else if (op == 5) {
            vm.prank(MODULE);
            try treasury.routeReserved(gameId, x, y) { } catch { }
        } else if (op == 6) {
            vm.prank(MODULE);
            try treasury.payOwed(gameId, WALLET, x) { } catch { }
        } else if (op == 7) {
            vm.prank(MODULE);
            try treasury.creditDeposit(gameId, friendId, PAYER, x) { } catch { }
        } else if (op == 8) {
            vm.prank(DRAINING);
            try treasury.creditWithdraw(gameId, friendId, WALLET, x) { } catch { }
        } else if (op == 9) {
            vm.prank(MODULE);
            try treasury.creditSpend(gameId, friendId, x + y, x, y) { } catch { }
        } else if (op == 10) {
            try treasury.payFees(currency, (w >> 56) & 1 == 0 ? DEV : OP) { } catch { }
        } else if (op == 11) {
            try treasury.forwardRewards() { } catch { }
        } else if (op == 12) {
            vm.prank(OWNER);
            try treasury.withdrawFree(gameId, x) { } catch { }
        } else {
            if (currency == address(rf)) rf.mint(address(treasury), x);
            else usdg.mint(address(treasury), x);
            donations[currency] += x;
        }
    }
}
