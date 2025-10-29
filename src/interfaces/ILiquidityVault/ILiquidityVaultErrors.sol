// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title ILiquidityVaultErrors
 * @author @SocksNFlops
 * @notice Interface for errors emitted by LiquidityVaults.
 */
interface ILiquidityVaultErrors {
  /**
   * @notice Thrown when the depositable asset is not in the depositable assets list
   */
  error AssetNotDepositable(address asset);
}
