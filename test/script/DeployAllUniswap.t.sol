// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.t.sol";
import {DeployAllUniswapScript} from "../../script/DeployAllUniswap.s.sol";
import {RolloverVault} from "../../src/RolloverVault.sol";
import {UniswapFulfillmentVault} from "../../src/UniswapFulfillmentVault.sol";
import {RouterApproval} from "../../src/interfaces/IUniswapFulfillmentVault/RouterApproval.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev vm.setEnv writes process-global state; every var read by the script is set here so the
 * test does not depend on the shell's .env, and none of the HyperCore FULFILLMENT_VAULT_* vars is set.
 */
contract DeployAllUniswapScriptTest is BaseTest {
  uint256 public constant TEST_CHAIN_ID = 4663;

  DeployAllUniswapScript public script;
  MockPermit2 public permit2;
  address public universalRouter = makeAddr("universalRouter");
  address public swapRouter02 = makeAddr("swapRouter02");

  function setUp() public {
    setUpCore();
    permit2 = new MockPermit2();

    vm.setEnv("DEPLOYER_ADDRESS", vm.toString(admin));
    vm.setEnv("DEPLOYER_PRIVATE_KEY", "0");
    vm.setEnv("IS_TEST", "true");
    vm.setEnv("WRAPPED_NATIVE_TOKEN_ADDRESS", vm.toString(address(whype)));
    vm.setEnv("GENERAL_MANAGER_ADDRESS", vm.toString(address(generalManager)));
    vm.setEnv("SIMPLE_ORACLE_ADDRESS", vm.toString(address(0)));

    vm.setEnv("ROLLOVER_VAULT_NAME", "Rollover Vault");
    vm.setEnv("ROLLOVER_VAULT_SYMBOL", "RLV");
    vm.setEnv("ROLLOVER_VAULT_DECIMALS", "24");
    vm.setEnv("ROLLOVER_VAULT_DECIMALS_OFFSET", "6");
    vm.setEnv("ROLLOVER_VAULT_ADMIN_ADDRESS", vm.toString(admin));

    vm.setEnv("UNISWAP_FULFILLMENT_VAULT_NAME", "Uniswap Fulfillment Vault");
    vm.setEnv("UNISWAP_FULFILLMENT_VAULT_SYMBOL", "UFLV");
    vm.setEnv("UNISWAP_FULFILLMENT_VAULT_DECIMALS", "24");
    vm.setEnv("UNISWAP_FULFILLMENT_VAULT_DECIMALS_OFFSET", "6");
    vm.setEnv("UNISWAP_FULFILLMENT_VAULT_ADMIN_ADDRESS", vm.toString(admin));
    vm.setEnv("USDG_ADDRESS", vm.toString(address(usdt)));
    vm.setEnv("PERMIT2_ADDRESS", vm.toString(address(permit2)));
    vm.setEnv("ALLOWED_ROUTER_COUNT", "2");
    vm.setEnv("ALLOWED_ROUTER_0", vm.toString(universalRouter));
    vm.setEnv("ALLOWED_ROUTER_0_APPROVAL", "PERMIT2");
    vm.setEnv("ALLOWED_ROUTER_1", vm.toString(swapRouter02));
    vm.setEnv("ALLOWED_ROUTER_1_APPROVAL", "ERC20");

    script = new DeployAllUniswapScript();
    script.setUp();
  }

  function _addressesPath() internal view returns (string memory) {
    return string.concat(vm.projectRoot(), "/addresses/addresses-", vm.toString(TEST_CHAIN_ID), ".json");
  }

  function test_setUp_readsEnv() public view {
    assertEq(script.deployerAddress(), admin);
    assertEq(script.generalManagerAddress(), address(generalManager));
    assertEq(script.wrappedNativeTokenAddress(), address(whype));
    assertEq(script.simpleOracleAddress(), address(0));
    assertEq(script.usdgAddress(), address(usdt));
    assertEq(script.permit2Address(), address(permit2));
    assertEq(script.rolloverVaultAdminAddress(), admin);
    assertEq(script.uniswapFulfillmentVaultAdminAddress(), admin);
  }

  function test_deployRouter_revertsBeforeVaults() public {
    vm.expectRevert("Rollover vault not deployed");
    script.deployRouter();
  }

  function test_run_deploysStackAndWritesAddresses() public {
    vm.chainId(TEST_CHAIN_ID);
    string memory path = _addressesPath();
    assertFalse(vm.isFile(path));

    script.run();

    RolloverVault rolloverVault = script.rolloverVault();
    UniswapFulfillmentVault vault = script.uniswapFulfillmentVault();
    address router = address(script.router());
    assertTrue(address(rolloverVault) != address(0));
    assertTrue(address(vault) != address(0));
    assertTrue(router != address(0));

    // Rollover vault: admin holds keeper and admin
    assertTrue(rolloverVault.hasRole(rolloverVault.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(rolloverVault.hasRole(rolloverVault.KEEPER_ROLE(), admin));

    // Uniswap fulfillment vault: wiring and roles
    assertEq(vault.generalManager(), address(generalManager));
    assertEq(vault.usdx(), address(usdx));
    assertEq(vault.usdg(), address(usdt));
    assertEq(vault.permit2(), address(permit2));
    assertTrue(vault.routerApproval(universalRouter) == RouterApproval.Permit2);
    assertTrue(vault.routerApproval(swapRouter02) == RouterApproval.ERC20);
    assertTrue(vault.routerApproval(rando) == RouterApproval.None);
    assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(vault.hasRole(vault.KEEPER_ROLE(), admin));
    assertTrue(vault.hasRole(vault.WHITELIST_ROLE(), admin));

    // Router points at both vaults and holds its approvals
    assertEq(script.router().rolloverVault(), address(rolloverVault));
    assertEq(script.router().fulfillmentVault(), address(vault));
    assertEq(script.router().generalManager(), address(generalManager));
    assertEq(IERC20(address(whype)).allowance(router, address(generalManager)), type(uint256).max);
    assertEq(IERC20(address(ubtc)).allowance(router, address(generalManager)), type(uint256).max);
    assertEq(IERC20(address(usdt)).allowance(router, address(usdx)), type(uint256).max);
    assertEq(IERC20(address(usdc)).allowance(router, address(usdx)), type(uint256).max);

    // Address book carries the same three keys as the HyperCore stack
    string memory json = vm.readFile(path);
    assertEq(vm.parseJsonAddress(json, ".routerAddress"), router);
    assertEq(vm.parseJsonAddress(json, ".rolloverVaultAddress"), address(rolloverVault));
    assertEq(vm.parseJsonAddress(json, ".fulfillmentVaultAddress"), address(vault));
    vm.removeFile(path);
  }
}
