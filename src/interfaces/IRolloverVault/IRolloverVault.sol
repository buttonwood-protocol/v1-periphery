// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ILiquidityVault} from "../ILiquidityVault/ILiquidityVault.sol";
import {IRolloverVaultEvents} from "./IRolloverVaultEvents.sol";
import {IRolloverVaultErrors} from "./IRolloverVaultErrors.sol";

/**
 * @title IRolloverVault
 * @author @SocksNFlops
 * @notice Interface for RolloverVault, a vault that facilitates automatically rotates unused assets into origination pools.
 */
interface IRolloverVault is ILiquidityVault, IRolloverVaultEvents, IRolloverVaultErrors {
  /**
   * @notice Gets the address of the USDX token
   * @return The address of the USDX token
   */
  function usdx() external view returns (address);

  /**
   * @notice Gets the address of the consol token
   * @return The address of the consol token
   */
  function consol() external view returns (address);

  /**
   * @notice Gets the address of the general manager
   * @return The address of the general manager
   */
  function generalManager() external view returns (address);

  /**
   * @notice Gets the address of the origination pool scheduler
   * @return The address of the origination pool scheduler
   */
  function originationPoolScheduler() external view returns (address);

  /**
   * @notice Gets the addresses of the origination pools the rollover vault currently has a balance in
   * @return The addresses of the origination pools the rollover vault currently has a balance in
   */
  function originationPools() external view returns (address[] memory);

  /**
   * @notice Checks if the given origination pool is being tracked by the rollover vault
   * @param originationPool The address of the origination pool to check if it is being tracked
   * @return True if the origination pool is being tracked, false otherwise
   */
  function isTracked(address originationPool) external view returns (bool);

  /**
   * @notice Deposits the given amount of the given origination pool into the rollover vault
   * @param originationPool The address of the origination pool to deposit into
   * @param amount The amount of the origination pool to deposit
   */
  function depositOriginationPool(address originationPool, uint256 amount) external;

  /**
   * @notice Redeems the entire balance of the given origination pool from the rollover vault
   * @param originationPool The address of the origination pool to redeem from
   */
  function redeemOriginationPool(address originationPool) external;
}
