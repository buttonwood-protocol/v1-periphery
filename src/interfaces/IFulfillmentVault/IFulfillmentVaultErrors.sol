// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title IFulfillmentVaultErrors
 * @author @SocksNFlops
 * @notice Interface for errors emitted by FulfillmentVaults.
 */
interface IFulfillmentVaultErrors {
  /**
   * @notice Thrown when the fulfillment vault fails to withdraw native gas
   * @param amount The amount of native gas to withdraw
   */
  error FailedToWithdrawNativeGas(uint256 amount);
}
