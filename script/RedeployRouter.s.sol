// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseScript} from "./BaseScript.s.sol";
import {console} from "forge-std/console.sol";
import {Router} from "../src/Router.sol";

/**
 * @notice Replaces the Router on a chain that already runs the full stack. Every constructor input comes from the
 * chain's address books, the new Router is checked field-by-field against the one it replaces, and its address is
 * printed. The address books are left untouched.
 *
 * Env: DEPLOYER_ADDRESS (the broadcasting wallet), DEPLOYER_PRIVATE_KEY (optional; otherwise the CLI wallet signs).
 */
contract RedeployRouterScript is BaseScript {
  address public oldRouterAddress;
  address public rolloverVaultAddress;
  address public fulfillmentVaultAddress;
  Router public oldRouter;
  Router public router;

  function setUp() public virtual override {
    deployerAddress = vm.envAddress("DEPLOYER_ADDRESS");
    console.log("Deployer address: %s", deployerAddress);
    deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
    if (deployerPrivateKey != 0) {
      require(deployerAddress == vm.addr(deployerPrivateKey), "Deployer address and private key do not match");
    }
    readAddressBooks();
  }

  /// @dev The core book lives in the sibling core checkout, which is only present in the monorepo.
  function coreAddressBookPath() public view virtual returns (string memory) {
    return string.concat(vm.projectRoot(), "/../contracts/addresses/addresses-", vm.toString(block.chainid), ".json");
  }

  function peripheryAddressBookPath() public view virtual returns (string memory) {
    return string.concat(vm.projectRoot(), "/addresses/addresses-", vm.toString(block.chainid), ".json");
  }

  function readAddressBooks() public {
    string memory core = vm.readFile(coreAddressBookPath());
    string memory periphery = vm.readFile(peripheryAddressBookPath());

    wrappedNativeTokenAddress = vm.parseJsonAddress(core, ".nativeWrapper");
    generalManagerAddress = vm.parseJsonAddress(core, ".generalManagerAddress");
    // Absent on chains whose oracles are read on-chain
    simpleOracleAddress =
      vm.keyExistsJson(core, ".simpleOracleAddress") ? vm.parseJsonAddress(core, ".simpleOracleAddress") : address(0);
    rolloverVaultAddress = vm.parseJsonAddress(periphery, ".rolloverVaultAddress");
    fulfillmentVaultAddress = vm.parseJsonAddress(periphery, ".fulfillmentVaultAddress");
    oldRouterAddress = vm.parseJsonAddress(periphery, ".routerAddress");
    oldRouter = Router(payable(oldRouterAddress));

    console.log("Wrapped native token address: %s", wrappedNativeTokenAddress);
    console.log("General manager address: %s", generalManagerAddress);
    console.log("Simple oracle address: %s", simpleOracleAddress);
    console.log("Rollover vault address: %s", rolloverVaultAddress);
    console.log("Fulfillment vault address: %s", fulfillmentVaultAddress);
    console.log("Old router address: %s", oldRouterAddress);
  }

  function run() public virtual override {
    startDeployerBroadcast();
    router = new Router(
      wrappedNativeTokenAddress,
      generalManagerAddress,
      rolloverVaultAddress,
      fulfillmentVaultAddress,
      simpleOracleAddress
    );
    router.approveCollaterals();
    router.approveUsdTokens();
    vm.stopBroadcast();

    assertMatchesOldRouter();
    console.log("New router address: %s", address(router));
  }

  /// @dev The replacement must point at exactly the contracts the old router does.
  function assertMatchesOldRouter() public view {
    require(oldRouterAddress.code.length > 0, "Old router has no code");
    require(router.usdx() == oldRouter.usdx(), "usdx mismatch");
    require(router.consol() == oldRouter.consol(), "consol mismatch");
    require(router.generalManager() == oldRouter.generalManager(), "generalManager mismatch");
    require(router.rolloverVault() == oldRouter.rolloverVault(), "rolloverVault mismatch");
    require(router.fulfillmentVault() == oldRouter.fulfillmentVault(), "fulfillmentVault mismatch");
    require(
      router.originationPoolScheduler() == oldRouter.originationPoolScheduler(), "originationPoolScheduler mismatch"
    );
    require(router.wrappedNativeToken() == oldRouter.wrappedNativeToken(), "wrappedNativeToken mismatch");
    require(router.simpleOracle() == oldRouter.simpleOracle(), "simpleOracle mismatch");
  }
}
