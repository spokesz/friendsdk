// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Fixture } from "../Fixture.sol";
import { LaunchTerms } from "../../script/LaunchTerms.sol";
import { GameItems } from "../../src/GameItems.sol";
import { Treasury } from "../../src/Treasury.sol";
import { RandomnessCoordinator } from "../../src/RandomnessCoordinator.sol";
import { DrawModule } from "../../src/DrawModule.sol";
import { RoundModule } from "../../src/RoundModule.sol";
import { DrawTables } from "../../src/libraries/DrawTables.sol";
import {
    MockRF,
    MockUSDG,
    MockGenerations,
    MockFriendWallet,
    MockDice,
    MockActivationManager
} from "../doubles/ExternalDoubles.sol";

/// @dev Stateful driver for the invariant suite. Owns ten Friends (generations 1..6) and plays
/// every launch game through the real hub: Rare Breeds buy/play/settle/redeem, Penalty Kings
/// pack/kick/settle under USDG recipient blocks, Rare Royale credit/rounds/spends/settlement/
/// refunds/abandonment, Dice reveals and coordinator retries, fee payouts, rewards forwarding,
/// owner withdrawals and direct donations. Inputs are bounded so almost every call succeeds;
/// a call whose preconditions the handler has verified is expected to succeed and any other
/// outcome is recorded in `unexpectedReverts` for `invariant_noUnexpectedReverts`. Ghost
/// variables record what the Treasury must have burned, accrued and received.
contract PlatformHandler is CommonBase, StdCheats, StdUtils {
    struct Env {
        MockRF rf;
        MockUSDG usdg;
        MockGenerations generations;
        MockDice dice;
        MockActivationManager manager;
        Treasury treasury;
        RandomnessCoordinator coordinator;
        DrawModule draw;
        RoundModule round;
        GameItems breedsItems;
        GameItems parkItems;
        address owner;
        address settler;
        address provider;
        uint256 breedsId;
        uint256 parkId;
        uint256 royaleId;
    }

    uint256 internal constant FRIEND_COUNT = 10;
    uint256 internal constant FIRST_FRIEND = 1001;
    uint256 internal constant MAX_LIVE_ROUNDS = 3;
    uint256 internal constant BPS = 10_000;
    uint128 internal constant MAX_DICE_FEE = 0.000_025 ether;
    address internal constant PARK_DEVELOPER = 0xd0BB5CC938dA89E0d7129F1eE01C2cfc61C2e36F;
    address internal constant PARK_OPERATOR = 0x1EcBF27dC1F809179B9ef2d382cd76ccBa21B6d2;

    MockRF internal rf;
    MockUSDG internal usdg;
    MockGenerations internal generations;
    MockDice internal dice;
    MockActivationManager internal manager;
    Treasury internal treasury;
    RandomnessCoordinator internal coordinator;
    DrawModule internal draw;
    RoundModule internal round;
    GameItems internal breedsItems;
    GameItems internal parkItems;
    address internal owner;
    address internal settler;
    address internal provider;
    uint256 internal breedsId;
    uint256 internal parkId;
    uint256 internal royaleId;

    uint256[] internal _friends;
    // Coordinator requests Dice has not revealed yet (Draw commits and Round closes).
    uint256[] internal _pendingRequests;
    // Draw commits with a request that are not settled yet.
    uint256[] internal _openCommits;
    // Rounds that are Open or Closed.
    uint256[] internal _liveRounds;
    mapping(uint256 roundId => bytes32) internal _secretOf;
    uint256 internal _nonce;

    // ------------------------------------------------------------------------- ghosts
    // RF supply when the handler was deployed; afterwards only the handler mints RF.
    uint256 public rfSupplyBaseline;
    uint256 public rfMinted;
    // Tokens sent straight to the Treasury without a ledger entry (I2).
    uint256 public donatedRf;
    uint256 public donatedUsdg;
    // RF the Treasury must have burned and accrued for rewards (round settlements and spends).
    uint256 public expectedBurn;
    uint256 public expectedRewards;
    // Penalty Kings fees by the section 3.3 splits, and what payFees has delivered.
    uint256 public devAccrued;
    uint256 public opAccrued;
    uint256 public devPaid;
    uint256 public opPaid;
    // Calls that had to succeed (or had to revert) and did not.
    uint256 public unexpectedReverts;
    string public lastAction;
    bytes public lastRevert;
    // Dice callbacks the coordinator rejected.
    uint256 public callbackFailures;

    constructor(Env memory e) {
        rf = e.rf;
        usdg = e.usdg;
        generations = e.generations;
        dice = e.dice;
        manager = e.manager;
        treasury = e.treasury;
        coordinator = e.coordinator;
        draw = e.draw;
        round = e.round;
        breedsItems = e.breedsItems;
        parkItems = e.parkItems;
        owner = e.owner;
        settler = e.settler;
        provider = e.provider;
        breedsId = e.breedsId;
        parkId = e.parkId;
        royaleId = e.royaleId;

        rf.approve(address(treasury), type(uint256).max);
        usdg.approve(address(treasury), type(uint256).max);
        bytes memory approve =
            abi.encodeCall(IERC20.approve, (address(treasury), type(uint256).max));
        for (uint256 i; i < FRIEND_COUNT; ++i) {
            uint256 friendId = FIRST_FRIEND + i;
            generations.mint(address(this), friendId, _u8(i % 6 + 1));
            _friends.push(friendId);
            // The canonical wallet may also pay: approve the Treasury from inside it.
            _wallet(friendId).execute(address(rf), 0, approve, 0);
            _wallet(friendId).execute(address(usdg), 0, approve, 0);
        }
        rfSupplyBaseline = rf.totalSupply();
    }

    // -------------------------------------------------------------------------- views

    function friendCount() external view returns (uint256) {
        return _friends.length;
    }

    function friendAt(uint256 index) external view returns (uint256) {
        return _friends[index];
    }

    function liveRoundCount() external view returns (uint256) {
        return _liveRounds.length;
    }

    function liveRoundAt(uint256 index) external view returns (uint256) {
        return _liveRounds[index];
    }

    function pendingRequestCount() external view returns (uint256) {
        return _pendingRequests.length;
    }

    function openCommitCount() external view returns (uint256) {
        return _openCommits.length;
    }

    // ------------------------------------------------------------ actions: treasury

    /// @dev Anyone adds free stake to any game.
    function fund(uint256 seed, uint256 amount) external {
        uint256 gameId = _game(seed);
        _fund(gameId, bound(amount, 1, gameId == parkId ? 500e6 : 500e18));
    }

    /// @dev Tokens sent straight to the Treasury: balance grows, no ledger moves (I2 ghost).
    function donate(uint256 seed, uint256 amount) external {
        if (seed & 1 == 1) {
            amount = bound(amount, 1, 100e18);
            _mintRf(address(this), amount);
            if (!rf.transfer(address(treasury), amount)) _unexpected("donateRf", "");
            donatedRf += amount;
        } else {
            amount = bound(amount, 1, 100e6);
            usdg.mint(address(this), amount);
            if (!usdg.transfer(address(treasury), amount)) _unexpected("donateUsdg", "");
            donatedUsdg += amount;
        }
    }

    /// @dev Accrued Penalty Kings fees; a blocked recipient must keep its ledger.
    function payFees(uint256 seed) external {
        address recipient = seed & 1 == 1 ? PARK_DEVELOPER : PARK_OPERATOR;
        uint256 owed = treasury.feesOwed(address(usdg), recipient);
        if (owed == 0) {
            try treasury.payFees(address(usdg), recipient) {
                _unexpected("payFeesNothingOwed", "");
            } catch (bytes memory reason) {
                _expectError("payFeesNothingOwed", reason, Treasury.NothingOwed.selector);
            }
            return;
        }
        bool blocked = usdg.blockedRecipient() == recipient;
        try treasury.payFees(address(usdg), recipient) {
            if (blocked) _unexpected("payFeesBlocked", "");
            else if (recipient == PARK_DEVELOPER) devPaid += owed;
            else opPaid += owed;
        } catch (bytes memory reason) {
            if (blocked) {
                _expectError("payFeesBlocked", reason, SafeERC20.SafeERC20FailedOperation.selector);
            } else {
                _unexpected("payFees", reason);
            }
        }
    }

    /// @dev Forward accrued RF rewards; a retired manager leaves the pending balance intact.
    function forwardRewards(uint256 seed) external {
        bool retired = seed & 1 == 1;
        manager.setRetired(retired);
        if (treasury.rewardsPending() == 0) return;
        try treasury.forwardRewards() {
            if (retired) _unexpected("forwardRewardsRetired", "");
        } catch (bytes memory reason) {
            if (retired) {
                _expectError("forwardRewards", reason, Treasury.ManagerUnavailable.selector);
            } else {
                _unexpected("forwardRewards", reason);
            }
        }
    }

    /// @dev The registry owner withdraws free stake to the funder, up to the whole bankroll.
    function withdrawFree(uint256 seed, uint256 amount) external {
        uint256 gameId = _game(seed);
        (uint256 free,,,) = treasury.ledgers(gameId);
        if (free == 0) return;
        vm.prank(owner);
        try treasury.withdrawFree(gameId, bound(amount, 1, free)) { }
        catch (bytes memory reason) {
            _unexpected("withdrawFree", reason);
        }
    }

    /// @dev The USDG issuer freezes one address: a fee recipient, a Friend wallet, or nobody.
    function toggleBlockedRecipient(uint256 seed) external {
        uint256 choice = seed % 4;
        address target = choice == 0
            ? address(0)
            : choice == 1
                ? PARK_DEVELOPER
                : choice == 2 ? PARK_OPERATOR : _walletOf(_friend(seed >> 8));
        usdg.blockRecipient(target);
    }

    /// @dev A Friend climbs one generation, changing future kick tables and pack splits only.
    function promoteFriend(uint256 seed) external {
        uint256 friendId = _friend(seed);
        if (generations.generation(friendId) > 1) generations.promote(friendId);
    }

    /// @dev Dice quotes a different fee, never above the platform cap.
    function setDiceFee(uint128 fee) external {
        dice.setFee(_u128(bound(fee, 1, MAX_DICE_FEE)));
    }

    /// @dev Blocks and time pass.
    function advanceChain(uint256 blocks, uint256 secs) external {
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 10));
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 1 hours));
    }

    // ---------------------------------------------------------------- actions: draw

    /// @dev Rare Breeds: buy 1..10 eggs, paid by the owner or from the canonical wallet.
    function buyEggs(uint256 seed, uint8 qty) external {
        _buyEggs(_friend(seed), _u8(bound(qty, 1, 10)), seed & 2 == 2);
    }

    /// @dev Rare Breeds: play 1..10 held eggs (buying some first when nobody holds any).
    function playEggs(uint256 seed, uint8 qty) external {
        (bool found, uint256 friendId) = _friendWithItem(breedsItems, LaunchTerms.BREEDS_EGG, seed);
        if (!found) {
            friendId = _friend(seed);
            if (!_buyEggs(friendId, _u8(bound(qty, 1, 10)), false)) return;
        }
        uint256 eggs = breedsItems.balanceOf(_walletOf(friendId), LaunchTerms.BREEDS_EGG);
        _playEggs(friendId, _u8(bound(qty, 1, eggs < 10 ? eggs : 10)), seed & 2 == 2);
    }

    /// @dev Penalty Kings: buy 1..10 packs; fees accrue by the generation's split.
    function buyPacks(uint256 seed, uint8 qty) external {
        _buyPacks(_friend(seed), _u8(bound(qty, 1, 10)));
    }

    /// @dev Penalty Kings: kick a held ball (buying and settling a pack first when none exists).
    function kickBall(uint256 seed) external {
        (bool found, uint256 friendId, uint16 ball) = _friendWithBall(seed);
        if (!found) {
            (bool ok, uint256 commitId) = _buyPacks(_friend(seed), 1);
            if (!ok || !_settle(commitId, seed)) return;
            (found, friendId, ball) = _friendWithBall(seed);
            if (!found) return;
        }
        _kick(friendId, ball);
    }

    /// @dev Settle a pending Draw commit, revealing its word first when Dice has not.
    function settleDraw(uint256 seed) external {
        if (_openCommits.length == 0 && !_bootstrapCommit(seed)) return;
        _settle(_openCommits[seed % _openCommits.length], seed);
    }

    /// @dev Rare Breeds: redeem held tier tokens (playing an egg first when none exists).
    function redeemTier(uint256 seed, uint256 qty) external {
        (bool found, uint256 friendId, uint16 tier) = _friendWithTier(seed);
        if (!found) {
            friendId = _friend(seed);
            if (
                breedsItems.balanceOf(_walletOf(friendId), LaunchTerms.BREEDS_EGG) == 0
                    && !_buyEggs(friendId, 1, false)
            ) return;
            (bool ok, uint256 commitId) = _playEggs(friendId, 1, false);
            if (!ok || !_settle(commitId, seed)) return;
            (found, friendId, tier) = _friendWithTier(seed);
            if (!found) return;
        }
        uint256 balance = breedsItems.balanceOf(_walletOf(friendId), tier);
        try draw.redeem(breedsId, friendId, tier, bound(qty, 1, balance), bytes32(0)) { }
        catch (bytes memory reason) {
            _unexpected("redeem", reason);
        }
    }

    /// @dev Dice reveals the word of a pending request (a zero word now and then).
    function revealWord(uint256 seed) external {
        if (_pendingRequests.length == 0 && !_bootstrapCommit(seed)) return;
        _reveal(_pendingRequests[seed % _pendingRequests.length], seed);
    }

    /// @dev Reclaim-and-retry a stuck request after Dice's refund delay, or too early.
    function retryRequest(uint256 seed, uint64 delay) external {
        if (_pendingRequests.length == 0 && !_bootstrapCommit(seed)) return;
        uint256 requestId = _pendingRequests[seed % _pendingRequests.length];
        (,,, uint64 sequence,,,) = coordinator.requests(requestId);
        uint64 blocks = _u64(bound(delay, 1, 20));
        dice.setRefundDelayBlocks(blocks);
        uint256 available = uint256(dice.getRequestV2(provider, sequence).blockNumber) + blocks;
        if (seed & 1 == 1 && block.number < available) {
            // Too early: Dice's RefundNotAvailable propagates and nothing is rebound.
            try coordinator.retry(requestId) {
                _unexpected("retryEarly", "");
            } catch (bytes memory reason) {
                _expectError("retryEarly", reason, MockDice.RefundNotAvailable.selector);
            }
            return;
        }
        if (block.number < available) vm.roll(available);
        try coordinator.retry(requestId) { }
        catch (bytes memory reason) {
            _unexpected("retry", reason);
        }
    }

    // --------------------------------------------------------------- actions: round

    /// @dev Rare Royale: prefund a Friend's credit.
    function depositCredit(uint256 seed, uint256 amount) external {
        _deposit(_friend(seed), bound(amount, 1, 10e18));
    }

    /// @dev Rare Royale: withdraw credit of an idle Friend; a Friend in a live round is refused.
    function withdrawCredit(uint256 seed, uint256 amount) external {
        if (seed & 1 == 1) {
            (bool busy, uint256 lockedFriend) = _busyFriendWithCredit(seed);
            if (busy) {
                try round.withdrawCredit(royaleId, lockedFriend, 1) {
                    _unexpected("withdrawCreditLocked", "");
                } catch (bytes memory reason) {
                    _expectError(
                        "withdrawCreditLocked", reason, RoundModule.RoundInProgress.selector
                    );
                }
                return;
            }
        }
        (bool found, uint256 friendId) = _idleFriendWithCredit(seed);
        if (!found) {
            (found, friendId) = _idleFriend(seed);
            if (!found || !_deposit(friendId, bound(amount, 1, 10e18))) return;
        }
        uint256 credit = treasury.creditOf(royaleId, friendId);
        try round.withdrawCredit(royaleId, friendId, bound(amount, 1, credit)) { }
        catch (bytes memory reason) {
            _unexpected("withdrawCredit", reason);
        }
    }

    /// @dev The settler opens a round, or finishes one when enough are already live.
    function openRound(uint256 seed, uint8 payees) external {
        if (_liveRounds.length < MAX_LIVE_ROUNDS) {
            _openRound(seed);
            return;
        }
        uint256 roundId = _liveRounds[seed % _liveRounds.length];
        if (_status(roundId) == RoundModule.Status.Open) _close(roundId);
        else _settleRound(roundId, seed, payees);
    }

    /// @dev Idle Friends enter an open round, paid by the owner or from the canonical wallet.
    function enterRound(uint256 seed, uint8 count) external {
        (bool found, uint256 roundId) = _liveWithStatus(seed, RoundModule.Status.Open);
        if (!found) (found, roundId) = _openRound(seed);
        if (found) _fill(roundId, seed, bound(count, 1, _friends.length));
    }

    /// @dev The settler closes an open round: a word is requested, or a short round refunds.
    function closeRound(uint256 seed, uint8 count) external {
        (bool found, uint256 roundId) = _liveWithStatus(seed, RoundModule.Status.Open);
        if (!found) {
            (found, roundId) = _openRound(seed);
            if (!found) return;
            _fill(roundId, seed, bound(count, 0, _friends.length));
        }
        _close(roundId);
    }

    /// @dev The settler debits an entrant's credit for a kind, topping the credit up first.
    function spendCredit(uint256 seed, uint8 kind) external {
        (bool found, uint256 roundId, uint256 payer) = _liveEntrant(seed);
        if (!found) {
            (found, roundId) = _openRound(seed);
            if (!found || _fill(roundId, seed, 1 + seed % 3) == 0) return;
            (found, roundId, payer) = _liveEntrant(seed);
            if (!found) return;
        }
        _spend(roundId, payer, _friend(seed >> 8), _u8(bound(kind, 1, 13)));
    }

    /// @dev The settler reveals and pays a closed round (opening and filling one when needed).
    function settleRound(uint256 seed, uint8 payees) external {
        (bool found, uint256 roundId) = _liveWithStatus(seed, RoundModule.Status.Closed);
        if (!found) {
            if (_idleCount() < LaunchTerms.ROYALE_MIN_ENTRIES) return;
            (found, roundId) = _openRound(seed);
            if (!found) return;
            _fill(roundId, seed, bound(payees, LaunchTerms.ROYALE_MIN_ENTRIES, _friends.length));
            if (!_close(roundId) || _status(roundId) != RoundModule.Status.Closed) return;
        }
        _settleRound(roundId, seed, payees);
    }

    /// @dev Anyone refunds a live round after the clock; before it the call must be refused.
    function abandonRound(uint256 seed, uint8 count) external {
        uint256 roundId;
        if (_liveRounds.length == 0) {
            (bool ok, uint256 id) = _openRound(seed);
            if (!ok) return;
            roundId = id;
            _fill(roundId, seed, bound(count, 0, 3));
        } else {
            roundId = _liveRounds[seed % _liveRounds.length];
        }
        (,, uint64 openedAt,,) = round.rounds(roundId);
        uint256 ready = uint256(openedAt) + round.ABANDON_AFTER();
        if (seed & 1 == 1 && vm.getBlockTimestamp() < ready) {
            try round.abandonRound(roundId) {
                _unexpected("abandonEarly", "");
            } catch (bytes memory reason) {
                _expectError("abandonEarly", reason, RoundModule.NotAbandonable.selector);
            }
            return;
        }
        if (vm.getBlockTimestamp() < ready) vm.warp(ready);
        try round.abandonRound(roundId) {
            _remove(_liveRounds, roundId);
        } catch (bytes memory reason) {
            _unexpected("abandonRound", reason);
        }
    }

    // ------------------------------------------------------------- internals: draw

    /// @dev Buying N eggs needs free_before + N >= 6N; the handler funds the shortfall first.
    function _buyEggs(uint256 friendId, uint8 qty, bool viaWallet) internal returns (bool ok) {
        _ensureFree(breedsId, 5e18 * uint256(qty));
        _ensureRf(viaWallet ? _walletOf(friendId) : address(this), 1e18 * uint256(qty));
        (ok,) = _commit(breedsId, LaunchTerms.BREEDS_BUY, friendId, qty, viaWallet, "buyEggs");
    }

    function _playEggs(uint256 friendId, uint8 qty, bool viaWallet)
        internal
        returns (bool ok, uint256 commitId)
    {
        (ok, commitId) = _commit(
            breedsId, LaunchTerms.BREEDS_PLAY, friendId, qty, viaWallet, "playEggs"
        );
        if (ok) _track(commitId);
    }

    /// @dev Records the fee legs the generation's split must accrue (section 3.3).
    function _buyPacks(uint256 friendId, uint8 qty) internal returns (bool ok, uint256 commitId) {
        uint256 amount = uint256(LaunchTerms.PARK_PACK_PRICE) * qty;
        _ensureUsdg(amount);
        uint256 edge = LaunchTerms.parkEdgeBps(generations.generation(friendId));
        uint256 operatorBps = edge / 4;
        (ok, commitId) = _commit(parkId, LaunchTerms.PARK_PACK, friendId, qty, false, "buyPacks");
        if (!ok) return (ok, commitId);
        devAccrued += amount * (edge - operatorBps) / BPS;
        opAccrued += amount * operatorBps / BPS;
        _track(commitId);
    }

    /// @dev A kick reserves the ball's maximum prize; the handler funds the shortfall first.
    function _kick(uint256 friendId, uint16 ball) internal returns (bool ok, uint256 commitId) {
        _ensureFree(parkId, LaunchTerms.parkMaxPrize(ball));
        (ok, commitId) =
            _commit(parkId, LaunchTerms.parkKickAction(ball), friendId, 1, false, "kickBall");
        if (ok) _track(commitId);
    }

    /// @dev Owned-path commit by the owner, or through the canonical wallet's `execute`.
    function _commit(
        uint256 gameId,
        uint8 actionId,
        uint256 friendId,
        uint8 quantity,
        bool viaWallet,
        string memory action
    ) internal returns (bool ok, uint256 commitId) {
        bytes32 context = bytes32(++_nonce);
        if (viaWallet) {
            bytes memory data = abi.encodeCall(
                DrawModule.commit, (gameId, actionId, friendId, quantity, context, bytes32(0))
            );
            try _wallet(friendId).execute(address(draw), 0, data, 0) returns (bytes memory result) {
                return (true, abi.decode(result, (uint256)));
            } catch (bytes memory reason) {
                _unexpected(action, reason);
            }
        } else {
            try draw.commit(gameId, actionId, friendId, quantity, context, bytes32(0)) returns (
                uint256 id
            ) {
                return (true, id);
            } catch (bytes memory reason) {
                _unexpected(action, reason);
            }
        }
    }

    /// @dev A commit with a request is pending until settled; its request until revealed.
    function _track(uint256 commitId) internal {
        (,,,,,,, uint256 requestId) = draw.commits(commitId);
        if (requestId == 0) return;
        _openCommits.push(commitId);
        _pendingRequests.push(requestId);
    }

    /// @dev Settlement must succeed once the word exists, unless USDG blocks the prize wallet.
    function _settle(uint256 commitId, uint256 seed) internal returns (bool ok) {
        (uint256 gameId, uint256 friendId,,,,,, uint256 requestId) = draw.commits(commitId);
        (bool fulfilled,) = coordinator.word(requestId);
        if (!fulfilled && !_reveal(requestId, seed)) return false;
        try draw.settle(commitId) {
            _remove(_openCommits, commitId);
            return true;
        } catch (bytes memory reason) {
            // A frozen USDG prize wallet is the one legitimate failure: the transfer returns
            // false, SafeERC20 reverts, the reservation stays and the commit stays retryable.
            bool blocked = gameId == parkId && usdg.blockedRecipient() == _walletOf(friendId);
            if (blocked) {
                _expectError("settleBlocked", reason, SafeERC20.SafeERC20FailedOperation.selector);
            } else {
                _unexpected("settle", reason);
            }
        }
    }

    /// @dev Dice delivers a word for the request's current sequence; the callback must land.
    function _reveal(uint256 requestId, uint256 seed) internal returns (bool ok) {
        (,,, uint64 sequence,,,) = coordinator.requests(requestId);
        bytes32 word = seed % 5 == 0 ? bytes32(0) : keccak256(abi.encode(seed, requestId));
        try dice.reveal(sequence, word) returns (bool success) {
            if (!success) ++callbackFailures;
            _remove(_pendingRequests, requestId);
            return true;
        } catch (bytes memory reason) {
            _unexpected("reveal", reason);
        }
    }

    /// @dev Creates one commit that needs a word: an egg play when eggs exist, else a pack.
    function _bootstrapCommit(uint256 seed) internal returns (bool ok) {
        (bool found, uint256 friendId) = _friendWithItem(breedsItems, LaunchTerms.BREEDS_EGG, seed);
        if (found) (ok,) = _playEggs(friendId, 1, false);
        else (ok,) = _buyPacks(_friend(seed), 1);
    }

    // ------------------------------------------------------------ internals: round

    function _openRound(uint256 seed) internal returns (bool ok, uint256 roundId) {
        bytes32 secret = keccak256(abi.encode("secret", seed, ++_nonce));
        vm.prank(settler);
        try round.openRound(royaleId, keccak256(abi.encode(secret))) returns (uint256 id) {
            _secretOf[id] = secret;
            _liveRounds.push(id);
            return (true, id);
        } catch (bytes memory reason) {
            _unexpected("openRound", reason);
        }
    }

    /// @dev Enter an idle Friend into an open round, paid by the owner or from its wallet.
    function _enter(uint256 roundId, uint256 friendId, bool viaWallet) internal returns (bool ok) {
        _ensureRf(viaWallet ? _walletOf(friendId) : address(this), LaunchTerms.ROYALE_ENTRY);
        if (viaWallet) {
            bytes memory data = abi.encodeCall(RoundModule.enter, (roundId, friendId));
            try _wallet(friendId).execute(address(round), 0, data, 0) {
                return true;
            } catch (bytes memory reason) {
                _unexpected("enter", reason);
            }
        } else {
            try round.enter(roundId, friendId) {
                return true;
            } catch (bytes memory reason) {
                _unexpected("enter", reason);
            }
        }
    }

    /// @dev Enters up to `count` idle Friends, starting from a seeded offset.
    function _fill(uint256 roundId, uint256 seed, uint256 count)
        internal
        returns (uint256 entered)
    {
        uint256 n = _friends.length;
        for (uint256 k; k < n && entered < count; ++k) {
            uint256 friendId = _friends[(seed % n + k) % n];
            if (!_isIdle(friendId)) continue;
            if (_enter(roundId, friendId, (seed >> k) & 1 == 1)) ++entered;
        }
    }

    /// @dev Close: a short round is refunded on the spot, otherwise its request is tracked.
    function _close(uint256 roundId) internal returns (bool ok) {
        vm.prank(settler);
        try round.closeRound(roundId) {
            (,,, RoundModule.Status status, uint256 requestId) = round.rounds(roundId);
            if (status == RoundModule.Status.Refunded) _remove(_liveRounds, roundId);
            else _pendingRequests.push(requestId);
            return true;
        } catch (bytes memory reason) {
            _unexpected("closeRound", reason);
        }
    }

    /// @dev Pays the pot to 1..n seeded entrants (duplicates allowed) after revealing the word.
    function _settleRound(uint256 roundId, uint256 seed, uint256 payees)
        internal
        returns (bool ok)
    {
        (,,,, uint256 requestId) = round.rounds(roundId);
        (bool fulfilled,) = coordinator.word(requestId);
        if (!fulfilled && !_reveal(requestId, seed)) return false;
        uint256[] memory entrants = round.entrants(roundId);
        (uint256[] memory ids, uint256[] memory amounts) =
            _payoutList(entrants, round.potOf(roundId), seed, bound(payees, 1, entrants.length));
        vm.prank(settler);
        try round.settleRound(roundId, _secretOf[roundId], ids, amounts) {
            uint256 gross = entrants.length * LaunchTerms.ROYALE_ENTRY;
            expectedBurn += gross * LaunchTerms.ROYALE_BURN_BPS / BPS;
            expectedRewards += gross * LaunchTerms.ROYALE_REWARDS_BPS / BPS;
            _remove(_liveRounds, roundId);
            return true;
        } catch (bytes memory reason) {
            _unexpected("settleRound", reason);
        }
    }

    function _payoutList(uint256[] memory entrants, uint256 pot, uint256 seed, uint256 k)
        internal
        pure
        returns (uint256[] memory ids, uint256[] memory amounts)
    {
        ids = new uint256[](k);
        amounts = new uint256[](k);
        uint256 remaining = pot;
        for (uint256 i; i < k; ++i) {
            ids[i] = entrants[uint256(keccak256(abi.encode(seed, i))) % entrants.length];
            amounts[i] = i + 1 == k ? remaining : pot / k;
            remaining -= amounts[i];
        }
    }

    /// @dev Half of every spend burns and half accrues for rewards (section 3.4).
    function _spend(uint256 roundId, uint256 payerFriendId, uint256 targetFriendId, uint8 kind)
        internal
        returns (bool ok)
    {
        uint256 price = round.kindPrices(royaleId)[kind - 1];
        uint256 credit = treasury.creditOf(royaleId, payerFriendId);
        if (credit < price && !_deposit(payerFriendId, price - credit)) return false;
        vm.prank(settler);
        try round.spend(roundId, payerFriendId, targetFriendId, kind) {
            uint256 burned = price * LaunchTerms.ROYALE_SPEND_BURN_BPS / BPS;
            expectedBurn += burned;
            expectedRewards += price - burned;
            return true;
        } catch (bytes memory reason) {
            _unexpected("spend", reason);
        }
    }

    function _deposit(uint256 friendId, uint256 amount) internal returns (bool ok) {
        _ensureRf(address(this), amount);
        try round.depositCredit(royaleId, friendId, amount) {
            return true;
        } catch (bytes memory reason) {
            _unexpected("depositCredit", reason);
        }
    }

    // ------------------------------------------------------------------- finders

    function _friend(uint256 seed) internal view returns (uint256) {
        return _friends[seed % _friends.length];
    }

    function _game(uint256 seed) internal view returns (uint256) {
        uint256 choice = seed % 3;
        return choice == 0 ? breedsId : choice == 1 ? parkId : royaleId;
    }

    /// @dev First Friend from a seeded offset whose wallet holds `classId`.
    function _friendWithItem(GameItems collection, uint256 classId, uint256 seed)
        internal
        view
        returns (bool found, uint256 friendId)
    {
        uint256 n = _friends.length;
        for (uint256 k; k < n; ++k) {
            friendId = _friends[(seed % n + k) % n];
            if (collection.balanceOf(_walletOf(friendId), classId) != 0) return (true, friendId);
        }
    }

    /// @dev First Friend and ball class, from seeded offsets, with a ball to kick.
    function _friendWithBall(uint256 seed)
        internal
        view
        returns (bool found, uint256 friendId, uint16 ball)
    {
        for (uint256 b; b < LaunchTerms.PARK_BALLS; ++b) {
            ball = _u16(1 + (seed % LaunchTerms.PARK_BALLS + b) % LaunchTerms.PARK_BALLS);
            (found, friendId) = _friendWithItem(parkItems, ball, seed >> 8);
            if (found) return (found, friendId, ball);
        }
    }

    /// @dev First Friend and tier class (2..5), from seeded offsets, with a token to redeem.
    function _friendWithTier(uint256 seed)
        internal
        view
        returns (bool found, uint256 friendId, uint16 tier)
    {
        for (uint256 t; t < 4; ++t) {
            tier = _u16(LaunchTerms.BREEDS_COMMON + (seed % 4 + t) % 4);
            (found, friendId) = _friendWithItem(breedsItems, tier, seed >> 8);
            if (found) return (found, friendId, tier);
        }
    }

    function _isIdle(uint256 friendId) internal view returns (bool) {
        uint256 latest = round.roundOf(royaleId, friendId);
        return latest == 0 || _status(latest) >= RoundModule.Status.Settled;
    }

    function _status(uint256 roundId) internal view returns (RoundModule.Status status) {
        (,,, status,) = round.rounds(roundId);
    }

    function _idleFriend(uint256 seed) internal view returns (bool found, uint256 friendId) {
        uint256 n = _friends.length;
        for (uint256 k; k < n; ++k) {
            friendId = _friends[(seed % n + k) % n];
            if (_isIdle(friendId)) return (true, friendId);
        }
    }

    function _idleCount() internal view returns (uint256 count) {
        for (uint256 i; i < _friends.length; ++i) {
            if (_isIdle(_friends[i])) ++count;
        }
    }

    function _idleFriendWithCredit(uint256 seed)
        internal
        view
        returns (bool found, uint256 friendId)
    {
        uint256 n = _friends.length;
        for (uint256 k; k < n; ++k) {
            friendId = _friends[(seed % n + k) % n];
            if (_isIdle(friendId) && treasury.creditOf(royaleId, friendId) != 0) {
                return (true, friendId);
            }
        }
    }

    function _busyFriendWithCredit(uint256 seed)
        internal
        view
        returns (bool found, uint256 friendId)
    {
        uint256 n = _friends.length;
        for (uint256 k; k < n; ++k) {
            friendId = _friends[(seed % n + k) % n];
            if (!_isIdle(friendId) && treasury.creditOf(royaleId, friendId) != 0) {
                return (true, friendId);
            }
        }
    }

    function _liveWithStatus(uint256 seed, RoundModule.Status wanted)
        internal
        view
        returns (bool found, uint256 roundId)
    {
        uint256 n = _liveRounds.length;
        for (uint256 k; k < n; ++k) {
            roundId = _liveRounds[(seed % n + k) % n];
            if (_status(roundId) == wanted) return (true, roundId);
        }
    }

    /// @dev A live round with entrants and one of its entrants, from seeded offsets.
    function _liveEntrant(uint256 seed)
        internal
        view
        returns (bool found, uint256 roundId, uint256 friendId)
    {
        uint256 n = _liveRounds.length;
        for (uint256 k; k < n; ++k) {
            roundId = _liveRounds[(seed % n + k) % n];
            uint256[] memory entrants = round.entrants(roundId);
            if (entrants.length == 0) continue;
            return (true, roundId, entrants[(seed >> 8) % entrants.length]);
        }
    }

    // ----------------------------------------------------------------- utilities

    function _walletOf(uint256 friendId) internal view returns (address) {
        return generations.tokenBoundAccount(friendId);
    }

    function _wallet(uint256 friendId) internal view returns (MockFriendWallet) {
        return MockFriendWallet(payable(_walletOf(friendId)));
    }

    function _mintRf(address to, uint256 amount) internal {
        rf.mint(to, amount);
        rfMinted += amount;
    }

    function _ensureRf(address holder, uint256 amount) internal {
        uint256 balance = rf.balanceOf(holder);
        if (balance < amount) _mintRf(holder, amount - balance);
    }

    function _ensureUsdg(uint256 amount) internal {
        uint256 balance = usdg.balanceOf(address(this));
        if (balance < amount) usdg.mint(address(this), amount - balance);
    }

    /// @dev Tops the game's free stake up to `needed` through `fund`.
    function _ensureFree(uint256 gameId, uint256 needed) internal {
        (uint256 free,,,) = treasury.ledgers(gameId);
        if (free < needed) _fund(gameId, needed - free);
    }

    function _fund(uint256 gameId, uint256 amount) internal {
        if (gameId == parkId) _ensureUsdg(amount);
        else _ensureRf(address(this), amount);
        try treasury.fund(gameId, amount) { }
        catch (bytes memory reason) {
            _unexpected("fund", reason);
        }
    }

    function _unexpected(string memory action, bytes memory reason) internal {
        ++unexpectedReverts;
        lastAction = action;
        lastRevert = reason;
    }

    /// @dev A call that had to revert did; record it unless it reverted with `selector`.
    function _expectError(string memory action, bytes memory reason, bytes4 selector) internal {
        // Only the leading selector is compared; the length check keeps the read in bounds.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (reason.length < 4 || bytes4(reason) != selector) _unexpected(action, reason);
    }

    function _remove(uint256[] storage list, uint256 value) internal {
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] != value) continue;
            list[i] = list[n - 1];
            list.pop();
            return;
        }
    }

    /// @dev Callers bound every value to the target range before narrowing.
    function _u8(uint256 x) internal pure returns (uint8) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(x);
    }

    function _u16(uint256 x) internal pure returns (uint16) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(x);
    }

    function _u64(uint256 x) internal pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(x);
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }
}

/// @dev Stateful invariant suite over the Fixture with all three launch games (SPEC section 9,
/// `invariant/Platform.invariant.t.sol`). The handler above is the only fuzz target; every
/// invariant is checked after every handler call with the `[invariant]` settings of
/// foundry.toml (64 runs, depth 32, `fail_on_revert = false`).
contract PlatformInvariantTest is Fixture {
    PlatformHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new PlatformHandler(
            PlatformHandler.Env({
                rf: rf,
                usdg: usdg,
                generations: generations,
                dice: dice,
                manager: manager,
                treasury: treasury,
                coordinator: coordinator,
                draw: draw,
                round: round,
                breedsItems: items(breedsId),
                parkItems: items(parkId),
                owner: owner,
                settler: settler,
                provider: provider,
                breedsId: breedsId,
                parkId: parkId,
                royaleId: royaleId
            })
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](25);
        selectors[0] = PlatformHandler.fund.selector;
        selectors[1] = PlatformHandler.donate.selector;
        selectors[2] = PlatformHandler.payFees.selector;
        selectors[3] = PlatformHandler.forwardRewards.selector;
        selectors[4] = PlatformHandler.withdrawFree.selector;
        selectors[5] = PlatformHandler.toggleBlockedRecipient.selector;
        selectors[6] = PlatformHandler.promoteFriend.selector;
        selectors[7] = PlatformHandler.setDiceFee.selector;
        selectors[8] = PlatformHandler.advanceChain.selector;
        selectors[9] = PlatformHandler.buyEggs.selector;
        selectors[10] = PlatformHandler.playEggs.selector;
        selectors[11] = PlatformHandler.buyPacks.selector;
        selectors[12] = PlatformHandler.kickBall.selector;
        selectors[13] = PlatformHandler.settleDraw.selector;
        selectors[14] = PlatformHandler.redeemTier.selector;
        selectors[15] = PlatformHandler.revealWord.selector;
        selectors[16] = PlatformHandler.retryRequest.selector;
        selectors[17] = PlatformHandler.depositCredit.selector;
        selectors[18] = PlatformHandler.withdrawCredit.selector;
        selectors[19] = PlatformHandler.openRound.selector;
        selectors[20] = PlatformHandler.enterRound.selector;
        selectors[21] = PlatformHandler.closeRound.selector;
        selectors[22] = PlatformHandler.spendCredit.selector;
        selectors[23] = PlatformHandler.settleRound.selector;
        selectors[24] = PlatformHandler.abandonRound.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    // -------------------------------------------------------------------- I1..I4

    /// @dev I1: the held balance covers every obligation, per currency.
    function invariant_solventPerCurrency() public view {
        assertSolvent(address(rf));
        assertSolvent(address(usdg));
    }

    /// @dev I2: balance == every ledger column + rewardsPending + direct donations, exactly.
    function invariant_conservation() public view {
        assertEq(
            rf.balanceOf(address(treasury)),
            treasury.backed(address(rf)) + handler.donatedRf(),
            "RF conservation"
        );
        assertEq(
            usdg.balanceOf(address(treasury)),
            treasury.backed(address(usdg)) + handler.donatedUsdg(),
            "USDG conservation"
        );
    }

    /// @dev I3: per-game ledgers sum to the currency totals; fees total the fee ledger.
    function invariant_ledgerTotals() public view {
        assertEq(registry.gameCount(), 3, "exactly the three launch games");
        (uint256 bFree, uint256 bReserved, uint256 bOwed, uint256 bCredit) = ledger(breedsId);
        (uint256 yFree, uint256 yReserved, uint256 yOwed, uint256 yCredit) = ledger(royaleId);
        (uint256 free, uint256 reserved, uint256 owed, uint256 credit, uint256 fees) =
            treasury.totals(address(rf));
        assertEq(free, bFree + yFree, "RF free");
        assertEq(reserved, bReserved + yReserved, "RF reserved");
        assertEq(owed, bOwed + yOwed, "RF owed");
        assertEq(credit, bCredit + yCredit, "RF credit");
        assertEq(fees, 0, "RF fees");

        (uint256 pFree, uint256 pReserved, uint256 pOwed, uint256 pCredit) = ledger(parkId);
        (free, reserved, owed, credit, fees) = treasury.totals(address(usdg));
        assertEq(free, pFree, "USDG free");
        assertEq(reserved, pReserved, "USDG reserved");
        assertEq(owed, pOwed, "USDG owed");
        assertEq(credit, pCredit, "USDG credit");
        assertEq(
            fees,
            treasury.feesOwed(address(usdg), PARK_DEVELOPER)
                + treasury.feesOwed(address(usdg), PARK_OPERATOR),
            "USDG fees"
        );
    }

    /// @dev I4: per-Friend credit sums to the game's credit column; Draw games hold none.
    function invariant_creditSums() public view {
        uint256 sum;
        for (uint256 i; i < handler.friendCount(); ++i) {
            sum += treasury.creditOf(royaleId, handler.friendAt(i));
        }
        (,,, uint256 credit) = ledger(royaleId);
        assertEq(sum, credit, "royale credit");
        (,,, credit) = ledger(breedsId);
        assertEq(credit, 0, "breeds credit");
        (,,, credit) = ledger(parkId);
        assertEq(credit, 0, "park credit");
    }

    // ------------------------------------------------------------ module backing

    /// @dev reserved == Σ unsettled Commit.reservedTotal + eggs × 6e18 (Breeds), Σ unsettled
    /// reservedTotal (Park), Σ live round entries × 1e18 (Royale).
    function invariant_reservedMatchesPending() public view {
        uint256 breedsPending;
        uint256 parkPending;
        uint256 count = draw.commitCount();
        for (uint256 id = 1; id <= count; ++id) {
            (uint256 gameId,,,,, bool settled, uint128 reservedTotal,) = draw.commits(id);
            if (settled) continue;
            if (gameId == breedsId) breedsPending += reservedTotal;
            else parkPending += reservedTotal;
        }
        uint256 eggs = _supply(items(breedsId), LaunchTerms.BREEDS_EGG);
        (, uint256 reserved,,) = ledger(breedsId);
        assertEq(reserved, breedsPending + eggs * 6e18, "breeds reserved");
        (, reserved,,) = ledger(parkId);
        assertEq(reserved, parkPending, "park reserved");

        uint256 entries;
        uint256 rounds = round.roundCount();
        for (uint256 id = 1; id <= rounds; ++id) {
            (,,, RoundModule.Status status,) = round.rounds(id);
            if (status == RoundModule.Status.Open || status == RoundModule.Status.Closed) {
                entries += round.entrants(id).length;
            }
        }
        (, reserved,,) = ledger(royaleId);
        assertEq(reserved, entries * LaunchTerms.ROYALE_ENTRY, "royale reserved");
    }

    /// @dev owed == Σ tier supply × class value for Breeds; the other games owe nothing.
    function invariant_owedMatchesSupply() public view {
        DrawTables.Class[] memory classes = draw.classes(breedsId);
        uint256 expected;
        for (uint256 i; i < classes.length; ++i) {
            // Class ids are 1-based; only the four tier classes carry a value.
            if (classes[i].value != 0) {
                expected += _supply(items(breedsId), i + 1) * classes[i].value;
            }
        }
        (,, uint256 owed,) = ledger(breedsId);
        assertEq(owed, expected, "breeds owed");
        (,, owed,) = ledger(parkId);
        assertEq(owed, 0, "park owed");
        (,, owed,) = ledger(royaleId);
        assertEq(owed, 0, "royale owed");
    }

    // ---------------------------------------------------------------- randomness

    /// @dev Every requested word is bound to exactly one commit or round and vice versa; live
    /// sequences point back at their request and fulfilled ones are unbound.
    function invariant_oneRequestPerAction() public view {
        uint256 bindings;
        uint256 last;
        uint256 count = draw.commitCount();
        for (uint256 id = 1; id <= count; ++id) {
            (uint256 gameId,,,,,,, uint256 requestId) = draw.commits(id);
            if (requestId == 0) continue;
            _assertBinding(requestId, address(draw), gameId, bytes32(id));
            // Draw requests are made at commit time, so they grow with the commit id.
            assertGt(requestId, last, "draw request ids repeat");
            last = requestId;
            ++bindings;
        }
        uint256 rounds = round.roundCount();
        for (uint256 id = 1; id <= rounds; ++id) {
            (uint256 gameId,,,, uint256 requestId) = round.rounds(id);
            if (requestId == 0) continue;
            _assertBinding(requestId, address(round), gameId, bytes32(id));
            ++bindings;
        }
        assertEq(coordinator.requestCount(), bindings, "unbound coordinator requests");
    }

    /// @dev The coordinator holds platform ETH only: no RF or USDG, and its balance moves only
    /// against the game budgets (every fee leaves a budget, every reclaim returns to one).
    function invariant_coordinatorHoldsNoPlayerMoney() public view {
        assertEq(rf.balanceOf(address(coordinator)), 0, "coordinator RF");
        assertEq(usdg.balanceOf(address(coordinator)), 0, "coordinator USDG");
        assertEq(rf.balanceOf(address(draw)), 0, "draw RF");
        assertEq(usdg.balanceOf(address(draw)), 0, "draw USDG");
        assertEq(rf.balanceOf(address(round)), 0, "round RF");
        assertEq(rf.balanceOf(address(registry)), 0, "registry RF");
        uint256 budgets = coordinator.budget(breedsId) + coordinator.budget(parkId)
            + coordinator.budget(royaleId);
        assertEq(address(coordinator).balance, 7 ether + budgets, "budget accounting");
        assertEq(address(coordinator).balance + address(dice).balance, 10 ether, "ETH leaked");
    }

    // ------------------------------------------------------------------ routing

    /// @dev Burns and rewards come only from round settlements and spends, in the exact bps.
    function invariant_burnAndRewardsRouting() public view {
        assertEq(
            rf.totalSupply(),
            handler.rfSupplyBaseline() + handler.rfMinted() - handler.expectedBurn(),
            "RF burned"
        );
        assertEq(
            treasury.rewardsPending() + manager.funded(address(rf)),
            handler.expectedRewards(),
            "RF rewards"
        );
        assertEq(rf.balanceOf(address(manager)), manager.funded(address(rf)), "manager RF");
    }

    /// @dev Penalty Kings fees accrue by the section 3.3 split and leave only through payFees.
    function invariant_feesMatchSplits() public view {
        assertEq(
            treasury.feesOwed(address(usdg), PARK_DEVELOPER),
            handler.devAccrued() - handler.devPaid(),
            "developer fees"
        );
        assertEq(
            treasury.feesOwed(address(usdg), PARK_OPERATOR),
            handler.opAccrued() - handler.opPaid(),
            "operator fees"
        );
        assertEq(usdg.balanceOf(PARK_DEVELOPER), handler.devPaid(), "developer paid");
        assertEq(usdg.balanceOf(PARK_OPERATOR), handler.opPaid(), "operator paid");
    }

    /// @dev Every entrant of a live round points at it, and no round exceeds maxEntries.
    function invariant_roundEntrantsConsistent() public view {
        for (uint256 i; i < handler.liveRoundCount(); ++i) {
            uint256 roundId = handler.liveRoundAt(i);
            (uint256 gameId,,, RoundModule.Status status,) = round.rounds(roundId);
            assertEq(gameId, royaleId, "live round game");
            assertTrue(
                status == RoundModule.Status.Open || status == RoundModule.Status.Closed,
                "live round status"
            );
            uint256[] memory entrants = round.entrants(roundId);
            assertLe(entrants.length, LaunchTerms.ROYALE_MAX_ENTRIES, "round over capacity");
            for (uint256 j; j < entrants.length; ++j) {
                assertEq(round.roundOf(royaleId, entrants[j]), roundId, "entrant roundOf");
            }
        }
    }

    /// @dev Every call whose preconditions held succeeded, every refused call reverted with the
    /// specified error, and every Dice callback landed.
    function invariant_noUnexpectedReverts() public view {
        if (handler.unexpectedReverts() != 0) {
            console.log("unexpected outcome in", handler.lastAction());
            console.logBytes(handler.lastRevert());
        }
        assertEq(handler.unexpectedReverts(), 0, "unexpected reverts");
        assertEq(handler.callbackFailures(), 0, "rejected Dice callbacks");
    }

    // ------------------------------------------------------------------ helpers

    function _supply(GameItems collection, uint256 classId) internal view returns (uint256 sum) {
        for (uint256 i; i < handler.friendCount(); ++i) {
            sum += collection.balanceOf(walletOf(handler.friendAt(i)), classId);
        }
    }

    function _assertBinding(uint256 requestId, address module, uint256 gameId, bytes32 actionKey)
        internal
        view
    {
        (address m, uint256 g, bytes32 key, uint64 sequence,, RandomnessCoordinator.State state,) =
            coordinator.requests(requestId);
        assertEq(m, module, "request module");
        assertEq(g, gameId, "request game");
        assertEq(key, actionKey, "request action");
        assertTrue(state != RandomnessCoordinator.State.None, "request state");
        assertEq(
            coordinator.boundRequest(keccak256(abi.encode(module, gameId, actionKey))),
            requestId,
            "binding key"
        );
        if (state == RandomnessCoordinator.State.Requested) {
            assertEq(coordinator.requestOfSequence(sequence), requestId, "live sequence");
        } else {
            assertEq(coordinator.requestOfSequence(sequence), 0, "stale sequence");
        }
    }
}
