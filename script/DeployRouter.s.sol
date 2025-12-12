// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {DeployFulfillmentVaultScript} from "./DeployFulfillmentVault.s.sol";
import {console} from "forge-std/console.sol";
import {Router} from "../src/Router.sol";

contract DeployRouterScript is DeployFulfillmentVaultScript {
  Router public router;

  function setUp() public virtual override {
    super.setUp();
  }

  function run() public virtual override {
    vm.startBroadcast(deployerPrivateKey);
    deployRouter();
    // logAddresses();
    vm.stopBroadcast();
  }

  function deployRouter() public {
    router = new Router(wrappedNativeTokenAddress, generalManagerAddress, address(rolloverVault), pythAddress);
    router.approveCollaterals();
    router.approveUsdTokens();
  }

  function logRouter(string memory objectKey) public returns (string memory json) {
    json = vm.serializeAddress(objectKey, "routerAddress", address(router));
  }
}
