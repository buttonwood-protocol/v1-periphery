// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseScript} from "./BaseScript.s.sol";
import {console} from "forge-std/console.sol";
import {UniswapFulfillmentVault} from "../src/UniswapFulfillmentVault.sol";
import {RolloverVault} from "../src/RolloverVault.sol";
import {Roles} from "@core/libraries/Roles.sol";
import {IConsol} from "@core/interfaces/IConsol/IConsol.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Post-deploy configuration for a chain that fills on Uniswap: wires the UniswapFulfillmentVault
 * into the core stack and hands out the operational roles. Reads both address books for the current
 * chain. Every step is idempotent, so a partial run can be repeated.
 *
 * Env: KEEPER_ADDRESS (KEEPER_ROLE on both vaults), CONSOL_USDX_MAXIMUM_CAP (0 leaves the cap alone),
 * ADMIN_ADDRESS (PAUSE_ROLE holder; defaults to the deployer).
 */
contract ConfigureUniswapFulfillmentScript is BaseScript {
  address public keeperAddress;
  address public adminAddress;
  uint256 public consolUsdxMaximumCap;

  address public usdx;
  address public consol;
  address public orderPool;
  address[] public collaterals;
  address[] public pausables;
  UniswapFulfillmentVault public uniswapFulfillmentVault;
  RolloverVault public rolloverVault;

  function setUp() public virtual override {
    super.setUp();
    keeperAddress = vm.envAddress("KEEPER_ADDRESS");
    console.log("Keeper address: %s", keeperAddress);
    adminAddress = vm.envOr("ADMIN_ADDRESS", deployerAddress);
    console.log("Admin (PAUSE_ROLE) address: %s", adminAddress);
    consolUsdxMaximumCap = vm.envOr("CONSOL_USDX_MAXIMUM_CAP", uint256(0));
    console.log("Consol USDX maximum cap: %s", consolUsdxMaximumCap);
    readAddressBooks();
  }

  /// @dev The core book lives in the sibling core checkout, which is only present in the monorepo.
  /// Overridable, with its pair below, so a test can point at fixtures it owns.
  function coreAddressBookPath() public view virtual returns (string memory) {
    return string.concat(vm.projectRoot(), "/../contracts/addresses/addresses-", vm.toString(block.chainid), ".json");
  }

  function peripheryAddressBookPath() public view virtual returns (string memory) {
    return string.concat(vm.projectRoot(), "/addresses/addresses-", vm.toString(block.chainid), ".json");
  }

  function readAddressBooks() public {
    string memory core = vm.readFile(coreAddressBookPath());
    string memory periphery = vm.readFile(peripheryAddressBookPath());

    usdx = vm.parseJsonAddress(core, ".usdxAddress");
    consol = vm.parseJsonAddress(core, ".consolAddress");
    orderPool = vm.parseJsonAddress(core, ".orderPoolAddress");
    collaterals = vm.parseJsonAddressArray(core, ".collateralAddresses");
    pausables.push(vm.parseJsonAddress(core, ".generalManagerAddress"));
    pausables.push(vm.parseJsonAddress(core, ".forfeitedAssetsPoolAddress"));
    pausables.push(vm.parseJsonAddress(core, ".usdxQueue"));
    pausables.push(vm.parseJsonAddress(core, ".forfeitedAssetsQueue"));
    pausables.push(vm.parseJsonAddress(core, ".originationPoolSchedulerAddress"));
    address[] memory conversionQueues = vm.parseJsonAddressArray(core, ".conversionQueues");
    for (uint256 i = 0; i < conversionQueues.length; i++) {
      pausables.push(conversionQueues[i]);
    }

    uniswapFulfillmentVault =
      UniswapFulfillmentVault(payable(vm.parseJsonAddress(periphery, ".fulfillmentVaultAddress")));
    rolloverVault = RolloverVault(payable(vm.parseJsonAddress(periphery, ".rolloverVaultAddress")));

    require(uniswapFulfillmentVault.orderPool() == orderPool, "Vault order pool does not match the core address book");
    require(uniswapFulfillmentVault.usdx() == usdx, "Vault USDX does not match the core address book");
    console.log("Address books read: %s collaterals, %s pausable contracts", collaterals.length, pausables.length);
  }

  function run() public virtual override {
    startDeployerBroadcast();
    configureConsolCap();
    configureFulfillment();
    configurePauseRole();
    configureKeepers();
    vm.stopBroadcast();
    assertConfigured();
  }

  function configureConsolCap() public {
    if (consolUsdxMaximumCap == 0) {
      console.log("Consol USDX cap: unchanged");
      return;
    }
    if (IConsol(consol).maximumCap(usdx) == consolUsdxMaximumCap) {
      console.log("Consol USDX cap: already set");
      return;
    }
    IConsol(consol).setMaximumCap(usdx, consolUsdxMaximumCap);
    console.log("Consol USDX cap: set");
  }

  function configureFulfillment() public {
    address vault = address(uniswapFulfillmentVault);
    _grantIfMissing(orderPool, Roles.FULFILLMENT_ROLE, vault, "OrderPool FULFILLMENT_ROLE -> vault");
    _grantIfMissing(usdx, Roles.IGNORE_CAP_ROLE, vault, "USDX IGNORE_CAP_ROLE -> vault");
    for (uint256 i = 0; i < collaterals.length; i++) {
      _approveIfMissing(collaterals[i]);
    }
    _approveIfMissing(usdx);
  }

  function configurePauseRole() public {
    for (uint256 i = 0; i < pausables.length; i++) {
      _grantIfMissing(pausables[i], Roles.PAUSE_ROLE, adminAddress, "PAUSE_ROLE -> admin");
    }
  }

  function configureKeepers() public {
    _grantIfMissing(
      address(rolloverVault), rolloverVault.KEEPER_ROLE(), keeperAddress, "RolloverVault KEEPER_ROLE -> keeper"
    );
    _grantIfMissing(
      address(uniswapFulfillmentVault),
      uniswapFulfillmentVault.KEEPER_ROLE(),
      keeperAddress,
      "Vault KEEPER_ROLE -> keeper"
    );
  }

  /// @dev Re-reads everything after the broadcast so a silent miss fails the run.
  function assertConfigured() public view {
    address vault = address(uniswapFulfillmentVault);
    if (consolUsdxMaximumCap != 0) {
      require(IConsol(consol).maximumCap(usdx) == consolUsdxMaximumCap, "Consol USDX cap not set");
    }
    require(IAccessControl(orderPool).hasRole(Roles.FULFILLMENT_ROLE, vault), "FULFILLMENT_ROLE missing");
    require(IAccessControl(usdx).hasRole(Roles.IGNORE_CAP_ROLE, vault), "IGNORE_CAP_ROLE missing");
    for (uint256 i = 0; i < collaterals.length; i++) {
      require(IERC20(collaterals[i]).allowance(vault, orderPool) == type(uint256).max, "Collateral allowance missing");
    }
    require(IERC20(usdx).allowance(vault, orderPool) == type(uint256).max, "USDX allowance missing");
    for (uint256 i = 0; i < pausables.length; i++) {
      require(IAccessControl(pausables[i]).hasRole(Roles.PAUSE_ROLE, adminAddress), "PAUSE_ROLE missing");
    }
    require(rolloverVault.hasRole(rolloverVault.KEEPER_ROLE(), keeperAddress), "RolloverVault keeper missing");
    require(
      uniswapFulfillmentVault.hasRole(uniswapFulfillmentVault.KEEPER_ROLE(), keeperAddress), "Vault keeper missing"
    );
    console.log("Configuration verified");
  }

  function _grantIfMissing(address target, bytes32 role, address account, string memory label) internal {
    if (IAccessControl(target).hasRole(role, account)) {
      console.log("%s: already held (%s)", label, target);
      return;
    }
    IAccessControl(target).grantRole(role, account);
    console.log("%s: granted (%s)", label, target);
  }

  function _approveIfMissing(address asset) internal {
    if (IERC20(asset).allowance(address(uniswapFulfillmentVault), orderPool) == type(uint256).max) {
      console.log("Order pool approval: already max (%s)", asset);
      return;
    }
    uniswapFulfillmentVault.approveAssetToOrderPool(asset);
    console.log("Order pool approval: set (%s)", asset);
  }
}
