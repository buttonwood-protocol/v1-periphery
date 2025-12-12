// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";

contract BaseScript is Script {
  address public deployerAddress;
  uint256 public deployerPrivateKey;
  bool public isTest;

  // Core Args
  address public wrappedNativeTokenAddress;
  address public generalManagerAddress;
  address public pythAddress;

  function setUp() public virtual {
    deployerAddress = vm.envAddress("DEPLOYER_ADDRESS");
    // deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    isTest = vm.envBool("IS_TEST");

    // require(deployerAddress == vm.addr(deployerPrivateKey), "Deployer address and private key do not match");

    // Setting up core args
    wrappedNativeTokenAddress = vm.envAddress("WRAPPED_NATIVE_TOKEN_ADDRESS");
    console.log("Wrapped native token address: %s", wrappedNativeTokenAddress);
    generalManagerAddress = vm.envAddress("GENERAL_MANAGER_ADDRESS");
    console.log("General manager address: %s", generalManagerAddress);
    pythAddress = vm.envAddress("PYTH_ADDRESS");
    console.log("Pyth address: %s", pythAddress);
  }

  function run() public virtual {
    vm.startBroadcast(deployerPrivateKey);
    vm.stopBroadcast();
  }
}
