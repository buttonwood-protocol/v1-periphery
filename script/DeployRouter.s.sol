// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseScript, console} from "./BaseScript.s.sol";
import {Router} from "../src/Router.sol";

contract RouterScript is BaseScript {
  address public wrappedNativeTokenAddress;
  address public generalManagerAddress;
  address public pythAddress;
  Router public router;

  function setUp() public override {
    super.setUp();
    wrappedNativeTokenAddress = vm.envAddress("WRAPPED_NATIVE_TOKEN_ADDRESS");
    console.log("Wrapped native token address: %s", wrappedNativeTokenAddress);
    generalManagerAddress = vm.envAddress("GENERAL_MANAGER_ADDRESS");
    console.log("General manager address: %s", generalManagerAddress);
    pythAddress = vm.envAddress("PYTH_ADDRESS");
    console.log("Pyth address: %s", pythAddress);
  }

  function run() public override {
    vm.startBroadcast(deployerPrivateKey);
    deployRouter();
    logAddresses();
    vm.stopBroadcast();
  }

  function deployRouter() public {
    router = new Router(wrappedNativeTokenAddress, generalManagerAddress, pythAddress);
    router.approveCollaterals();
    router.approveUsdTokens();
  }

  function logRouter(string memory objectKey) public returns (string memory json) {
    json = vm.serializeAddress(objectKey, "routerAddress", address(router));
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
    // Output final json to file
    vm.writeJson(json, path);
  }
}
