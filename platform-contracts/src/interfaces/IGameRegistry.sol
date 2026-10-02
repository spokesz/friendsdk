// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Registry views read by the Treasury, the coordinator, the collections and the modules.
interface IGameRegistry {
    enum Status {
        None,
        Draft,
        Active,
        Retired
    }

    enum Binding {
        None,
        Active,
        Draining
    }

    struct Game {
        address module;
        Status status;
        address currency;
        address items;
        address funder;
        address developer;
        address operator;
        address settler;
        bytes32 termsHash;
    }

    function owner() external view returns (address);
    function generations() external view returns (address);
    function rf() external view returns (address);
    function usdg() external view returns (address);
    function custody() external view returns (address);
    function custodyExecutor() external view returns (address);
    function game(uint256 gameId) external view returns (Game memory);
    function currentModule(uint256 gameId) external view returns (address);
    function isActive(uint256 gameId) external view returns (bool);
    function isBound(uint256 gameId, address module) external view returns (bool);
    function canCommit(uint256 gameId, address module) external view returns (bool);
    function currencyOf(uint256 gameId) external view returns (address);
    function itemsOf(uint256 gameId) external view returns (address);
    function settlerOf(uint256 gameId) external view returns (address);
    function recipientsOf(uint256 gameId)
        external
        view
        returns (address funder, address developer, address operator);
    function custodyActionUsed(bytes32 actionId) external view returns (bool);
    /// @dev The one write a bound module may make: spend a custody action id exactly once.
    function consumeCustodyAction(bytes32 actionId, uint256 gameId) external;
}
