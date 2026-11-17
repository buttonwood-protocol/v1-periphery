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

/**
 * @title PayFirstVaultUpgradeScript
 * @notice Upgrades a live UniswapFulfillmentVault to the implementation that fills through the general
 *         manager's fulfillment callback, signed by ADMIN_ADDRESS_0. Entry points:
 *           run()                 deploys the implementation and upgrades the vault proxy to it. fillOrder is
 *                                 unchanged, so this can go out before the core cutover.
 *           approveAssets()       approves every collateral and USDX to the general manager's current order
 *                                 pool. Run it after the core cutover, which changes that order pool.
 *           rollback()            upgrades the vault proxy back to the previous implementation.
 *         verify() is read-only and never broadcasts.
 * @dev Reads both address books for the current chain. Inputs:
 *        ADMIN_ADDRESS_0                         the signer; DEFAULT_ADMIN_ROLE on the vault
 *        PAY_FIRST_VAULT_IMPLEMENTATION          logged by run(); required by verify()
 *        PAY_FIRST_VAULT_PREVIOUS_IMPLEMENTATION logged by run(); required by rollback()
 */
contract PayFirstVaultUpgradeScript is Script {
  /// @dev ERC-1967 implementation slot
  bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
  /// @dev EIP-170 runtime size limit
  uint256 internal constant MAX_RUNTIME_SIZE = 24_576;

  /// @dev The vault state an upgrade must leave untouched
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

  address public admin;
  UniswapFulfillmentVault public vault;
  IGeneralManager public generalManager;
  address[] public assets;

  address public newImplementation;
  address public previousImplementation;

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

  /// @notice Pins what run() deployed instead of reading the PAY_FIRST_VAULT_* variables.
  function setDeployment(address newImplementation_, address previousImplementation_) external {
    _deploymentPinned = true;
    newImplementation = newImplementation_;
    previousImplementation = previousImplementation_;
  }

  /// @dev The core book lives in the sibling core checkout, which is only present in the monorepo.
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
    require(vault.generalManager() == address(generalManager), "vault is wired to another general manager");

    if (!_deploymentPinned) {
      newImplementation = vm.envOr("PAY_FIRST_VAULT_IMPLEMENTATION", address(0));
      previousImplementation = vm.envOr("PAY_FIRST_VAULT_PREVIOUS_IMPLEMENTATION", address(0));
    }
  }

  /// @notice Deploys the new implementation and upgrades the vault proxy to it.
  function run() public {
    _requireAdmin();
    previousImplementation = _implementation();
    VaultState memory before = _state();

    vm.startBroadcast(admin);
    newImplementation = address(new UniswapFulfillmentVault());
    vault.upgradeToAndCall(newImplementation, "");
    vm.stopBroadcast();

    _checkUpgraded();
    _requireSameState(before, _state());
    console.log("Vault: %s", address(vault));
    console.log("Record these, then run approveAssets() after the core cutover:");
    console.log(string.concat("  PAY_FIRST_VAULT_IMPLEMENTATION=", vm.toString(newImplementation)));
    console.log(string.concat("  PAY_FIRST_VAULT_PREVIOUS_IMPLEMENTATION=", vm.toString(previousImplementation)));
    console.log("  Vault implementation runtime size: %s", newImplementation.code.length);
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

  /// @notice Upgrades the vault proxy back to the previous implementation.
  function rollback() public {
    _requireAdmin();
    require(previousImplementation.code.length != 0, "PAY_FIRST_VAULT_PREVIOUS_IMPLEMENTATION has no code");
    require(_implementation() != previousImplementation, "vault is already on the previous implementation");
    VaultState memory before = _state();

    vm.startBroadcast(admin);
    vault.upgradeToAndCall(previousImplementation, "");
    vm.stopBroadcast();

    require(_implementation() == previousImplementation, "previous implementation was not restored");
    _requireSameState(before, _state());
    console.log("Vault rolled back to implementation: %s", previousImplementation);
  }

  /// @notice Read-only check that the vault is upgraded and wired to the general manager's order pool. Never broadcasts.
  function verify() public view {
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
    console.log("Vault: %s", address(vault));
    console.log("  implementation: %s", newImplementation);
    console.log("  implementation runtime size: %s", newImplementation.code.length);
    console.log("  order pool: %s", orderPool);
    console.log("  assets approved: %s", assets.length);
    console.log("  USDX balance: %s", IERC20(vault.usdx()).balanceOf(address(vault)));
    console.log("  paused: %s", vault.paused());
    console.log("Verified the pay-first vault upgrade");
  }

  function assetCount() external view returns (uint256) {
    return assets.length;
  }

  function _requireAdmin() internal view {
    require(address(vault).code.length != 0, "fulfillmentVaultAddress has no code");
    require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "ADMIN_ADDRESS_0 lacks DEFAULT_ADMIN_ROLE on the vault");
  }

  function _checkUpgraded() internal view {
    require(newImplementation.code.length != 0, "PAY_FIRST_VAULT_IMPLEMENTATION has no code");
    require(newImplementation.code.length <= MAX_RUNTIME_SIZE, "vault implementation exceeds the EIP-170 limit");
    require(
      IERC1822Proxiable(newImplementation).proxiableUUID() == IMPLEMENTATION_SLOT,
      "PAY_FIRST_VAULT_IMPLEMENTATION is not a UUPS implementation"
    );
    require(_implementation() == newImplementation, "vault is not on the new implementation");
    require(
      IERC165(address(vault)).supportsInterface(type(IOrderFulfillmentCallback).interfaceId),
      "vault does not implement the fulfillment callback"
    );
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

  function _implementation() internal view returns (address) {
    return address(uint160(uint256(vm.load(address(vault), IMPLEMENTATION_SLOT))));
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

  function _requireSameState(VaultState memory a, VaultState memory b) internal pure {
    require(keccak256(abi.encode(a)) == keccak256(abi.encode(b)), "vault state changed");
  }
}
