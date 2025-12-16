// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// forge-lint: disable-next-line(unused-import)
import {DeployRouterScript} from "./DeployRouter.s.sol";
import {console} from "forge-std/console.sol";

contract DeployAllScript is DeployRouterScript {
  function setUp() public virtual override {
    super.setUp();
  }

  function run() public virtual override {
    vm.startBroadcast();
    deployRolloverVault();
    deployFulfillmentVault();
    deployRouter();
    logAddresses();
    vm.stopBroadcast();
  }

  function logAddresses() public {
    uint256 chainId = block.chainid;
    string memory root = vm.projectRoot();
    string memory path = string.concat(root, "/addresses/addresses-", vm.toString(chainId), ".json");
    string memory obj = "key";
    string memory json;
    // Remove the file if it exists
    if (vm.isFile(path)) {
      vm.removeFile(path);
    }

    // Log the router address
    json = logRouter(obj);
    // Log the rollover vault address
    json = logRolloverVault(obj);
    // Log the fulfillment vault address
    json = logFulfillmentVault(obj);
    // Output final json to file
    vm.writeJson(json, path);
  }
}
