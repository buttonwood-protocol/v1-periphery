// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ILiquidityVault} from "../ILiquidityVault/ILiquidityVault.sol";
import {IUniswapFulfillmentVaultEvents} from "./IUniswapFulfillmentVaultEvents.sol";
import {IUniswapFulfillmentVaultErrors} from "./IUniswapFulfillmentVaultErrors.sol";
import {RouterApproval} from "./RouterApproval.sol";

/**
 * @title IUniswapFulfillmentVault
 * @author @SocksNFlops
 * @notice Interface for UniswapFulfillmentVault, a vault that fulfills purchase orders atomically by swapping USDG for collateral on an allowlisted on-chain venue.
 */
interface IUniswapFulfillmentVault is ILiquidityVault, IUniswapFulfillmentVaultEvents, IUniswapFulfillmentVaultErrors {
  /**
   * @notice Gets the address of the general manager
   * @return The address of the general manager
   */
  function generalManager() external view returns (address);

  /**
   * @notice Gets the address of the order pool
   * @return The address of the order pool
   */
  function orderPool() external view returns (address);

  /**
   * @notice Gets the address of the USDX token
   * @return The address of the USDX token
   */
  function usdx() external view returns (address);

  /**
   * @notice Gets the address of the USDG token (the USDX supported token used for the swap leg)
   * @return The address of the USDG token
   */
  function usdg() external view returns (address);

  /**
   * @notice Gets the address of the Permit2 contract used for Permit2-mode routers
   * @return The address of the Permit2 contract
   */
  function permit2() external view returns (address);

  /**
   * @notice Gets the approval mode a swap router is allowed under
   * @param router The address of the router
   * @return The approval mode. None means the router is not allowed.
   */
  function routerApproval(address router) external view returns (RouterApproval);

  /**
   * @notice Checks whether a swap router is on the allowlist
   * @param router The address of the router
   * @return Whether the router is allowed (its approval mode is not None)
   */
  function isAllowedRouter(address router) external view returns (bool);

  /**
   * @notice Sets the approval mode a swap router is allowed under. None disallows the router.
   * @param router The address of the router
   * @param approval The approval mode for the router
   */
  function setRouterApproval(address router, RouterApproval approval) external;

  /**
   * @notice Approves an asset to the order pool
   * @param asset The address of the asset to approve
   */
  function approveAssetToOrderPool(address asset) external;

  /**
   * @notice Fills an order from the order pool by swapping USDG for the order's collateral through an allowlisted router. Expired orders are swept (cancelled and refunded) without swapping.
   * @param index The index of the order to fill
   * @param hintPrevIds The hint prev ids for the relevant mortgage queues
   * @param router The allowlisted router to execute the swap calldata against
   * @param swapCalldata The pre-encoded swap call. The vault enforces balance-delta invariants around it.
   */
  function fillOrder(uint256 index, uint256[] calldata hintPrevIds, address router, bytes calldata swapCalldata)
    external;
}
