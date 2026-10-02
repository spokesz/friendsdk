// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { LaunchTerms } from "./LaunchTerms.sol";
import { Mainnet } from "./Mainnet.sol";

/// @notice Simulation of registering the three launch games with docs/SPEC.md section 3 terms.
/// @dev Must run as the registry owner (simulate with `--sender <owner>`). Environment:
/// PLATFORM_REGISTRY, PLATFORM_DRAW, PLATFORM_ROUND, PLATFORM_FUNDER, PLATFORM_SETTLER.
contract RegisterLaunchGames is Script {
    address internal constant PARK_DEVELOPER = 0xd0BB5CC938dA89E0d7129F1eE01C2cfc61C2e36F;
    address internal constant PARK_OPERATOR = 0x1EcBF27dC1F809179B9ef2d382cd76ccBa21B6d2;

    function run() external {
        GameRegistry registry = GameRegistry(vm.envAddress("PLATFORM_REGISTRY"));
        DrawModule draw = DrawModule(vm.envAddress("PLATFORM_DRAW"));
        RoundModule round = RoundModule(vm.envAddress("PLATFORM_ROUND"));
        address funder = vm.envAddress("PLATFORM_FUNDER");
        address settler = vm.envAddress("PLATFORM_SETTLER");

        vm.startBroadcast();
        uint256 breeds = registry.createGame(
            address(draw), Mainnet.RF, funder, address(0), address(0), address(0), 5, ""
        );
        draw.defineClasses(breeds, LaunchTerms.breedsClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        draw.defineAction(breeds, a, s, t);
        (a, s, t) = LaunchTerms.breedsPlayAction();
        draw.defineAction(breeds, a, s, t);
        registry.activateGame(breeds);

        uint256 park = registry.createGame(
            address(draw),
            Mainnet.USDG,
            funder,
            PARK_DEVELOPER,
            PARK_OPERATOR,
            address(0),
            LaunchTerms.PARK_BALLS,
            ""
        );
        draw.defineClasses(park, LaunchTerms.parkClasses());
        (a, s, t) = LaunchTerms.parkPackAction();
        draw.defineAction(park, a, s, t);
        for (uint16 ball = 1; ball <= LaunchTerms.PARK_BALLS; ++ball) {
            (a, s, t) = LaunchTerms.parkKickActionTerms(ball);
            draw.defineAction(park, a, s, t);
        }
        registry.activateGame(park);

        uint256 royale = registry.createGame(
            address(round), Mainnet.RF, funder, address(0), address(0), settler, 0, ""
        );
        round.defineTerms(
            royale,
            RoundModule.Terms({
                entryPrice: LaunchTerms.ROYALE_ENTRY,
                potBps: LaunchTerms.ROYALE_POT_BPS,
                burnBps: LaunchTerms.ROYALE_BURN_BPS,
                rewardsBps: LaunchTerms.ROYALE_REWARDS_BPS,
                spendBurnBps: LaunchTerms.ROYALE_SPEND_BURN_BPS,
                spendRewardsBps: LaunchTerms.ROYALE_SPEND_REWARDS_BPS,
                minEntries: LaunchTerms.ROYALE_MIN_ENTRIES,
                maxEntries: LaunchTerms.ROYALE_MAX_ENTRIES
            }),
            LaunchTerms.royaleKindPrices()
        );
        registry.activateGame(royale);
        vm.stopBroadcast();

        console.log("Rare Breeds   gameId", breeds);
        console.logBytes32(draw.termsHash(breeds));
        console.log("Penalty Kings gameId", park);
        console.logBytes32(draw.termsHash(park));
        console.log("Rare Royale   gameId", royale);
        console.logBytes32(round.termsHash(royale));
        console.log("Next: Treasury.fund per game, Coordinator.setBudget per game, fund ETH.");
    }
}
