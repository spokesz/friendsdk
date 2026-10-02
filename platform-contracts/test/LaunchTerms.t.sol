// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";

/// @dev The launch terms reproduce the deployed Penalty Kings odds and the Rare Breeds table.
contract LaunchTermsTest is Test {
    function testParkKickTablesMatchDeployedOdds() public pure {
        for (uint16 ball = 1; ball <= 7; ++ball) {
            for (uint8 gen = 1; gen <= 6; ++gen) {
                DrawTables.Row[] memory rows = LaunchTerms.parkKickTable(ball, gen);
                uint16[7] memory odds = _deployedOdds(ball, gen);
                uint256 total;
                uint256 expectedPaying;
                for (uint256 i; i < rows.length; ++i) {
                    total += rows[i].weightBps;
                    if (rows[i].value != 0) expectedPaying += rows[i].weightBps;
                }
                assertEq(total, 10_000, "weights sum");
                assertEq(10_000 - expectedPaying, odds[0], "saved weight");
                // Every paying prize appears once with the deployed weight, highest first.
                uint256 cursor;
                for (uint128 i = 6; i >= 1; --i) {
                    if (odds[i] == 0) continue;
                    assertEq(rows[cursor].weightBps, odds[i], "prize weight");
                    assertEq(rows[cursor].value, LaunchTerms.PARK_GOAL_PRIZE << (i - 1), "prize");
                    ++cursor;
                }
                assertEq(rows[cursor].value, 0, "saved row last");
                assertEq(rows[cursor].classId, 0, "saved mints nothing");
                assertEq(cursor + 1, rows.length, "row count");
            }
        }
    }

    function testParkGenerationReturnsAreExact() public pure {
        uint16[7] memory weights = [uint16(3150), 2700, 2000, 1100, 700, 250, 100];
        for (uint8 gen = 1; gen <= 6; ++gen) {
            // Expected payout per purchased ball, scaled by 1e8 (bps × bps).
            uint256 expected;
            for (uint16 ball = 1; ball <= 7; ++ball) {
                DrawTables.Row[] memory rows = LaunchTerms.parkKickTable(ball, gen);
                uint256 perKick;
                for (uint256 i; i < rows.length; ++i) {
                    perKick += uint256(rows[i].weightBps) * rows[i].value;
                }
                expected += uint256(weights[ball - 1]) * perKick;
            }
            // Return = expected payout per pack / price; both balls share one pack.
            uint256 returnBps = expected * 2 * 10_000 / (LaunchTerms.PARK_PACK_PRICE * 1e8);
            assertEq(returnBps, 10_000 - LaunchTerms.parkEdgeBps(gen), "generation return");
        }
    }

    function testParkPackSplitsReproduceDeployedRouting() public pure {
        (, DrawTables.Split[6] memory splits, DrawTables.Row[][] memory tables) =
            LaunchTerms.parkPackAction();
        for (uint8 gen = 1; gen <= 6; ++gen) {
            DrawTables.Split memory s = splits[gen - 1];
            assertEq(
                uint256(s.freeBps) + s.developerBps + s.operatorBps + s.burnBps + s.rewardsBps,
                10_000
            );
            uint256 price = 20 * LaunchTerms.USDG_UNIT;
            uint256 feeTotal = price * LaunchTerms.parkEdgeBps(gen) / 10_000;
            assertEq(price * s.operatorBps / 10_000, feeTotal / 4, "operator share");
            assertEq(price * s.developerBps / 10_000, feeTotal - feeTotal / 4, "developer share");
        }
        assertEq(tables.length, 1);
        assertEq(tables[0].length, 7);
    }

    function testBreedsTableAndExpectation() public pure {
        (,, DrawTables.Row[][] memory tables) = LaunchTerms.breedsPlayAction();
        DrawTables.Class[] memory classes = LaunchTerms.breedsClasses();
        uint256 total;
        uint256 expected;
        for (uint256 i; i < tables[0].length; ++i) {
            total += tables[0][i].weightBps;
            expected += uint256(tables[0][i].weightBps) * classes[tables[0][i].classId - 1].value;
        }
        assertEq(total, 10_000);
        assertEq(expected / 10_000, 0.8875e18);
        assertEq(LaunchTerms.royaleKindPrices().length, 13);
    }

    /// @dev PenaltyKingsPark.payoutOdds, transcribed: [saved, 2, 4, 8, 16, 32, 64].
    function _deployedOdds(uint16 ballId, uint8 generation)
        private
        pure
        returns (uint16[7] memory odds)
    {
        if (ballId < 5) {
            uint16[4] memory chances = [uint16(3300), 4000, 4500, 4800];
            odds[1] = chances[ballId - 1];
        } else if (ballId == 5) {
            odds = [uint16(0), 3600, 800, 500, 100, 0, 0];
        } else {
            odds = [uint16(0), 3900, 800, 400, 200, 100, 0];
            if (ballId == 7) odds[6] = 100;
        }
        odds[1] += uint16(6 - generation) * 50;
        uint16 chance;
        for (uint256 i = 1; i < odds.length; ++i) {
            chance += odds[i];
        }
        odds[0] = 10_000 - chance;
    }
}
