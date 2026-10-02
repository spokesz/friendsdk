// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Fixture } from "./Fixture.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { Treasury } from "../src/Treasury.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { FriendAccess } from "../src/libraries/FriendAccess.sol";
import { Rolls } from "../src/libraries/Rolls.sol";

/// @dev Penalty Kings through the integrated hub (docs/SPEC.md sections 3.3, 4.2, 7.2, 7.3 and
/// the `PenaltyKings.t.sol` row of section 9): the rarity and 42 kick tables, generation
/// returns, the deployed fee arithmetic, kick reservations, blocked USDG payouts, the custody
/// replay matrix and fee payout.
contract PenaltyKingsTest is Fixture {
    uint256 internal constant FRIEND = 1234;
    uint8 internal constant GEN = 3;
    uint256 internal constant CUSTODIED = 777;
    uint8 internal constant CUSTODIED_GEN = 5;
    uint256 internal constant STAKE = 5000e6;
    uint16 internal constant GOLDEN_BOOT = 7;
    uint256 internal constant GOLDEN_BOOT_MAX = 64e6;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        mintFriend(alice, FRIEND, GEN);
        mintFriend(address(custody), CUSTODIED, CUSTODIED_GEN);
    }

    // ----------------------------------------------------------------------- helpers

    /// @dev A word whose roll for draw `index` of `commitId` equals `target` (about 10k tries).
    /// Runs in its own call frame and hashes in scratch memory so the search never grows memory.
    function wordFor(uint256 commitId, uint256 index, uint16 target)
        external
        view
        returns (bytes32 word)
    {
        address module = address(draw);
        uint256 chainId = block.chainid;
        uint256 limit = type(uint256).max - (type(uint256).max % Rolls.RANGE);
        for (uint256 nonce;; ++nonce) {
            uint256 value;
            assembly ("memory-safe") {
                mstore(0, nonce)
                word := keccak256(0, 32)
                let p := mload(0x40)
                mstore(p, word)
                mstore(add(p, 32), module)
                mstore(add(p, 64), chainId)
                mstore(add(p, 96), commitId)
                mstore(add(p, 128), index)
                value := keccak256(p, 160)
            }
            if (value < limit && value % Rolls.RANGE == target) break;
        }
        assertEq(Rolls.roll(word, module, chainId, commitId, index), target, "search");
    }

    function _wordFor(uint256 commitId, uint16 target) internal view returns (bytes32) {
        return this.wordFor(commitId, 0, target);
    }

    function _balls(uint256 friendId, uint16 ball) internal view returns (uint256) {
        return items(parkId).balanceOf(walletOf(friendId), ball);
    }

    function _requestOf(uint256 commitId) internal view returns (uint256 requestId) {
        (,,,,,,, requestId) = draw.commits(commitId);
    }

    function _isSettled(uint256 commitId) internal view returns (bool settled) {
        (,,,,, settled,,) = draw.commits(commitId);
    }

    /// @dev Buys `quantity` packs for a Friend from its owner, leaving the commit pending.
    function _buyPacks(address buyer, uint256 friendId, uint8 quantity)
        internal
        returns (uint256 commitId)
    {
        giveUSDG(buyer, uint256(quantity) * LaunchTerms.PARK_PACK_PRICE);
        vm.prank(buyer);
        commitId = draw.commit(parkId, LaunchTerms.PARK_PACK, friendId, quantity, 0, 0);
    }

    /// @dev Buys one pack and forces its first draw onto a Golden Boot (roll 9900), so the
    /// wallet holds ball 7 afterwards.
    function _giveGoldenBoot(address buyer, uint256 friendId) internal {
        uint256 commitId = _buyPacks(buyer, friendId, 1);
        fulfill(_requestOf(commitId), _wordFor(commitId, 9900));
        draw.settle(commitId);
        assertTrue(_balls(friendId, GOLDEN_BOOT) != 0, "Golden Boot minted");
    }

    /// @dev Commits a Golden Boot kick from the owner; returns the commit and its request.
    function _kickGoldenBoot(address kicker, uint256 friendId)
        internal
        returns (uint256 commitId, uint256 requestId)
    {
        vm.prank(kicker);
        commitId = draw.commit(parkId, LaunchTerms.parkKickAction(GOLDEN_BOOT), friendId, 1, 0, 0);
        requestId = _requestOf(commitId);
    }

    /// @dev Prize the deployed PenaltyKingsPark `prizeForRoll` pays for `roll` on a kick table
    /// written as the spec states it: cumulative thresholds, highest prize first.
    function _prizeForRoll(DrawTables.Row[] memory rows, uint16 roll)
        internal
        pure
        returns (uint256)
    {
        uint256 cumulative;
        for (uint256 i; i < rows.length; ++i) {
            cumulative += rows[i].weightBps;
            if (roll < cumulative) return rows[i].value;
        }
        revert("roll outside table");
    }

    /// @dev Section 3.3 kick table for one ball and generation, written out independently of
    /// LaunchTerms: the paying rows highest prize first, then the generation-adjusted 2 USDG
    /// row, then the saved row.
    function _specKickTable(uint16 ball, uint8 generation)
        internal
        pure
        returns (DrawTables.Row[] memory rows)
    {
        uint16 bonus = (6 - generation) * 50;
        uint16[7] memory goalBases = [uint16(3300), 4000, 4500, 4800, 3600, 3900, 3900];
        uint16 goal = goalBases[ball - 1] + bonus;
        if (ball < 5) {
            rows = new DrawTables.Row[](2);
            rows[0] = DrawTables.Row(goal, 0, 2e6);
            rows[1] = DrawTables.Row(10_000 - goal, 0, 0);
        } else if (ball == 5) {
            rows = new DrawTables.Row[](5);
            rows[0] = DrawTables.Row(100, 0, 16e6);
            rows[1] = DrawTables.Row(500, 0, 8e6);
            rows[2] = DrawTables.Row(800, 0, 4e6);
            rows[3] = DrawTables.Row(goal, 0, 2e6);
            rows[4] = DrawTables.Row(10_000 - 1400 - goal, 0, 0);
        } else if (ball == 6) {
            rows = new DrawTables.Row[](6);
            rows[0] = DrawTables.Row(100, 0, 32e6);
            rows[1] = DrawTables.Row(200, 0, 16e6);
            rows[2] = DrawTables.Row(400, 0, 8e6);
            rows[3] = DrawTables.Row(800, 0, 4e6);
            rows[4] = DrawTables.Row(goal, 0, 2e6);
            rows[5] = DrawTables.Row(10_000 - 1500 - goal, 0, 0);
        } else {
            rows = new DrawTables.Row[](7);
            rows[0] = DrawTables.Row(100, 0, 64e6);
            rows[1] = DrawTables.Row(100, 0, 32e6);
            rows[2] = DrawTables.Row(200, 0, 16e6);
            rows[3] = DrawTables.Row(400, 0, 8e6);
            rows[4] = DrawTables.Row(800, 0, 4e6);
            rows[5] = DrawTables.Row(goal, 0, 2e6);
            rows[6] = DrawTables.Row(10_000 - 1600 - goal, 0, 0);
        }
    }

    function _assertRowsEqual(
        DrawTables.Row[] memory actual,
        DrawTables.Row[] memory expected,
        string memory label
    ) internal pure {
        assertEq(actual.length, expected.length, string.concat(label, " length"));
        for (uint256 i; i < expected.length; ++i) {
            assertEq(actual[i].weightBps, expected[i].weightBps, string.concat(label, " weight"));
            assertEq(actual[i].classId, expected[i].classId, string.concat(label, " class"));
            assertEq(actual[i].value, expected[i].value, string.concat(label, " value"));
        }
    }

    // -------------------------------------------------------------------------- tables

    /// @dev The pack's rarity table is exactly the section 3.3 row list and reserves nothing.
    function testRarityTableExact() public view {
        DrawTables.Row[] memory table = draw.rows(parkId, LaunchTerms.PARK_PACK, 0);
        uint16[7] memory weights = [uint16(3150), 2700, 2000, 1100, 700, 250, 100];
        assertEq(table.length, 7);
        uint256 total;
        for (uint16 ball = 1; ball <= 7; ++ball) {
            assertEq(table[ball - 1].weightBps, weights[ball - 1], "rarity weight");
            assertEq(table[ball - 1].classId, ball, "rarity class");
            assertEq(table[ball - 1].value, 0, "packs never pay");
            total += weights[ball - 1];
        }
        assertEq(total, DrawTables.BPS);
        assertEq(draw.maxPayable(parkId, LaunchTerms.PARK_PACK, 0), 0, "packs reserve nothing");
        (DrawTables.Input input,,, uint128 price, uint8 draws, uint8 maxUnits, bool perGen) =
            draw.actions(parkId, LaunchTerms.PARK_PACK);
        assertEq(uint8(input), uint8(DrawTables.Input.Currency));
        assertEq(price, 2e6);
        assertEq(draws, 2);
        assertEq(maxUnits, 10);
        assertFalse(perGen);
        DrawTables.Class[] memory classes = draw.classes(parkId);
        assertEq(classes.length, 7);
        for (uint256 i; i < classes.length; ++i) {
            assertEq(classes[i].value, 0, "balls carry no payout promise");
            assertEq(classes[i].reserve, 0, "unused balls reserve nothing");
        }
    }

    /// @dev All 42 kick tables read back from the module equal the LaunchTerms rows and the
    /// section 3.3 table written out independently; every row boundary pays what the deployed
    /// `prizeForRoll` pays; `maxPayable` per table is 2, 2, 2, 2, 16, 32, 64 USDG.
    function testKickTablesMatchDeployedForEveryBallAndGeneration() public view {
        for (uint16 ball = 1; ball <= LaunchTerms.PARK_BALLS; ++ball) {
            _assertKickAction(ball);
            for (uint8 gen = 1; gen <= 6; ++gen) {
                _assertKickTable(ball, gen);
            }
        }
        assertEq(draw.maxPayable(parkId, LaunchTerms.parkKickAction(1), 6), 2e6);
        assertEq(draw.maxPayable(parkId, LaunchTerms.parkKickAction(4), 1), 2e6);
        assertEq(draw.maxPayable(parkId, LaunchTerms.parkKickAction(5), 3), 16e6);
        assertEq(draw.maxPayable(parkId, LaunchTerms.parkKickAction(6), 3), 32e6);
        assertEq(draw.maxPayable(parkId, LaunchTerms.parkKickAction(7), 3), 64e6);
        assertEq(draw.actionCount(parkId), 8, "pack plus seven kicks");
    }

    function _assertKickAction(uint16 ball) internal view {
        uint8 actionId = LaunchTerms.parkKickAction(ball);
        (
            DrawTables.Input input,
            uint16 inputClass,
            uint8 inputCount,
            uint128 price,
            uint8 draws,
            uint8 maxUnits,
            bool perGen
        ) = draw.actions(parkId, actionId);
        assertEq(uint8(input), uint8(DrawTables.Input.BurnClass));
        assertEq(inputClass, ball, "kick burns its ball");
        assertEq(inputCount, 1);
        assertEq(price, 0);
        assertEq(draws, 1);
        assertEq(maxUnits, 1, "one kick per commit");
        assertTrue(perGen, "tables by generation");
        assertEq(draw.rows(parkId, actionId, 0).length, 0, "no shared table");
    }

    function _assertKickTable(uint16 ball, uint8 gen) internal view {
        uint8 actionId = LaunchTerms.parkKickAction(ball);
        DrawTables.Row[] memory stored = draw.rows(parkId, actionId, gen);
        DrawTables.Row[] memory spec = _specKickTable(ball, gen);
        string memory label =
            string.concat("ball ", vm.toString(uint256(ball)), " gen ", vm.toString(uint256(gen)));
        _assertRowsEqual(stored, spec, label);
        _assertRowsEqual(stored, LaunchTerms.parkKickTable(ball, gen), label);
        // Highest prize first, saved row last, weights cover the range.
        uint256 cumulative;
        for (uint256 i; i < stored.length; ++i) {
            assertEq(stored[i].classId, 0, "kicks never mint");
            if (i + 1 < stored.length) {
                assertTrue(stored[i].value > stored[i + 1].value, "descending prizes");
            }
            // Every roll boundary pays the same prize through the stored rows and the spec.
            cumulative += stored[i].weightBps;
            // Cumulative weights never exceed 10_000, so both casts fit.
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(_prizeForRoll(stored, uint16(cumulative - 1)), spec[i].value, "last roll");
            if (cumulative < DrawTables.BPS) {
                // forge-lint: disable-next-line(unsafe-typecast)
                assertEq(_prizeForRoll(stored, uint16(cumulative)), spec[i + 1].value, "next");
            }
        }
        assertEq(cumulative, DrawTables.BPS, "weights sum");
        assertEq(stored[stored.length - 1].value, 0, "saved row last");
        assertEq(draw.maxPayable(parkId, actionId, gen), LaunchTerms.parkMaxPrize(ball), label);
        assertEq(draw.maxPayable(parkId, actionId, gen), stored[0].value, "max is row 0");
    }

    /// @dev The saved share of each table is the section 3.3 column: gen 6 … gen 1.
    function testSavedRowsMatchSpecColumn() public view {
        uint16[7] memory savedGen6 = [uint16(6700), 6000, 5500, 5200, 5000, 4600, 4500];
        uint16[7] memory savedGen1 = [uint16(6450), 5750, 5250, 4950, 4750, 4350, 4250];
        for (uint16 ball = 1; ball <= 7; ++ball) {
            uint8 actionId = LaunchTerms.parkKickAction(ball);
            DrawTables.Row[] memory g6 = draw.rows(parkId, actionId, 6);
            DrawTables.Row[] memory g1 = draw.rows(parkId, actionId, 1);
            assertEq(g6[g6.length - 1].weightBps, savedGen6[ball - 1], "saved gen 6");
            assertEq(g1[g1.length - 1].weightBps, savedGen1[ball - 1], "saved gen 1");
        }
    }

    /// @dev Overall return per generation, from the stored rarity and kick tables alone, is
    /// exactly 90% (gen 6) rising 1% per generation to 95% (gen 1) of the 1 USDG a ball costs.
    function testGenerationReturns() public view {
        DrawTables.Row[] memory rarity = draw.rows(parkId, LaunchTerms.PARK_PACK, 0);
        for (uint8 gen = 1; gen <= 6; ++gen) {
            // Σ_ball P(ball) × Σ_row P(row) × prize, scaled by 10_000².
            uint256 scaled;
            for (uint256 b; b < rarity.length; ++b) {
                DrawTables.Row[] memory kick =
                    draw.rows(parkId, LaunchTerms.parkKickAction(rarity[b].classId), gen);
                uint256 kickValue;
                for (uint256 r; r < kick.length; ++r) {
                    kickValue += uint256(kick[r].weightBps) * kick[r].value;
                }
                scaled += uint256(rarity[b].weightBps) * kickValue;
            }
            uint256 returnBps = 9000 + uint256(6 - gen) * 100;
            uint256 costPerBall = LaunchTerms.PARK_PACK_PRICE / 2;
            assertEq(scaled % (DrawTables.BPS * DrawTables.BPS), 0, "exact");
            assertEq(
                scaled / (DrawTables.BPS * DrawTables.BPS),
                costPerBall * returnBps / DrawTables.BPS,
                string.concat("return gen ", vm.toString(uint256(gen)))
            );
        }
    }

    // -------------------------------------------------------------------------- splits

    /// @dev The stored splits are the section 3.3 table: edge 400 + 100·gen bps, operator a
    /// quarter of it, developer the rest, nothing burned or routed to rewards.
    function testPackSplitsMatchSpecTable() public view {
        for (uint8 gen = 1; gen <= 6; ++gen) {
            (
                uint16 freeBps,
                uint16 developerBps,
                uint16 operatorBps,
                uint16 burnBps,
                uint16 rewardsBps
            ) = draw.splits(parkId, LaunchTerms.PARK_PACK, gen);
            uint16 edge = 400 + 100 * uint16(gen);
            assertEq(freeBps, 10_000 - edge, "free");
            assertEq(operatorBps, edge / 4, "operator");
            assertEq(developerBps, edge - edge / 4, "developer");
            assertEq(burnBps, 0);
            assertEq(rewardsBps, 0);
            assertEq(uint256(freeBps) + developerBps + operatorBps, DrawTables.BPS);
        }
        (uint16 f, uint16 d, uint16 o,,) = draw.splits(parkId, LaunchTerms.PARK_PACK, 1);
        assertEq(f, 9500);
        assertEq(d, 375);
        assertEq(o, 125);
        (f, d, o,,) = draw.splits(parkId, LaunchTerms.PARK_PACK, 6);
        assertEq(f, 9000);
        assertEq(d, 750);
        assertEq(o, 250);
        // Kicks route nothing.
        for (uint16 ball = 1; ball <= 7; ++ball) {
            for (uint8 gen = 1; gen <= 6; ++gen) {
                (f, d, o,,) = draw.splits(parkId, LaunchTerms.parkKickAction(ball), gen);
                assertEq(uint256(f) + d + o, 0, "kick split");
            }
        }
    }

    struct Snapshot {
        uint256 developer;
        uint256 operator;
        uint256 free;
        uint256 reserved;
        uint256 fees;
        uint256 balance;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.developer = treasury.feesOwed(address(usdg), PARK_DEVELOPER);
        s.operator = treasury.feesOwed(address(usdg), PARK_OPERATOR);
        (s.free, s.reserved,,) = ledger(parkId);
        (,,,, s.fees) = treasury.totals(address(usdg));
        s.balance = usdg.balanceOf(address(treasury));
    }

    /// @dev Quantities 1, 2, 5 and 10 across generations 1..6 accrue exactly the deployed
    /// PenaltyKingsPark fee arithmetic: `feeTotal = amount × edge / 10_000`, operator
    /// `feeTotal / 4`, developer the remainder, bankroll the rest; nothing is reserved.
    function testPackSplitsReproduceDeployedFeeArithmetic() public {
        uint8[4] memory quantities = [uint8(1), 2, 5, 10];
        for (uint8 gen = 1; gen <= 6; ++gen) {
            uint256 friendId = 1000 + gen;
            mintFriend(alice, friendId, gen);
            for (uint256 q; q < quantities.length; ++q) {
                _assertPackPurchase(friendId, gen, quantities[q]);
            }
        }
        assertSolvent(address(usdg));
    }

    function _assertPackPurchase(uint256 friendId, uint8 gen, uint8 quantity) internal {
        uint256 amount = uint256(quantity) * LaunchTerms.PARK_PACK_PRICE;
        uint256 feeTotal = amount * (400 + 100 * uint256(gen)) / 10_000;
        uint256 operatorFee = feeTotal / 4;
        Snapshot memory before = _snapshot();

        uint256 commitId = _buyPacks(alice, friendId, quantity);

        (,,,, uint8 generation,, uint128 reservedTotal,) = draw.commits(commitId);
        assertEq(generation, gen, "generation snapshot");
        assertEq(reservedTotal, 0, "packs reserve nothing");
        Snapshot memory later = _snapshot();
        assertEq(later.developer - before.developer, feeTotal - operatorFee, "developer fee");
        assertEq(later.operator - before.operator, operatorFee, "operator fee");
        assertEq(later.free - before.free, amount - feeTotal, "bankroll share");
        assertEq(later.reserved, before.reserved, "no reservation");
        assertEq(later.fees - before.fees, feeTotal, "fee total");
        assertEq(later.balance - before.balance, amount, "pulled");
        assertEq(usdg.balanceOf(alice), 0, "the owner paid exactly the price");
    }

    /// @dev Section 3.3 worked example: gen 6, ten packs → developer 1.5, operator 0.5, free 18.
    function testGenSixTenPacksWorkedExample() public {
        mintFriend(bob, 66, 6);
        (uint256 freeBefore,,,) = ledger(parkId);
        _buyPacks(bob, 66, 10);
        assertEq(treasury.feesOwed(address(usdg), PARK_DEVELOPER), 1_500_000);
        assertEq(treasury.feesOwed(address(usdg), PARK_OPERATOR), 500_000);
        (uint256 free,,,) = ledger(parkId);
        assertEq(free - freeBefore, 18_000_000);
    }

    // --------------------------------------------------------------------------- kicks

    /// @dev A kick burns the ball, reserves exactly the table's maximum (64 USDG for a Golden
    /// Boot) and, at settlement, pays the prize to the wallet and releases the remainder to
    /// free: the section 7.2 trace with roll 150 → 32 USDG.
    function testKickReservesMaxAndReleasesRemainder() public {
        _giveGoldenBoot(alice, FRIEND);
        address wallet = walletOf(FRIEND);
        uint256 boots = _balls(FRIEND, GOLDEN_BOOT);
        (uint256 freeBefore, uint256 reservedBefore,,) = ledger(parkId);
        assertEq(reservedBefore, 0);

        (uint256 commitId, uint256 requestId) = _kickGoldenBoot(alice, FRIEND);
        assertEq(_balls(FRIEND, GOLDEN_BOOT), boots - 1, "ball burned");
        (,,,, uint8 generation, bool settled, uint128 reservedTotal,) = draw.commits(commitId);
        assertEq(generation, GEN);
        assertFalse(settled);
        assertEq(reservedTotal, GOLDEN_BOOT_MAX, "maximum reserved");
        (uint256 free, uint256 reserved,,) = ledger(parkId);
        assertEq(free, freeBefore - GOLDEN_BOOT_MAX);
        assertEq(reserved, GOLDEN_BOOT_MAX);

        fulfill(requestId, _wordFor(commitId, 150));
        draw.settle(commitId);
        assertEq(draw.rollFor(commitId, 0), 150);
        assertTrue(_isSettled(commitId));
        (free, reserved,,) = ledger(parkId);
        assertEq(reserved, 0, "reservation resolved");
        assertEq(free, freeBefore - 32e6, "remainder released to free");
        assertEq(usdg.balanceOf(wallet), 32e6, "prize paid to the wallet");
        assertEq(usdg.balanceOf(alice), 0, "never to the owner address");
        assertSolvent(address(usdg));
    }

    /// @dev Every row of the gen 3 Golden Boot table pays its prize at the boundary roll and
    /// the saved row returns the whole reservation to free.
    function testGoldenBootRowsPayExactPrizes() public {
        // Gen 3 cumulative edges: 100, 200, 400, 800, 1600, 5650, 10_000.
        uint16[7] memory rolls = [uint16(0), 199, 200, 799, 1600, 5649, 9999];
        uint256[7] memory prizes = [uint256(64e6), 32e6, 16e6, 8e6, 2e6, 2e6, 0];
        address wallet = walletOf(FRIEND);
        for (uint256 i; i < rolls.length; ++i) {
            _giveGoldenBoot(alice, FRIEND);
            (uint256 freeBefore,,,) = ledger(parkId);
            uint256 walletBefore = usdg.balanceOf(wallet);
            (uint256 commitId, uint256 requestId) = _kickGoldenBoot(alice, FRIEND);
            fulfill(requestId, _wordFor(commitId, rolls[i]));
            draw.settle(commitId);
            (uint256 free, uint256 reserved,,) = ledger(parkId);
            assertEq(usdg.balanceOf(wallet) - walletBefore, prizes[i], "prize");
            assertEq(free, freeBefore - prizes[i], "free absorbs exactly the prize");
            assertEq(reserved, 0);
        }
        assertSolvent(address(usdg));
    }

    /// @dev A kick needs free bankroll covering its maximum; the revert leaves the ball unburned
    /// and nothing reserved, and funding again makes the same kick work.
    function testKickNeedsFreeBankrollForItsMaximum() public {
        _giveGoldenBoot(alice, FRIEND);
        uint256 boots = _balls(FRIEND, GOLDEN_BOOT);
        (uint256 free,,,) = ledger(parkId);
        vm.prank(owner);
        treasury.withdrawFree(parkId, free - (GOLDEN_BOOT_MAX - 1));
        vm.prank(alice);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        draw.commit(parkId, LaunchTerms.parkKickAction(GOLDEN_BOOT), FRIEND, 1, 0, 0);
        assertEq(_balls(FRIEND, GOLDEN_BOOT), boots, "ball kept on revert");
        (, uint256 reserved,,) = ledger(parkId);
        assertEq(reserved, 0);
        fundGame(parkId, 1);
        (uint256 commitId,) = _kickGoldenBoot(alice, FRIEND);
        (,,,,,, uint128 reservedTotal,) = draw.commits(commitId);
        assertEq(reservedTotal, GOLDEN_BOOT_MAX);
        (free, reserved,,) = ledger(parkId);
        assertEq(free, 0);
        assertEq(reserved, GOLDEN_BOOT_MAX);
    }

    /// @dev Kicks keep working on a retired game; only pack purchases stop.
    function testRetireStopsPacksOnly() public {
        _giveGoldenBoot(alice, FRIEND);
        vm.prank(owner);
        registry.retireGame(parkId);
        giveUSDG(alice, 2e6);
        vm.prank(alice);
        vm.expectRevert(DrawModule.GameNotActive.selector);
        draw.commit(parkId, LaunchTerms.PARK_PACK, FRIEND, 1, 0, 0);
        (uint256 commitId, uint256 requestId) = _kickGoldenBoot(alice, FRIEND);
        fulfill(requestId, _wordFor(commitId, 0));
        draw.settle(commitId);
        assertEq(usdg.balanceOf(walletOf(FRIEND)), 64e6);
    }

    /// @dev Section 7.2 step 7: a USDG transfer the issuer rejects reverts the whole settlement
    /// through SafeERC20, the reservation stays, the commit stays open, and `settle` succeeds
    /// later with the same deterministic prize once the wallet is unblocked.
    function testBlockedUsdgPayoutKeepsReservationAndSettlesAfterUnblocking() public {
        _giveGoldenBoot(alice, FRIEND);
        address wallet = walletOf(FRIEND);
        (uint256 freeBefore,,,) = ledger(parkId);
        (uint256 commitId, uint256 requestId) = _kickGoldenBoot(alice, FRIEND);
        fulfill(requestId, _wordFor(commitId, 150));

        usdg.blockRecipient(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdg))
        );
        draw.settle(commitId);
        assertFalse(_isSettled(commitId), "commit still open");
        (uint256 free, uint256 reserved,,) = ledger(parkId);
        assertEq(reserved, GOLDEN_BOOT_MAX, "reservation kept");
        assertEq(free, freeBefore - GOLDEN_BOOT_MAX, "free untouched");
        assertEq(usdg.balanceOf(wallet), 0);
        assertSolvent(address(usdg));
        // The ball is already burned; the owner cannot reach the reserved prize.
        vm.prank(owner);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        treasury.withdrawFree(parkId, free + 1);

        // Still blocked a block later: same outcome.
        vm.roll(block.number + 1);
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdg))
        );
        draw.settle(commitId);

        usdg.blockRecipient(address(0));
        draw.settle(commitId);
        assertTrue(_isSettled(commitId));
        assertEq(usdg.balanceOf(wallet), 32e6, "the same prize lands");
        (free, reserved,,) = ledger(parkId);
        assertEq(reserved, 0);
        assertEq(free, freeBefore - 32e6);
        assertSolvent(address(usdg));
    }

    // ------------------------------------------------------------------------- custody

    function _custodyPack(bytes32 actionId) internal returns (uint256 commitId) {
        giveUSDG(executor, 2 * LaunchTerms.PARK_PACK_PRICE);
        vm.prank(executor);
        commitId = draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, actionId);
    }

    /// @dev Section 7.3: the executor buys a pack for a custodied Friend; the executor pays, the
    /// gen 5 split applies, balls mint to the Friend wallet and the action id is consumed.
    function testCustodyPackCommit() public {
        bytes32 a1 = keccak256("A1");
        address wallet = walletOf(CUSTODIED);
        (uint256 freeBefore,,,) = ledger(parkId);
        uint256 commitId = draw.commitCount() + 1;
        uint256 requestId = coordinator.requestCount() + 1;
        giveUSDG(executor, 4e6);
        vm.expectEmit(true, true, true, true, address(draw));
        emit DrawModule.Committed(
            commitId,
            parkId,
            CUSTODIED,
            wallet,
            LaunchTerms.PARK_PACK,
            2,
            CUSTODIED_GEN,
            0,
            requestId,
            bytes32(0),
            a1
        );
        vm.prank(executor);
        assertEq(draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, a1), commitId);
        assertTrue(registry.custodyActionUsed(a1), "action consumed");
        assertEq(usdg.balanceOf(executor), 0, "the executor paid");
        assertEq(treasury.feesOwed(address(usdg), PARK_DEVELOPER), 270_000);
        assertEq(treasury.feesOwed(address(usdg), PARK_OPERATOR), 90_000);
        (uint256 free,,,) = ledger(parkId);
        assertEq(free - freeBefore, 3_640_000);

        fulfill(requestId, keccak256("pack"));
        draw.settle(commitId);
        uint256 balls;
        for (uint16 ball = 1; ball <= 7; ++ball) {
            balls += _balls(CUSTODIED, ball);
        }
        assertEq(balls, 4, "balls land in the Friend wallet");
        assertEq(items(parkId).balanceOf(executor, 1), 0);
    }

    /// @dev Replay matrix: a used id is refused for commit and redeem; a zero id falls to the
    /// owned path, which the executor is not; a non-executor cannot use the custody path; a
    /// Friend not in custody is refused; a Friend that left custody is refused and its new owner
    /// plays through the owned path; every refused call leaves the id unused.
    function testCustodyReplayMatrix() public {
        bytes32 a1 = keccak256("A1");
        _custodyPack(a1);

        // Reuse on commit and on redeem.
        giveUSDG(executor, 4e6);
        vm.prank(executor);
        vm.expectRevert(GameRegistry.InvalidCustodyAction.selector);
        draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, a1);
        vm.prank(executor);
        vm.expectRevert(GameRegistry.InvalidCustodyAction.selector);
        draw.redeem(parkId, CUSTODIED, 1, 1, a1);
        // The same id is also spent for Breeds: one namespace across games.
        giveRF(executor, 1e18);
        vm.prank(executor);
        vm.expectRevert(GameRegistry.InvalidCustodyAction.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, CUSTODIED, 1, 0, a1);

        // Zero id: the owned path, where the executor is nobody.
        vm.prank(executor);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, bytes32(0));

        // Non-executor with a fresh id.
        bytes32 a2 = keccak256("A2");
        giveUSDG(alice, 4e6);
        vm.prank(alice);
        vm.expectRevert(DrawModule.OnlyCustodyExecutor.selector);
        draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, a2);
        assertFalse(registry.custodyActionUsed(a2), "refused call leaves the id unused");

        // Executor for a Friend that is not in custody.
        bytes32 a3 = keccak256("A3");
        vm.prank(executor);
        vm.expectRevert(FriendAccess.NotCustodied.selector);
        draw.commit(parkId, LaunchTerms.PARK_PACK, FRIEND, 2, 0, a3);
        assertFalse(registry.custodyActionUsed(a3));

        // The Friend leaves custody: the custody path closes, the owned path opens.
        vm.prank(address(custody));
        generations.transfer(CUSTODIED, bob);
        bytes32 a4 = keccak256("A4");
        vm.prank(executor);
        vm.expectRevert(FriendAccess.NotCustodied.selector);
        draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, a4);
        assertFalse(registry.custodyActionUsed(a4));
        giveUSDG(bob, 2e6);
        vm.prank(bob);
        uint256 commitId = draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 1, 0, 0);
        assertEq(usdg.balanceOf(bob), 0, "the new owner pays");
        fulfill(_requestOf(commitId), keccak256("bob"));
        draw.settle(commitId);
        assertEq(usdg.balanceOf(executor), 4e6, "the executor's later funds were never pulled");
    }

    /// @dev A reverted custody commit leaves the id unused so the same order can be retried;
    /// once it lands, the prize pays the Friend wallet, never the executor.
    function testRevertedCustodyCommitLeavesIdUnused() public {
        // Give the custodied Friend a Golden Boot through the custody path.
        bytes32 a1 = keccak256("A1");
        giveUSDG(executor, 2e6);
        vm.prank(executor);
        uint256 packId = draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 1, 0, a1);
        fulfill(_requestOf(packId), _wordFor(packId, 9900));
        draw.settle(packId);
        assertTrue(_balls(CUSTODIED, GOLDEN_BOOT) != 0);

        (uint256 free,,,) = ledger(parkId);
        vm.prank(owner);
        treasury.withdrawFree(parkId, free);
        bytes32 a5 = keccak256("A5");
        vm.prank(executor);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        draw.commit(parkId, LaunchTerms.parkKickAction(GOLDEN_BOOT), CUSTODIED, 1, 0, a5);
        assertFalse(registry.custodyActionUsed(a5), "revert leaves the id unused");
        assertEq(_balls(CUSTODIED, GOLDEN_BOOT), 1, "ball kept");

        fundGame(parkId, GOLDEN_BOOT_MAX);
        vm.prank(executor);
        uint256 kickId =
            draw.commit(parkId, LaunchTerms.parkKickAction(GOLDEN_BOOT), CUSTODIED, 1, 0, a5);
        assertTrue(registry.custodyActionUsed(a5), "retry consumed the id");
        fulfill(_requestOf(kickId), _wordFor(kickId, 0));
        draw.settle(kickId);
        assertEq(usdg.balanceOf(walletOf(CUSTODIED)), 64e6, "prize to the Friend wallet");
        assertEq(usdg.balanceOf(executor), 0);
        assertSolvent(address(usdg));
    }

    /// @dev Rotating the executor key moves the custody path; zero disables it entirely.
    function testCustodyExecutorRotation() public {
        address next = makeAddr("next executor");
        vm.prank(owner);
        registry.setCustodyExecutor(next);
        giveUSDG(executor, 4e6);
        vm.prank(executor);
        vm.expectRevert(DrawModule.OnlyCustodyExecutor.selector);
        draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, keccak256("B1"));
        giveUSDG(next, 4e6);
        vm.prank(next);
        draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, keccak256("B1"));
        vm.prank(owner);
        registry.setCustodyExecutor(address(0));
        giveUSDG(next, 4e6);
        vm.prank(next);
        vm.expectRevert(DrawModule.OnlyCustodyExecutor.selector);
        draw.commit(parkId, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, keccak256("B2"));
        assertFalse(registry.custodyActionUsed(keccak256("B2")));
    }

    // ---------------------------------------------------------------------------- fees

    /// @dev Fees accrue at purchase and `payFees` pays each recipient exactly once; a blocked
    /// USDG recipient keeps its ledger and never blocks a purchase.
    function testFeesAccrueAndPayFeesPays() public {
        _buyPacks(alice, FRIEND, 2);
        assertEq(treasury.feesOwed(address(usdg), PARK_DEVELOPER), 210_000);
        assertEq(treasury.feesOwed(address(usdg), PARK_OPERATOR), 70_000);
        (,,,, uint256 fees) = treasury.totals(address(usdg));
        assertEq(fees, 280_000);
        assertEq(usdg.balanceOf(PARK_DEVELOPER), 0, "nothing transferred inline");

        treasury.payFees(address(usdg), PARK_DEVELOPER);
        assertEq(usdg.balanceOf(PARK_DEVELOPER), 210_000);
        assertEq(treasury.feesOwed(address(usdg), PARK_DEVELOPER), 0);
        (,,,, fees) = treasury.totals(address(usdg));
        assertEq(fees, 70_000);
        vm.expectRevert(Treasury.NothingOwed.selector);
        treasury.payFees(address(usdg), PARK_DEVELOPER);

        // A frozen operator keeps its ledger; purchases keep accruing to it meanwhile.
        usdg.blockRecipient(PARK_OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdg))
        );
        treasury.payFees(address(usdg), PARK_OPERATOR);
        assertEq(treasury.feesOwed(address(usdg), PARK_OPERATOR), 70_000, "ledger kept");
        _buyPacks(alice, FRIEND, 2);
        assertEq(treasury.feesOwed(address(usdg), PARK_OPERATOR), 140_000, "still accruing");
        assertSolvent(address(usdg));

        usdg.blockRecipient(address(0));
        vm.prank(bob); // anyone may push fees
        treasury.payFees(address(usdg), PARK_OPERATOR);
        assertEq(usdg.balanceOf(PARK_OPERATOR), 140_000);
        (,,,, fees) = treasury.totals(address(usdg));
        assertEq(fees, 210_000, "the developer's second accrual remains");
        vm.expectRevert(Treasury.NothingOwed.selector);
        treasury.payFees(address(usdg), bob);
        assertSolvent(address(usdg));
    }
}
