// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { Treasury } from "../src/Treasury.sol";
import { RandomnessCoordinator } from "../src/RandomnessCoordinator.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { GameItems } from "../src/GameItems.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { IDiceEntropy, IGenerations } from "../src/interfaces/IExternal.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";
import { Mainnet } from "../script/Mainnet.sol";

interface IFriendCustody {
    function beneficiary(uint256 tokenId) external view returns (address);
}

/// @dev Runs the real RF, Generations, canonical wallet, FriendCustody and Dice code on a local
/// fork of Robinhood mainnet. Gated on PLATFORM_FORK_RPC; never broadcasts. Dice delivery is
/// simulated by pranking the oracle because the live provider cannot observe a private fork.
contract MainnetForkTest is Test {
    uint256 internal constant FRIEND = 7730; // a hardwired generation-3 Friend
    address internal owner = makeAddr("owner");
    address internal funder = makeAddr("funder");

    GameRegistry internal registry;
    Treasury internal treasury;
    RandomnessCoordinator internal coordinator;
    DrawModule internal draw;
    RoundModule internal round;
    uint256 internal breedsId;

    function setUp() public {
        string memory rpc = vm.envOr("PLATFORM_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, Mainnet.CHAIN_ID);
        registry = new GameRegistry(
            owner, Mainnet.GENERATIONS, Mainnet.RF, Mainnet.USDG, Mainnet.FRIEND_CUSTODY, address(0)
        );
        treasury = new Treasury(address(registry), Mainnet.RF, Mainnet.USDG, Mainnet.GENERATIONS);
        coordinator = new RandomnessCoordinator(
            address(registry), Mainnet.DICE_ENTROPY, Mainnet.DICE_PROVIDER
        );
        draw = new DrawModule(
            address(registry), address(treasury), address(coordinator), Mainnet.GENERATIONS
        );
        round = new RoundModule(
            address(registry), address(treasury), address(coordinator), Mainnet.GENERATIONS
        );
        vm.deal(address(coordinator), 1 ether);
        vm.startPrank(owner);
        registry.allowModule(address(draw));
        registry.allowModule(address(round));
        coordinator.setMaxFee(Mainnet.OBSERVED_DICE_FEE);
        breedsId = registry.createGame(
            address(draw), Mainnet.RF, funder, address(0), address(0), address(0), 5, "breeds/{id}"
        );
        draw.defineClasses(breedsId, LaunchTerms.breedsClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        draw.defineAction(breedsId, a, s, t);
        (a, s, t) = LaunchTerms.breedsPlayAction();
        draw.defineAction(breedsId, a, s, t);
        registry.activateGame(breedsId);
        coordinator.setBudget(breedsId, 0.1 ether);
        vm.stopPrank();
    }

    function testRealDependenciesAndDiceRequestRefundPath() public {
        IGenerations generations = IGenerations(Mainnet.GENERATIONS);
        assertEq(generations.token(), Mainnet.RF, "Generations is bound to RF");
        assertGe(generations.generation(FRIEND), 1, "hardwired Friend");
        address friendOwner = generations.ownerOf(FRIEND);
        address wallet = generations.tokenBoundAccount(FRIEND);
        assertTrue(wallet.code.length != 0, "canonical wallet deployed");
        // FriendCustody answers the beneficiary query for any id.
        IFriendCustody(Mainnet.FRIEND_CUSTODY).beneficiary(FRIEND);

        // Real Dice quote and refund delay.
        IDiceEntropy dice = IDiceEntropy(Mainnet.DICE_ENTROPY);
        assertEq(dice.getFeeV2(Mainnet.DICE_PROVIDER, 200_000), Mainnet.OBSERVED_DICE_FEE);
        assertEq(dice.getRefundDelayBlocks(), 6);

        // Fund the game and the player with real RF (storage write on the real token).
        deal(Mainnet.RF, funder, 100e18);
        vm.startPrank(funder);
        IERC20(Mainnet.RF).approve(address(treasury), 100e18);
        treasury.fund(breedsId, 100e18);
        vm.stopPrank();
        deal(Mainnet.RF, friendOwner, 1e18);
        vm.startPrank(friendOwner);
        IERC20(Mainnet.RF).approve(address(treasury), 1e18);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        assertEq(GameItems(registry.itemsOf(breedsId)).balanceOf(wallet, LaunchTerms.BREEDS_EGG), 1);
        // The play requests a real Dice word through the real requestV2.
        uint256 commitId = draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0);
        vm.stopPrank();
        (,,,,,,, uint256 requestId) = draw.commits(commitId);
        (,,, uint64 sequence,,,) = coordinator.requests(requestId);
        IDiceEntropy.Request memory req = dice.getRequestV2(Mainnet.DICE_PROVIDER, sequence);
        assertEq(req.sequenceNumber, sequence, "request struct layout decodes");
        assertEq(req.requester, address(coordinator));
        assertEq(req.callbackStatus, 1);
        assertEq(req.feePaid, Mainnet.OBSERVED_DICE_FEE);

        // Dice's own reclaim path: too early, then after the delay with the fee returned.
        vm.expectRevert();
        coordinator.retry(requestId);
        vm.roll(block.number + 6);
        uint256 budgetBefore = coordinator.budget(breedsId);
        coordinator.retry(requestId);
        assertEq(coordinator.budget(breedsId), budgetBefore, "reclaimed fee paid the retry");
        (,,, uint64 fresh, uint32 attempt,,) = coordinator.requests(requestId);
        assertTrue(fresh != sequence && attempt == 1);
        assertEq(dice.getRequestV2(Mainnet.DICE_PROVIDER, sequence).sequenceNumber, 0, "cleared");

        // Simulated delivery for the fresh sequence, then settlement mints into the real wallet.
        vm.prank(Mainnet.DICE_ENTROPY);
        coordinator._entropyCallback(fresh, Mainnet.DICE_PROVIDER, keccak256("fork word"));
        draw.settle(commitId);
        uint256 tiers;
        for (uint256 id = 2; id <= 5; ++id) {
            tiers += GameItems(registry.itemsOf(breedsId)).balanceOf(wallet, id);
        }
        assertEq(tiers, 1, "one tier token in the canonical wallet");
        assertTrue(treasury.solvent(Mainnet.RF));
    }
}
