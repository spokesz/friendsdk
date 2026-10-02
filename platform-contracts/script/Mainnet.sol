// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Existing Robinhood Chain mainnet dependencies, read-verified on 2026-10-02.
/// @dev Reference values for deployment simulation and fork tests. Nothing here deploys.
library Mainnet {
    uint256 internal constant CHAIN_ID = 4663;
    address internal constant RF = 0x0779369854d3EcdEA927206718FFD7730C67B71f;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant GENERATIONS = 0x14C49e6118F46525dE9ab41a51cBAA3c6EBF181D;
    address internal constant DICE_ENTROPY = 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c;
    address internal constant DICE_PROVIDER = 0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6;
    address internal constant FRIEND_CUSTODY = 0x37702f6b25217e5eF34F6b3aF589476CEa35Be3a;
    /// @dev Observed Dice fee for a 200,000 gas callback: 0.000025 ETH.
    uint128 internal constant OBSERVED_DICE_FEE = 25_000_000_000_000;
}
