// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title IFulfillmentVaultEvents
 * @author @SocksNFlops
 * @notice Interface for events emitted by FulfillmentVaults.
 */
interface IFulfillmentVaultEvents {
  /**
   * @notice Emitted when an asset is approved to the order pool.
   * @param asset The address of the asset that was approved.
   */
  event AssetApproved(address indexed asset);

  /**
   * @notice Emitted when hype is wrapped.
   * @param amount The amount of hype that was wrapped.
   */
  event HypeWrapped(uint256 amount);

  /**
   * @notice Emitted when whype is unwrapped.
   * @param amount The amount of whype that was unwrapped.
   */
  event WhypeUnwrapped(uint256 amount);

  /**
   * @notice Emitted when an asset is bridged from core to evm.
   * @param asset The index of the asset that was bridged.
   * @param amount The amount of asset that was bridged.
   */
  event AssetBridgedFromCoreToEvm(uint64 indexed asset, uint256 amount);

  /**
   * @notice Emitted when usdx is burned.
   * @param amount The amount of usdx that was burned.
   */
  event UsdxBurned(uint256 amount);

  /**
   * @notice Emitted when a usd token is withdrawn from usdx.
   * @param usdToken The address of the usd token that was withdrawn.
   * @param amount The amount of usd token that was withdrawn.
   */
  event UsdTokenWithdrawnFromUsdx(address indexed usdToken, uint256 amount);

  /**
   * @notice Emitted when a usd token is deposited into usdx.
   * @param usdToken The address of the usd token that was deposited.
   * @param amount The amount of usd token that was deposited.
   */
  event UsdTokenDepositedToUsdx(address indexed usdToken, uint256 amount);

  /**
   * @notice Emitted when an asset is bridged from evm to core.
   * @param asset The address of the asset that was bridged.
   * @param amount The amount of asset that was bridged (in evm amounts)
   */
  event AssetBridgedFromEvmToCore(address indexed asset, uint256 amount);

  /**
   * @notice Emitted when a trade is made on core.
   * @param spotId The spotId of the trade.
   * @param isBuy Whether the trade is a buy or sell.
   * @param limitPx The limit price of the trade.
   * @param sz The size of the trade.
   * @param cloid The cloid of the trade, generated from the nonce.
   */
  event TradeOnCore(uint32 indexed spotId, bool isBuy, uint64 limitPx, uint64 sz, uint128 indexed cloid);

  /**
   * @notice Emitted when an order is filled.
   * @param index The index of the order that was filled.
   * @param hintPrevIds The hint previous ids of the order that was filled (used for conversion queues).
   */
  event OrderFilled(uint256 index, uint256[] indexed hintPrevIds);
}
