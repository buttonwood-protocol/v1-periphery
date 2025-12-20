// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ILoanManager} from "@core/interfaces/ILoanManager/ILoanManager.sol";
import {IGeneralManager, IGeneralManagerErrors} from "@core/interfaces/IGeneralManager/IGeneralManager.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOriginationPool, IOriginationPoolErrors} from "@core/interfaces/IOriginationPool/IOriginationPool.sol";
import {IPriceOracle} from "@core/interfaces/IPriceOracle.sol";
import {IConsol} from "@core/interfaces/IConsol/IConsol.sol";
import {ISubConsol} from "@core/interfaces/ISubConsol/ISubConsol.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IUSDX} from "@core/interfaces/IUSDX/IUSDX.sol";
import {CreationRequest} from "@core/types/orders/OrderRequests.sol";
import {IWNT} from "./interfaces/IWNT.sol";
import {OPoolConfigId} from "@core/types/OPoolConfigId.sol";
import {
  IOriginationPoolScheduler,
  IOriginationPoolSchedulerErrors
} from "@core/interfaces/IOriginationPoolScheduler/IOriginationPoolScheduler.sol";
import {IRouter} from "./interfaces/IRouter/IRouter.sol";
import {IMortgageNFT} from "@core/interfaces/IMortgageNFT/IMortgageNFT.sol";
import {IMortgageNFTErrors} from "@core/interfaces/IMortgageNFT/IMortgageNFTErrors.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPyth} from "@pythnetwork/IPyth.sol";
import {PythErrors} from "@pythnetwork/PythErrors.sol";
import {MortgageMath} from "@core/libraries/MortgageMath.sol";
import {MortgagePosition} from "@core/types/MortgagePosition.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault/ILiquidityVault.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title Router
 * @author @SocksNFlops
 * @notice This contract facilitates user interactions with core contracts of the Cash protocol.
 */
contract Router is
  IRouter,
  Context,
  IMortgageNFTErrors,
  IERC20Errors,
  IGeneralManagerErrors,
  IOriginationPoolErrors,
  IOriginationPoolSchedulerErrors
{
  using SafeERC20 for IERC20;
  using MortgageMath for MortgagePosition;
  using PythErrors for IPyth;

  /// @inheritdoc IRouter
  address public immutable generalManager;
  /// @inheritdoc IRouter
  address public immutable rolloverVault;
  /// @inheritdoc IRouter
  address public immutable fulfillmentVault;
  /// @inheritdoc IRouter
  address public immutable pyth;
  /// @inheritdoc IRouter
  address public immutable wrappedNativeToken;
  /// @inheritdoc IRouter
  address public immutable usdx;
  /// @inheritdoc IRouter
  address public immutable consol;
  /// @inheritdoc IRouter
  address public immutable originationPoolScheduler;

  /**
   * @param _wrappedNativeToken The address of the wrapped native token (i.e., whype: 0x555...)
   * @param _generalManager The address of the general manager contract
   * @param _rolloverVault The address of the rollover vault contract
   * @param _fulfillmentVault The address of the fulfillment vault contract
   * @param _pyth The address of the Pyth contract
   */
  constructor(
    address _wrappedNativeToken,
    address _generalManager,
    address _rolloverVault,
    address _fulfillmentVault,
    address _pyth
  ) {
    wrappedNativeToken = _wrappedNativeToken;
    generalManager = _generalManager;
    rolloverVault = _rolloverVault;
    fulfillmentVault = _fulfillmentVault;
    pyth = _pyth;
    usdx = IGeneralManager(_generalManager).usdx();
    consol = IGeneralManager(_generalManager).consol();
    originationPoolScheduler = IGeneralManager(_generalManager).originationPoolScheduler();

    // Auto-approve the tokens to be spent by the consol/generalManager contracts
    IWNT(wrappedNativeToken).approve(generalManager, type(uint256).max);
    IUSDX(usdx).approve(consol, type(uint256).max);
    IConsol(consol).approve(generalManager, type(uint256).max);
    IUSDX(usdx).approve(generalManager, type(uint256).max);
  }

  receive() external payable {}

  /**
   * @inheritdoc IRouter
   */
  function approveCollaterals() external {
    address[] memory consolInputTokens = IConsol(consol).getSupportedTokens();
    // Iterate over consolInputTokens to find which are SubConsol tokens
    for (uint256 i = 0; i < consolInputTokens.length; i++) {
      if (IERC165(consolInputTokens[i]).supportsInterface(type(ISubConsol).interfaceId)) {
        // Fetch the collateral out of the SubConsol and max approve it to be spent by the generalManager
        address collateral = ISubConsol(consolInputTokens[i]).collateral();
        IERC20(collateral).approve(address(generalManager), type(uint256).max);
      }
    }
  }

  /**
   * @inheritdoc IRouter
   */
  function approveUsdTokens() external {
    address[] memory usdTokens = IUSDX(usdx).getSupportedTokens();
    // Iterate over usdTokens and approve them to be spent by the USDX contract
    for (uint256 i = 0; i < usdTokens.length; i++) {
      IERC20(usdTokens[i]).approve(address(usdx), type(uint256).max);
    }
  }

  /**
   * @dev Internal function to pull in USDX via the underlying usdToken
   * @param usdToken The address of the usdToken to pull in
   * @param usdxAmount The amount of USDX to pull in
   */
  function _pullUsdToken(address usdToken, uint256 usdxAmount) internal {
    if (usdToken == address(usdx)) {
      // Don't need to wrap USDX
      // Pull in the USDX from the user
      IERC20(usdToken).safeTransferFrom(_msgSender(), address(this), usdxAmount);
    } else {
      // Need to wrap token into USDX
      // Calculate how much usdToken to pull in from the user
      uint256 usdTokenAmount = IUSDX(usdx).convertUnderlying(usdToken, usdxAmount);

      // Pull in the usdToken from the user
      IERC20(usdToken).safeTransferFrom(_msgSender(), address(this), usdTokenAmount);

      // Deposit the usdToken into the USDX contract
      IUSDX(usdx).deposit(usdToken, usdTokenAmount);
    }
  }

  /**
   * @dev Internal function to pull in Consol via the underlying usdTokens, USDX, SubConsols, or ForfeitedAssetsPool
   * @param inputToken The address of the input token to pull in
   * @param consolAmount The amount of Consol to pull in
   */
  function _pullInConsol(address inputToken, uint256 consolAmount) internal {
    if (inputToken == address(consol)) {
      // Input token is Consol
      // Pull in the Consol from the user
      IERC20(consol).safeTransferFrom(_msgSender(), address(this), consolAmount);
    } else {
      // Need to wrap token into USDX and then Consol
      // Calculate how much usdx is needed
      uint256 usdxAmount = IConsol(consol).convertUnderlying(usdx, consolAmount);
      // Pull in the usdToken from the user and convert it to USDX
      _pullUsdToken(inputToken, usdxAmount);
      // Deposit the USDX into Consol
      IConsol(consol).deposit(address(usdx), consolAmount);
    }
  }

  /**
   * @dev Internal function to pull in collateral
   * @param collateral The address of the collateral token to pull in
   * @param collateralCollected The amount of collateral to pull in
   * @param isNative Whether the collateral is the native token or not (i.e., whype: 0x555...)
   */
  function _pullCollateral(address collateral, uint256 collateralCollected, bool isNative) internal {
    if (isNative && collateral == address(wrappedNativeToken)) {
      // If you're paying with the native token, needs to be wrapped into the wrappedNativeToken first
      IWNT(wrappedNativeToken).deposit{value: collateralCollected}();
    } else {
      // Otherwise, pull in the collateral directly from the user
      IERC20(collateral).safeTransferFrom(_msgSender(), address(this), collateralCollected);
    }
  }

  /**
   * @dev Internal function to calculate the cost of a borrowing the collateral amount (including the price spread)
   * @param collateral The address of the collateral token
   * @param collateralAmount The amount of collateral to calculate the cost for
   * @return cost The cost of the collateral amount (including the price spread)
   * @return collateralDecimals The decimals of the collateral token
   */
  function _calculateCost(address collateral, uint256 collateralAmount)
    internal
    view
    returns (uint256 cost, uint8 collateralDecimals)
  {
    IPriceOracle priceOracle = IPriceOracle(IGeneralManager(generalManager).priceOracles(collateral));
    (cost, collateralDecimals) = priceOracle.cost(collateralAmount);

    // Get the price spread
    uint16 priceSpread = IGeneralManager(generalManager).priceSpread();

    // Add the price spread to the cost
    cost = Math.mulDiv(cost, 1e4 + priceSpread, 1e4);
  }

  /**
   * @inheritdoc IRouter
   */
  function calculateCollectedAmounts(CreationRequest calldata creationRequest)
    public
    view
    returns (uint256 collateralCollected, uint256 usdxCollected, uint256 paymentAmount, uint8 collateralDecimals)
  {
    if (creationRequest.base.isCompounding) {
      for (uint256 i = 0; i < creationRequest.base.originationPools.length; i++) {
        // If compounding, need to collect 1/2 of the collateral amount + commission fee (this is in the form of collateral)
        collateralCollected += IOriginationPool(creationRequest.base.originationPools[i])
          .calculateReturnAmount((creationRequest.base.collateralAmounts[i] + 1) / 2);
        (uint256 _cost, uint8 _collateralDecimals) =
          _calculateCost(creationRequest.collateral, creationRequest.base.collateralAmounts[i] / 2);
        collateralDecimals = _collateralDecimals;
        paymentAmount += (2 * _cost)
          - IOriginationPool(creationRequest.base.originationPools[i]).calculateReturnAmount(_cost);
      }
    } else {
      for (uint256 i = 0; i < creationRequest.base.originationPools.length; i++) {
        // If non-compounding, need to collect the full amountBorrowed in USDX + commission fee
        (uint256 _cost, uint8 _collateralDecimals) =
          _calculateCost(creationRequest.collateral, creationRequest.base.collateralAmounts[i]);
        paymentAmount += _cost;
        collateralDecimals = _collateralDecimals;
        usdxCollected += IOriginationPool(creationRequest.base.originationPools[i]).calculateReturnAmount(_cost / 2);
        if (_cost % 2 == 1) {
          usdxCollected += 1;
        }
      }
    }
  }

  /**
   * @inheritdoc IRouter
   */
  function updatePriceFeedsAndRequestMortgage(
    bytes[] calldata priceUpdates,
    address usdToken,
    CreationRequest calldata creationRequest,
    bool isNative,
    uint256 maxCollected
  )
    public
    payable
    returns (uint256 collateralCollected, uint256 usdxCollected, uint256 paymentAmount, uint8 collateralDecimals)
  {
    // Fetch the update fees
    uint256 updateFee = IPyth(pyth).getUpdateFee(priceUpdates);

    // Fetch the Pyth contract
    IPyth(pyth).updatePriceFeeds{value: updateFee}(priceUpdates);

    return requestMortgage(usdToken, creationRequest, isNative, maxCollected);
  }

  /**
   * @inheritdoc IRouter
   */
  function requestMortgage(
    address usdToken,
    CreationRequest calldata creationRequest,
    bool isNative,
    uint256 maxCollected
  )
    public
    payable
    returns (uint256 collateralCollected, uint256 usdxCollected, uint256 paymentAmount, uint8 collateralDecimals)
  {
    (collateralCollected, usdxCollected, paymentAmount, collateralDecimals) = calculateCollectedAmounts(creationRequest);

    if (collateralCollected > 0) {
      if (collateralCollected > maxCollected) {
        revert CollectedAmountExceedsMaximum(creationRequest.collateral, collateralCollected, maxCollected);
      }
      _pullCollateral(creationRequest.collateral, collateralCollected, isNative);
    }

    if (usdxCollected > 0) {
      if (usdxCollected > maxCollected) {
        revert CollectedAmountExceedsMaximum(usdToken, usdxCollected, maxCollected);
      }
      _pullUsdToken(usdToken, usdxCollected);
    }

    uint256 tokenId =
      IGeneralManager(generalManager).requestMortgageCreation{value: address(this).balance}(creationRequest);

    // Transfer the mortgageNFT to the user
    IMortgageNFT(IGeneralManager(generalManager).mortgageNFT()).transferFrom(address(this), _msgSender(), tokenId);
  }

  /**
   * @inheritdoc IRouter
   */
  function periodPay(address inputToken, uint256 tokenId, uint256 inputAmount) external {
    // Convert the inputAmount to Consol
    uint256 consolAmount = convert(inputToken, consol, inputAmount);

    // Pull in inputToken and wrap into Consol
    _pullInConsol(inputToken, consolAmount);

    // Make the period payment on Consol
    address loanManager = IGeneralManager(generalManager).loanManager();
    IConsol(consol).approve(loanManager, consolAmount);
    ILoanManager(loanManager).periodPay(tokenId, consolAmount);
  }

  /**
   * @inheritdoc IRouter
   */
  function penaltyPay(address inputToken, uint256 tokenId, uint256 inputAmount) external {
    // Convert the inputAmount to Consol
    uint256 consolAmount = convert(inputToken, consol, inputAmount);

    // Pull in inputToken and wrap into Consol
    _pullInConsol(inputToken, consolAmount);

    // Make the penalty payment on Consol
    address loanManager = IGeneralManager(generalManager).loanManager();
    IConsol(consol).approve(loanManager, consolAmount);
    ILoanManager(loanManager).penaltyPay(tokenId, consolAmount);
  }

  /**
   * @inheritdoc IRouter
   */
  function refinance(address inputToken, uint256 tokenId, uint8 newTotalPeriods) external {
    // Fetch the loan manager
    address loanManager = IGeneralManager(generalManager).loanManager();

    // Fetch the mortgage position
    MortgagePosition memory mortgagePosition = ILoanManager(loanManager).getMortgagePosition(tokenId);

    // Fetch the refinance rate
    uint256 refinanceRate = IGeneralManager(generalManager).refinanceRate(mortgagePosition);

    // Calculate the refinance fee
    uint256 refinanceFee = Math.mulDiv(mortgagePosition.principalRemaining(), refinanceRate, 1e4, Math.Rounding.Ceil);

    // Pull in inputToken and wrap into Consol
    _pullInConsol(inputToken, refinanceFee);

    // Transfer the mortgageNFT to the router
    IMortgageNFT(IGeneralManager(generalManager).mortgageNFT()).transferFrom(_msgSender(), address(this), tokenId);

    // Call `refinanceMortgage` on the loan manager
    IConsol(consol).approve(loanManager, refinanceFee);
    ILoanManager(loanManager).refinanceMortgage(tokenId, newTotalPeriods);

    // Return the mortgageNFT to the user
    IMortgageNFT(IGeneralManager(generalManager).mortgageNFT()).transferFrom(address(this), _msgSender(), tokenId);
  }

  /**
   * @dev Internal function to get or create the latest origination pool for a given OPoolConfigId
   * @param oPoolConfigId The OPoolConfigId of the origination pool config
   * @return originationPool The origination pool
   */
  function _getOrCreateOriginationPool(OPoolConfigId oPoolConfigId)
    internal
    returns (IOriginationPool originationPool)
  {
    originationPool = IOriginationPool(
      IOriginationPoolScheduler(originationPoolScheduler).predictOriginationPool(oPoolConfigId)
    );
    if (!IOriginationPoolScheduler(originationPoolScheduler).isRegistered(address(originationPool))) {
      IOriginationPool(IOriginationPoolScheduler(originationPoolScheduler).deployOriginationPool(oPoolConfigId));
    }
  }

  /**
   * @inheritdoc IRouter
   */
  function originationPoolDeposit(OPoolConfigId oPoolConfigId, address usdToken, uint256 usdTokenAmount) external {
    // Convert the usdTokenAmount to USDX
    uint256 usdxAmount = convert(usdToken, usdx, usdTokenAmount);

    // Fetch the origination pool
    IOriginationPool originationPool = _getOrCreateOriginationPool(oPoolConfigId);

    // Pull in the usdToken from the user
    _pullUsdToken(usdToken, usdxAmount);

    // Deposit the USDX into the origination pool
    IUSDX(usdx).approve(address(originationPool), usdxAmount);
    originationPool.deposit(usdxAmount);

    // Transfer the originationPool receipt tokens to the user
    originationPool.transfer(msg.sender, originationPool.balanceOf(address(this)));
  }

  /**
   * @inheritdoc IRouter
   */
  function convert(address inputToken, address outputToken, uint256 inputAmount)
    public
    view
    returns (uint256 outputAmount)
  {
    // Check if input and output tokens are the same
    if (inputToken == outputToken) {
      outputAmount = inputAmount;
    }
    // If the input is Consol, then recurse from (Consol -> USDX) -> outputToken
    else if (inputToken == address(consol)) {
      // If the inputToken is Consol, convert it to USDX
      outputAmount = convert(address(usdx), outputToken, IConsol(consol).convertUnderlying(usdx, inputAmount));
    }
    // If the output token is Consol, then recurse from (inputToken -> USDX) -> Consol
    else if (outputToken == address(consol)) {
      outputAmount = IConsol(consol).convertAmount(usdx, convert(inputToken, usdx, inputAmount));
    }
    // If the input is USDX, then the outputToken is a usdToken
    else if (inputToken == address(usdx)) {
      outputAmount = IUSDX(usdx).convertUnderlying(outputToken, inputAmount);
    }
    // Output token must be USDX, meaning the input token is a usdToken
    else {
      outputAmount = IUSDX(usdx).convertAmount(inputToken, inputAmount);
    }
  }

  /**
   * @inheritdoc IRouter
   */
  function wrap(address inputToken, address outputToken, uint256 inputAmount) public {
    // Check if input and output tokens are the same. If so, don't do anything
    if (inputToken == outputToken) {
      return;
    } else if (inputAmount == 0) {
      return;
    }
    // Pull in the input token
    IERC20(inputToken).safeTransferFrom(_msgSender(), address(this), inputAmount);

    // If the inputToken isn't USDX, it must be a usdToken. Deposit it into USDX
    if (inputToken != address(usdx)) {
      IUSDX(usdx).deposit(inputToken, inputAmount);
    }

    // If the outputToken is Consol, then we must do one more wrapping
    if (outputToken == address(consol)) {
      // Fetch the new inputAmount
      inputAmount = IUSDX(usdx).balanceOf(address(this));
      // Convert the USDX to Consol
      IConsol(consol).deposit(address(usdx), inputAmount);
    }

    // Transfer the output token to the user
    IERC20(outputToken).safeTransfer(_msgSender(), IERC20(outputToken).balanceOf(address(this)));
  }

  /**
   * @dev Internal function to deposit into a liquidity vault
   * @param vault The address of the liquidity vault to deposit into
   * @param usdToken The address of the usdToken to pull in
   * @param usdTokenAmount The amount of usdToken to pull in
   */
  function _vaultDeposit(address vault, address usdToken, uint256 usdTokenAmount) internal {
    if (
      ILiquidityVault(vault).whitelistEnforced()
        && !IAccessControl(vault).hasRole(ILiquidityVault(vault).WHITELIST_ROLE(), _msgSender())
    ) {
      revert VaultWhitelistEnforced(vault, _msgSender());
    }

    // Convert the usdTokenAmount to USDX
    uint256 usdxAmount = convert(usdToken, usdx, usdTokenAmount);

    // Pull in the usdToken from the user
    _pullUsdToken(usdToken, usdxAmount);

    // Deposit the USDX into the vault
    IUSDX(usdx).approve(vault, usdxAmount);
    ILiquidityVault(vault).deposit(usdx, usdxAmount);

    // Transfer the vault share tokens to the user
    ILiquidityVault(vault).transfer(_msgSender(), ILiquidityVault(vault).balanceOf(address(this)));
  }

  /**
   * @inheritdoc IRouter
   */
  function rolloverVaultDeposit(address usdToken, uint256 usdTokenAmount) external {
    _vaultDeposit(rolloverVault, usdToken, usdTokenAmount);
  }

  /**
   * @inheritdoc IRouter
   */
  function fulfillmentVaultDeposit(address usdToken, uint256 usdTokenAmount) external {
    _vaultDeposit(fulfillmentVault, usdToken, usdTokenAmount);
  }
}
