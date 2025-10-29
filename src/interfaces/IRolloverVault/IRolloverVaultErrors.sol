// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title IRolloverVaultErrors
 * @author @SocksNFlops
 * @notice Interface for errors emitted by RolloverVaults.
 */
interface IRolloverVaultErrors {
  /**
   * @notice Thrown when an origination pool is not registered
   * @param originationPool The address of the origination pool that is not registered
   */
  error OriginationPoolNotRegistered(address originationPool);

  /**
   * @notice Thrown when an amount is zero
   */
  error AmountIsZero();

  /**
   * @notice Thrown when an origination pool is not being tracked by the rollover vault
   * @param originationPool The address of the origination pool that is not being tracked
   */
  error OriginationPoolNotTracked(address originationPool);
}
