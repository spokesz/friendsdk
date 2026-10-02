// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Module-facing ledger primitives of the Treasury.
interface ITreasury {
    /// @dev Destinations of one collect; the amount pulled from the payer is the sum of all legs.
    struct Legs {
        uint256 toFree;
        uint256 toReserved;
        uint256 developer;
        uint256 operator;
        uint256 burn;
        uint256 rewards;
    }

    function collect(uint256 gameId, address payer, Legs calldata legs) external;
    function reserve(uint256 gameId, uint256 amount) external;
    function release(uint256 gameId, uint256 amount) external;
    function resolve(
        uint256 gameId,
        uint256 amount,
        uint256 toOwed,
        uint256 toKeep,
        address payTo,
        uint256 pay
    ) external;
    function routeReserved(uint256 gameId, uint256 burned, uint256 rewards) external;
    function payOwed(uint256 gameId, address to, uint256 amount) external;
    function creditDeposit(uint256 gameId, uint256 friendId, address payer, uint256 amount) external;
    function creditWithdraw(uint256 gameId, uint256 friendId, address to, uint256 amount) external;
    function creditSpend(
        uint256 gameId,
        uint256 friendId,
        uint256 amount,
        uint256 burned,
        uint256 rewards
    ) external;
    function ledgers(uint256 gameId)
        external
        view
        returns (uint256 free, uint256 reserved, uint256 owed, uint256 credit);
    function creditOf(uint256 gameId, uint256 friendId) external view returns (uint256);
}
