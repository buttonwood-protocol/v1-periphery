// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseScript} from "./BaseScript.s.sol";
import {console} from "forge-std/console.sol";
import {RolloverVault} from "../src/RolloverVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployRolloverVaultScript is BaseScript {
  string public rolloverVaultName;
  string public rolloverVaultSymbol;
  uint8 public rolloverVaultDecimals;
  uint8 public rolloverVaultDecimalsOffset;
  address public rolloverVaultAdminAddress;

  RolloverVault public rolloverVault;

  function setUp() public virtual override {
    super.setUp();
    // Setting up rollover vault args
    rolloverVaultName = vm.envString("ROLLOVER_VAULT_NAME");
    console.log("Rollover vault name: %s", rolloverVaultName);
    rolloverVaultSymbol = vm.envString("ROLLOVER_VAULT_SYMBOL");
    console.log("Rollover vault symbol: %s", rolloverVaultSymbol);
    rolloverVaultDecimals = uint8(vm.envUint("ROLLOVER_VAULT_DECIMALS"));
    console.log("Rollover vault decimals: %s", rolloverVaultDecimals);
    rolloverVaultDecimalsOffset = uint8(vm.envUint("ROLLOVER_VAULT_DECIMALS_OFFSET"));
    console.log("Rollover vault decimals offset: %s", rolloverVaultDecimalsOffset);
    rolloverVaultAdminAddress = vm.envAddress("ROLLOVER_VAULT_ADMIN_ADDRESS");
    console.log("Rollover vault admin address: %s", rolloverVaultAdminAddress);
  }

  function run() public virtual override {
    vm.startBroadcast(deployerPrivateKey);
    deployRolloverVault();
    // logAddresses();
    vm.stopBroadcast();
  }

  function deployRolloverVault() public {
    // Deploy the rolloverVault implementation
    RolloverVault rolloverVaultImplementation = new RolloverVault();

    // Create the initializer data
    bytes memory initializerData = abi.encodeWithSelector(
      RolloverVault.initialize.selector,
      rolloverVaultName,
      rolloverVaultSymbol,
      rolloverVaultDecimals,
      rolloverVaultDecimalsOffset,
      generalManagerAddress,
      rolloverVaultAdminAddress
    );

    // Deploy the proxy with the initializer data
    ERC1967Proxy proxy = new ERC1967Proxy(address(rolloverVaultImplementation), initializerData);
    rolloverVault = RolloverVault(payable(address(proxy)));

    // Grant the keeper role to the vault admin address
    rolloverVault.grantRole(rolloverVault.KEEPER_ROLE(), rolloverVaultAdminAddress);

    // Grant the default admin role to the vault admin address
    rolloverVault.grantRole(rolloverVault.DEFAULT_ADMIN_ROLE(), rolloverVaultAdminAddress);
  }

  function logRolloverVault(string memory objectKey) public returns (string memory json) {
    json = vm.serializeAddress(objectKey, "rolloverVaultAddress", address(rolloverVault));
  }
}
