// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseScript} from "./BaseScript.s.sol";
import {console} from "forge-std/console.sol";
import {FulfillmentVault} from "../src/FulfillmentVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeFulfillmentVaultScript is BaseScript {
  FulfillmentVault public fulfillmentVault;

  function setUp() public virtual override {
    super.setUp();
    fulfillmentVault = FulfillmentVault(payable(vm.envAddress("FULFILLMENT_VAULT_ADDRESS")));
    console.log("Fulfillment vault currently deployed at: %s", address(fulfillmentVault));
  }

  function run() public virtual override {
    vm.startBroadcast();
    upgradeFulfillmentVault();
    vm.stopBroadcast();
  }

  function upgradeFulfillmentVault() public {
    // Deploy the new implementation of the fulfillmentVault
    FulfillmentVault fulfillmentVaultImplementation = new FulfillmentVault();

    // Console log the new implementation address
    console.log("New fulfillment vault implementation deployed at: %s", address(fulfillmentVaultImplementation));

    // Upgrade the fulfillmentVault to the new implementation
    fulfillmentVault.upgradeToAndCall(address(fulfillmentVaultImplementation), "");
  }
}
