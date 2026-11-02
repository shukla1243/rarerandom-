// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script, console} from "forge-std/Script.sol";
import {RareRandomV1} from "../src/RareRandomV1.sol";

/// @notice Deploys RareRandomV1. Without --broadcast this only simulates (including the BLS self-test).
/// Env: OWNER, FEE_RECIPIENT, RELAYER_0 (required); RELAYER_1, RELAYER_2, MARGIN (5e12), WINDOW (60),
///      CANCEL_TIMEOUT (86400), MIN_LEAD (1), GAS_PRICE_SOURCE (1 on Nitro chains such as 4663), GAS_PRICE_FLOOR (2e7)
contract Deploy is Script {
    function run() external returns (RareRandomV1 core) {
        vm.startBroadcast();
        core = new RareRandomV1(
            vm.envAddress("OWNER"),
            vm.envAddress("FEE_RECIPIENT"),
            uint96(vm.envOr("MARGIN", uint256(5e12))),
            uint32(vm.envOr("WINDOW", uint256(60))),
            uint32(vm.envOr("CANCEL_TIMEOUT", uint256(86_400))),
            [vm.envAddress("RELAYER_0"), vm.envOr("RELAYER_1", address(0)), vm.envOr("RELAYER_2", address(0))],
            vm.envOr("MIN_LEAD", uint256(1)),
            uint8(vm.envOr("GAS_PRICE_SOURCE", uint256(1))),
            vm.envOr("GAS_PRICE_FLOOR", uint256(2e7))
        );
        vm.stopBroadcast();
        console.log("RareRandomV1:", address(core));
    }
}
