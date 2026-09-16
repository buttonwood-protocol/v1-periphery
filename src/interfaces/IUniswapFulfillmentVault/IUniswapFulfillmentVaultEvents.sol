// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {RouterApproval} from "./RouterApproval.sol";

/**
 * @title IUniswapFulfillmentVaultEvents
 * @author @SocksNFlops
 * @notice Interface for events emitted by UniswapFulfillmentVaults.
 */
interface IUniswapFulfillmentVaultEvents {
  /**
   * @notice Emitted when an asset is approved to the order pool.
   * @param asset The address of the asset that was approved.
   */
  event AssetApproved(address indexed asset);

  /**
   * @notice Emitted when a collateral route is set (or disabled via a zero maxFillCost).
   * @param collateral The address of the collateral token.
   * @param priceOracle The address of the price oracle anchoring the route.
   * @param maxPremiumBps The maximum execution premium over the oracle cost, in basis points.
   * @param maxFillCost The per-fill cap in oracle terms (18 decimals). Zero disables the route.
   */
  event CollateralRouteSet(address indexed collateral, address priceOracle, uint16 maxPremiumBps, uint256 maxFillCost);

  /**
   * @notice Emitted when a swap router's approval mode is set (None disallows the router).
   * @param router The address of the router.
   * @param approval The approval mode for the router.
   */
  event RouterApprovalSet(address indexed router, RouterApproval approval);

  /**
   * @notice Emitted when an order is filled.
   * @param index The index of the order that was filled.
   * @param collateral The address of the collateral token.
   * @param collateralPurchased The amount of collateral delivered to the order pool.
   * @param usdgSpent The amount of USDG consumed by the swap (USDG decimals).
   * @param purchaseAmountReceived The amount of USDX received for the fill.
   */
  event OrderFilled(
    uint256 indexed index,
    address indexed collateral,
    uint256 collateralPurchased,
    uint256 usdgSpent,
    uint256 purchaseAmountReceived
  );

  /**
   * @notice Emitted when an expired order is swept (cancelled and refunded, no swap performed).
   * @param index The index of the order that was swept.
   */
  event OrderExpiredSwept(uint256 indexed index);
}
