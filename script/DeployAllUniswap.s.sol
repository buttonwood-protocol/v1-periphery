// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {DeployRolloverVaultScript} from "./DeployRolloverVault.s.sol";
import {DeployUniswapFulfillmentVaultScript} from "./DeployUniswapFulfillmentVault.s.sol";
import {Router} from "../src/Router.sol";

/**
 * @notice Deploys the periphery stack for chains whose orders fill on Uniswap: RolloverVault,
 * UniswapFulfillmentVault, and a Router pointed at both. The HyperCore FulfillmentVault and its
 * env vars are not involved.
 */
contract DeployAllUniswapScript is DeployRolloverVaultScript, DeployUniswapFulfillmentVaultScript {
  Router public router;

  function setUp() public virtual override(DeployRolloverVaultScript, DeployUniswapFulfillmentVaultScript) {
    super.setUp();
  }

  function run() public virtual override(DeployRolloverVaultScript, DeployUniswapFulfillmentVaultScript) {
    startDeployerBroadcast();
    deployRolloverVault();
    deployUniswapFulfillmentVault();
    deployRouter();
    logAddresses();
    vm.stopBroadcast();
  }

  function deployRouter() public {
    if (address(rolloverVault) == address(0)) {
      revert("Rollover vault not deployed");
    }
    if (address(uniswapFulfillmentVault) == address(0)) {
      revert("Uniswap fulfillment vault not deployed");
    }
    router = new Router(
      wrappedNativeTokenAddress,
      generalManagerAddress,
      address(rolloverVault),
      address(uniswapFulfillmentVault),
      simpleOracleAddress
    );
    router.approveCollaterals();
    router.approveUsdTokens();
  }

  function logRouter(string memory objectKey) public returns (string memory json) {
    json = vm.serializeAddress(objectKey, "routerAddress", address(router));
  }

  /// @dev Writes the same keys as the HyperCore DeployAll so the address book reads both stacks alike:
  /// `fulfillmentVaultAddress` is the UniswapFulfillmentVault proxy.
  function logAddresses() public {
    uint256 chainId = block.chainid;
    string memory root = vm.projectRoot();
    string memory path = string.concat(root, "/addresses/addresses-", vm.toString(chainId), ".json");
    string memory obj = "key";
    string memory json;
    if (vm.isFile(path)) {
      vm.removeFile(path);
    }
    json = logRouter(obj);
    json = logRolloverVault(obj);
    json = vm.serializeAddress(obj, "fulfillmentVaultAddress", address(uniswapFulfillmentVault));
    vm.writeJson(json, path);
  }
}
