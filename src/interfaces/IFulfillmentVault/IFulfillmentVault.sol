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
   * @notice Burns USDX into usdTokens for the purpose of transferring them to core
   * @param amount The amount of USDX to burn
   */
  function burnUsdx(uint256 amount) external;

  /**
   * @notice Bridges usdTokens to core
   * @param token The address of the usdToken to bridge
   * @param amount The amount of usdToken to bridge
   */
  function bridgeUsdTokenToCore(address token, uint256 amount) external;

  /**
   * @notice Burns USDX and bridges the usdTokens to core
   * @param amount The amount of USDX to burn
   */
  function burnUsdxAndBridgeToCore(uint256 amount) external;
}

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
