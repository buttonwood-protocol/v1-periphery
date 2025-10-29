// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ToDo: Add events for all keeper functions too!
/**
 * @title ILiquidityVaultEvents
 * @author @SocksNFlops
 * @notice Interface for events emitted by LiquidityVaults.
 */
interface ILiquidityVaultEvents {
  /**
   * @notice Emitted when a user deposits assets into the vault.
   * @param user The address of the user who deposited the assets.
   * @param depositableAsset The address of the depositable asset.
   * @param amountDeposited The amount of depositable asset sent.
   * @param sharesMinted The amount of shares minted.
   */
  event Deposited(
    address indexed user, address indexed depositableAsset, uint256 amountDeposited, uint256 sharesMinted
  );

  /**
   * @notice Emitted when a user redeems assets from the vault.
   * @param user The address of the user who redeemed the assets.
   * @param redeemableAssets The addresses of the redeemable assets.
   * @param amountsRedeemed The amounts of redeemable assets received.
   * @param sharesBurned The amount of shares burned.
   */
  event Redeemed(address indexed user, address[] indexed redeemableAssets, uint256[] amountsRedeemed, uint256 sharesBurned);
}
