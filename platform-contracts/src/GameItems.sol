// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ERC1155 } from "lib/openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import { IGameItems } from "./interfaces/IGameItems.sol";
import { IGameRegistry } from "./interfaces/IGameRegistry.sol";

/// @notice One Friend-bound ERC-1155 collection per game, deployed by the registry.
/// @dev Every id is bound to the wallet it was minted to: transfers revert except mint and burn.
/// Authority is read live from the registry, so a module bound to the game (Active or Draining)
/// may mint and burn without any write here when a successor module takes over.
contract GameItems is ERC1155, IGameItems {
    uint256 private constant _MAX_CLASSES = 64;

    IGameRegistry public immutable registry;
    uint256 public immutable gameId;
    // Valid ids are 1..classCount.
    uint256 public immutable classCount;

    error InvalidConfiguration();
    error NotBoundModule();
    error OnlyRegistry();
    error UnknownClass();
    error FriendBoundInventory();

    modifier onlyBound() {
        if (!registry.isBound(gameId, msg.sender)) revert NotBoundModule();
        _;
    }

    constructor(address registry_, uint256 gameId_, uint256 classCount_, string memory uri_)
        ERC1155(uri_)
    {
        if (classCount_ == 0 || classCount_ > _MAX_CLASSES) revert InvalidConfiguration();
        registry = IGameRegistry(registry_);
        gameId = gameId_;
        classCount = classCount_;
    }

    /// @notice A bound module mints several classes into a Friend wallet at once.
    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts)
        external
        onlyBound
    {
        for (uint256 i; i < ids.length; ++i) {
            _checkClass(ids[i]);
        }
        _mintBatch(to, ids, amounts, "");
    }

    /// @notice A bound module consumes items in play; no holder approval is involved.
    function burn(address from, uint256 id, uint256 amount) external onlyBound {
        _checkClass(id);
        _burn(from, id, amount);
    }

    /// @notice The registry owner sets metadata through the registry; OZ emits `URI`.
    function setURI(string calldata newuri) external {
        if (msg.sender != address(registry)) revert OnlyRegistry();
        _setURI(newuri);
    }

    function _checkClass(uint256 id) private view {
        if (id == 0 || id > classCount) revert UnknownClass();
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        if (from != address(0) && to != address(0)) revert FriendBoundInventory();
        super._update(from, to, ids, values);
    }
}
