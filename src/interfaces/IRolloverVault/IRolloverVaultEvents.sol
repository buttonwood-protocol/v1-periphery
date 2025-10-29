// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title IRolloverVaultEvents
 * @author @SocksNFlops
 * @notice Interface for events emitted by RolloverVaults.
 */
interface IRolloverVaultEvents {
  /**
   * @notice Emitted when an origination pool is added to the rollover vault
   * @param originationPool The address of the origination pool that was added
   */
  event OriginationPoolAdded(address originationPool);

  /**
   * @notice Emitted when USDX is deposited into an origination pool
   * @param originationPool The address of the origination pool that was deposited into
   * @param amount The amount of USDX that was deposited into the origination pool
   */
  event OriginationPoolDeposited(address originationPool, uint256 amount);

  /**
   * @notice Emitted when USDX is redeemed from an origination pool
   * @param originationPool The address of the origination pool that was redeemed from
   * @param amount The amount of receipt tokens that was redeemed from the origination pool
   */
  event OriginationPoolRedeemed(address originationPool, uint256 amount);
}
