// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC1155 } from "lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import { IERC1155Errors } from "lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import { GameItems } from "../src/GameItems.sol";
import { MockFriendWallet, MockGenerations, MockRF } from "./doubles/ExternalDoubles.sol";

/// @dev The one registry view the collection reads, with bindings the test flips directly.
contract StubRegistry {
    mapping(uint256 gameId => mapping(address module => bool)) public isBound;

    function bind(uint256 gameId, address module, bool bound) external {
        isBound[gameId][module] = bound;
    }
}

contract GameItemsTest is Test {
    uint256 internal constant GAME_ID = 7;
    uint256 internal constant CLASS_COUNT = 5;
    uint256 internal constant FRIEND_A = 1234;
    uint256 internal constant FRIEND_B = 5678;

    StubRegistry internal registry;
    GameItems internal items;
    MockGenerations internal generations;
    address internal moduleV1 = makeAddr("moduleV1");
    address internal moduleV2 = makeAddr("moduleV2");
    address internal ownerA = makeAddr("ownerA");
    address internal ownerB = makeAddr("ownerB");
    address internal stranger = makeAddr("stranger");
    address internal walletA;
    address internal walletB;

    function setUp() public {
        registry = new StubRegistry();
        registry.bind(GAME_ID, moduleV1, true);
        items = new GameItems(address(registry), GAME_ID, CLASS_COUNT, "ipfs://items/{id}.json");
        generations = new MockGenerations(address(new MockRF()));
        generations.mint(ownerA, FRIEND_A, 3);
        generations.mint(ownerB, FRIEND_B, 2);
        walletA = generations.tokenBoundAccount(FRIEND_A);
        walletB = generations.tokenBoundAccount(FRIEND_B);
    }

    function _mintTo(address wallet, uint256 id, uint256 amount) internal {
        vm.prank(moduleV1);
        items.mintBatch(wallet, _single(id), _single(amount));
    }

    function _single(uint256 value) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = value;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    // ---- construction -------------------------------------------------------------------------

    function testConstructorRecordsImmutables() public view {
        assertEq(address(items.registry()), address(registry));
        assertEq(items.gameId(), GAME_ID);
        assertEq(items.classCount(), CLASS_COUNT);
        assertEq(items.uri(1), "ipfs://items/{id}.json");
    }

    function testConstructorRejectsZeroClasses() public {
        vm.expectRevert(GameItems.InvalidConfiguration.selector);
        new GameItems(address(registry), GAME_ID, 0, "");
    }

    function testConstructorRejectsMoreThanSixtyFourClasses() public {
        vm.expectRevert(GameItems.InvalidConfiguration.selector);
        new GameItems(address(registry), GAME_ID, 65, "");
        GameItems full = new GameItems(address(registry), GAME_ID, 64, "");
        assertEq(full.classCount(), 64);
    }

    // ---- mint and burn authority ---------------------------------------------------------------

    function testBoundModuleMintsAndBurns() public {
        vm.expectEmit(address(items));
        emit IERC1155.TransferSingle(moduleV1, address(0), walletA, 2, 3);
        _mintTo(walletA, 2, 3);
        assertEq(items.balanceOf(walletA, 2), 3);

        vm.prank(moduleV1);
        items.burn(walletA, 2, 2);
        assertEq(items.balanceOf(walletA, 2), 1);
    }

    function testBoundModuleMintsBatch() public {
        uint256[] memory amounts = _ids(4, 1);
        vm.prank(moduleV1);
        items.mintBatch(walletA, _ids(1, 5), amounts);
        assertEq(items.balanceOf(walletA, 1), 4);
        assertEq(items.balanceOf(walletA, 5), 1);
    }

    function testBurnNeedsNoHolderApproval() public {
        _mintTo(walletA, 1, 1);
        assertFalse(items.isApprovedForAll(walletA, moduleV1));
        vm.prank(moduleV1);
        items.burn(walletA, 1, 1);
        assertEq(items.balanceOf(walletA, 1), 0);
    }

    function testBurnMoreThanHeldReverts() public {
        _mintTo(walletA, 1, 1);
        vm.prank(moduleV1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, walletA, 1, 2, 1
            )
        );
        items.burn(walletA, 1, 2);
    }

    function testUnboundCallerCannotMintBatchOrBurn() public {
        _mintTo(walletA, 1, 1);
        address[3] memory callers = [stranger, ownerA, address(registry)];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(GameItems.NotBoundModule.selector);
            items.mintBatch(walletA, _single(1), _single(1));
            vm.expectRevert(GameItems.NotBoundModule.selector);
            items.mintBatch(walletA, _ids(1, 2), _ids(1, 1));
            vm.expectRevert(GameItems.NotBoundModule.selector);
            items.burn(walletA, 1, 1);
            vm.stopPrank();
        }
    }

    function testAuthorityFlipsWithSuccessionWithoutAnyWriteHere() public {
        vm.prank(moduleV2);
        vm.expectRevert(GameItems.NotBoundModule.selector);
        items.mintBatch(walletA, _single(1), _single(1));

        // Succession binds v2 and leaves v1 Draining: both are bound, both may mint and burn.
        registry.bind(GAME_ID, moduleV2, true);
        vm.prank(moduleV2);
        items.mintBatch(walletA, _single(1), _single(2));
        vm.prank(moduleV1);
        items.burn(walletA, 1, 1);
        vm.prank(moduleV2);
        items.burn(walletA, 1, 1);
        assertEq(items.balanceOf(walletA, 1), 0);

        // A binding the registry no longer reports loses authority immediately.
        registry.bind(GAME_ID, moduleV1, false);
        vm.prank(moduleV1);
        vm.expectRevert(GameItems.NotBoundModule.selector);
        items.mintBatch(walletA, _single(1), _single(1));
    }

    function testBindingIsScopedToThisGame() public {
        registry.bind(GAME_ID + 1, moduleV2, true);
        vm.prank(moduleV2);
        vm.expectRevert(GameItems.NotBoundModule.selector);
        items.mintBatch(walletA, _single(1), _single(1));
    }

    // ---- class bounds --------------------------------------------------------------------------

    function testUnknownClassRejectedOnEveryEntryPoint() public {
        uint256[2] memory bad = [uint256(0), CLASS_COUNT + 1];
        for (uint256 i; i < bad.length; ++i) {
            vm.startPrank(moduleV1);
            vm.expectRevert(GameItems.UnknownClass.selector);
            items.mintBatch(walletA, _single(bad[i]), _single(1));
            vm.expectRevert(GameItems.UnknownClass.selector);
            items.mintBatch(walletA, _ids(1, bad[i]), _ids(1, 1));
            vm.expectRevert(GameItems.UnknownClass.selector);
            items.burn(walletA, bad[i], 1);
            vm.stopPrank();
        }
    }

    function testFuzzClassBounds(uint256 id) public {
        vm.prank(moduleV1);
        if (id == 0 || id > CLASS_COUNT) vm.expectRevert(GameItems.UnknownClass.selector);
        items.mintBatch(walletA, _single(id), _single(1));
    }

    // ---- Friend-bound transfers ----------------------------------------------------------------

    function testDirectTransferByHolderReverts() public {
        _mintTo(walletA, 1, 1);
        vm.prank(walletA);
        vm.expectRevert(GameItems.FriendBoundInventory.selector);
        items.safeTransferFrom(walletA, walletB, 1, 1, "");
        assertEq(items.balanceOf(walletA, 1), 1);
    }

    function testTransferThroughWalletExecuteReverts() public {
        _mintTo(walletA, 1, 1);
        bytes memory data = abi.encodeCall(
            IERC1155.safeTransferFrom, (walletA, walletB, uint256(1), uint256(1), bytes(""))
        );
        vm.prank(ownerA);
        vm.expectRevert(GameItems.FriendBoundInventory.selector);
        MockFriendWallet(payable(walletA)).execute(address(items), 0, data, 0);
    }

    function testTransferThroughApprovedOperatorReverts() public {
        _mintTo(walletA, 1, 2);
        vm.prank(walletA);
        items.setApprovalForAll(stranger, true);
        assertTrue(items.isApprovedForAll(walletA, stranger));

        vm.startPrank(stranger);
        vm.expectRevert(GameItems.FriendBoundInventory.selector);
        items.safeTransferFrom(walletA, walletB, 1, 1, "");
        vm.expectRevert(GameItems.FriendBoundInventory.selector);
        items.safeBatchTransferFrom(walletA, walletB, _ids(1, 1), _ids(1, 1), "");
        vm.stopPrank();
        assertEq(items.balanceOf(walletA, 1), 2);
        assertEq(items.balanceOf(walletB, 1), 0);
    }

    function testBoundModuleCannotMoveItemsEither() public {
        _mintTo(walletA, 1, 1);
        vm.prank(walletA);
        items.setApprovalForAll(moduleV1, true);
        vm.prank(moduleV1);
        vm.expectRevert(GameItems.FriendBoundInventory.selector);
        items.safeTransferFrom(walletA, walletB, 1, 1, "");
    }

    function testSelfTransferReverts() public {
        _mintTo(walletA, 1, 1);
        vm.prank(walletA);
        vm.expectRevert(GameItems.FriendBoundInventory.selector);
        items.safeTransferFrom(walletA, walletA, 1, 1, "");
    }

    // ---- metadata ------------------------------------------------------------------------------

    function testSetURIOnlyByRegistry() public {
        address[3] memory callers = [stranger, moduleV1, ownerA];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(GameItems.OnlyRegistry.selector);
            items.setURI("x");
        }
        // OpenZeppelin's _setURI emits no URI event: the template cannot name a single id.
        vm.prank(address(registry));
        items.setURI("ipfs://v2/{id}.json");
        assertEq(items.uri(3), "ipfs://v2/{id}.json");
    }
}
