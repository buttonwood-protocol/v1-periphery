// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ILiquidityVault} from "../ILiquidityVault/ILiquidityVault.sol";

/**
 * @title IFulfillmentVault
 * @author @SocksNFlops
 * @notice Interface for FulfillmentVault, a vault that facilitates liquidity provisioning for fulfilling purchase orders in the OrderPool.
 */
interface IFulfillmentVault is ILiquidityVault {
  /**
   * @notice Gets the address of the wrapped native token
   * @return The address of the wrapped native token (i.e., whype: 0x555...)
   */
  function wrappedNativeToken() external view returns (address);

  /**
   * @notice Gets the address of the order pool
   * @return The address of the order pool
   */
  function orderPool() external view returns (address);

  /**
   * @notice Gets the ongoing nonce that generates distinct cloid values for exchanges on core
   * @return The ongoing nonce
   */
  function nonce() external view returns (uint128);

  /**
   * @notice Approves whype to the order pool
   */
  function approveWhype() external;

  /**
   * @notice Wraps entire hype balance of the fulfillment vault into whype
   */
  function wrapHype() external;

  /**
   * @notice Bridges hype from core to evm
   * @param amount The amount of hype to bridge (in evm units)
   */
  function bridgeHypeFromCoreToEvm(uint256 amount) external;

  /**
   * @notice Burns USDX into usdTokens for the purpose of transferring them to core
   * @param amount The amount of USDX to burn
   */
  function burnUsdx(uint256 amount) external;


  /**
   * @notice Withdraws usdToken from usdx
   * @param usdToken The address of the usdToken to withdraw
   * @param amount The amount of usdToken to withdraw
   */
  function withdrawUsdTokenFromUsdx(address usdToken, uint256 amount) external;

  /**
   * @notice Bridges usdTokens to core
   * @param usdToken The address of the usdToken to bridge
   * @param amount The amount of usdToken to bridge
   */
  function bridgeUsdTokenToCore(address usdToken, uint256 amount) external;

  /**
   * @notice Trades tokens on core
   * @param asset The assetId of the asset to trade
   * @param isBuy Whether to buy or sell
   * @param limitPx The limit price. Note, This is is (weiUnits - szUnits). For USDT and USDH, weiUnits is 1e6.
   * @param sz The size of the trade. Note, this is in szUnits. For USDT and USDH, szUnits is 1e2.
   */
  function tradeOnCore(uint32 asset, bool isBuy, uint32 limitPx, uint64 sz) external;

  /**
   * @notice Fills an order from the order pool
   * @param index The index of the order to fill
   * @param hintPrevIds The hint prev ids for the relevant mortgage queues.
   */
  function fillOrder(uint256 index, uint256[] memory hintPrevIds) external;
}

// ToDo: GENERALIZE TO BUYING MORE THAN JUST HYPE

/**
 * FulfillmentVault:
 * - Keeper Functions:
 *   - Buy hype via usdc
 *   - Transfer Hype to evm
 *   - Wrap hype into whype
 *   - Approve whype to order pool (maybe we infinite approve this)
 *   - Fill order
 *   - Unwrap USDX (burn it into usd-tokens)
 *   - Transfer usd-tokens to core
 *   - Trade usd tokens to usdc
 * - Special Considerations:
 *   - Need to temporarily pause withdrawals while processing orders. So need a withdrawal queue.
 *   - Not just withdrawing usdx + hype, but balances from hypercore...
 *   - Protocol fee in here?
 */
