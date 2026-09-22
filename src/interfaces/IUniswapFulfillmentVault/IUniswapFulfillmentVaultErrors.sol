// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title IUniswapFulfillmentVaultErrors
 * @author @SocksNFlops
 * @notice Interface for errors emitted by UniswapFulfillmentVaults.
 */
interface IUniswapFulfillmentVaultErrors {
  /**
   * @notice Thrown when the vault fails to withdraw native gas
   * @param amount The amount of native gas to withdraw
   */
  error FailedToWithdrawNativeGas(uint256 amount);

  /**
   * @notice Thrown when the order at the given index has already been processed (or never existed)
   * @param index The index of the order
   */
  error OrderAlreadyProcessed(uint256 index);

  /**
   * @notice Thrown when the swap router is not on the allowlist
   * @param router The address of the router
   */
  error RouterNotAllowed(address router);

  /**
   * @notice Thrown when the swap delivers less collateral than the order requires
   * @param received The amount of collateral received from the swap
   * @param needed The amount of collateral the order requires
   */
  error InsufficientCollateralOut(uint256 received, uint256 needed);

  /**
   * @notice Thrown when the swap consumes more USDG than the order's purchase amount allows
   * @param spent The amount of USDG consumed by the swap
   * @param maxUsdgIn The maximum amount of USDG the swap was allowed to consume
   */
  error OverSpent(uint256 spent, uint256 maxUsdgIn);

  /**
   * @notice Thrown when attempting to allow the zero address as a router
   * @param router The address of the router
   */
  error InvalidRouter(address router);

  /**
   * @notice Thrown when initializing with an invalid USDG address
   * @param usdg The address of the USDG token
   */
  error InvalidUsdg(address usdg);

  /**
   * @notice Thrown when initializing with an invalid Permit2 address
   * @param permit2 The address of the Permit2 contract
   */
  error InvalidPermit2(address permit2);
}
