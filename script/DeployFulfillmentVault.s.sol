// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {DeployRolloverVaultScript} from "./DeployRolloverVault.s.sol";
import {console} from "forge-std/console.sol";
import {FulfillmentVault} from "../src/FulfillmentVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployFulfillmentVaultScript is DeployRolloverVaultScript {
  string public fulfillmentVaultName;
  string public fulfillmentVaultSymbol;
  uint8 public fulfillmentVaultDecimals;
  uint8 public fulfillmentVaultDecimalsOffset;
  address public fulfillmentVaultAdminAddress;

  FulfillmentVault public fulfillmentVault;

  function setUp() public virtual override {
    super.setUp();
    fulfillmentVaultName = vm.envString("FULFILLMENT_VAULT_NAME");
    console.log("Fulfillment vault name: %s", fulfillmentVaultName);
    fulfillmentVaultSymbol = vm.envString("FULFILLMENT_VAULT_SYMBOL");
    console.log("Fulfillment vault symbol: %s", fulfillmentVaultSymbol);
    fulfillmentVaultDecimals = uint8(vm.envUint("FULFILLMENT_VAULT_DECIMALS"));
    console.log("Fulfillment vault decimals: %s", fulfillmentVaultDecimals);
    fulfillmentVaultDecimalsOffset = uint8(vm.envUint("FULFILLMENT_VAULT_DECIMALS_OFFSET"));
    console.log("Fulfillment vault decimals offset: %s", fulfillmentVaultDecimalsOffset);
    fulfillmentVaultAdminAddress = vm.envAddress("FULFILLMENT_VAULT_ADMIN_ADDRESS");
    console.log("Fulfillment vault admin address: %s", fulfillmentVaultAdminAddress);
  }

  function run() public virtual override {
    vm.startBroadcast(deployerPrivateKey);
    deployFulfillmentVault();
    // logAddresses();
    vm.stopBroadcast();
  }

  function deployFulfillmentVault() public {
    // Deploy the fulfillmentVault implementation
    FulfillmentVault fulfillmentVaultImplementation = new FulfillmentVault();

    // Create the initializer data
    bytes memory initializerData = abi.encodeWithSelector(
      FulfillmentVault.initialize.selector,
      fulfillmentVaultName,
      fulfillmentVaultSymbol,
      fulfillmentVaultDecimals,
      fulfillmentVaultDecimalsOffset,
      wrappedNativeTokenAddress,
      generalManagerAddress,
      fulfillmentVaultAdminAddress
    );

    // Deploy the proxy with the initializer data
    ERC1967Proxy proxy = new ERC1967Proxy(address(fulfillmentVaultImplementation), initializerData);
    fulfillmentVault = FulfillmentVault(payable(address(proxy)));

    // Grant the keeper role to the vault admin address
    fulfillmentVault.grantRole(fulfillmentVault.KEEPER_ROLE(), fulfillmentVaultAdminAddress);

    // Grant the whitelist role to the vault admin address
    fulfillmentVault.grantRole(fulfillmentVault.WHITELIST_ROLE(), fulfillmentVaultAdminAddress);
  }

  function logFulfillmentVault(string memory objectKey) public returns (string memory json) {
    json = vm.serializeAddress(objectKey, "fulfillmentVaultAddress", address(fulfillmentVault));
  }
}
