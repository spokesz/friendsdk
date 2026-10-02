// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Draw term structures and table validation shared by the Draw module and its tests.
library DrawTables {
    uint256 internal constant MAX_ACTIONS = 32;
    uint256 internal constant MAX_ROWS = 16;
    uint256 internal constant MAX_DRAWS = 4;
    uint256 internal constant MAX_UNITS = 16;
    uint256 internal constant BPS = 10_000;

    enum Input {
        None,
        Currency,
        BurnClass
    }

    /// @dev One slot. A class never has both value and reserve nonzero.
    struct Class {
        // Fixed redemption value owed on mint and paid on redeem; 0 = not redeemable.
        uint128 value;
        // Backing locked from free while the item exists; 0 = none.
        uint128 reserve;
    }

    /// @dev Sums to 10_000. Read for Currency input only.
    struct Split {
        uint16 freeBps;
        uint16 developerBps;
        uint16 operatorBps;
        uint16 burnBps;
        uint16 rewardsBps;
    }

    /// @dev One slot.
    struct Action {
        Input input;
        uint16 inputClass;
        uint8 inputCount;
        uint128 price;
        uint8 draws;
        uint8 maxUnits;
        bool perGeneration;
    }

    /// @dev One slot. classId != 0 mints one of that class; value != 0 pays that much; both zero
    /// is "nothing"; both nonzero is invalid.
    struct Row {
        uint16 weightBps;
        uint16 classId;
        uint128 value;
    }

    error InvalidTable();

    /// @dev Reverts unless `rows` is well formed against `classes`; returns the table's maximum
    /// backing per draw: max over rows of value + (class value + class reserve when minting).
    function validate(Row[] calldata rows, Class[] storage classes)
        internal
        view
        returns (uint128 maxPayable)
    {
        if (rows.length == 0 || rows.length > MAX_ROWS) revert InvalidTable();
        uint256 total;
        for (uint256 i; i < rows.length; ++i) {
            Row calldata row = rows[i];
            if (row.weightBps == 0 || row.classId > classes.length) revert InvalidTable();
            if (row.classId != 0 && row.value != 0) revert InvalidTable();
            total += row.weightBps;
            uint256 backing = row.value;
            if (row.classId != 0) {
                Class storage class = classes[row.classId - 1];
                backing += uint256(class.value) + class.reserve;
            }
            if (backing > type(uint128).max) revert InvalidTable();
            // Bounded by the check above.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (backing > maxPayable) maxPayable = uint128(backing);
        }
        if (total != BPS) revert InvalidTable();
    }
}
