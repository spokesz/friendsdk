// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { DrawTables } from "../src/libraries/DrawTables.sol";

/// @notice The three launch games' terms exactly as docs/SPEC.md section 3 states them.
/// @dev Shared by the test fixture, the integration tests and the simulation scripts so every
/// consumer registers byte-identical terms and therefore the same terms hash.
library LaunchTerms {
    uint256 internal constant RF_UNIT = 1e18;
    uint256 internal constant USDG_UNIT = 1e6;

    // ----------------------------------------------------------------- Rare Breeds (RF)

    uint16 internal constant BREEDS_EGG = 1;
    uint16 internal constant BREEDS_COMMON = 2;
    uint16 internal constant BREEDS_SPOTTED = 3;
    uint16 internal constant BREEDS_MUTANT = 4;
    uint16 internal constant BREEDS_PRISMATIC = 5;
    uint8 internal constant BREEDS_BUY = 1;
    uint8 internal constant BREEDS_PLAY = 2;

    function breedsClasses() internal pure returns (DrawTables.Class[] memory classes) {
        classes = new DrawTables.Class[](5);
        classes[0] = DrawTables.Class(0, 6e18);
        classes[1] = DrawTables.Class(5e17, 0);
        classes[2] = DrawTables.Class(1e18, 0);
        classes[3] = DrawTables.Class(15e17, 0);
        classes[4] = DrawTables.Class(6e18, 0);
    }

    function breedsBuyAction()
        internal
        pure
        returns (
            DrawTables.Action memory action,
            DrawTables.Split[6] memory splits,
            DrawTables.Row[][] memory tables
        )
    {
        action = DrawTables.Action(DrawTables.Input.Currency, 0, 0, 1e18, 1, 10, false);
        for (uint256 g; g < 6; ++g) {
            splits[g] = DrawTables.Split(10_000, 0, 0, 0, 0);
        }
        tables = new DrawTables.Row[][](1);
        tables[0] = new DrawTables.Row[](1);
        tables[0][0] = DrawTables.Row(10_000, BREEDS_EGG, 0);
    }

    function breedsPlayAction()
        internal
        pure
        returns (
            DrawTables.Action memory action,
            DrawTables.Split[6] memory splits,
            DrawTables.Row[][] memory tables
        )
    {
        action = DrawTables.Action(DrawTables.Input.BurnClass, BREEDS_EGG, 1, 0, 1, 10, false);
        splits = _noSplits();
        tables = new DrawTables.Row[][](1);
        tables[0] = new DrawTables.Row[](4);
        tables[0][0] = DrawTables.Row(6000, BREEDS_COMMON, 0);
        tables[0][1] = DrawTables.Row(2500, BREEDS_SPOTTED, 0);
        tables[0][2] = DrawTables.Row(1250, BREEDS_MUTANT, 0);
        tables[0][3] = DrawTables.Row(250, BREEDS_PRISMATIC, 0);
    }

    // ------------------------------------------------------------- Penalty Kings (USDG)

    uint8 internal constant PARK_BALLS = 7;
    uint8 internal constant PARK_PACK = 1;
    uint128 internal constant PARK_PACK_PRICE = 2e6;
    uint128 internal constant PARK_GOAL_PRIZE = 2e6;

    /// @dev Kick action id for a ball class (1..7).
    function parkKickAction(uint16 ball) internal pure returns (uint8) {
        // Ball ids are 1..7, so the action id is 2..8.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(ball + 1);
    }

    function parkClasses() internal pure returns (DrawTables.Class[] memory classes) {
        classes = new DrawTables.Class[](PARK_BALLS);
    }

    /// @dev Gross house edge in bps by generation: gen 6 is 10%, gen 1 is 5%.
    function parkEdgeBps(uint8 generation) internal pure returns (uint16) {
        return 400 + 100 * uint16(generation);
    }

    function parkPackAction()
        internal
        pure
        returns (
            DrawTables.Action memory action,
            DrawTables.Split[6] memory splits,
            DrawTables.Row[][] memory tables
        )
    {
        action = DrawTables.Action(DrawTables.Input.Currency, 0, 0, PARK_PACK_PRICE, 2, 10, false);
        for (uint8 g = 1; g <= 6; ++g) {
            uint16 edge = parkEdgeBps(g);
            uint16 operator = edge / 4;
            splits[g - 1] = DrawTables.Split(10_000 - edge, edge - operator, operator, 0, 0);
        }
        uint16[7] memory weights = [uint16(3150), 2700, 2000, 1100, 700, 250, 100];
        tables = new DrawTables.Row[][](1);
        tables[0] = new DrawTables.Row[](PARK_BALLS);
        for (uint16 ball = 1; ball <= PARK_BALLS; ++ball) {
            tables[0][ball - 1] = DrawTables.Row(weights[ball - 1], ball, 0);
        }
    }

    /// @dev Per-kick table for one ball and generation, highest prize first, saved row last,
    /// reproducing the deployed PenaltyKingsPark payoutOdds and prizeForRoll ordering.
    function parkKickTable(uint16 ball, uint8 generation)
        internal
        pure
        returns (DrawTables.Row[] memory rows)
    {
        uint16 bonus = uint16(6 - generation) * 50;
        uint16 goal;
        if (ball < 5) {
            uint16[4] memory bases = [uint16(3300), 4000, 4500, 4800];
            goal = bases[ball - 1] + bonus;
            rows = new DrawTables.Row[](2);
            rows[0] = DrawTables.Row(goal, 0, PARK_GOAL_PRIZE);
            rows[1] = DrawTables.Row(10_000 - goal, 0, 0);
            return rows;
        }
        // Weights for 64, 32, 16, 8, 4 USDG followed by the generation-adjusted 2 USDG row.
        uint16[5] memory upper;
        uint256 count;
        if (ball == 5) {
            upper = [uint16(0), 0, 100, 500, 800];
            count = 5;
        } else if (ball == 6) {
            upper = [uint16(0), 100, 200, 400, 800];
            count = 6;
        } else {
            upper = [uint16(100), 100, 200, 400, 800];
            count = 7;
        }
        rows = new DrawTables.Row[](count);
        uint256 index;
        uint16 paying;
        for (uint128 i; i < 5; ++i) {
            if (upper[i] == 0) continue;
            rows[index++] = DrawTables.Row(upper[i], 0, PARK_GOAL_PRIZE << (5 - i));
            paying += upper[i];
        }
        goal = (ball == 5 ? 3600 : 3900) + bonus;
        rows[index++] = DrawTables.Row(goal, 0, PARK_GOAL_PRIZE);
        rows[index] = DrawTables.Row(10_000 - paying - goal, 0, 0);
    }

    function parkKickActionTerms(uint16 ball)
        internal
        pure
        returns (
            DrawTables.Action memory action,
            DrawTables.Split[6] memory splits,
            DrawTables.Row[][] memory tables
        )
    {
        action = DrawTables.Action(DrawTables.Input.BurnClass, ball, 1, 0, 1, 1, true);
        splits = _noSplits();
        tables = new DrawTables.Row[][](6);
        for (uint8 g = 1; g <= 6; ++g) {
            tables[g - 1] = parkKickTable(ball, g);
        }
    }

    /// @dev BurnClass actions carry no routing; every split field is zero.
    function _noSplits() private pure returns (DrawTables.Split[6] memory splits) {
        return splits;
    }

    /// @dev Maximum prize a ball can pay, in USDG base units.
    function parkMaxPrize(uint16 ball) internal pure returns (uint256) {
        return PARK_GOAL_PRIZE * (ball < 5 ? 1 : uint256(1) << (ball - 2));
    }

    // ------------------------------------------------------------------ Rare Royale (RF)

    uint128 internal constant ROYALE_ENTRY = 1e18;
    uint16 internal constant ROYALE_POT_BPS = 8000;
    uint16 internal constant ROYALE_BURN_BPS = 1000;
    uint16 internal constant ROYALE_REWARDS_BPS = 1000;
    uint16 internal constant ROYALE_SPEND_BURN_BPS = 5000;
    uint16 internal constant ROYALE_SPEND_REWARDS_BPS = 5000;
    uint16 internal constant ROYALE_MIN_ENTRIES = 5;
    uint16 internal constant ROYALE_MAX_ENTRIES = 50;

    /// @dev Kinds 1..13: shield, medkit, second life I/II/III, paid call, shout, aura I/II/III,
    /// title I/II/III.
    function royaleKindPrices() internal pure returns (uint128[] memory prices) {
        prices = new uint128[](13);
        prices[0] = 1e18;
        prices[1] = 1e18;
        prices[2] = 2e18;
        prices[3] = 4e18;
        prices[4] = 8e18;
        prices[5] = 1e18;
        prices[6] = 1e18;
        prices[7] = 2e18;
        prices[8] = 2e18;
        prices[9] = 5e18;
        prices[10] = 1e18;
        prices[11] = 3e18;
        prices[12] = 5e18;
    }
}
