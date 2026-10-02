// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { DrawTables } from "./DrawTables.sol";

/// @notice Domain-separated, bias-free rolls and cumulative-weight row selection.
library Rolls {
    uint256 internal constant RANGE = 10_000;
    uint256 private constant _LIMIT = type(uint256).max - (type(uint256).max % RANGE);

    error InvalidRoll();

    /// @dev Unbiased roll in [0, 10_000); the same sampler as the deployed PenaltyKingsPark.
    function roll(bytes32 word, address module, uint256 chainId, uint256 id, uint256 index)
        internal
        pure
        returns (uint16)
    {
        uint256 value = uint256(keccak256(abi.encode(word, module, chainId, id, index)));
        // Reject the incomplete final interval rather than introducing modulo bias.
        while (value >= _LIMIT) {
            value = uint256(keccak256(abi.encode(value)));
        }
        // Reduced modulo 10_000, so the result always fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(value % RANGE);
    }

    /// @dev First row index whose cumulative weight range contains `value`, in declared order.
    function pick(DrawTables.Row[] storage rows, uint16 value) internal view returns (uint8) {
        uint256 cumulative;
        uint256 length = rows.length;
        for (uint256 i; i < length; ++i) {
            cumulative += rows[i].weightBps;
            // Row counts are bounded by DrawTables.MAX_ROWS, so the index fits.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (value < cumulative) return uint8(i);
        }
        revert InvalidRoll();
    }
}
