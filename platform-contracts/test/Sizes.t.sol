// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Fixture } from "./Fixture.sol";

/// @dev docs/SPEC.md section 8: every runtime stays at most 24_576 - 512 bytes, measured both on
/// the deployed fixture addresses and on the compiled artifacts, so the planned splits are applied
/// before the EIP-170 limit bites.
contract SizesTest is Fixture {
    uint256 internal constant LIMIT = 24_576 - 512;

    function testDeployedRuntimesFitUnderTheLimit() public view {
        _assertFits("GameRegistry", address(registry).code.length);
        _assertFits("Treasury", address(treasury).code.length);
        _assertFits("RandomnessCoordinator", address(coordinator).code.length);
        _assertFits("DrawModule", address(draw).code.length);
        _assertFits("RoundModule", address(round).code.length);
        _assertFits("GameItems(breeds)", address(items(breedsId)).code.length);
        _assertFits("GameItems(park)", address(items(parkId)).code.length);
    }

    function testArtifactRuntimesFitUnderTheLimit() public view {
        _assertFits("GameRegistry", vm.getDeployedCode("GameRegistry.sol:GameRegistry").length);
        _assertFits("Treasury", vm.getDeployedCode("Treasury.sol:Treasury").length);
        _assertFits(
            "RandomnessCoordinator",
            vm.getDeployedCode("RandomnessCoordinator.sol:RandomnessCoordinator").length
        );
        _assertFits("DrawModule", vm.getDeployedCode("DrawModule.sol:DrawModule").length);
        _assertFits("RoundModule", vm.getDeployedCode("RoundModule.sol:RoundModule").length);
        _assertFits("GameItems", vm.getDeployedCode("GameItems.sol:GameItems").length);
    }

    /// @dev The registry embeds the GameItems creation code (section 2.6), so it is the one
    /// runtime whose size depends on another contract; both halves must fit on their own.
    function testRegistryEmbedsItemsCreationCode() public view {
        uint256 itemsRuntime = vm.getDeployedCode("GameItems.sol:GameItems").length;
        uint256 registryRuntime = vm.getDeployedCode("GameRegistry.sol:GameRegistry").length;
        assertGt(registryRuntime, itemsRuntime, "registry must carry the items creation code");
    }

    function _assertFits(string memory name, uint256 size) private pure {
        assertGt(size, 0, string.concat(name, ": no runtime code"));
        assertLe(size, LIMIT, string.concat(name, ": runtime exceeds 24_576 - 512 bytes"));
    }
}
