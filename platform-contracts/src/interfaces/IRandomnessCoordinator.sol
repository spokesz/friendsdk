// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The platform's only Dice requester, as seen by modules.
interface IRandomnessCoordinator {
    function request(uint256 gameId, bytes32 actionKey) external returns (uint256 requestId);
    function word(uint256 requestId) external view returns (bool fulfilled, bytes32 value);
    function retry(uint256 requestId) external;
}
