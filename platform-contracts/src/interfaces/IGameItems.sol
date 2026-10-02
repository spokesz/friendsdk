// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice A game's Friend-bound ERC-1155 collection, as seen by modules and the registry.
interface IGameItems {
    function classCount() external view returns (uint256);
    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function setURI(string calldata newuri) external;
}
