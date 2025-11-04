// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseScript, console} from "./BaseScript.s.sol";
import {Router} from "../src/Router.sol";

contract DeployRouterScript is BaseScript {
  address public wrappedNativeTokenAddress;
  address public generalManagerAddress;
  address public pythAddress;
  Router public router;

  function setUp() public virtual override {
    super.setUp();
    wrappedNativeTokenAddress = vm.envAddress("WRAPPED_NATIVE_TOKEN_ADDRESS");
    console.log("Wrapped native token address: %s", wrappedNativeTokenAddress);
    generalManagerAddress = vm.envAddress("GENERAL_MANAGER_ADDRESS");
    console.log("General manager address: %s", generalManagerAddress);
    pythAddress = vm.envAddress("PYTH_ADDRESS");
    console.log("Pyth address: %s", pythAddress);
  }

  function run() public virtual override {
    vm.startBroadcast(deployerPrivateKey);
    deployRouter();
    // logAddresses();
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
}
