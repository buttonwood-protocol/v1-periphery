// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {CreationRequest} from "@core/types/orders/OrderRequests.sol";
import {OPoolConfigId} from "@core/types/OPoolConfigId.sol";
import {IRouterErrors} from "./IRouterErrors.sol";

/**
 * @title IRouter
 * @author @SocksNFlops
 * @notice Interface for the Router contract meant to facilitate user interactions with core contracts of the Cash protocol.
 */
interface IRouter is IRouterErrors {
  /**
   * @notice The address of the general manager contract
   * @return The address of the general manager contract
   */
  function generalManager() external view returns (address);

  /**
   * @notice The address of the rollover vault contract
   * @return The address of the rollover vault contract
   */
  function rolloverVault() external view returns (address);

  /**
   * @notice The address of the fulfillment vault contract
   * @return The address of the fulfillment vault contract
   */
  function fulfillmentVault() external view returns (address);

  /**
   * @notice The address of the Pyth contract
   * @return The address of the Pyth contract
   */
  function pyth() external view returns (address);

  /**
   * @notice The address of the wrapped native token
   * @return The address of the wrapped native token
   */
  function wrappedNativeToken() external view returns (address);

  /**
   * @notice The address of the USDX token contract
   * @return The address of the USDX token contract
   */
  function usdx() external view returns (address);

  /**
   * @notice The address of the Consol token contract
   * @return The address of the Consol token contract
   */
  function consol() external view returns (address);

  /**
   * @notice The address of the origination pool scheduler contract
   * @return The address of the origination pool scheduler contract
   */
  function originationPoolScheduler() external view returns (address);

  /**
   * @notice Approve all the collaterals to be spent by the general manager
   */
  function approveCollaterals() external;

  /**
   * @notice Approve all the usdTokens to be spent by the USDX contract (for depositing into USDX)
   */
  function approveUsdTokens() external;

  /**
   * @notice Calculates the amounts that will be collected from the borrower for a given creation request before sending the request to the general manager
   * @param creationRequest The creation request
   * @return collateralCollected The amount of collateral that will be collected from the borrower
   * @return usdxCollected The amount of USDX that will be collected from the borrower
   * @return paymentAmount The amount of USDX that will be paid to the fulfilller
   * @return collateralDecimals The decimals of the collateral token
   */
  function calculateCollectedAmounts(CreationRequest calldata creationRequest)
    external
    view
    returns (uint256 collateralCollected, uint256 usdxCollected, uint256 paymentAmount, uint8 collateralDecimals);

  /**
   * @notice Request a mortgage
   * @param usdToken The address of the usdToken to pull in
   * @param creationRequest The creation request
   * @param isNative Whether the collateral is the native token or not (i.e., whype: 0x555...)
   * @param maxCollected The maximum amount that can be collected from the borrower (in USDX if non-compounding, in collateral if compounding)
   * @return collateralCollected The amount of collateral collected
   * @return usdxCollected The amount of USDX collected
   * @return paymentAmount The amount of payment to be made
   * @return collateralDecimals The decimals of the collateral
   */
  function requestMortgage(
    address usdToken,
    CreationRequest calldata creationRequest,
    bool isNative,
    uint256 maxCollected
  )
    external
    payable
    returns (uint256 collateralCollected, uint256 usdxCollected, uint256 paymentAmount, uint8 collateralDecimals);

  /**
   * @notice Request a mortgage
   * @param priceUpdates The price updates to send to the Pyth contract
   * @param usdToken The address of the usdToken to pull in
   * @param creationRequest The creation request
   * @param isNative Whether the collateral is the native token or not (i.e., whype: 0x555...)
   * @param maxCollected The maximum amount that can be collected from the borrower (in USDX if non-compounding, in collateral if compounding)
   * @return collateralCollected The amount of collateral collected
   * @return usdxCollected The amount of USDX collected
   * @return paymentAmount The amount of payment to be made
   * @return collateralDecimals The decimals of the collateral
   */
  function updatePriceFeedsAndRequestMortgage(
    bytes[] calldata priceUpdates,
    address usdToken,
    CreationRequest calldata creationRequest,
    bool isNative,
    uint256 maxCollected
  )
    external
    payable
    returns (uint256 collateralCollected, uint256 usdxCollected, uint256 paymentAmount, uint8 collateralDecimals);

  /**
   * @notice Make a periodic payment on a mortgage
   * @param inputToken The address of the input token to pull in
   * @param tokenId The token ID
   * @param inputAmount The amount of input token to pull in
   */
  function periodPay(address inputToken, uint256 tokenId, uint256 inputAmount) external;

  /**
   * @notice Make a penalty payment on a mortgage
   * @param inputToken The address of the input token to pull in
   * @param tokenId The token ID
   * @param inputAmount The amount of input token to pull in
   */
  function penaltyPay(address inputToken, uint256 tokenId, uint256 inputAmount) external;

  /**
   * @notice Refinance a mortgage
   * @param inputToken The address of the input token to pull in
   * @param tokenId The token ID of the mortgage to refinance
   * @param newTotalPeriods The new total periods of the mortgage
   */
  function refinance(address inputToken, uint256 tokenId, uint8 newTotalPeriods) external;

  /**
   * @notice Deposit into an origination pool
   * @param oPoolConfigId The OPoolConfigId of the origination pool to deposit into
   * @param usdToken The address of the usdToken to pull in
   * @param usdTokenAmount The amount of usdToken to pull in
   */
  function originationPoolDeposit(OPoolConfigId oPoolConfigId, address usdToken, uint256 usdTokenAmount) external;

  /**
   * @notice Quotes the amount of output token that would be received for a given amount of input token
   * @param inputToken The address of the input token
   * @param outputToken The address of the output token
   * @param inputAmount The amount of input token to convert
   * @return outputAmount The amount of output token received
   */
  function convert(address inputToken, address outputToken, uint256 inputAmount)
    external
    view
    returns (uint256 outputAmount);

  /**
   * @notice Wraps tokens from usdToken -> usdx -> consol
   * @param inputToken The address of the input token
   * @param outputToken The address of the output token
   * @param inputAmount The amount of input token to convert
   */
  function wrap(address inputToken, address outputToken, uint256 inputAmount) external;

  /**
   * @notice Deposit into the rollover vault
   * @param usdToken The address of the usdToken to pull in
   * @param usdTokenAmount The amount of usdToken to pull in
   */
  function rolloverVaultDeposit(address usdToken, uint256 usdTokenAmount) external;

  /**
   * @notice Deposit into the fulfillment vault
   * @param usdToken The address of the usdToken to pull in
   * @param usdTokenAmount The amount of usdToken to pull in
   */
  function fulfillmentVaultDeposit(address usdToken, uint256 usdTokenAmount) external;
}
