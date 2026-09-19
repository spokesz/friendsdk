// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ChanceGame, IChanceGenerations, IDiceEntropy } from "../src/ChanceGame.sol";

interface IForkFriendWallet {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory);
}

/// @dev The game holds no clock of its own, so it never reads Dice's delay; the test does.
interface IForkDiceRefund {
    function getRefundDelayBlocks() external view returns (uint64);
}

/// @notice Optional local fork check against the existing mainnet dependencies.
/// @dev Set FRIENDSDK_FORK_RPC to run. Funding and transactions exist only on the local
/// fork. Dice's request executes its deployed code, but delivery is explicitly mocked:
/// the real provider cannot fulfill a request created on a private local fork.
contract MainnetForkTest is Test {
    address private constant RF = 0x0779369854d3EcdEA927206718FFD7730C67B71f;
    address private constant GENERATIONS = 0x14C49e6118F46525dE9ab41a51cBAA3c6EBF181D;
    address private constant DICE = 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c;
    address private constant PROVIDER = 0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6;
    uint256 private constant FRIEND_ID = 7730;

    function testMainnetForkCanonicalWalletAndDiceRequestWithMockedDelivery() public {
        string memory rpc = vm.envOr("FRIENDSDK_FORK_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        assertGt(RF.code.length, 0);
        assertGt(GENERATIONS.code.length, 0);
        assertGt(DICE.code.length, 0);

        IChanceGenerations generations = IChanceGenerations(GENERATIONS);
        assertEq(generations.token(), RF);
        assertGt(generations.generation(FRIEND_ID), 0);
        address owner = generations.ownerOf(FRIEND_ID);
        address account = generations.tokenBoundAccount(FRIEND_ID);
        assertGt(account.code.length, 0);
        IForkFriendWallet wallet = IForkFriendWallet(account);
        IERC20 rf = IERC20(RF);
        uint256 ownerRF = rf.balanceOf(owner);
        uint256 accountRF = rf.balanceOf(account);
        address developer = makeAddr("fork developer");

        // Cheatcode funding changes this fork only; no existing protocol is redeployed.
        deal(RF, developer, 20 ether);
        vm.deal(address(this), 1 ether);
        vm.startPrank(developer);
        ChanceGame game = new ChanceGame(
            RF, GENERATIONS, DICE, PROVIDER, "Bait", "BAIT", 1 ether, _fishingTable()
        );
        assertTrue(rf.approve(address(game), 10 ether));
        game.fund(10 ether);
        assertTrue(rf.transfer(account, 1 ether));
        vm.stopPrank();
        assertEq(game.team(), developer);

        // The real NFT owner uses the existing ERC-6551 wallet for approval and payment.
        vm.startPrank(owner);
        wallet.execute(RF, 0, abi.encodeCall(IERC20.approve, (address(game), 1 ether)), 0);
        wallet.execute(address(game), 0, abi.encodeCall(ChanceGame.buy, (FRIEND_ID, 1)), 0);
        bytes memory committed =
            wallet.execute(address(game), 0, abi.encodeCall(ChanceGame.play, (FRIEND_ID, 1)), 0);
        vm.stopPrank();
        (uint256 playId, uint256 batchId) = abi.decode(committed, (uint256, uint256));
        assertEq(rf.balanceOf(owner), ownerRF);
        assertEq(rf.balanceOf(account), accountRF);
        assertEq(game.consumable().balanceOf(account), 0);
        assertEq(game.reservedPlays(), 10 ether);
        assertEq(game.pendingPlays(), 1);

        _requestAndMockDelivery(game, batchId, playId);
        game.settle(playId);
        assertEq(game.balanceOf(account, 8), 1);
        assertEq(game.reservedPlays(), 0);
        assertEq(game.pendingPlays(), 0);
        assertEq(game.rewardLiability(), 10 ether);

        vm.prank(owner);
        wallet.execute(address(game), 0, abi.encodeCall(ChanceGame.redeem, (FRIEND_ID, 8, 1)), 0);
        assertEq(rf.balanceOf(account), accountRF + 10 ether);
        assertEq(rf.balanceOf(owner), ownerRF);
        assertEq(game.balanceOf(account, 8), 0);
        assertEq(game.rewardLiability(), 0);
        assertEq(game.freeStake(), 1 ether);
    }

    function _requestAndMockDelivery(ChanceGame game, uint256 batchId, uint256 playId) private {
        // This calls the real Dice proxy/provider configuration on the local fork.
        uint128 fee = IDiceEntropy(DICE).getFeeV2(PROVIDER, game.CALLBACK_GAS_LIMIT());
        uint256 sponsorBefore = address(this).balance;
        uint64 sequenceNumber = game.requestRandomness{ value: fee }(batchId);
        (uint64 storedSequence, bool requested, bool fulfilled,) = game.randomness(batchId);
        assertEq(storedSequence, sequenceNumber);
        assertTrue(requested);
        assertFalse(fulfilled);
        assertEq(address(this).balance, sponsorBefore - fee);
        vm.expectRevert(ChanceGame.RandomnessPending.selector);
        game.settle(playId);

        // Reclaim and re-request through Dice's deployed code. This is the only check
        // that the DiceRequest layout decodes and that the refund path behaves as read.
        sequenceNumber = _retryThroughDice(game, batchId, sequenceNumber);

        // MOCKED DELIVERY: impersonate Dice and choose a fixture word yielding Legend.
        // This verifies callback/settlement compatibility, not live provider delivery.
        bytes32 word = _legendWord(address(game), batchId, playId);
        vm.prank(DICE);
        game._entropyCallback(sequenceNumber, PROVIDER, word);
    }

    /// @dev Only the Friend's owner may retry, and only once Dice's own delay has passed.
    function _retryThroughDice(ChanceGame game, uint256 batchId, uint64 stale)
        private
        returns (uint64 sequenceNumber)
    {
        address owner = IChanceGenerations(GENERATIONS).ownerOf(FRIEND_ID);
        uint128 fee = IDiceEntropy(DICE).getFeeV2(PROVIDER, game.CALLBACK_GAS_LIMIT());
        vm.roll(block.number + IForkDiceRefund(DICE).getRefundDelayBlocks());
        vm.deal(owner, fee);
        vm.prank(owner);
        sequenceNumber = game.retryRandomness{ value: fee }(batchId);
        assertNotEq(sequenceNumber, stale);
        // Dice cleared the old request, so no late word can ever land on this batch.
        assertEq(IDiceEntropy(DICE).getRequestV2(PROVIDER, stale).sequenceNumber, 0);
        assertEq(address(game).balance, 0);
        assertEq(owner.balance, fee);
        (uint64 storedSequence, bool requested, bool fulfilled,) = game.randomness(batchId);
        assertEq(storedSequence, sequenceNumber);
        assertTrue(requested);
        assertFalse(fulfilled);
    }

    function _legendWord(address game, uint256 batchId, uint256 playId)
        private
        view
        returns (bytes32 word)
    {
        for (uint256 candidate;; ++candidate) {
            word = bytes32(candidate);
            uint256 roll =
                uint256(keccak256(abi.encode(word, game, block.chainid, batchId, playId))) % 10_000;
            if (roll >= 9800) return word;
        }
    }

    function _fishingTable() private pure returns (ChanceGame.Outcome[] memory table) {
        uint16[8] memory chances = [uint16(1500), 3000, 2200, 1400, 900, 500, 300, 200];
        uint256[8] memory rewards = [
            uint256(0), 0.25 ether, 0.5 ether, 0.75 ether, 1.5 ether, 2.5 ether, 5 ether, 10 ether
        ];
        table = new ChanceGame.Outcome[](8);
        for (uint256 i; i < table.length; ++i) {
            table[i] = ChanceGame.Outcome(chances[i], rewards[i], "");
        }
    }
}
