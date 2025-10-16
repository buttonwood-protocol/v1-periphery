// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

contract BaseScript is Script {
  address public deployerAddress;
  uint256 public deployerPrivateKey;
  bool public isTest;

  function setUp() public virtual {
    deployerAddress = vm.envAddress("DEPLOYER_ADDRESS");
    deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    isTest = vm.envBool("IS_TEST");

    require(deployerAddress == vm.addr(deployerPrivateKey), "Deployer address and private key do not match");
  }

  function run() public virtual {
    vm.startBroadcast(deployerPrivateKey);
    vm.stopBroadcast();
  }
}
