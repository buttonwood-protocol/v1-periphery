// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseScript} from "./BaseScript.s.sol";
import {console} from "forge-std/console.sol";
import {UniswapFulfillmentVault} from "../src/UniswapFulfillmentVault.sol";
import {RouterApproval, RouterConfig} from "../src/interfaces/IUniswapFulfillmentVault/RouterApproval.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployUniswapFulfillmentVaultScript is BaseScript {
  string public uniswapFulfillmentVaultName;
  string public uniswapFulfillmentVaultSymbol;
  uint8 public uniswapFulfillmentVaultDecimals;
  uint8 public uniswapFulfillmentVaultDecimalsOffset;
  address public uniswapFulfillmentVaultAdminAddress;
  address public usdgAddress;
  address public permit2Address;
  RouterConfig[] public routers;

  error InvalidRouterApproval(uint256 index, string approval);

  UniswapFulfillmentVault public uniswapFulfillmentVault;

  function setUp() public virtual override {
    super.setUp();
    uniswapFulfillmentVaultName = vm.envString("UNISWAP_FULFILLMENT_VAULT_NAME");
    console.log("Uniswap fulfillment vault name: %s", uniswapFulfillmentVaultName);
    uniswapFulfillmentVaultSymbol = vm.envString("UNISWAP_FULFILLMENT_VAULT_SYMBOL");
    console.log("Uniswap fulfillment vault symbol: %s", uniswapFulfillmentVaultSymbol);
    uniswapFulfillmentVaultDecimals = uint8(vm.envUint("UNISWAP_FULFILLMENT_VAULT_DECIMALS"));
    console.log("Uniswap fulfillment vault decimals: %s", uniswapFulfillmentVaultDecimals);
    uniswapFulfillmentVaultDecimalsOffset = uint8(vm.envUint("UNISWAP_FULFILLMENT_VAULT_DECIMALS_OFFSET"));
    console.log("Uniswap fulfillment vault decimals offset: %s", uniswapFulfillmentVaultDecimalsOffset);
    uniswapFulfillmentVaultAdminAddress = vm.envAddress("UNISWAP_FULFILLMENT_VAULT_ADMIN_ADDRESS");
    console.log("Uniswap fulfillment vault admin address: %s", uniswapFulfillmentVaultAdminAddress);
    usdgAddress = vm.envAddress("USDG_ADDRESS");
    console.log("USDG address: %s", usdgAddress);
    permit2Address = vm.envAddress("PERMIT2_ADDRESS");
    console.log("Permit2 address: %s", permit2Address);
    // Each router is a pair: ALLOWED_ROUTER_<i> (address) and ALLOWED_ROUTER_<i>_APPROVAL ("ERC20" or "PERMIT2")
    uint256 allowedRouterCount = vm.envUint("ALLOWED_ROUTER_COUNT");
    for (uint256 i = 0; i < allowedRouterCount; i++) {
      address router = vm.envAddress(string.concat("ALLOWED_ROUTER_", vm.toString(i)));
      string memory approvalName = vm.envString(string.concat("ALLOWED_ROUTER_", vm.toString(i), "_APPROVAL"));
      RouterApproval approval = _parseRouterApproval(i, approvalName);
      console.log("Allowed router %s: %s (%s)", i, router, approvalName);
      routers.push(RouterConfig({router: router, approval: approval}));
    }
  }

  function _parseRouterApproval(uint256 index, string memory approvalName) internal pure returns (RouterApproval) {
    bytes32 nameHash = keccak256(bytes(approvalName));
    if (nameHash == keccak256("ERC20")) {
      return RouterApproval.ERC20;
    }
    if (nameHash == keccak256("PERMIT2")) {
      return RouterApproval.Permit2;
    }
    revert InvalidRouterApproval(index, approvalName);
  }

  function run() public virtual override {
    startDeployerBroadcast();
    deployUniswapFulfillmentVault();
    vm.stopBroadcast();
  }

  function deployUniswapFulfillmentVault() public {
    // Deploy the uniswapFulfillmentVault implementation
    UniswapFulfillmentVault uniswapFulfillmentVaultImplementation = new UniswapFulfillmentVault();

    // Create the initializer data
    bytes memory initializerData = abi.encodeCall(
      UniswapFulfillmentVault.initialize,
      (
        uniswapFulfillmentVaultName,
        uniswapFulfillmentVaultSymbol,
        uniswapFulfillmentVaultDecimals,
        uniswapFulfillmentVaultDecimalsOffset,
        generalManagerAddress,
        usdgAddress,
        permit2Address,
        routers,
        uniswapFulfillmentVaultAdminAddress
      )
    );

    // Deploy the proxy with the initializer data
    ERC1967Proxy proxy = new ERC1967Proxy(address(uniswapFulfillmentVaultImplementation), initializerData);
    uniswapFulfillmentVault = UniswapFulfillmentVault(payable(address(proxy)));

    // Grant the keeper role to the vault admin address
    uniswapFulfillmentVault.grantRole(uniswapFulfillmentVault.KEEPER_ROLE(), uniswapFulfillmentVaultAdminAddress);

    // Grant the whitelist role to the vault admin address
    uniswapFulfillmentVault.grantRole(uniswapFulfillmentVault.WHITELIST_ROLE(), uniswapFulfillmentVaultAdminAddress);

    // Post-deploy grants executed by the maintainer: the order pool's FULFILLMENT_ROLE and USDX's
    // IGNORE_CAP_ROLE (for the leftover-USDG redeposit) both go to the vault, then per-collateral
    // setCollateralRoute and approveAssetToOrderPool calls.
    //
    // On Robinhood Chain (4663) the allowlist carries both Universal Router deployments in PERMIT2
    // mode — 0x204FAca1764B154221e35c0d20aBb3c525710498 (2.1.2, the Trading API's default target) and
    // 0x8876789976dEcBfCbBbe364623C63652db8C0904 (2.1.1) — so the keeper can fill through either.
  }

  function logUniswapFulfillmentVault(string memory objectKey) public returns (string memory json) {
    json = vm.serializeAddress(objectKey, "uniswapFulfillmentVaultAddress", address(uniswapFulfillmentVault));
  }
}
