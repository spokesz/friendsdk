// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { SafeCast } from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { IActivationManager, IGenerations, IRareFriends } from "./interfaces/IExternal.sol";
import { IGameRegistry } from "./interfaces/IGameRegistry.sol";
import { ITreasury } from "./interfaces/ITreasury.sol";

/// @notice Custody of every RF and USDG balance behind the platform's games.
/// @dev Per-game ledgers {free, reserved, owed, credit}, per-currency totals, an accrued fee
/// ledger and an RF rewards ledger. Only modules the registry reports as bound move ledgers; the
/// registry owner may withdraw free stake to the recorded funder and nothing else. The Treasury
/// knows nothing about Friends, randomness or terms: it trusts a bound module to compute legs
/// from its immutable terms and enforces conservation itself through the single `_move` writer.
contract Treasury is ITreasury, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct Ledger {
        // Bankroll: withdrawable to the funder; feeds reservations.
        uint256 free;
        // Maximum payable value of pending commits, held item reserves and open round pots.
        uint256 reserved;
        // Fixed redemption liability of minted valued items.
        uint256 owed;
        // Sum of creditOf[gameId][*].
        uint256 credit;
    }

    struct Totals {
        uint256 free;
        uint256 reserved;
        uint256 owed;
        uint256 credit;
        uint256 fees;
    }

    IGameRegistry public immutable registry;
    IRareFriends public immutable rf;
    IERC20 public immutable usdg;
    IGenerations public immutable generations;

    mapping(uint256 gameId => Ledger) public ledgers;
    mapping(uint256 gameId => mapping(uint256 friendId => uint256)) public creditOf;
    mapping(address currency => Totals) public totals;
    mapping(address currency => mapping(address recipient => uint256)) public feesOwed;
    // RF accrued for the activation manager; forwarded permissionlessly, never on a player path.
    uint256 public rewardsPending;

    error InvalidConfiguration();
    error UnknownGame();
    error NotCommittingModule();
    error NotBoundModule();
    error NotRegistryOwner();
    error ZeroAmount();
    error UnsupportedLeg();
    error NoRecipient();
    error UnbalancedSpend();
    error InsufficientFree();
    error InsufficientReserved();
    error InsufficientOwed();
    error InsufficientCredit();
    error InvalidResolution();
    error NothingOwed();
    error ManagerUnavailable();

    event Funded(uint256 indexed gameId, address indexed from, uint256 amount);
    event Collected(uint256 indexed gameId, address indexed payer, Legs legs);
    event Reserved(uint256 indexed gameId, uint256 amount);
    event Released(uint256 indexed gameId, uint256 amount);
    event Resolved(
        uint256 indexed gameId,
        uint256 amount,
        uint256 toOwed,
        uint256 toKeep,
        address indexed payTo,
        uint256 paid
    );
    event ReservedRouted(uint256 indexed gameId, uint256 burned, uint256 rewards);
    event OwedPaid(uint256 indexed gameId, address indexed to, uint256 amount);
    event CreditDeposited(
        uint256 indexed gameId, uint256 indexed friendId, address indexed payer, uint256 amount
    );
    event CreditWithdrawn(
        uint256 indexed gameId, uint256 indexed friendId, address indexed to, uint256 amount
    );
    event CreditSpent(
        uint256 indexed gameId,
        uint256 indexed friendId,
        uint256 amount,
        uint256 burned,
        uint256 rewards
    );
    event FeesPaid(address indexed currency, address indexed recipient, uint256 amount);
    event RewardsForwarded(address indexed manager, uint256 amount);
    event FreeWithdrawn(uint256 indexed gameId, address indexed funder, uint256 amount);

    modifier onlyCommitting(uint256 gameId) {
        if (!registry.canCommit(gameId, msg.sender)) revert NotCommittingModule();
        _;
    }

    modifier onlyBound(uint256 gameId) {
        if (!registry.isBound(gameId, msg.sender)) revert NotBoundModule();
        _;
    }

    constructor(address registry_, address rf_, address usdg_, address generations_) {
        if (
            registry_.code.length == 0 || rf_.code.length == 0 || usdg_.code.length == 0
                || generations_.code.length == 0 || IGameRegistry(registry_).rf() != rf_
                || IGameRegistry(registry_).usdg() != usdg_
                || IGameRegistry(registry_).generations() != generations_
        ) revert InvalidConfiguration();
        registry = IGameRegistry(registry_);
        rf = IRareFriends(rf_);
        usdg = IERC20(usdg_);
        generations = IGenerations(generations_);
    }

    /// @notice Anyone may add free stake to any registered game.
    function fund(uint256 gameId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        address currency = _currency(gameId);
        IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
        _move(gameId, currency, amount.toInt256(), 0, 0, 0);
        emit Funded(gameId, msg.sender, amount);
    }

    /// @notice Pull one payment from the payer and route it along the module's fixed legs.
    /// @dev Developer and operator fees accrue so a frozen fee address never blocks a purchase.
    function collect(uint256 gameId, address payer, Legs calldata legs)
        external
        onlyCommitting(gameId)
    {
        uint256 fees = legs.developer + legs.operator;
        uint256 total = legs.toFree + legs.toReserved + fees + legs.burn + legs.rewards;
        if (total == 0) revert ZeroAmount();
        address currency = _currency(gameId);
        if (currency != address(rf) && (legs.burn != 0 || legs.rewards != 0)) {
            revert UnsupportedLeg();
        }
        (, address developer, address operator) = registry.recipientsOf(gameId);
        if (
            (legs.developer != 0 && developer == address(0))
                || (legs.operator != 0 && operator == address(0))
        ) revert NoRecipient();
        IERC20(currency).safeTransferFrom(payer, address(this), total);
        _move(gameId, currency, legs.toFree.toInt256(), legs.toReserved.toInt256(), 0, 0);
        feesOwed[currency][developer] += legs.developer;
        feesOwed[currency][operator] += legs.operator;
        totals[currency].fees += fees;
        if (legs.burn != 0) rf.burn(legs.burn);
        rewardsPending += legs.rewards;
        emit Collected(gameId, payer, legs);
    }

    /// @notice Lock free stake behind a pending commit, a held item reserve or a round pot.
    function reserve(uint256 gameId, uint256 amount) external onlyBound(gameId) {
        if (amount == 0) revert ZeroAmount();
        int256 delta = amount.toInt256();
        _move(gameId, _currency(gameId), -delta, delta, 0, 0);
        emit Reserved(gameId, amount);
    }

    /// @notice Return locked backing to free stake without any payout.
    function release(uint256 gameId, uint256 amount) external onlyBound(gameId) {
        if (amount == 0) revert ZeroAmount();
        int256 delta = amount.toInt256();
        _move(gameId, _currency(gameId), delta, -delta, 0, 0);
        emit Released(gameId, amount);
    }

    /// @notice Replace a reservation with its actual result: kept backing, owed value and payout.
    /// @dev A reverting transfer reverts the whole call so the reservation stays and the module's
    /// commit stays pending and retryable with the same inputs.
    function resolve(
        uint256 gameId,
        uint256 amount,
        uint256 toOwed,
        uint256 toKeep,
        address payTo,
        uint256 pay
    ) external nonReentrant onlyBound(gameId) {
        if (amount < toOwed + toKeep + pay) revert InvalidResolution();
        address currency = _currency(gameId);
        _move(
            gameId,
            currency,
            (amount - toOwed - toKeep - pay).toInt256(),
            -((amount - toKeep).toInt256()),
            toOwed.toInt256(),
            0
        );
        if (pay != 0) IERC20(currency).safeTransfer(payTo, pay);
        emit Resolved(gameId, amount, toOwed, toKeep, payTo, pay);
    }

    /// @notice Burn part of a reserved RF pot and accrue the rest for rewards.
    function routeReserved(uint256 gameId, uint256 burned, uint256 rewards)
        external
        onlyBound(gameId)
    {
        address currency = _currency(gameId);
        if (currency != address(rf)) revert UnsupportedLeg();
        _move(gameId, currency, 0, -((burned + rewards).toInt256()), 0, 0);
        if (burned != 0) rf.burn(burned);
        rewardsPending += rewards;
        emit ReservedRouted(gameId, burned, rewards);
    }

    /// @notice Pay a fixed redemption liability; works forever, on retired games too.
    function payOwed(uint256 gameId, address to, uint256 amount)
        external
        nonReentrant
        onlyBound(gameId)
    {
        if (amount == 0) revert ZeroAmount();
        address currency = _currency(gameId);
        _move(gameId, currency, 0, 0, -(amount.toInt256()), 0);
        IERC20(currency).safeTransfer(to, amount);
        emit OwedPaid(gameId, to, amount);
    }

    /// @notice Prefund a Friend's credit for in-round spends; only a committing module opens it.
    function creditDeposit(uint256 gameId, uint256 friendId, address payer, uint256 amount)
        external
        onlyCommitting(gameId)
    {
        if (amount == 0) revert ZeroAmount();
        address currency = _currency(gameId);
        IERC20(currency).safeTransferFrom(payer, address(this), amount);
        creditOf[gameId][friendId] += amount;
        _move(gameId, currency, 0, 0, 0, amount.toInt256());
        emit CreditDeposited(gameId, friendId, payer, amount);
    }

    /// @notice Return unspent credit; the module fixes the recipient to the canonical wallet.
    function creditWithdraw(uint256 gameId, uint256 friendId, address to, uint256 amount)
        external
        nonReentrant
        onlyBound(gameId)
    {
        if (amount == 0) revert ZeroAmount();
        address currency = _currency(gameId);
        _debitCredit(gameId, friendId, currency, amount);
        IERC20(currency).safeTransfer(to, amount);
        emit CreditWithdrawn(gameId, friendId, to, amount);
    }

    /// @notice Consume credit into burn and rewards only; a spend never reaches another ledger.
    function creditSpend(
        uint256 gameId,
        uint256 friendId,
        uint256 amount,
        uint256 burned,
        uint256 rewards
    ) external onlyBound(gameId) {
        address currency = _currency(gameId);
        if (currency != address(rf)) revert UnsupportedLeg();
        if (burned + rewards != amount) revert UnbalancedSpend();
        _debitCredit(gameId, friendId, currency, amount);
        if (burned != 0) rf.burn(burned);
        rewardsPending += rewards;
        emit CreditSpent(gameId, friendId, amount, burned, rewards);
    }

    /// @notice Anyone may push accrued fees to their recipient at any cadence.
    /// @dev A frozen USDG recipient keeps its ledger; the payout simply reverts until it can land.
    function payFees(address currency, address recipient) external nonReentrant {
        uint256 amount = feesOwed[currency][recipient];
        if (amount == 0) revert NothingOwed();
        feesOwed[currency][recipient] = 0;
        totals[currency].fees -= amount;
        IERC20(currency).safeTransfer(recipient, amount);
        emit FeesPaid(currency, recipient, amount);
    }

    /// @notice Anyone may forward accrued RF rewards to the current activation manager.
    /// @dev A retired or replaced manager leaves the pending balance intact for a later call.
    function forwardRewards() external nonReentrant {
        uint256 amount = rewardsPending;
        if (amount == 0) revert NothingOwed();
        address manager = generations.activationManager();
        if (manager.code.length == 0 || IActivationManager(manager).retired()) {
            revert ManagerUnavailable();
        }
        rewardsPending = 0;
        IERC20(address(rf)).forceApprove(manager, amount);
        IActivationManager(manager).fund(address(rf), amount);
        emit RewardsForwarded(manager, amount);
    }

    /// @notice The registry owner may withdraw free stake only, and only to the recorded funder.
    function withdrawFree(uint256 gameId, uint256 amount) external nonReentrant {
        if (msg.sender != registry.owner()) revert NotRegistryOwner();
        if (amount == 0) revert ZeroAmount();
        address currency = _currency(gameId);
        (address funder,,) = registry.recipientsOf(gameId);
        _move(gameId, currency, -(amount.toInt256()), 0, 0, 0);
        IERC20(currency).safeTransfer(funder, amount);
        emit FreeWithdrawn(gameId, funder, amount);
    }

    /// @notice I1: the held balance covers every obligation of the currency.
    function solvent(address currency) external view returns (bool) {
        Totals storage t = totals[currency];
        return IERC20(currency).balanceOf(address(this))
            >= t.reserved + t.owed + t.credit + t.fees + _rewardsIn(currency);
    }

    /// @notice Every ledger column of the currency summed; equals the balance less donations.
    function backed(address currency) external view returns (uint256) {
        Totals storage t = totals[currency];
        return t.free + t.reserved + t.owed + t.credit + t.fees + _rewardsIn(currency);
    }

    function _rewardsIn(address currency) private view returns (uint256) {
        return currency == address(rf) ? rewardsPending : 0;
    }

    function _currency(uint256 gameId) private view returns (address currency) {
        currency = registry.currencyOf(gameId);
        if (currency == address(0)) revert UnknownGame();
    }

    function _debitCredit(uint256 gameId, uint256 friendId, address currency, uint256 amount)
        private
    {
        uint256 balance = creditOf[gameId][friendId];
        if (balance < amount) revert InsufficientCredit();
        creditOf[gameId][friendId] = balance - amount;
        _move(gameId, currency, 0, 0, 0, -(amount.toInt256()));
    }

    /// @dev The only writer of `ledgers` and `totals`, so the two can never drift apart. Every
    /// delta is applied with checked arithmetic and a negative result reverts by column.
    function _move(
        uint256 gameId,
        address currency,
        int256 dFree,
        int256 dReserved,
        int256 dOwed,
        int256 dCredit
    ) private {
        Ledger storage ledger = ledgers[gameId];
        Totals storage total = totals[currency];
        if (dFree != 0) {
            (ledger.free, total.free) =
                _shift(ledger.free, total.free, dFree, InsufficientFree.selector);
        }
        if (dReserved != 0) {
            (ledger.reserved, total.reserved) =
                _shift(ledger.reserved, total.reserved, dReserved, InsufficientReserved.selector);
        }
        if (dOwed != 0) {
            (ledger.owed, total.owed) =
                _shift(ledger.owed, total.owed, dOwed, InsufficientOwed.selector);
        }
        if (dCredit != 0) {
            (ledger.credit, total.credit) =
                _shift(ledger.credit, total.credit, dCredit, InsufficientCredit.selector);
        }
    }

    /// @dev Applies one signed delta to a game column and its currency total.
    function _shift(uint256 column, uint256 total, int256 delta, bytes4 shortfall)
        private
        pure
        returns (uint256, uint256)
    {
        if (delta > 0) {
            // Positive, so the conversion cannot wrap.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 up = uint256(delta);
            return (column + up, total + up);
        }
        // Every delta is a SafeCast of a uint256 or its negation, so -delta cannot overflow and
        // the result is non-negative.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 down = uint256(-delta);
        if (column < down) {
            assembly ("memory-safe") {
                mstore(0, shortfall)
                revert(0, 4)
            }
        }
        // total >= column for the same currency by construction of _move.
        return (column - down, total - down);
    }
}
