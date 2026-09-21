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
  address public simpleOracleAddress;

  function setUp() public virtual {
    deployerAddress = vm.envAddress("DEPLOYER_ADDRESS");
    console.log("Deployer address: %s", deployerAddress);
    deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
    isTest = vm.envBool("IS_TEST");

    if (deployerPrivateKey != 0) {
      require(deployerAddress == vm.addr(deployerPrivateKey), "Deployer address and private key do not match");
    }

    // Setting up core args
    wrappedNativeTokenAddress = vm.envAddress("WRAPPED_NATIVE_TOKEN_ADDRESS");
    console.log("Wrapped native token address: %s", wrappedNativeTokenAddress);
    generalManagerAddress = vm.envAddress("GENERAL_MANAGER_ADDRESS");
    console.log("General manager address: %s", generalManagerAddress);
    // Zero on chains whose oracles are read on-chain; the Router's price-push path is disabled there
    simpleOracleAddress = vm.envOr("SIMPLE_ORACLE_ADDRESS", address(0));
    console.log("Simple oracle address: %s", simpleOracleAddress);
  }

  /**
   * @notice Starts a broadcast signed by the deployer.
   * @dev With DEPLOYER_PRIVATE_KEY set, signs with it. With it unset, broadcasts as
   * DEPLOYER_ADDRESS so the signature comes from the CLI wallet flags
   * (e.g. --ledger --mnemonic-indexes N); a wallet for a different address fails loudly.
   */
  function startDeployerBroadcast() internal {
    if (deployerPrivateKey != 0) {
      vm.startBroadcast(deployerPrivateKey);
    } else {
      vm.startBroadcast(deployerAddress);
    }
  }

  function run() public virtual {
    startDeployerBroadcast();
    vm.stopBroadcast();
  }
}
