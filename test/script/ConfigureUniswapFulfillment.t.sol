// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.t.sol";
import {ConfigureUniswapFulfillmentScript} from "../../script/ConfigureUniswapFulfillment.s.sol";
import {DeployRolloverVaultScript} from "../../script/DeployRolloverVault.s.sol";
import {DeployUniswapFulfillmentVaultScript} from "../../script/DeployUniswapFulfillmentVault.s.sol";
import {RolloverVault} from "../../src/RolloverVault.sol";
import {UniswapFulfillmentVault} from "../../src/UniswapFulfillmentVault.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {ForfeitedAssetsQueue} from "@core/ForfeitedAssetsQueue.sol";
import {UsdxQueue} from "@core/UsdxQueue.sol";
import {Roles} from "@core/libraries/Roles.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Reads both books from fixtures the test owns: the core book the script reads in production
/// lives in the sibling core checkout, which is not part of this repo's checkout, and the periphery
/// book is a tracked file the suite must not leave rewritten.
contract ConfigureUniswapFulfillmentHarness is ConfigureUniswapFulfillmentScript {
  string internal corePath;
  string internal peripheryPath;

  constructor(string memory corePath_, string memory peripheryPath_) {
    corePath = corePath_;
    peripheryPath = peripheryPath_;
  }

  function coreAddressBookPath() public view override returns (string memory) {
    return corePath;
  }

  function peripheryAddressBookPath() public view override returns (string memory) {
    return peripheryPath;
  }
}

/**
 * @dev vm.setEnv writes process-global state; every var read by the deploy and configure scripts is
 * set here so the test does not depend on the shell's .env.
 */
contract ConfigureUniswapFulfillmentScriptTest is BaseTest {
  uint256 public constant TEST_CHAIN_ID = 4663;
  uint256 public constant USDX_CAP = 1_000_000e18;

  bytes32 internal constant ROLE_GRANTED = keccak256("RoleGranted(bytes32,address,address)");
  bytes32 internal constant APPROVAL = keccak256("Approval(address,address,uint256)");
  bytes32 internal constant MAXIMUM_CAP_SET = keccak256("MaximumCapSet(address,uint256)");

  DeployRolloverVaultScript public rolloverVaultScript;
  DeployUniswapFulfillmentVaultScript public vaultScript;
  ConfigureUniswapFulfillmentHarness public script;
  MockPermit2 public permit2;

  UsdxQueue public usdxQueue;
  ForfeitedAssetsQueue public forfeitedAssetsQueue;

  RolloverVault public deployedRolloverVault;
  UniswapFulfillmentVault public vault;

  address public pauseAdmin = makeAddr("pauseAdmin");
  address public universalRouter = makeAddr("universalRouter");
  address public swapRouter02 = makeAddr("swapRouter02");

  function setUp() public {
    setUpCore();
    permit2 = new MockPermit2();
    usdxQueue = new UsdxQueue(address(usdx), address(consol), admin);
    forfeitedAssetsQueue = new ForfeitedAssetsQueue(address(forfeitedAssetsPool), address(consol), admin);

    _setDeployEnv();
    vm.setEnv("KEEPER_ADDRESS", vm.toString(keeper));
    vm.setEnv("ADMIN_ADDRESS", vm.toString(pauseAdmin));
    vm.setEnv("CONSOL_USDX_MAXIMUM_CAP", vm.toString(USDX_CAP));

    vm.chainId(TEST_CHAIN_ID);

    // The per-vault scripts write no address book, so this suite never touches the tracked one that
    // DeployAllUniswap's own test snapshots and restores
    rolloverVaultScript = new DeployRolloverVaultScript();
    rolloverVaultScript.setUp();
    rolloverVaultScript.run();
    deployedRolloverVault = rolloverVaultScript.rolloverVault();

    vaultScript = new DeployUniswapFulfillmentVaultScript();
    vaultScript.setUp();
    vaultScript.run();
    vault = vaultScript.uniswapFulfillmentVault();

    _writePeripheryFixture();
    _writeCoreFixture();
    script = new ConfigureUniswapFulfillmentHarness(_coreFixturePath(), _peripheryFixturePath());
    script.setUp();
  }

  function test_setUp_readsBothBooks() public view {
    assertEq(script.keeperAddress(), keeper);
    assertEq(script.adminAddress(), pauseAdmin);
    assertEq(script.consolUsdxMaximumCap(), USDX_CAP);
    assertEq(script.usdx(), address(usdx));
    assertEq(script.consol(), address(consol));
    assertEq(script.orderPool(), address(orderPool));
    assertEq(address(script.uniswapFulfillmentVault()), address(vault));
    assertEq(address(script.rolloverVault()), address(deployedRolloverVault));
  }

  function test_run_configuresStack() public {
    assertFalse(IAccessControl(address(orderPool)).hasRole(Roles.FULFILLMENT_ROLE, address(vault)));
    assertEq(consol.maximumCap(address(usdx)), type(uint256).max);

    script.run();

    assertEq(consol.maximumCap(address(usdx)), USDX_CAP);
    assertTrue(IAccessControl(address(orderPool)).hasRole(Roles.FULFILLMENT_ROLE, address(vault)));
    assertTrue(IAccessControl(address(usdx)).hasRole(Roles.IGNORE_CAP_ROLE, address(vault)));

    assertEq(IERC20(address(whype)).allowance(address(vault), address(orderPool)), type(uint256).max);
    assertEq(IERC20(address(ubtc)).allowance(address(vault), address(orderPool)), type(uint256).max);
    assertEq(IERC20(address(usdx)).allowance(address(vault), address(orderPool)), type(uint256).max);

    address[7] memory pausables = [
      address(generalManager),
      address(forfeitedAssetsPool),
      address(usdxQueue),
      address(forfeitedAssetsQueue),
      address(originationPoolScheduler),
      address(whypeConversionQueue),
      address(ubtcConversionQueue)
    ];
    for (uint256 i = 0; i < pausables.length; i++) {
      assertTrue(IAccessControl(pausables[i]).hasRole(Roles.PAUSE_ROLE, pauseAdmin));
    }

    assertTrue(deployedRolloverVault.hasRole(deployedRolloverVault.KEEPER_ROLE(), keeper));
    assertTrue(vault.hasRole(vault.KEEPER_ROLE(), keeper));

    // Re-reads the chain rather than the script's own bookkeeping
    script.assertConfigured();
  }

  function test_run_secondRunIsIdempotent() public {
    vm.recordLogs();
    script.run();
    (uint256 grants, uint256 approvals, uint256 caps) = _countWrites(vm.getRecordedLogs());
    // FULFILLMENT_ROLE, IGNORE_CAP_ROLE, PAUSE_ROLE on 7 contracts, KEEPER_ROLE on both vaults
    assertEq(grants, 11);
    // Both collaterals and USDX
    assertEq(approvals, 3);
    assertEq(caps, 1);

    vm.recordLogs();
    script.run();
    (grants, approvals, caps) = _countWrites(vm.getRecordedLogs());
    assertEq(grants, 0);
    assertEq(approvals, 0);
    assertEq(caps, 0);

    script.assertConfigured();
  }

  function test_run_zeroCapLeavesConsolCapUntouched() public {
    vm.setEnv("CONSOL_USDX_MAXIMUM_CAP", "0");
    ConfigureUniswapFulfillmentHarness zeroCapScript =
      new ConfigureUniswapFulfillmentHarness(_coreFixturePath(), _peripheryFixturePath());
    zeroCapScript.setUp();
    assertEq(zeroCapScript.consolUsdxMaximumCap(), 0);

    uint256 capBefore = consol.maximumCap(address(usdx));
    assertEq(capBefore, type(uint256).max);

    vm.recordLogs();
    zeroCapScript.run();
    (,, uint256 caps) = _countWrites(vm.getRecordedLogs());

    assertEq(caps, 0);
    assertEq(consol.maximumCap(address(usdx)), capBefore);
  }

  function test_setUp_revertsWhenVaultOrderPoolMismatches() public {
    vm.mockCall(address(vault), abi.encodeWithSelector(UniswapFulfillmentVault.orderPool.selector), abi.encode(rando));
    ConfigureUniswapFulfillmentHarness mismatched =
      new ConfigureUniswapFulfillmentHarness(_coreFixturePath(), _peripheryFixturePath());

    vm.expectRevert("Vault order pool does not match the core address book");
    mismatched.setUp();
  }

  function test_setUp_revertsWhenVaultUsdxMismatches() public {
    vm.mockCall(address(vault), abi.encodeWithSelector(UniswapFulfillmentVault.usdx.selector), abi.encode(rando));
    ConfigureUniswapFulfillmentHarness mismatched =
      new ConfigureUniswapFulfillmentHarness(_coreFixturePath(), _peripheryFixturePath());

    vm.expectRevert("Vault USDX does not match the core address book");
    mismatched.setUp();
  }

  function _countWrites(Vm.Log[] memory logs) internal pure returns (uint256 grants, uint256 approvals, uint256 caps) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == ROLE_GRANTED) grants++;
      if (logs[i].topics[0] == APPROVAL) approvals++;
      if (logs[i].topics[0] == MAXIMUM_CAP_SET) caps++;
    }
  }

  function _setDeployEnv() internal {
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
  }

  function _coreFixturePath() internal view returns (string memory) {
    return string.concat(vm.projectRoot(), "/addresses/tests/core-addresses-", vm.toString(TEST_CHAIN_ID), ".json");
  }

  function _peripheryFixturePath() internal view returns (string memory) {
    return string.concat(vm.projectRoot(), "/addresses/tests/periphery-addresses-", vm.toString(TEST_CHAIN_ID), ".json");
  }

  /// @dev Only the keys the script reads.
  function _writePeripheryFixture() internal {
    string memory obj = "periphery";
    vm.serializeAddress(obj, "rolloverVaultAddress", address(deployedRolloverVault));
    string memory json = vm.serializeAddress(obj, "fulfillmentVaultAddress", address(vault));
    _write(_peripheryFixturePath(), json);
  }

  /// @dev Only the keys the script reads.
  function _writeCoreFixture() internal {
    address[] memory collaterals = new address[](2);
    collaterals[0] = address(whype);
    collaterals[1] = address(ubtc);
    address[] memory conversionQueues = new address[](2);
    conversionQueues[0] = address(whypeConversionQueue);
    conversionQueues[1] = address(ubtcConversionQueue);

    string memory obj = "core";
    vm.serializeAddress(obj, "usdxAddress", address(usdx));
    vm.serializeAddress(obj, "consolAddress", address(consol));
    vm.serializeAddress(obj, "orderPoolAddress", address(orderPool));
    vm.serializeAddress(obj, "generalManagerAddress", address(generalManager));
    vm.serializeAddress(obj, "forfeitedAssetsPoolAddress", address(forfeitedAssetsPool));
    vm.serializeAddress(obj, "usdxQueue", address(usdxQueue));
    vm.serializeAddress(obj, "forfeitedAssetsQueue", address(forfeitedAssetsQueue));
    vm.serializeAddress(obj, "originationPoolSchedulerAddress", address(originationPoolScheduler));
    vm.serializeAddress(obj, "collateralAddresses", collaterals);
    string memory json = vm.serializeAddress(obj, "conversionQueues", conversionQueues);

    _write(_coreFixturePath(), json);
  }

  function _write(string memory path, string memory json) internal {
    if (vm.isFile(path)) {
      vm.removeFile(path);
    }
    vm.writeFile(path, json);
  }
}
