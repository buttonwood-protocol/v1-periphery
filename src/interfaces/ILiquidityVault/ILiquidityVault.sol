// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVaultEvents} from "./ILiquidityVaultEvents.sol";
import {ILiquidityVaultErrors} from "./ILiquidityVaultErrors.sol";

/**
 * @title ILiquidityVault
 * @author @SocksNFlops
 * @notice Interface for LiquidityVault, a yield-bearing vault that enables depositing tokens for redeemable shares that earn yield.
 */
interface ILiquidityVault is IERC20, ILiquidityVaultEvents, ILiquidityVaultErrors {
  /**
   * @notice The role for the keeper
   * @return The role for the keeper
   */
  function KEEPER_ROLE() external view returns (bytes32);

  /**
   * @notice
   * @return The role for the whitelist
   */
  function WHITELIST_ROLE() external view returns (bytes32);

  /**
   * @notice Whether the whitelist is enforced.
   * @return Whether the whitelist is enforced.
   */
  function whitelistEnforced() external view returns (bool);

  /**
   * @notice Enforces the whitelist.
   * @param enforced Whether the whitelist is enforced.
   */
  function setWhitelistEnforced(bool enforced) external;

  /**
   * @notice The decimals offset. The number of decimals to offset the shares by. Used to protect against inflation attacks.
   * @return The decimals offset
   */
  function decimalsOffset() external view returns (uint8);

  /**
   * @notice The total assets of the vault
   * @return The total assets of the vault
   */
  function totalAssets() external view returns (uint256);

  /**
   * @notice The address of the depositable asset.
   * @return The address of the depositable asset.
   */
  function depositableAsset() external view returns (address);

  /**
   * @notice The address of the redeemable asset.
   * @return The address of the redeemable asset.
   */
  function redeemableAsset() external view returns (address);

  /**
   * @notice Sets the paused state of the vault.
   * @param paused The paused state of the vault.
   */
  function setPaused(bool paused) external;

  /**
   * @notice Deposits the specified amount of depositable asset into the vault.
   * @param assets The amount of depositable asset to deposit.
   */
  function deposit(uint256 assets) external;

  /**
   * @notice Redeems the specified amount of shares for the redeemable asset.
   * @param shares The amount of shares to redeem.
   */
  function redeem(uint256 shares) external;
}
