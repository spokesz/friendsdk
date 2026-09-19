// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC1155 } from "lib/openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import { ReentrancyGuard } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { Consumable } from "./Consumable.sol";

interface IChanceGenerations {
    function token() external view returns (address);
    function ownerOf(uint256 friendId) external view returns (address);
    function generation(uint256 friendId) external view returns (uint8);
    function tokenBoundAccount(uint256 friendId) external view returns (address);
}

/// @dev Dice's deployed Entropy V2 interface; no oracle implementation is bundled here.
interface IDiceEntropy {
    /// @dev Mirrors Dice's stored request field for field; a layout mismatch would decode
    /// garbage, so the local fork test checks it against deployed code.
    struct DiceRequest {
        address provider;
        uint64 sequenceNumber;
        uint32 numHashes;
        bytes32 commitment;
        uint64 blockNumber;
        address requester;
        bool useBlockhash;
        uint8 callbackStatus;
        uint16 gasLimit10k;
        uint128 feePaid;
    }

    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128);
    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        external
        payable
        returns (uint64);
    function refundRequest(address provider, uint64 sequenceNumber) external;
    function getRequestV2(address provider, uint64 sequenceNumber)
        external
        view
        returns (DiceRequest memory);
}

/// @notice Fixed RF terms and permanently backed inventory for Generations wallets.
/// @dev Bought plays reserve their maximum prize until settlement replaces that reserve
/// with the actual reward liability. Redemption has no deadline. The deploying developer
/// can withdraw only free stake; no game terms or external dependencies can be changed.
contract ChanceGame is ERC1155, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Outcome {
        uint16 chanceBps;
        uint256 reward;
        string metadataURI;
    }

    struct Play {
        uint256 friendId;
        uint256 batchId;
        // Zero until settled; outcome IDs start at one.
        uint256 outcomeId;
    }

    struct Randomness {
        uint64 sequenceNumber;
        bool requested;
        bool fulfilled;
        bytes32 word;
    }

    uint32 public constant CALLBACK_GAS_LIMIT = 200_000;

    IERC20 public immutable rf;
    IChanceGenerations public immutable generations;
    IDiceEntropy public immutable entropy;
    address public immutable provider;
    address public immutable team;
    Consumable public immutable consumable;
    uint256 public immutable price;
    uint256 public immutable maxPrize;
    uint256 public immutable outcomeCount;

    // RF base units reserved for unused consumables plus unresolved plays.
    uint256 public reservedPlays;
    // RF base units owed for kept rewards; time never releases this liability.
    uint256 public rewardLiability;
    uint256 public playCount;
    uint256 public pendingPlays;
    mapping(uint256 outcomeId => Outcome) public outcomes;
    mapping(uint256 playId => Play) public plays;
    mapping(uint256 batchId => Randomness) public randomness;
    mapping(uint64 sequenceNumber => uint256 batchId) private _requestBatch;

    error InvalidConfiguration();
    error InvalidQuantity();
    error InvalidOutcome();
    error InvalidPlay();
    error InvalidFriend();
    error NotFriendController();
    error NotFriendWallet();
    error OnlyTeam();
    error InsufficientStake();
    error FriendBoundInventory();
    error InvalidBatch();
    error RandomnessAlreadyRequested();
    error RandomnessPending();
    error IncorrectOracleFee();
    error UnauthorizedRandomness();
    error InvalidRandomness();
    error RetryUnavailable();
    error RefundFailed();

    event Funded(address indexed funder, uint256 amount);
    event Purchased(uint256 indexed friendId, uint256 quantity, uint256 payment);
    event Played(uint256 indexed playId, uint256 indexed friendId, uint256 indexed batchId);
    event Settled(uint256 indexed playId, uint256 indexed friendId, uint256 indexed outcomeId);
    event Redeemed(
        uint256 indexed friendId, uint256 indexed outcomeId, uint256 quantity, uint256 payment
    );
    event SurplusWithdrawn(address indexed recipient, uint256 amount);
    event RandomnessRequested(uint256 indexed batchId, uint64 indexed sequenceNumber);
    event RandomnessFulfilled(uint256 indexed batchId, uint64 indexed sequenceNumber);
    event RandomnessRetried(
        uint256 indexed batchId,
        uint64 indexed staleSequence,
        uint64 indexed sequenceNumber,
        uint256 reclaimed
    );

    constructor(
        address rf_,
        address generations_,
        address entropy_,
        address provider_,
        string memory consumableName,
        string memory consumableSymbol,
        uint256 price_,
        Outcome[] memory table
    ) ERC1155("") {
        if (
            rf_.code.length == 0 || generations_.code.length == 0 || entropy_.code.length == 0
                || provider_ == address(0) || price_ == 0 || table.length == 0
                || IChanceGenerations(generations_).token() != rf_
        ) revert InvalidConfiguration();
        uint256 totalChance;
        uint256 highestPrize;
        for (uint256 i; i < table.length; ++i) {
            if (table[i].chanceBps == 0) revert InvalidConfiguration();
            totalChance += table[i].chanceBps;
            if (table[i].reward > highestPrize) highestPrize = table[i].reward;
            outcomes[i + 1] = table[i];
        }
        if (totalChance != 10_000 || highestPrize == 0) revert InvalidConfiguration();
        rf = IERC20(rf_);
        generations = IChanceGenerations(generations_);
        entropy = IDiceEntropy(entropy_);
        provider = provider_;
        team = msg.sender;
        price = price_;
        maxPrize = highestPrize;
        outcomeCount = table.length;
        consumable = new Consumable(consumableName, consumableSymbol);
    }

    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidQuantity();
        rf.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice The canonical Friend wallet buys and pays for its own prepaid plays.
    function buy(uint256 friendId, uint256 quantity) external nonReentrant {
        if (quantity == 0) revert InvalidQuantity();
        address account = _controller(friendId);
        if (msg.sender != account) revert NotFriendWallet();
        if (!canBuy(quantity)) revert InsufficientStake();
        uint256 payment = quantity * price;
        rf.safeTransferFrom(account, address(this), payment);
        reservedPlays += quantity * maxPrize;
        consumable.mint(account, quantity);
        emit Purchased(friendId, quantity, payment);
    }

    /// @notice Consume prepaid units even when no stake remains for new purchases.
    /// @dev Each call commits one batch; its ID is the first play ID in that call.
    function play(uint256 friendId, uint256 quantity)
        external
        nonReentrant
        returns (uint256 firstPlayId, uint256 batchId)
    {
        if (quantity == 0) revert InvalidQuantity();
        address account = _controller(friendId);
        consumable.controllerBurn(account, quantity);
        pendingPlays += quantity;
        firstPlayId = playCount + 1;
        batchId = firstPlayId;
        for (uint256 i; i < quantity; ++i) {
            uint256 id = ++playCount;
            plays[id] = Play(friendId, batchId, 0);
            emit Played(id, friendId, batchId);
        }
    }

    /// @notice Anyone may pay Dice's native fee for a previously committed batch.
    /// @dev One request per batch. Only Dice clearing an unrevealed request admits
    /// another, through retryRandomness. Failed requests revert atomically; a successful
    /// request needs the pinned provider to deliver.
    function requestRandomness(uint256 batchId)
        external
        payable
        nonReentrant
        returns (uint64 sequenceNumber)
    {
        if (batchId == 0 || plays[batchId].batchId != batchId) revert InvalidBatch();
        Randomness storage result = randomness[batchId];
        if (result.requested) revert RandomnessAlreadyRequested();
        if (msg.value != entropy.getFeeV2(provider, CALLBACK_GAS_LIMIT)) {
            revert IncorrectOracleFee();
        }
        result.requested = true;
        sequenceNumber = entropy.requestV2{ value: msg.value }(
            provider,
            keccak256(abi.encode(address(this), block.chainid, batchId)),
            CALLBACK_GAS_LIMIT
        );
        result.sequenceNumber = sequenceNumber;
        _requestBatch[sequenceNumber] = batchId;
        emit RandomnessRequested(batchId, sequenceNumber);
    }

    /// @notice The Friend's controller binds a new request after Dice clears an old one.
    /// @dev Dice's own refund delay is the only clock; the game keeps none. A delivered
    /// word is never re-requested, so this can never reroll a play. Play IDs, pending
    /// count and reserved backing are untouched: the same plays wait on a new request.
    function retryRandomness(uint256 batchId)
        external
        payable
        nonReentrant
        returns (uint64 sequenceNumber)
    {
        if (batchId == 0 || plays[batchId].batchId != batchId) revert InvalidBatch();
        Randomness storage result = randomness[batchId];
        if (!result.requested || result.fulfilled) revert RetryUnavailable();
        _controller(plays[batchId].friendId);
        if (msg.value != entropy.getFeeV2(provider, CALLBACK_GAS_LIMIT)) {
            revert IncorrectOracleFee();
        }
        uint64 stale = result.sequenceNumber;
        // Dice clears a request by zeroing only its sequence number, and the slot can
        // later hold another request; status 1 is "not started", so a revealed word
        // (status 3) is refused here rather than reclaimed.
        IDiceEntropy.DiceRequest memory stored = entropy.getRequestV2(provider, stale);
        if (stored.sequenceNumber != stale || stored.callbackStatus != 1) {
            revert RetryUnavailable();
        }
        uint256 balanceBefore = address(this).balance;
        entropy.refundRequest(provider, stale);
        uint256 reclaimed = address(this).balance - balanceBefore;
        delete _requestBatch[stale];
        sequenceNumber = entropy.requestV2{ value: msg.value }(
            provider,
            keccak256(abi.encode(address(this), block.chainid, batchId)),
            CALLBACK_GAS_LIMIT
        );
        result.sequenceNumber = sequenceNumber;
        _requestBatch[sequenceNumber] = batchId;
        (bool sent,) = msg.sender.call{ value: reclaimed }("");
        if (!sent) revert RefundFailed();
        emit RandomnessRetried(batchId, stale, sequenceNumber, reclaimed);
    }

    /// @dev Only Dice's reclaimed fee enters the game, and only inside a guarded retry
    /// that forwards it to the caller in the same call.
    receive() external payable {
        if (msg.sender != address(entropy)) revert UnauthorizedRandomness();
    }

    /// @notice Dice callback only stores the word; receiver callbacks run at settlement.
    function _entropyCallback(uint64 sequenceNumber, address provider_, bytes32 randomNumber)
        external
    {
        if (msg.sender != address(entropy) || provider_ != provider) {
            revert UnauthorizedRandomness();
        }
        uint256 batchId = _requestBatch[sequenceNumber];
        Randomness storage result = randomness[batchId];
        if (batchId == 0 || result.fulfilled) revert InvalidRandomness();
        result.word = randomNumber;
        result.fulfilled = true;
        emit RandomnessFulfilled(batchId, sequenceNumber);
    }

    /// @notice Anyone may settle; the committed Friend receives its fixed outcome.
    function settle(uint256 playId) external nonReentrant {
        Play storage committed = plays[playId];
        if (committed.batchId == 0 || committed.outcomeId != 0) revert InvalidPlay();
        Randomness storage result = randomness[committed.batchId];
        if (!result.fulfilled) revert RandomnessPending();
        uint256 roll = uint256(
            keccak256(
                abi.encode(result.word, address(this), block.chainid, committed.batchId, playId)
            )
        ) % 10_000;
        uint256 id = outcomeForRoll(roll);
        committed.outcomeId = id;
        --pendingPlays;
        reservedPlays -= maxPrize;
        rewardLiability += outcomes[id].reward;
        _mint(generations.tokenBoundAccount(committed.friendId), id, 1, "");
        emit Settled(playId, committed.friendId, id);
    }

    /// @notice Redeem a kept reward at any time; RF enters the Friend's wallet.
    function redeem(uint256 friendId, uint256 outcomeId, uint256 quantity) external nonReentrant {
        if (quantity == 0) revert InvalidQuantity();
        address account = _controller(friendId);
        if (outcomeId == 0 || outcomeId > outcomeCount || outcomes[outcomeId].reward == 0) {
            revert InvalidOutcome();
        }
        uint256 payment = outcomes[outcomeId].reward * quantity;
        _burn(account, outcomeId, quantity);
        rewardLiability -= payment;
        rf.safeTransfer(account, payment);
        emit Redeemed(friendId, outcomeId, quantity, payment);
    }

    /// @notice The deploying developer can withdraw only RF backing no commitments.
    function withdrawSurplus(address recipient, uint256 amount) external nonReentrant {
        if (msg.sender != team) revert OnlyTeam();
        if (amount == 0) revert InvalidQuantity();
        if (amount > freeStake()) revert InsufficientStake();
        rf.safeTransfer(recipient, amount);
        emit SurplusWithdrawn(recipient, amount);
    }

    function freeStake() public view returns (uint256) {
        return rf.balanceOf(address(this)) - reservedPlays - rewardLiability;
    }

    function canBuy(uint256 quantity) public view returns (bool) {
        uint256 available = freeStake();
        return quantity != 0 && available >= maxPrize
            && available + quantity * price >= quantity * maxPrize;
    }

    function outcomeForRoll(uint256 roll) public view returns (uint256) {
        if (roll >= 10_000) revert InvalidOutcome();
        uint256 cumulative;
        for (uint256 id = 1; id <= outcomeCount; ++id) {
            cumulative += outcomes[id].chanceBps;
            if (roll < cumulative) return id;
        }
        revert InvalidOutcome();
    }

    function uri(uint256 id) public view override returns (string memory) {
        if (id == 0 || id > outcomeCount) revert InvalidOutcome();
        return outcomes[id].metadataURI;
    }

    function _controller(uint256 friendId) private view returns (address account) {
        address owner = generations.ownerOf(friendId);
        if (generations.generation(friendId) == 0) revert InvalidFriend();
        account = generations.tokenBoundAccount(friendId);
        if (msg.sender != owner && msg.sender != account) revert NotFriendController();
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory amounts)
        internal
        override
    {
        if (from != address(0) && to != address(0)) revert FriendBoundInventory();
        super._update(from, to, ids, amounts);
    }
}
