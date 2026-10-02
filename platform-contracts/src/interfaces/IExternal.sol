// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev Existing mainnet RF token: ERC-20 plus burn. No implementation is bundled here.
interface IRareFriends is IERC20 {
    function burn(uint256 value) external;
}

/// @dev Existing RareFriendsGenerations collection.
interface IGenerations {
    function ownerOf(uint256 tokenId) external view returns (address);
    function generation(uint256 tokenId) external view returns (uint8);
    function tokenBoundAccount(uint256 tokenId) external view returns (address);
    function token() external view returns (address);
    function activationManager() external view returns (address);
}

/// @dev Existing ActivationManager: the protocol's rewards destination.
interface IActivationManager {
    function fund(address asset, uint256 amount) external;
    function retired() external view returns (bool);
}

/// @dev Dice's deployed Entropy V2 interface; the Request struct mirrors Dice storage in order.
interface IDiceEntropy {
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

    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128);
    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        external
        payable
        returns (uint64 sequenceNumber);
    function refundRequest(address provider, uint64 sequenceNumber) external;
    function getRequestV2(address provider, uint64 sequenceNumber)
        external
        view
        returns (Request memory);
    function getRefundDelayBlocks() external view returns (uint64);
}
