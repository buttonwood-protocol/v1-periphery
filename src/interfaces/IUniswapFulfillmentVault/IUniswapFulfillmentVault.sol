// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ILiquidityVault} from "../ILiquidityVault/ILiquidityVault.sol";
import {IUniswapFulfillmentVaultEvents} from "./IUniswapFulfillmentVaultEvents.sol";
import {IUniswapFulfillmentVaultErrors} from "./IUniswapFulfillmentVaultErrors.sol";

/**
 * @notice The oracle-anchored fill bounds for a collateral
 * @param priceOracle The price oracle anchoring the route (IPriceOracle, 18-decimal cost)
 * @param maxPremiumBps The maximum execution premium over the oracle cost, in basis points
 * @param maxFillCost The per-fill cap in oracle terms (18 decimals). Zero disables the route.
 */
struct CollateralRoute {
  address priceOracle;
  uint16 maxPremiumBps;
  uint256 maxFillCost;
}

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
   * @notice Gets the route configured for a collateral
   * @param collateral The address of the collateral token
   * @return The collateral route. A zero maxFillCost means the route is disabled.
   */
  function collateralRoute(address collateral) external view returns (CollateralRoute memory);

  /**
   * @notice Checks whether a swap router is on the allowlist
   * @param router The address of the router
   * @return Whether the router is allowed
   */
  function isAllowedRouter(address router) external view returns (bool);

  /**
   * @notice Sets the route for a collateral. Setting a zero maxFillCost disables the route.
   * @param collateral The address of the collateral token
   * @param route The route to set
   */
  function setCollateralRoute(address collateral, CollateralRoute calldata route) external;

  /**
   * @notice Allows or disallows a swap router
   * @param router The address of the router
   * @param allowed Whether the router is allowed
   */
  function setRouterAllowed(address router, bool allowed) external;

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
   * @param swapCalldata The pre-encoded swap call. The vault enforces oracle-anchored balance-delta invariants around it.
   */
  function fillOrder(uint256 index, uint256[] calldata hintPrevIds, address router, bytes calldata swapCalldata)
    external;
}
