// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ReentrancyGuard } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { IDiceEntropy } from "./interfaces/IExternal.sol";
import { IGameRegistry } from "./interfaces/IGameRegistry.sol";
import { IRandomnessCoordinator } from "./interfaces/IRandomnessCoordinator.sol";

/// @notice The platform's only Dice requester. Holds platform ETH; players never send value.
/// @dev One request is bound once per (module, game, action) for its lifetime. The callback is
/// store-only. The only recovery for an unrevealed request is Dice's own `refundRequest` after
/// its delay, which rebinds the same request id to a fresh sequence; a request Dice reports as
/// failed (status 3) is never re-requested because its word is already public.
contract RandomnessCoordinator is IRandomnessCoordinator, ReentrancyGuard {
    enum State {
        None,
        Requested,
        Fulfilled
    }

    struct Request {
        address module;
        uint256 gameId;
        bytes32 actionKey;
        uint64 sequence;
        uint32 attempt;
        State state;
        bytes32 word;
    }

    uint32 public constant CALLBACK_GAS_LIMIT = 200_000;

    IGameRegistry public immutable registry;
    IDiceEntropy public immutable dice;
    address public immutable provider;

    // Platform cap on the quoted Dice fee; zero disables requests.
    uint128 public maxFee;
    uint256 public requestCount;
    mapping(uint256 requestId => Request) public requests;
    // Live sequences only; a fulfilled or retried sequence is deleted.
    mapping(uint64 sequence => uint256 requestId) public requestOfSequence;
    // keccak256(abi.encode(module, gameId, actionKey)) => requestId, bound once forever.
    mapping(bytes32 bindingKey => uint256 requestId) public boundRequest;
    // Wei the game may still spend on Dice fees.
    mapping(uint256 gameId => uint256) public budget;

    error InvalidConfiguration();
    error NotBoundModule();
    error NotRegistryOwner();
    error AlreadyBound();
    error FeeAboveCap();
    error BudgetExceeded();
    error InsufficientBalance();
    error SequenceReused();
    error UnauthorizedRandomness();
    error InvalidRandomness();
    error RetryUnavailable();
    error TransferFailed();

    event Requested(
        uint256 indexed requestId,
        uint256 indexed gameId,
        address indexed module,
        bytes32 actionKey,
        uint64 sequence,
        uint128 fee
    );
    event Fulfilled(uint256 indexed requestId, uint64 indexed sequence, bytes32 word);
    event Retried(
        uint256 indexed requestId,
        uint64 indexed staleSequence,
        uint64 indexed sequence,
        uint32 attempt,
        uint256 reclaimed,
        uint128 fee
    );
    event MaxFeeSet(uint128 fee);
    event BudgetSet(uint256 indexed gameId, uint256 budget);
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    constructor(address registry_, address dice_, address provider_) {
        if (registry_.code.length == 0 || dice_.code.length == 0 || provider_ == address(0)) {
            revert InvalidConfiguration();
        }
        registry = IGameRegistry(registry_);
        dice = IDiceEntropy(dice_);
        provider = provider_;
    }

    /// @notice Platform funding from anyone; Dice refunds during a retry are reported by `Retried`.
    receive() external payable {
        if (msg.sender != address(dice)) emit Deposited(msg.sender, msg.value);
    }

    /// @notice A module bound to the game requests one word for an action it has committed.
    function request(uint256 gameId, bytes32 actionKey)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (!registry.isBound(gameId, msg.sender)) revert NotBoundModule();
        bytes32 key = keccak256(abi.encode(msg.sender, gameId, actionKey));
        if (boundRequest[key] != 0) revert AlreadyBound();
        requestId = ++requestCount;
        Request storage r = requests[requestId];
        r.module = msg.sender;
        r.gameId = gameId;
        r.actionKey = actionKey;
        r.state = State.Requested;
        boundRequest[key] = requestId;
        (uint64 sequence, uint128 fee) = _send(requestId, gameId, 0, maxFee);
        emit Requested(requestId, gameId, msg.sender, actionKey, sequence, fee);
    }

    /// @notice Dice delivers the word for a live sequence; store-only, a zero word is valid.
    function _entropyCallback(uint64 sequence, address provider_, bytes32 randomNumber) external {
        if (msg.sender != address(dice) || provider_ != provider) revert UnauthorizedRandomness();
        uint256 requestId = requestOfSequence[sequence];
        Request storage r = requests[requestId];
        if (requestId == 0 || r.state != State.Requested || r.sequence != sequence) {
            revert InvalidRandomness();
        }
        r.word = randomNumber;
        r.state = State.Fulfilled;
        delete requestOfSequence[sequence];
        emit Fulfilled(requestId, sequence, randomNumber);
    }

    /// @notice The stored word, readable by anyone once Dice has delivered it.
    function word(uint256 requestId) external view returns (bool fulfilled, bytes32 value) {
        Request storage r = requests[requestId];
        return (r.state == State.Fulfilled, r.word);
    }

    /// @notice Anyone may reclaim a request Dice still shows as unrevealed and rebind it.
    /// @dev Dice's `RefundNotAvailable` before its delay and `Unauthorized` propagate. Status 2
    /// and 3 and cleared requests are refused forever. Module and Treasury state are untouched.
    /// A retry the reclaimed fee pays for in full is never blocked by the fee cap.
    function retry(uint256 requestId) external nonReentrant {
        Request storage r = requests[requestId];
        if (r.state != State.Requested) revert RetryUnavailable();
        uint64 stale = r.sequence;
        IDiceEntropy.Request memory d = dice.getRequestV2(provider, stale);
        if (d.sequenceNumber != stale || d.callbackStatus != 1) revert RetryUnavailable();
        uint256 before = address(this).balance;
        dice.refundRequest(provider, stale);
        uint256 reclaimed = address(this).balance - before;
        uint256 gameId = r.gameId;
        budget[gameId] += reclaimed;
        delete requestOfSequence[stale];
        uint32 attempt = ++r.attempt;
        // Reclaimed fees fit uint128 because Dice stores feePaid as uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 cap = reclaimed > maxFee ? uint128(reclaimed) : maxFee;
        (uint64 sequence, uint128 fee) = _send(requestId, gameId, attempt, cap);
        emit Retried(requestId, stale, sequence, attempt, reclaimed, fee);
    }

    /// @notice The registry owner caps the Dice fee the platform will pay; zero disables requests.
    function setMaxFee(uint128 fee) external {
        _onlyOwner();
        maxFee = fee;
        emit MaxFeeSet(fee);
    }

    /// @notice The registry owner sets a game's remaining fee budget in wei, absolutely.
    function setBudget(uint256 gameId, uint256 amount) external {
        _onlyOwner();
        budget[gameId] = amount;
        emit BudgetSet(gameId, amount);
    }

    /// @notice The registry owner withdraws platform ETH; the coordinator holds no player money.
    function withdraw(address to, uint256 amount) external nonReentrant {
        _onlyOwner();
        if (to == address(0)) revert InvalidConfiguration();
        (bool sent,) = to.call{ value: amount }("");
        if (!sent) revert TransferFailed();
        emit Withdrawn(to, amount);
    }

    /// @dev Pays the quoted fee from the game's budget and binds the new sequence to the request.
    function _send(uint256 requestId, uint256 gameId, uint32 attempt, uint128 cap)
        private
        returns (uint64 sequence, uint128 fee)
    {
        fee = dice.getFeeV2(provider, CALLBACK_GAS_LIMIT);
        if (fee > cap) revert FeeAboveCap();
        if (fee > budget[gameId]) revert BudgetExceeded();
        if (address(this).balance < fee) revert InsufficientBalance();
        budget[gameId] -= fee;
        sequence = dice.requestV2{ value: fee }(
            provider,
            keccak256(abi.encode(address(this), block.chainid, requestId, attempt)),
            CALLBACK_GAS_LIMIT
        );
        if (requestOfSequence[sequence] != 0) revert SequenceReused();
        requestOfSequence[sequence] = requestId;
        requests[requestId].sequence = sequence;
    }

    function _onlyOwner() private view {
        if (msg.sender != registry.owner()) revert NotRegistryOwner();
    }
}
