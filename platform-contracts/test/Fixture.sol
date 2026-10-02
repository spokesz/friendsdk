// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { GameItems } from "../src/GameItems.sol";
import { Treasury } from "../src/Treasury.sol";
import { RandomnessCoordinator } from "../src/RandomnessCoordinator.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";
import {
    MockRF,
    MockUSDG,
    MockGenerations,
    MockFriendWallet,
    MockCustody,
    MockDice,
    MockActivationManager
} from "./doubles/ExternalDoubles.sol";

/// @dev Deploys the hub and both modules, registers the three launch games with the exact terms
/// of docs/SPEC.md section 3, funds them, and offers the helpers every integration test needs.
contract Fixture is Test {
    uint128 internal constant DICE_FEE = 0.000_025 ether;
    address internal constant PARK_DEVELOPER = 0xd0BB5CC938dA89E0d7129F1eE01C2cfc61C2e36F;
    address internal constant PARK_OPERATOR = 0x1EcBF27dC1F809179B9ef2d382cd76ccBa21B6d2;

    MockRF internal rf;
    MockUSDG internal usdg;
    MockGenerations internal generations;
    MockCustody internal custody;
    MockDice internal dice;
    MockActivationManager internal manager;

    GameRegistry internal registry;
    Treasury internal treasury;
    RandomnessCoordinator internal coordinator;
    DrawModule internal draw;
    RoundModule internal round;

    address internal owner = makeAddr("owner");
    address internal executor = makeAddr("executor");
    address internal settler = makeAddr("settler");
    address internal funder = makeAddr("funder");
    address internal provider = makeAddr("provider");

    uint256 internal breedsId;
    uint256 internal parkId;
    uint256 internal royaleId;

    function setUp() public virtual {
        rf = new MockRF();
        usdg = new MockUSDG(6);
        generations = new MockGenerations(address(rf));
        rf.setGenerations(generations);
        custody = new MockCustody();
        dice = new MockDice(provider);
        manager = new MockActivationManager(address(rf));
        generations.setActivationManager(address(manager));

        registry = new GameRegistry(
            owner, address(generations), address(rf), address(usdg), address(custody), executor
        );
        treasury = new Treasury(address(registry), address(rf), address(usdg), address(generations));
        coordinator = new RandomnessCoordinator(address(registry), address(dice), provider);
        draw = new DrawModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
        round = new RoundModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
        vm.deal(address(coordinator), 10 ether);

        vm.startPrank(owner);
        registry.allowModule(address(draw));
        registry.allowModule(address(round));
        coordinator.setMaxFee(DICE_FEE);
        breedsId = _registerBreeds();
        parkId = _registerPark();
        royaleId = _registerRoyale();
        coordinator.setBudget(breedsId, 1 ether);
        coordinator.setBudget(parkId, 1 ether);
        coordinator.setBudget(royaleId, 1 ether);
        vm.stopPrank();

        fundGame(breedsId, 10_000e18);
        fundGame(parkId, 5000e6);
    }

    // ------------------------------------------------------------------ registration

    function _registerBreeds() internal returns (uint256 gameId) {
        gameId = registry.createGame(
            address(draw), address(rf), funder, address(0), address(0), address(0), 5, "breeds/{id}"
        );
        draw.defineClasses(gameId, LaunchTerms.breedsClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        draw.defineAction(gameId, a, s, t);
        (a, s, t) = LaunchTerms.breedsPlayAction();
        draw.defineAction(gameId, a, s, t);
        registry.activateGame(gameId);
    }

    function _registerPark() internal returns (uint256 gameId) {
        gameId = registry.createGame(
            address(draw),
            address(usdg),
            funder,
            PARK_DEVELOPER,
            PARK_OPERATOR,
            address(0),
            LaunchTerms.PARK_BALLS,
            "park/{id}"
        );
        draw.defineClasses(gameId, LaunchTerms.parkClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.parkPackAction();
        draw.defineAction(gameId, a, s, t);
        for (uint16 ball = 1; ball <= LaunchTerms.PARK_BALLS; ++ball) {
            (a, s, t) = LaunchTerms.parkKickActionTerms(ball);
            draw.defineAction(gameId, a, s, t);
        }
        registry.activateGame(gameId);
    }

    function _registerRoyale() internal returns (uint256 gameId) {
        gameId = registry.createGame(
            address(round), address(rf), funder, address(0), address(0), settler, 0, ""
        );
        round.defineTerms(gameId, royaleTerms(), LaunchTerms.royaleKindPrices());
        registry.activateGame(gameId);
    }

    function royaleTerms() internal pure returns (RoundModule.Terms memory) {
        return RoundModule.Terms({
            entryPrice: LaunchTerms.ROYALE_ENTRY,
            potBps: LaunchTerms.ROYALE_POT_BPS,
            burnBps: LaunchTerms.ROYALE_BURN_BPS,
            rewardsBps: LaunchTerms.ROYALE_REWARDS_BPS,
            spendBurnBps: LaunchTerms.ROYALE_SPEND_BURN_BPS,
            spendRewardsBps: LaunchTerms.ROYALE_SPEND_REWARDS_BPS,
            minEntries: LaunchTerms.ROYALE_MIN_ENTRIES,
            maxEntries: LaunchTerms.ROYALE_MAX_ENTRIES
        });
    }

    // ----------------------------------------------------------------------- helpers

    function fundGame(uint256 gameId, uint256 amount) internal {
        address currency = registry.currencyOf(gameId);
        if (currency == address(rf)) rf.mint(funder, amount);
        else usdg.mint(funder, amount);
        vm.startPrank(funder);
        MockRF(currency).approve(address(treasury), amount);
        treasury.fund(gameId, amount);
        vm.stopPrank();
    }

    function mintFriend(address holder, uint256 friendId, uint8 generation) internal {
        generations.mint(holder, friendId, generation);
    }

    function walletOf(uint256 friendId) internal view returns (address) {
        return generations.tokenBoundAccount(friendId);
    }

    function items(uint256 gameId) internal view returns (GameItems) {
        return GameItems(registry.itemsOf(gameId));
    }

    /// @dev Give `account` RF and approve the Treasury.
    function giveRF(address account, uint256 amount) internal {
        rf.mint(account, amount);
        vm.prank(account);
        rf.approve(address(treasury), amount);
    }

    /// @dev Give `account` USDG and approve the Treasury.
    function giveUSDG(address account, uint256 amount) internal {
        usdg.mint(account, amount);
        vm.prank(account);
        usdg.approve(address(treasury), amount);
    }

    /// @dev Call `target` through the Friend's canonical wallet as its owner.
    function viaWallet(address friendOwner, uint256 friendId, address target, bytes memory data)
        internal
        returns (bytes memory)
    {
        // Resolve the wallet before pranking: the view call would otherwise consume the prank.
        MockFriendWallet wallet = MockFriendWallet(payable(walletOf(friendId)));
        vm.prank(friendOwner);
        return wallet.execute(target, 0, data, 0);
    }

    function sequenceOf(uint256 requestId) internal view returns (uint64 sequence) {
        (,,, sequence,,,) = coordinator.requests(requestId);
    }

    /// @dev Deliver Dice's word for a coordinator request.
    function fulfill(uint256 requestId, bytes32 word) internal {
        assertTrue(dice.reveal(sequenceOf(requestId), word), "callback failed");
    }

    function ledger(uint256 gameId)
        internal
        view
        returns (uint256 free, uint256 reserved, uint256 owed, uint256 credit)
    {
        return treasury.ledgers(gameId);
    }

    /// @dev Treasury invariant I1 for one currency.
    function assertSolvent(address currency) internal view {
        assertTrue(treasury.solvent(currency), "treasury insolvent");
    }
}
