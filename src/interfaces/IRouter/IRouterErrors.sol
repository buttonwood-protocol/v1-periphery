// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title IRouterErrors
 * @author @SocksNFlops
 * @notice Errors for the Router contract
 */
interface IRouterErrors {
  /**
   * @notice Thrown when the collected amount exceeds the maximum permitted collected amount
   * @param token The token that was collected
   * @param collectedAmount The amount that was collected
   * @param maxColllected The maximum amount that can be collected
   */
  error CollectedAmountExceedsMaximum(address token, uint256 collectedAmount, uint256 maxColllected);
}
