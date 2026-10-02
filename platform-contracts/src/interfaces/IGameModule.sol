// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice What the registry needs from any mechanic module.
interface IGameModule {
    function LINEAGE() external view returns (bytes32);
    /// @dev Registry only. Validates and freezes the game's terms; idempotent once sealed.
    function seal(uint256 gameId) external returns (bytes32 termsHash);
    /// @dev Zero until sealed.
    function termsHash(uint256 gameId) external view returns (bytes32);
    /// @dev Whether the registry may hand the game's committing role to a successor now. A
    /// module whose player locks live in its own storage answers false while they are live.
    function succeedable(uint256 gameId) external view returns (bool);
}
