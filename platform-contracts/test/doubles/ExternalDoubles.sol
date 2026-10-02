// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    IERC1155Receiver
} from "lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";

// Test doubles for the existing mainnet contracts the platform calls. They model only the
// external behavior our contracts depend on (see docs/BRIEF.md section 3). No Rare Friends
// protocol implementation is bundled here.

/// @dev RF: ERC-20 with burn and the Generations preview side effect on every transfer.
contract MockRF is ERC20 {
    MockGenerations public generations;

    constructor() ERC20("Mock RF", "RF") { }

    function setGenerations(MockGenerations generations_) external {
        generations = generations_;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(generations) == address(0)) return;
        if (from != address(0)) generations.syncPreview(from, balanceOf(from));
        if (to != address(0) && to != from) generations.syncPreview(to, balanceOf(to));
    }
}

/// @dev USDG: six decimals by default; a blocked recipient makes transfers return false.
contract MockUSDG is ERC20 {
    uint8 private immutable _decimals;
    address public blockedRecipient;

    constructor(uint8 decimals_) ERC20("Mock USDG", "USDG") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function blockRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        if (recipient == blockedRecipient) return false;
        return super.transfer(recipient, amount);
    }

    function transferFrom(address from, address recipient, uint256 amount)
        public
        override
        returns (bool)
    {
        if (recipient == blockedRecipient) return false;
        return super.transferFrom(from, recipient, amount);
    }
}

/// @dev Generations: ownership, generation, canonical wallets, temporary Friends on RF balance.
contract MockGenerations {
    address public immutable token;
    address public activationManager;
    uint256 public totalMinted;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint8) public generation;
    mapping(uint256 => address) public tokenBoundAccount;
    mapping(address => uint256) public temporaryFriend;

    error OnlyToken();
    error NotOwner();

    constructor(address token_) {
        token = token_;
    }

    function setActivationManager(address manager) external {
        activationManager = manager;
    }

    /// @dev Hardwired Friend with a deployed canonical wallet.
    function mint(address owner, uint256 id, uint8 generation_) external {
        ownerOf[id] = owner;
        generation[id] = generation_;
        tokenBoundAccount[id] = address(new MockFriendWallet(this, id));
        if (id > totalMinted) totalMinted = id;
    }

    function transfer(uint256 id, address recipient) external {
        if (msg.sender != ownerOf[id]) revert NotOwner();
        ownerOf[id] = recipient;
    }

    function promote(uint256 id) external {
        generation[id] -= 1;
    }

    /// @dev Mirrors RareFriendsGenerations.syncPreview: a generation-0 Friend without a wallet.
    function syncPreview(address account, uint256 balance) external {
        if (msg.sender != token) revert OnlyToken();
        uint256 id = temporaryFriend[account];
        if (balance >= 1 ether) {
            if (id != 0) return;
            id = ++totalMinted + 1_000_000;
            totalMinted = id;
            temporaryFriend[account] = id;
            ownerOf[id] = account;
        } else if (id != 0) {
            delete temporaryFriend[account];
            delete ownerOf[id];
        }
    }
}

/// @dev Canonical ERC-6551 wallet: execute by the NFT owner only; accepts ERC-1155.
contract MockFriendWallet is IERC1155Receiver {
    MockGenerations private immutable _generations;
    uint256 private immutable _friendId;

    error NotOwner();
    error UnsupportedOperation();

    constructor(MockGenerations generations_, uint256 friendId_) {
        _generations = generations_;
        _friendId = friendId_;
    }

    receive() external payable { }

    function owner() public view returns (address) {
        return _generations.ownerOf(_friendId);
    }

    function token() external view returns (uint256, address, uint256) {
        return (block.chainid, address(_generations), _friendId);
    }

    function execute(address target, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory result)
    {
        if (msg.sender != owner()) revert NotOwner();
        if (operation != 0) revert UnsupportedOperation();
        bool success;
        (success, result) = target.call{ value: value }(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == 0x01ffc9a7;
    }
}

/// @dev FriendCustody: holds Friends (tests mint them to this address) and binds payout wallets.
contract MockCustody {
    mapping(uint256 => address) public beneficiary;

    function bind(uint256 tokenId, address wallet) external {
        beneficiary[tokenId] = wallet;
    }
}

/// @dev Dice Entropy V2 as deployed on Robinhood: exact fee, sequence numbers, store-only
/// callbacks with Dice's status codes, refunds after the delay, and the live request struct.
contract MockDice {
    struct Request {
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

    uint8 public constant CALLBACK_NOT_STARTED = 1;
    uint8 public constant CALLBACK_IN_PROGRESS = 2;
    uint8 public constant CALLBACK_FAILED = 3;

    address public immutable provider;
    uint128 public fee = 0.000_025 ether;
    uint64 public refundDelayBlocks = 6;
    uint64 public sequenceNumber;
    bool public rejectRequests;
    mapping(uint64 => Request) private _requests;
    mapping(uint64 => bytes32) public userRandomness;
    mapping(uint64 => bytes32) public revealedWord;

    error NoSuchProvider();
    error NoSuchRequest();
    error InsufficientFee();
    error Unauthorized();
    error RefundNotAvailable();
    error RequestRejected();
    error CallbackInProgress();

    event Requested(uint64 indexed sequenceNumber, address indexed requester, uint32 gasLimit);
    event Revealed(uint64 indexed sequenceNumber, bytes32 word, bool callbackSucceeded);
    event RequestRefunded(uint64 indexed sequenceNumber, address indexed requester, uint128 amount);

    constructor(address provider_) {
        provider = provider_;
    }

    function setFee(uint128 fee_) external {
        fee = fee_;
    }

    function setRefundDelayBlocks(uint64 blocks) external {
        refundDelayBlocks = blocks;
    }

    function setRejectRequests(bool value) external {
        rejectRequests = value;
    }

    function getFeeV2(address provider_, uint32) external view returns (uint128) {
        if (provider_ != provider) revert NoSuchProvider();
        return fee;
    }

    function getRefundDelayBlocks() external view returns (uint64) {
        return refundDelayBlocks;
    }

    function getRequestV2(address provider_, uint64 sequence)
        external
        view
        returns (Request memory req)
    {
        req = _requests[sequence];
        if (req.provider != provider_) delete req;
    }

    function requestV2(address provider_, bytes32 userRandomNumber, uint32 gasLimit)
        external
        payable
        returns (uint64 sequence)
    {
        if (rejectRequests) revert RequestRejected();
        if (provider_ != provider) revert NoSuchProvider();
        if (msg.value < fee) revert InsufficientFee();
        sequence = ++sequenceNumber;
        _requests[sequence] = Request({
            provider: provider,
            sequenceNumber: sequence,
            numHashes: 1,
            commitment: keccak256(abi.encode(userRandomNumber, sequence)),
            blockNumber: uint64(block.number),
            requester: msg.sender,
            useBlockhash: false,
            callbackStatus: CALLBACK_NOT_STARTED,
            // Dice rounds the limit to 10k units; 200,000 fits uint16 after division.
            // forge-lint: disable-next-line(unsafe-typecast)
            gasLimit10k: uint16(gasLimit / 10_000),
            feePaid: uint128(msg.value)
        });
        userRandomness[sequence] = userRandomNumber;
        emit Requested(sequence, msg.sender, gasLimit);
    }

    /// @dev Provider reveal. A failed callback leaves the request active with status 3 and the
    /// word public, exactly as Dice does; a later reveal may retry the same word.
    function reveal(uint64 sequence, bytes32 word) external returns (bool success) {
        Request storage req = _requests[sequence];
        if (req.sequenceNumber == 0) revert NoSuchRequest();
        if (req.callbackStatus == CALLBACK_IN_PROGRESS) revert CallbackInProgress();
        if (req.callbackStatus == CALLBACK_FAILED && revealedWord[sequence] != word) {
            revert Unauthorized();
        }
        req.callbackStatus = CALLBACK_IN_PROGRESS;
        revealedWord[sequence] = word;
        (success,) = req.requester.call{ gas: uint256(req.gasLimit10k) * 10_000 }(
            abi.encodeWithSignature(
                "_entropyCallback(uint64,address,bytes32)", sequence, provider, word
            )
        );
        emit Revealed(sequence, word, success);
        if (success) delete _requests[sequence];
        else req.callbackStatus = CALLBACK_FAILED;
    }

    /// @dev Deliver a callback for a sequence this mock never issued, or from a wrong provider.
    function deliverRaw(address consumer, uint64 sequence, address provider_, bytes32 word)
        external
        returns (bool success)
    {
        (success,) = consumer.call(
            abi.encodeWithSignature(
                "_entropyCallback(uint64,address,bytes32)", sequence, provider_, word
            )
        );
    }

    function refundRequest(address provider_, uint64 sequence) external {
        Request storage req = _requests[sequence];
        if (req.sequenceNumber == 0 || req.provider != provider_) revert NoSuchRequest();
        if (req.requester != msg.sender) revert Unauthorized();
        if (block.number < uint256(req.blockNumber) + uint256(refundDelayBlocks)) {
            revert RefundNotAvailable();
        }
        address requester = req.requester;
        uint128 amount = req.feePaid;
        delete _requests[sequence];
        if (amount != 0) {
            (bool sent,) = requester.call{ value: amount }("");
            require(sent, "refund transfer failed");
        }
        emit RequestRefunded(sequence, requester, amount);
    }
}

/// @dev ActivationManager rewards funding: pulls an approved asset while not retired.
contract MockActivationManager {
    address public immutable rf;
    bool public retired;
    mapping(address asset => uint256) public funded;

    error Retired();
    error InvalidAsset();

    event Funded(address indexed asset, address indexed payer, uint256 amount);

    constructor(address rf_) {
        rf = rf_;
    }

    function setRetired(bool value) external {
        retired = value;
    }

    function fund(address asset, uint256 amount) external {
        if (retired) revert Retired();
        if (asset != rf) revert InvalidAsset();
        if (!IERC20(asset).transferFrom(msg.sender, address(this), amount)) revert InvalidAsset();
        funded[asset] += amount;
        emit Funded(asset, msg.sender, amount);
    }
}
