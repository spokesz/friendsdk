// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IGenerations } from "../interfaces/IExternal.sol";

/// @notice The one rule for who may act for a Friend. Returns its canonical wallet and generation.
library FriendAccess {
    error InvalidFriend();
    error NotFriendController();
    error NotCustodied();

    /// @dev Eligibility only: generation in [1, 6] and a deployed canonical wallet.
    function wallet(IGenerations g, uint256 friendId)
        internal
        view
        returns (address account, uint8 generation)
    {
        generation = g.generation(friendId);
        if (generation == 0 || generation > 6) revert InvalidFriend();
        account = g.tokenBoundAccount(friendId);
        if (account.code.length == 0) revert InvalidFriend();
    }

    /// @dev Owned path: the caller must be the current owner or the canonical wallet.
    function controlled(IGenerations g, uint256 friendId, address caller)
        internal
        view
        returns (address account, uint8 generation)
    {
        (account, generation) = wallet(g, friendId);
        if (caller != g.ownerOf(friendId) && caller != account) revert NotFriendController();
    }

    /// @dev Custody path: the Friend must currently be held by FriendCustody. The executor
    /// identity and the action-id replay guard are the module's job.
    function custodied(IGenerations g, uint256 friendId, address custody)
        internal
        view
        returns (address account, uint8 generation)
    {
        if (g.ownerOf(friendId) != custody) revert NotCustodied();
        (account, generation) = wallet(g, friendId);
    }
}
