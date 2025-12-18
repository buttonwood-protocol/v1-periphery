// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {DeployFulfillmentVaultScript} from "./DeployFulfillmentVault.s.sol";
import {console} from "forge-std/console.sol";
import {Router} from "../src/Router.sol";
import {RolloverVault} from "../src/RolloverVault.sol";
import {FulfillmentVault} from "../src/FulfillmentVault.sol";

contract DeployRouterScript is DeployFulfillmentVaultScript {
  Router public router;

  function setUp() public virtual override {
    super.setUp();
  }

  function run() public virtual override {
    rolloverVault = RolloverVault(payable(vm.envAddress("ROLLOVER_VAULT_ADDRESS")));
    console.log("Rollover vault address: %s", address(rolloverVault));
    fulfillmentVault = FulfillmentVault(payable(vm.envAddress("FULFILLMENT_VAULT_ADDRESS")));
    console.log("Fulfillment vault address: %s", address(fulfillmentVault));
    vm.startBroadcast();
    deployRouter();
    // logAddresses();
    vm.stopBroadcast();
  }

  function deployRouter() public {
    if (address(rolloverVault) == address(0)) {
      revert("Rollover vault not deployed");
    }
    if (address(fulfillmentVault) == address(0)) {
      revert("Fulfillment vault not deployed");
    }
    router = new Router(
      wrappedNativeTokenAddress, generalManagerAddress, address(rolloverVault), address(fulfillmentVault), pythAddress
    );
    router.approveCollaterals();
    router.approveUsdTokens();
  }

  function logRouter(string memory objectKey) public returns (string memory json) {
    json = vm.serializeAddress(objectKey, "routerAddress", address(router));
  }
}
