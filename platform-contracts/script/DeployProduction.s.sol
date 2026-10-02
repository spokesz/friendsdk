// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { Treasury } from "../src/Treasury.sol";
import { RandomnessCoordinator } from "../src/RandomnessCoordinator.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { LaunchTerms } from "./LaunchTerms.sol";
import { Mainnet } from "./Mainnet.sol";

/// @notice Production deployment of the hub plus Penalty Kings registration and funding.
/// @dev Keys come from the environment, never from arguments: PLATFORM_DEPLOYER_KEY (becomes the
/// registry owner and the game's funder), PLATFORM_KEEPER_KEY (tops up the deployer and funds the
/// coordinator), PLATFORM_EXECUTOR_KEY (the custody executor; funds the USDG bankroll).
/// Simulates unless --broadcast is passed; run with --slow so each transaction is mined in order.
contract DeployProduction is Script {
    uint256 internal constant DEPLOYER_TOP_UP = 0.004 ether;
    uint256 internal constant COORDINATOR_ETH = 0.01 ether;
    uint256 internal constant DICE_BUDGET = 0.01 ether;
    uint256 internal constant PARK_BANKROLL = 150e6; // 150 USDG
    address internal constant PARK_DEVELOPER = 0xd0BB5CC938dA89E0d7129F1eE01C2cfc61C2e36F;
    address internal constant PARK_OPERATOR = 0x1EcBF27dC1F809179B9ef2d382cd76ccBa21B6d2;
    string internal constant PARK_ITEMS_URI =
        "https://rarefriends-game-items.rarefriends-protocol.workers.dev/penalty-kings/v1/{id}.json";

    error WrongChain();

    struct Hub {
        GameRegistry registry;
        Treasury treasury;
        RandomnessCoordinator coordinator;
        DrawModule draw;
        RoundModule round;
        uint256 park;
    }

    function run() external {
        if (block.chainid != Mainnet.CHAIN_ID) revert WrongChain();
        uint256 deployerKey = vm.envUint("PLATFORM_DEPLOYER_KEY");
        uint256 keeperKey = vm.envUint("PLATFORM_KEEPER_KEY");
        uint256 executorKey = vm.envUint("PLATFORM_EXECUTOR_KEY");

        // 1. Gas for the deployer.
        vm.startBroadcast(keeperKey);
        payable(vm.addr(deployerKey)).transfer(DEPLOYER_TOP_UP);
        vm.stopBroadcast();

        // 2. Hub, modules and Penalty Kings from the deployer, who is the registry owner.
        vm.startBroadcast(deployerKey);
        Hub memory hub = _deploy(vm.addr(deployerKey), vm.addr(executorKey));
        _registerPark(hub, vm.addr(deployerKey));
        vm.stopBroadcast();

        // 3. Randomness fees from the keeper account.
        vm.startBroadcast(keeperKey);
        (bool funded,) = address(hub.coordinator).call{ value: COORDINATOR_ETH }("");
        require(funded, "coordinator funding failed");
        vm.stopBroadcast();

        // 4. Prize bankroll from the executor's USDG.
        vm.startBroadcast(executorKey);
        IERC20(Mainnet.USDG).approve(address(hub.treasury), PARK_BANKROLL);
        hub.treasury.fund(hub.park, PARK_BANKROLL);
        vm.stopBroadcast();

        _writeManifest(hub, vm.addr(deployerKey), vm.addr(executorKey));
    }

    function _deploy(address owner, address executor) private returns (Hub memory hub) {
        hub.registry = new GameRegistry(
            owner, Mainnet.GENERATIONS, Mainnet.RF, Mainnet.USDG, Mainnet.FRIEND_CUSTODY, executor
        );
        hub.treasury =
            new Treasury(address(hub.registry), Mainnet.RF, Mainnet.USDG, Mainnet.GENERATIONS);
        hub.coordinator = new RandomnessCoordinator(
            address(hub.registry), Mainnet.DICE_ENTROPY, Mainnet.DICE_PROVIDER
        );
        hub.draw = new DrawModule(
            address(hub.registry),
            address(hub.treasury),
            address(hub.coordinator),
            Mainnet.GENERATIONS
        );
        hub.round = new RoundModule(
            address(hub.registry),
            address(hub.treasury),
            address(hub.coordinator),
            Mainnet.GENERATIONS
        );
        hub.registry.allowModule(address(hub.draw));
        hub.registry.allowModule(address(hub.round));
        hub.coordinator.setMaxFee(Mainnet.OBSERVED_DICE_FEE);
    }

    function _registerPark(Hub memory hub, address funder) private {
        hub.park = hub.registry
            .createGame(
                address(hub.draw),
                Mainnet.USDG,
                funder,
                PARK_DEVELOPER,
                PARK_OPERATOR,
                address(0),
                LaunchTerms.PARK_BALLS,
                PARK_ITEMS_URI
            );
        hub.draw.defineClasses(hub.park, LaunchTerms.parkClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.parkPackAction();
        hub.draw.defineAction(hub.park, a, s, t);
        for (uint16 ball = 1; ball <= LaunchTerms.PARK_BALLS; ++ball) {
            (a, s, t) = LaunchTerms.parkKickActionTerms(ball);
            hub.draw.defineAction(hub.park, a, s, t);
        }
        hub.registry.activateGame(hub.park);
        hub.coordinator.setBudget(hub.park, DICE_BUDGET);
    }

    function _writeManifest(Hub memory hub, address owner, address executor) private {
        string memory json = "manifest";
        vm.serializeUint(json, "schemaVersion", 2);
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "owner", owner);
        vm.serializeAddress(json, "registry", address(hub.registry));
        vm.serializeAddress(json, "treasury", address(hub.treasury));
        vm.serializeAddress(json, "coordinator", address(hub.coordinator));
        vm.serializeAddress(json, "drawModule", address(hub.draw));
        vm.serializeAddress(json, "roundModule", address(hub.round));
        vm.serializeAddress(json, "items", hub.registry.itemsOf(hub.park));
        vm.serializeUint(json, "gameId", hub.park);
        vm.serializeUint(json, "deploymentBlock", block.number);
        vm.serializeBytes32(json, "termsHash", hub.draw.termsHash(hub.park));
        vm.serializeAddress(json, "usdg", Mainnet.USDG);
        vm.serializeAddress(json, "generations", Mainnet.GENERATIONS);
        vm.serializeAddress(json, "custody", Mainnet.FRIEND_CUSTODY);
        string memory out = vm.serializeAddress(json, "custodyExecutor", executor);
        vm.writeJson(out, "./deployments/4663-platform.json");
        console.log("GameRegistry          ", address(hub.registry));
        console.log("Treasury              ", address(hub.treasury));
        console.log("RandomnessCoordinator ", address(hub.coordinator));
        console.log("DrawModule            ", address(hub.draw));
        console.log("RoundModule           ", address(hub.round));
        console.log("Penalty Kings items   ", hub.registry.itemsOf(hub.park));
        console.log("Penalty Kings gameId  ", hub.park);
    }
}
