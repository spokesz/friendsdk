// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ReentrancyGuard } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { IGenerations } from "./interfaces/IExternal.sol";
import { IGameModule } from "./interfaces/IGameModule.sol";
import { IGameRegistry } from "./interfaces/IGameRegistry.sol";
import { IRandomnessCoordinator } from "./interfaces/IRandomnessCoordinator.sol";
import { ITreasury } from "./interfaces/ITreasury.sol";
import { FriendAccess } from "./libraries/FriendAccess.sol";

/// @notice Rare Royale rounds: a settler commits a secret, Friends enter a shared pot, one Dice
/// word is requested at close and the settler pays an explicit list whose sum equals the pot.
/// @dev Holds no funds. Entries are reserved whole in the Treasury and burn/rewards are routed
/// only at settlement so that a short or abandoned round returns every entry exactly. Mid-round
/// purchases debit prefunded Friend credit held by the Treasury.
contract RoundModule is ReentrancyGuard, IGameModule {
    enum Status {
        None,
        Open,
        Closed,
        Settled,
        Refunded
    }

    /// @dev One slot. potBps + burnBps + rewardsBps and spendBurnBps + spendRewardsBps sum to BPS.
    struct Terms {
        uint128 entryPrice;
        uint16 potBps;
        uint16 burnBps;
        uint16 rewardsBps;
        uint16 spendBurnBps;
        uint16 spendRewardsBps;
        uint16 minEntries;
        uint16 maxEntries;
    }

    struct Round {
        uint256 gameId;
        // keccak256(abi.encode(secret)), committed before entries open.
        bytes32 secretHash;
        uint64 openedAt;
        Status status;
        // Zero until closed with enough entries.
        uint256 requestId;
    }

    bytes32 public constant LINEAGE = keccak256("Round");
    // From openedAt; afterwards anyone may refund a round the settler never finished.
    uint256 public constant ABANDON_AFTER = 1 days;
    uint8 public constant MAX_KINDS = 32;
    uint256 private constant _BPS = 10_000;

    IGameRegistry public immutable registry;
    ITreasury public immutable treasury;
    IRandomnessCoordinator public immutable coordinator;
    IGenerations public immutable generations;

    mapping(uint256 gameId => Terms) public terms;
    // Index = kind - 1.
    mapping(uint256 gameId => uint128[]) private _kindPrices;
    mapping(uint256 gameId => bool) public isSealed;
    uint256 public roundCount;
    mapping(uint256 roundId => Round) public rounds;
    // Friend ids in entry order; pot and entry count derive from its length and the terms.
    mapping(uint256 roundId => uint256[]) private _entrants;
    // Latest round entered; a Friend is in at most one unsettled round at a time.
    mapping(uint256 gameId => mapping(uint256 friendId => uint256)) public roundOf;
    // Rounds Open or Closed; succession waits for zero so the per-Friend lock cannot be bypassed.
    mapping(uint256 gameId => uint256) public liveRounds;

    error InvalidConfiguration();
    error NotRegistryOwner();
    error OnlyRegistry();
    error Sealed();
    error InvalidTerms();
    error NotCurrentModule();
    error GameNotActive();
    error OnlySettler();
    error WrongStatus();
    error RoundFull();
    error NotEntrant();
    error UnknownKind();
    error BadSecret();
    error RandomnessPending();
    error LengthMismatch();
    error PotMismatch();
    error ZeroAmount();
    error RoundInProgress();
    error NotAbandonable();
    error NoTerms();

    event TermsDefined(uint256 indexed gameId, Terms terms, uint128[] kindPrices);
    event TermsSealed(uint256 indexed gameId, bytes32 termsHash);
    event RoundOpened(
        uint256 indexed roundId, uint256 indexed gameId, bytes32 secretHash, uint64 openedAt
    );
    event Entered(
        uint256 indexed roundId,
        uint256 indexed friendId,
        address indexed wallet,
        address payer,
        uint16 seat
    );
    event RoundClosed(uint256 indexed roundId, uint16 entries, uint256 pot, uint256 requestId);
    event Spent(
        uint256 indexed roundId,
        uint256 indexed payerFriendId,
        uint256 indexed targetFriendId,
        uint8 kind,
        uint256 price
    );
    event RoundSettled(
        uint256 indexed roundId,
        bytes32 word,
        bytes32 secret,
        uint256[] friendIds,
        uint256[] amounts
    );
    event RoundRefunded(uint256 indexed roundId, uint16 entries, bool abandoned);

    constructor(address registry_, address treasury_, address coordinator_, address generations_) {
        if (
            registry_.code.length == 0 || treasury_.code.length == 0
                || coordinator_.code.length == 0 || generations_.code.length == 0
                || IGameRegistry(registry_).generations() != generations_
        ) revert InvalidConfiguration();
        registry = IGameRegistry(registry_);
        treasury = ITreasury(treasury_);
        coordinator = IRandomnessCoordinator(coordinator_);
        generations = IGenerations(generations_);
    }

    /// @notice The registry owner defines a game's terms once, before the registry seals them.
    function defineTerms(uint256 gameId, Terms calldata t, uint128[] calldata prices) external {
        if (msg.sender != registry.owner()) revert NotRegistryOwner();
        if (isSealed[gameId]) revert Sealed();
        if (
            terms[gameId].entryPrice != 0 || registry.currencyOf(gameId) != registry.rf()
                || t.entryPrice == 0 || t.potBps == 0
                || uint256(t.potBps) + t.burnBps + t.rewardsBps != _BPS
                || uint256(t.spendBurnBps) + t.spendRewardsBps != _BPS || t.minEntries == 0
                || t.minEntries > t.maxEntries || prices.length == 0 || prices.length > MAX_KINDS
        ) revert InvalidTerms();
        for (uint256 i; i < prices.length; ++i) {
            if (prices[i] == 0) revert InvalidTerms();
        }
        terms[gameId] = t;
        _kindPrices[gameId] = prices;
        emit TermsDefined(gameId, t, prices);
    }

    /// @notice Registry only. Freezes the terms and returns their hash; idempotent once sealed.
    function seal(uint256 gameId) external returns (bytes32) {
        if (msg.sender != address(registry)) revert OnlyRegistry();
        if (isSealed[gameId]) return _termsHash(gameId);
        if (terms[gameId].entryPrice == 0) revert NoTerms();
        isSealed[gameId] = true;
        bytes32 hash = _termsHash(gameId);
        emit TermsSealed(gameId, hash);
        return hash;
    }

    /// @notice The settler opens a round for an active game, committing to its secret.
    function openRound(uint256 gameId, bytes32 secretHash)
        external
        nonReentrant
        returns (uint256 roundId)
    {
        if (msg.sender != registry.settlerOf(gameId)) revert OnlySettler();
        // Activation sealed the terms, so an active, current game is always sealed here.
        _requireCommitting(gameId);
        if (secretHash == 0) revert BadSecret();
        roundId = ++roundCount;
        ++liveRounds[gameId];
        // Timestamps fit uint64 for the lifetime of the chain.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 openedAt = uint64(block.timestamp);
        rounds[roundId] = Round(gameId, secretHash, openedAt, Status.Open, 0);
        emit RoundOpened(roundId, gameId, secretHash, openedAt);
    }

    /// @notice The settler closes entries: a short round refunds, otherwise one word is requested.
    function closeRound(uint256 roundId) external nonReentrant {
        Round storage round = _settlerRound(roundId);
        if (round.status != Status.Open) revert WrongStatus();
        uint256 n = _entrants[roundId].length;
        if (n < terms[round.gameId].minEntries) {
            _refund(roundId, false);
            return;
        }
        uint256 requestId = coordinator.request(round.gameId, bytes32(roundId));
        round.requestId = requestId;
        round.status = Status.Closed;
        // Bounded by maxEntries, a uint16.
        // forge-lint: disable-next-line(unsafe-typecast)
        emit RoundClosed(roundId, uint16(n), potOf(roundId), requestId);
    }

    /// @notice The settler debits an entrant's prefunded credit for a term-listed kind.
    /// @dev The target is informational for the replayable simulation; caps are the settler's job.
    function spend(uint256 roundId, uint256 payerFriendId, uint256 targetFriendId, uint8 kind)
        external
        nonReentrant
    {
        Round storage round = _settlerRound(roundId);
        if (round.status != Status.Open && round.status != Status.Closed) revert WrongStatus();
        uint256 gameId = round.gameId;
        if (roundOf[gameId][payerFriendId] != roundId) revert NotEntrant();
        uint128[] storage prices = _kindPrices[gameId];
        if (kind == 0 || kind > prices.length) revert UnknownKind();
        uint256 price = prices[kind - 1];
        uint256 burned = price * terms[gameId].spendBurnBps / _BPS;
        treasury.creditSpend(gameId, payerFriendId, price, burned, price - burned);
        emit Spent(roundId, payerFriendId, targetFriendId, kind, price);
    }

    /// @notice The settler reveals its secret and pays entrants a list summing exactly to the pot.
    function settleRound(
        uint256 roundId,
        bytes32 secret,
        uint256[] calldata friendIds,
        uint256[] calldata amounts
    ) external nonReentrant {
        Round storage round = _settlerRound(roundId);
        if (round.status != Status.Closed) revert WrongStatus();
        if (keccak256(abi.encode(secret)) != round.secretHash) revert BadSecret();
        (bool fulfilled, bytes32 word) = coordinator.word(round.requestId);
        if (!fulfilled) revert RandomnessPending();
        if (friendIds.length == 0 || friendIds.length != amounts.length) revert LengthMismatch();
        uint256 gameId = round.gameId;
        (uint256 burned, uint256 rewards, uint256 pot) = _split(roundId);
        uint256 total;
        for (uint256 i; i < friendIds.length; ++i) {
            if (roundOf[gameId][friendIds[i]] != roundId) revert NotEntrant();
            if (amounts[i] == 0) revert ZeroAmount();
            total += amounts[i];
        }
        if (total != pot) revert PotMismatch();
        round.status = Status.Settled;
        --liveRounds[gameId];
        treasury.routeReserved(gameId, burned, rewards);
        for (uint256 i; i < friendIds.length; ++i) {
            _pay(gameId, friendIds[i], amounts[i]);
        }
        emit RoundSettled(roundId, word, secret, friendIds, amounts);
    }

    /// @notice A Friend's owner or canonical wallet pays one entry into an open round.
    function enter(uint256 roundId, uint256 friendId) external nonReentrant {
        Round storage round = rounds[roundId];
        if (round.status != Status.Open) revert WrongStatus();
        uint256 gameId = round.gameId;
        if (!registry.isActive(gameId)) revert GameNotActive();
        Terms memory t = terms[gameId];
        uint256[] storage entrants_ = _entrants[roundId];
        if (entrants_.length >= t.maxEntries) revert RoundFull();
        _requireIdle(gameId, friendId);
        (address wallet,) = FriendAccess.controlled(generations, friendId, msg.sender);
        treasury.collect(gameId, msg.sender, ITreasury.Legs(0, t.entryPrice, 0, 0, 0, 0));
        entrants_.push(friendId);
        roundOf[gameId][friendId] = roundId;
        // Bounded by maxEntries, a uint16.
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Entered(roundId, friendId, wallet, msg.sender, uint16(entrants_.length));
    }

    /// @notice Anyone refunds a round its settler left unfinished past the abandonment clock.
    function abandonRound(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];
        if (round.status != Status.Open && round.status != Status.Closed) revert NotAbandonable();
        // A one-day window cannot be moved by the seconds a validator may skew the timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < uint256(round.openedAt) + ABANDON_AFTER) revert NotAbandonable();
        _refund(roundId, true);
    }

    /// @notice A Friend's owner or canonical wallet prefunds credit for mid-round purchases.
    function depositCredit(uint256 gameId, uint256 friendId, uint256 amount) external nonReentrant {
        _requireCommitting(gameId);
        FriendAccess.controlled(generations, friendId, msg.sender);
        treasury.creditDeposit(gameId, friendId, msg.sender, amount);
    }

    /// @notice Unspent credit returns to the canonical wallet whenever no live round uses it.
    function withdrawCredit(uint256 gameId, uint256 friendId, uint256 amount)
        external
        nonReentrant
    {
        (address wallet,) = FriendAccess.controlled(generations, friendId, msg.sender);
        _requireIdle(gameId, friendId);
        treasury.creditWithdraw(gameId, friendId, wallet, amount);
    }

    function termsHash(uint256 gameId) external view returns (bytes32) {
        return isSealed[gameId] ? _termsHash(gameId) : bytes32(0);
    }

    /// @inheritdoc IGameModule
    /// @dev The per-Friend credit lock lives in this module's `roundOf`, so a successor could
    /// not see a live round here; succession waits until every round has settled or refunded.
    function succeedable(uint256 gameId) external view returns (bool) {
        return liveRounds[gameId] == 0;
    }

    function entrants(uint256 roundId) external view returns (uint256[] memory) {
        return _entrants[roundId];
    }

    function kindPrices(uint256 gameId) external view returns (uint128[] memory) {
        return _kindPrices[gameId];
    }

    function potOf(uint256 roundId) public view returns (uint256 pot) {
        (,, pot) = _split(roundId);
    }

    /// @dev Returns every entry whole; nothing has left the pot before settlement.
    function _refund(uint256 roundId, bool abandoned) private {
        Round storage round = rounds[roundId];
        uint256 gameId = round.gameId;
        uint256[] storage entrants_ = _entrants[roundId];
        uint256 n = entrants_.length;
        uint256 entryPrice = terms[gameId].entryPrice;
        round.status = Status.Refunded;
        --liveRounds[gameId];
        for (uint256 i; i < n; ++i) {
            _pay(gameId, entrants_[i], entryPrice);
        }
        // Bounded by maxEntries, a uint16.
        // forge-lint: disable-next-line(unsafe-typecast)
        emit RoundRefunded(roundId, uint16(n), abandoned);
    }

    /// @dev Releases `amount` of the round's reservation straight into the Friend's wallet.
    function _pay(uint256 gameId, uint256 friendId, uint256 amount) private {
        treasury.resolve(gameId, amount, 0, 0, generations.tokenBoundAccount(friendId), amount);
    }

    function _settlerRound(uint256 roundId) private view returns (Round storage round) {
        round = rounds[roundId];
        if (msg.sender != registry.settlerOf(round.gameId)) revert OnlySettler();
    }

    /// @dev Burn and rewards legs taken at settlement, and the pot the settler's list must equal.
    function _split(uint256 roundId)
        private
        view
        returns (uint256 burned, uint256 rewards, uint256 pot)
    {
        Terms memory t = terms[rounds[roundId].gameId];
        uint256 gross = _entrants[roundId].length * t.entryPrice;
        burned = gross * t.burnBps / _BPS;
        rewards = gross * t.rewardsBps / _BPS;
        pot = gross - burned - rewards;
    }

    /// @dev Opening rounds and depositing credit need this module current on an active game.
    function _requireCommitting(uint256 gameId) private view {
        if (registry.currentModule(gameId) != address(this)) revert NotCurrentModule();
        if (!registry.isActive(gameId)) revert GameNotActive();
    }

    /// @dev A Friend whose latest round is still Open or Closed cannot enter or withdraw.
    function _requireIdle(uint256 gameId, uint256 friendId) private view {
        uint256 latest = roundOf[gameId][friendId];
        if (latest != 0 && rounds[latest].status < Status.Settled) revert RoundInProgress();
    }

    function _termsHash(uint256 gameId) private view returns (bytes32) {
        return keccak256(abi.encode(terms[gameId], _kindPrices[gameId]));
    }
}
