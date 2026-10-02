// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { Treasury } from "../src/Treasury.sol";
import { RandomnessCoordinator } from "../src/RandomnessCoordinator.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { Mainnet } from "./Mainnet.sol";

/// @notice Simulation of the hub deployment against the verified mainnet dependencies.
/// @dev Runs without broadcasting unless `--broadcast` is passed explicitly, which requires the
/// separate deployment authorization described in docs/BRIEF.md. Required environment:
/// PLATFORM_OWNER (multisig), PLATFORM_CUSTODY_EXECUTOR (may be zero to disable custody paths).
contract Deploy is Script {
    error WrongChain();

    function run() external {
        if (block.chainid != Mainnet.CHAIN_ID) revert WrongChain();
        address owner = vm.envAddress("PLATFORM_OWNER");
        address executor = vm.envOr("PLATFORM_CUSTODY_EXECUTOR", address(0));

        vm.startBroadcast();
        GameRegistry registry = new GameRegistry(
            owner, Mainnet.GENERATIONS, Mainnet.RF, Mainnet.USDG, Mainnet.FRIEND_CUSTODY, executor
        );
        Treasury treasury =
            new Treasury(address(registry), Mainnet.RF, Mainnet.USDG, Mainnet.GENERATIONS);
        RandomnessCoordinator coordinator = new RandomnessCoordinator(
            address(registry), Mainnet.DICE_ENTROPY, Mainnet.DICE_PROVIDER
        );
        DrawModule draw = new DrawModule(
            address(registry), address(treasury), address(coordinator), Mainnet.GENERATIONS
        );
        RoundModule round = new RoundModule(
            address(registry), address(treasury), address(coordinator), Mainnet.GENERATIONS
        );
        vm.stopBroadcast();

        console.log("GameRegistry          ", address(registry));
        console.log("Treasury              ", address(treasury));
        console.log("RandomnessCoordinator ", address(coordinator));
        console.log("DrawModule            ", address(draw));
        console.log("RoundModule           ", address(round));
        console.log("Owner must now: allowModule(draw), allowModule(round), setMaxFee(25e12).");
    }
}
