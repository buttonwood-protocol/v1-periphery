// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {Roles} from "@core/libraries/Roles.sol";
import {IGeneralManager} from "@core/interfaces/IGeneralManager/IGeneralManager.sol";
import {IOrderFulfillmentCallback} from "@core/interfaces/IOrderFulfillmentCallback.sol";
import {UniswapFulfillmentVault} from "../src/UniswapFulfillmentVault.sol";
import {RolloverVault} from "../src/RolloverVault.sol";

/**
 * @title PayFirstVaultUpgradeScript
 * @notice Upgrades the live RolloverVault and UniswapFulfillmentVault for fills through the general manager's
 *         fulfillment callback, signed by ADMIN_ADDRESS_0. Run after the core cutover. Entry points:
 *           run()            upgrades the RolloverVault (its shares freeze while the general manager is
 *                            executing), then the UniswapFulfillmentVault (adds fillOrderWithCallback).
 *           approveAssets()  approves every collateral and USDX to the general manager's current order pool.
 *           rollback()       upgrades both vault proxies back to their previous implementations.
 *         verify() is read-only and never broadcasts.
 * @dev The upgraded RolloverVault reads IGeneralManager.reentrancyGuardEntered on every share movement, which
 *      only the new general manager implementation answers: run() refuses to start before the core cutover,
 *      and rollback() must run before the core implementation is ever restored.
 *      Reads both address books for the current chain. Inputs:
 *        ADMIN_ADDRESS_0                                  the signer; DEFAULT_ADMIN_ROLE on both vaults
 *        PAY_FIRST_VAULT_IMPLEMENTATION                   logged by run(); required by verify()
 *        PAY_FIRST_VAULT_PREVIOUS_IMPLEMENTATION          logged by run(); required by rollback()
 *        PAY_FIRST_ROLLOVER_VAULT_IMPLEMENTATION          logged by run(); required by verify()
 *        PAY_FIRST_ROLLOVER_VAULT_PREVIOUS_IMPLEMENTATION logged by run(); required by rollback()
 */
contract PayFirstVaultUpgradeScript is Script {
  /// @dev ERC-1967 implementation slot
  bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
  /// @dev EIP-170 runtime size limit
  uint256 internal constant MAX_RUNTIME_SIZE = 24_576;

  /// @dev The fulfillment vault state an upgrade must leave untouched
  struct VaultState {
    address generalManager;
    address usdx;
    address usdg;
    address permit2;
    uint256 totalSupply;
    uint256 totalAssets;
    bool paused;
    bool whitelistEnforced;
    uint8 decimals;
  }

  /// @dev The rollover vault state an upgrade must leave untouched
  struct RolloverVaultState {
    address generalManager;
    address usdx;
    address consol;
    address[] originationPools;
    uint256 totalSupply;
    uint256 totalAssets;
    bool paused;
    bool whitelistEnforced;
    uint8 decimals;
  }

  address public admin;
  UniswapFulfillmentVault public vault;
  RolloverVault public rolloverVault;
  IGeneralManager public generalManager;
  address[] public assets;

  address public newImplementation;
  address public previousImplementation;
  address public newRolloverImplementation;
  address public previousRolloverImplementation;

  bool internal _deploymentPinned;
  string internal _coreAddressBookJson;
  string internal _peripheryAddressBookJson;

  /// @notice Pins the signer instead of reading ADMIN_ADDRESS_0.
  function setAdmin(address admin_) external {
    admin = admin_;
  }

  /// @notice Supplies both address book JSONs directly instead of reading the chain's files.
  function setAddressBookJsons(string memory core, string memory periphery) external {
    _coreAddressBookJson = core;
    _peripheryAddressBookJson = periphery;
  }

  /// @notice Pins what run() deployed instead of reading the PAY_FIRST_*VAULT_* variables.
  function setDeployment(
    address newImplementation_,
    address previousImplementation_,
    address newRolloverImplementation_,
    address previousRolloverImplementation_
  ) external {
    _deploymentPinned = true;
    newImplementation = newImplementation_;
    previousImplementation = previousImplementation_;
    newRolloverImplementation = newRolloverImplementation_;
    previousRolloverImplementation = previousRolloverImplementation_;
  }

  /// @dev The core book lives in the sibling core package, which is only present in the monorepo.
  function coreAddressBookPath() public view returns (string memory) {
    return string.concat(vm.projectRoot(), "/../contracts/addresses/addresses-", vm.toString(block.chainid), ".json");
  }

  function peripheryAddressBookPath() public view returns (string memory) {
    return string.concat(vm.projectRoot(), "/addresses/addresses-", vm.toString(block.chainid), ".json");
  }

  function setUp() public virtual {
    if (admin == address(0)) {
      admin = vm.envAddress("ADMIN_ADDRESS_0");
    }
    string memory core =
      bytes(_coreAddressBookJson).length != 0 ? _coreAddressBookJson : vm.readFile(coreAddressBookPath());
    string memory periphery = bytes(_peripheryAddressBookJson).length != 0
      ? _peripheryAddressBookJson
      : vm.readFile(peripheryAddressBookPath());
    generalManager = IGeneralManager(vm.parseJsonAddress(core, ".generalManagerAddress"));
    assets = vm.parseJsonAddressArray(core, ".collateralAddresses");
    require(assets.length != 0, "core address book has no collateralAddresses");
    // USDX is approved alongside the collaterals, as ConfigureUniswapFulfillment does at deploy
    assets.push(vm.parseJsonAddress(core, ".usdxAddress"));
    vault = UniswapFulfillmentVault(payable(vm.parseJsonAddress(periphery, ".fulfillmentVaultAddress")));
    rolloverVault = RolloverVault(payable(vm.parseJsonAddress(periphery, ".rolloverVaultAddress")));
    require(vault.generalManager() == address(generalManager), "vault is wired to another general manager");
    require(
      rolloverVault.generalManager() == address(generalManager), "rollover vault is wired to another general manager"
    );

    if (!_deploymentPinned) {
      newImplementation = vm.envOr("PAY_FIRST_VAULT_IMPLEMENTATION", address(0));
      previousImplementation = vm.envOr("PAY_FIRST_VAULT_PREVIOUS_IMPLEMENTATION", address(0));
      newRolloverImplementation = vm.envOr("PAY_FIRST_ROLLOVER_VAULT_IMPLEMENTATION", address(0));
      previousRolloverImplementation = vm.envOr("PAY_FIRST_ROLLOVER_VAULT_PREVIOUS_IMPLEMENTATION", address(0));
    }
  }

  /// @notice Deploys both implementations and upgrades the rollover vault, then the fulfillment vault.
  function run() public {
    _requireAdmin();
    _requireUpgradedGeneralManager();
    previousImplementation = _implementationOf(address(vault));
    previousRolloverImplementation = _implementationOf(address(rolloverVault));
    VaultState memory before = _state();
    RolloverVaultState memory rolloverBefore = _rolloverState();

    vm.startBroadcast(admin);
    newRolloverImplementation = address(new RolloverVault());
    rolloverVault.upgradeToAndCall(newRolloverImplementation, "");
    newImplementation = address(new UniswapFulfillmentVault());
    vault.upgradeToAndCall(newImplementation, "");
    vm.stopBroadcast();

    _checkUpgraded();
    _requireSameState(before, _state());
    _requireSameRolloverState(rolloverBefore, _rolloverState());
    console.log("Fulfillment vault: %s", address(vault));
    console.log("Rollover vault: %s", address(rolloverVault));
    console.log("Record these, then run approveAssets():");
    console.log(string.concat("  PAY_FIRST_VAULT_IMPLEMENTATION=", vm.toString(newImplementation)));
    console.log(string.concat("  PAY_FIRST_VAULT_PREVIOUS_IMPLEMENTATION=", vm.toString(previousImplementation)));
    console.log(string.concat("  PAY_FIRST_ROLLOVER_VAULT_IMPLEMENTATION=", vm.toString(newRolloverImplementation)));
    console.log(
      string.concat("  PAY_FIRST_ROLLOVER_VAULT_PREVIOUS_IMPLEMENTATION=", vm.toString(previousRolloverImplementation))
    );
    console.log("  Fulfillment vault implementation runtime size: %s", newImplementation.code.length);
    console.log("  Rollover vault implementation runtime size: %s", newRolloverImplementation.code.length);
  }

  /// @notice Approves every collateral and USDX to the general manager's current order pool, skipping those already approved.
  function approveAssets() public {
    address orderPool = generalManager.orderPool();
    console.log("Order pool: %s", orderPool);
    uint256 sent;
    vm.startBroadcast(admin);
    for (uint256 i = 0; i < assets.length; i++) {
      if (IERC20(assets[i]).allowance(address(vault), orderPool) != type(uint256).max) {
        vault.approveAssetToOrderPool(assets[i]);
        sent++;
      }
    }
    vm.stopBroadcast();
    _checkApprovals();
    console.log("Assets: %s, approvals sent: %s", assets.length, sent);
  }

  /// @notice Upgrades both vault proxies back to their previous implementations, the fulfillment vault first.
  function rollback() public {
    _requireAdmin();
    require(previousImplementation.code.length != 0, "PAY_FIRST_VAULT_PREVIOUS_IMPLEMENTATION has no code");
    require(
      previousRolloverImplementation.code.length != 0, "PAY_FIRST_ROLLOVER_VAULT_PREVIOUS_IMPLEMENTATION has no code"
    );
    VaultState memory before = _state();
    RolloverVaultState memory rolloverBefore = _rolloverState();

    vm.startBroadcast(admin);
    if (_implementationOf(address(vault)) != previousImplementation) {
      vault.upgradeToAndCall(previousImplementation, "");
    }
    if (_implementationOf(address(rolloverVault)) != previousRolloverImplementation) {
      rolloverVault.upgradeToAndCall(previousRolloverImplementation, "");
    }
    vm.stopBroadcast();

    require(_implementationOf(address(vault)) == previousImplementation, "previous vault implementation not restored");
    require(
      _implementationOf(address(rolloverVault)) == previousRolloverImplementation,
      "previous rollover vault implementation not restored"
    );
    _requireSameState(before, _state());
    _requireSameRolloverState(rolloverBefore, _rolloverState());
    console.log("Fulfillment vault rolled back to implementation: %s", previousImplementation);
    console.log("Rollover vault rolled back to implementation: %s", previousRolloverImplementation);
  }

  /// @notice Read-only check that both vaults are upgraded and the fulfillment vault is wired to the general
  ///         manager's order pool. Never broadcasts.
  function verify() public view {
    _requireUpgradedGeneralManager();
    _checkUpgraded();
    _checkApprovals();
    address orderPool = generalManager.orderPool();
    require(
      IAccessControl(orderPool).hasRole(Roles.FULFILLMENT_ROLE, address(vault)),
      "vault lacks FULFILLMENT_ROLE on the order pool"
    );
    require(
      IAccessControl(vault.usdx()).hasRole(Roles.IGNORE_CAP_ROLE, address(vault)), "vault lacks IGNORE_CAP_ROLE on USDX"
    );
    console.log("Fulfillment vault: %s", address(vault));
    console.log("  implementation: %s", newImplementation);
    console.log("  implementation runtime size: %s", newImplementation.code.length);
    console.log("  order pool: %s", orderPool);
    console.log("  assets approved: %s", assets.length);
    console.log("  USDX balance: %s", IERC20(vault.usdx()).balanceOf(address(vault)));
    console.log("  paused: %s", vault.paused());
    console.log("Rollover vault: %s", address(rolloverVault));
    console.log("  implementation: %s", newRolloverImplementation);
    console.log("  total assets: %s", rolloverVault.totalAssets());
    console.log("  paused: %s", rolloverVault.paused());
    console.log("Verified the pay-first vault upgrades");
  }

  function assetCount() external view returns (uint256) {
    return assets.length;
  }

  function _requireAdmin() internal view {
    require(address(vault).code.length != 0, "fulfillmentVaultAddress has no code");
    require(address(rolloverVault).code.length != 0, "rolloverVaultAddress has no code");
    require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "ADMIN_ADDRESS_0 lacks DEFAULT_ADMIN_ROLE on the vault");
    require(
      rolloverVault.hasRole(rolloverVault.DEFAULT_ADMIN_ROLE(), admin),
      "ADMIN_ADDRESS_0 lacks DEFAULT_ADMIN_ROLE on the rollover vault"
    );
  }

  /// @dev The upgraded rollover vault cannot move shares against a general manager that lacks this view
  function _requireUpgradedGeneralManager() internal view {
    try generalManager.reentrancyGuardEntered() returns (bool entered) {
      require(!entered, "general manager reports an entered reentrancy guard");
    } catch {
      revert("general manager is not upgraded; run the core cutover first");
    }
  }

  function _checkUpgraded() internal view {
    _checkImplementation(address(vault), newImplementation, "PAY_FIRST_VAULT_IMPLEMENTATION");
    _checkImplementation(address(rolloverVault), newRolloverImplementation, "PAY_FIRST_ROLLOVER_VAULT_IMPLEMENTATION");
    require(
      IERC165(address(vault)).supportsInterface(type(IOrderFulfillmentCallback).interfaceId),
      "vault does not implement the fulfillment callback"
    );
  }

  function _checkImplementation(address proxy, address implementation, string memory name) internal view {
    require(implementation.code.length != 0, string.concat(name, " has no code"));
    require(implementation.code.length <= MAX_RUNTIME_SIZE, string.concat(name, " exceeds the EIP-170 limit"));
    require(
      IERC1822Proxiable(implementation).proxiableUUID() == IMPLEMENTATION_SLOT,
      string.concat(name, " is not a UUPS implementation")
    );
    require(_implementationOf(proxy) == implementation, string.concat("proxy is not on ", name));
  }

  function _checkApprovals() internal view {
    address orderPool = generalManager.orderPool();
    for (uint256 i = 0; i < assets.length; i++) {
      require(
        IERC20(assets[i]).allowance(address(vault), orderPool) == type(uint256).max,
        "an asset is not approved to the order pool"
      );
    }
  }

  function _implementationOf(address proxy) internal view returns (address) {
    return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
  }

  function _state() internal view returns (VaultState memory) {
    return VaultState({
      generalManager: vault.generalManager(),
      usdx: vault.usdx(),
      usdg: vault.usdg(),
      permit2: vault.permit2(),
      totalSupply: vault.totalSupply(),
      totalAssets: vault.totalAssets(),
      paused: vault.paused(),
      whitelistEnforced: vault.whitelistEnforced(),
      decimals: vault.decimals()
    });
  }

  function _rolloverState() internal view returns (RolloverVaultState memory) {
    return RolloverVaultState({
      generalManager: rolloverVault.generalManager(),
      usdx: rolloverVault.usdx(),
      consol: rolloverVault.consol(),
      originationPools: rolloverVault.originationPools(),
      totalSupply: rolloverVault.totalSupply(),
      totalAssets: rolloverVault.totalAssets(),
      paused: rolloverVault.paused(),
      whitelistEnforced: rolloverVault.whitelistEnforced(),
      decimals: rolloverVault.decimals()
    });
  }

  function _requireSameState(VaultState memory a, VaultState memory b) internal pure {
    require(keccak256(abi.encode(a)) == keccak256(abi.encode(b)), "vault state changed");
  }

  function _requireSameRolloverState(RolloverVaultState memory a, RolloverVaultState memory b) internal pure {
    require(keccak256(abi.encode(a)) == keccak256(abi.encode(b)), "rollover vault state changed");
  }
}
