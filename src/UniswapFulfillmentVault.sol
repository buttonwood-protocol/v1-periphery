// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
  CollateralRoute,
  IUniswapFulfillmentVault
} from "./interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVault.sol";
import {RouterApproval, RouterConfig} from "./interfaces/IUniswapFulfillmentVault/RouterApproval.sol";
import {IERC165, LiquidityVault} from "./LiquidityVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IUSDX} from "@core/interfaces/IUSDX/IUSDX.sol";
import {IOrderPool} from "@core/interfaces/IOrderPool/IOrderPool.sol";
import {IGeneralManager} from "@core/interfaces/IGeneralManager/IGeneralManager.sol";
import {IPriceOracle} from "@core/interfaces/IPriceOracle.sol";
import {PurchaseOrder} from "@core/types/orders/PurchaseOrder.sol";
import {Constants} from "@core/libraries/Constants.sol";

/**
 * @title IAllowanceTransfer
 * @notice The subset of Permit2's AllowanceTransfer surface the vault uses to scope a router's USDG spend
 */
interface IAllowanceTransfer {
  /**
   * @notice Approves a spender to pull a token through Permit2, up to an amount, until an expiration
   * @dev Permit2 rejects a pull only when block.timestamp > expiration. A zero expiration is stored as block.timestamp.
   * @param token The token to approve
   * @param spender The spender address to approve
   * @param amount The approved amount of the token
   * @param expiration The timestamp at which the approval is no longer valid
   */
  function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/**
 * @title UniswapFulfillmentVault
 * @author @SocksNFlops
 * @notice A fulfillment vault for chains whose venue is synchronously composable. Each fill is a single
 *         atomic transaction: withdraw USDG from USDX, execute keeper-supplied swap calldata against an
 *         allowlisted router under oracle-anchored balance-delta invariants, and deliver the collateral to
 *         the order pool. The vault never constructs swaps; safety comes from the invariants, not the route.
 */
contract UniswapFulfillmentVault is LiquidityVault, ReentrancyGuardUpgradeable, IUniswapFulfillmentVault {
  using Math for uint256;
  using SafeCast for uint256;
  using SafeERC20 for IERC20;
  using Address for address;

  /// @notice Allow the contract to receive network native tokens (order gas fee refunds)
  receive() external payable {}

  /**
   * @custom:storage-location erc7201:buttonwood.storage.UniswapFulfillmentVault
   * @notice The storage for the UniswapFulfillmentVault contract
   * @param _generalManager The address of the general manager
   * @param _usdx The address of the USDX token
   * @param _usdg The address of the USDG token (the USDX supported token used for the swap leg)
   * @param _permit2 The address of the Permit2 contract used for Permit2-mode routers
   * @param _routes The oracle-anchored fill bounds per collateral
   * @param _routerApprovals The swap router allowlist, keyed by approval mode (None is not allowed)
   */
  struct UniswapFulfillmentVaultStorage {
    address _generalManager;
    address _usdx;
    address _usdg;
    address _permit2;
    mapping(address collateral => CollateralRoute route) _routes;
    mapping(address router => RouterApproval approval) _routerApprovals;
  }

  /**
   * @notice The storage location of the UniswapFulfillmentVault contract
   * @dev keccak256(abi.encode(uint256(keccak256("buttonwood.storage.UniswapFulfillmentVault")) - 1)) & ~bytes32(uint256(0xff))
   */
  // solhint-disable-next-line const-name-snakecase
  bytes32 private constant UniswapFulfillmentVaultStorageLocation =
    0x62b468087c7bc2ca57b4a872a804ea5defdcf62f2f88914f09f6e558fa6e3e00;

  /**
   * @dev Gets the storage location of the UniswapFulfillmentVault contract
   * @return $ The storage location of the UniswapFulfillmentVault contract
   */
  function _getUniswapFulfillmentVaultStorage() private pure returns (UniswapFulfillmentVaultStorage storage $) {
    // solhint-disable-next-line no-inline-assembly
    assembly {
      $.slot := UniswapFulfillmentVaultStorageLocation
    }
  }

  /**
   * @dev Initializes the UniswapFulfillmentVault contract and calls parent initializers
   * @param name The name of the vault
   * @param symbol The symbol of the vault
   * @param _decimals The decimals of the vault
   * @param _decimalsOffset The decimals offset for measuring internal precision of shares
   * @param _generalManager The address of the general manager
   * @param _usdg The address of the USDG token
   * @param _permit2 The address of the Permit2 contract
   * @param routers The initial swap router allowlist, as (router, approval mode) pairs
   */
  // solhint-disable-next-line func-name-mixedcase
  function __UniswapFulfillmentVault_init(
    string memory name,
    string memory symbol,
    uint8 _decimals,
    uint8 _decimalsOffset,
    address _generalManager,
    address _usdg,
    address _permit2,
    RouterConfig[] memory routers
  ) internal onlyInitializing {
    __ERC20_init_unchained(name, symbol);
    __ReentrancyGuard_init();
    address[] memory assets = new address[](1);
    assets[0] = IGeneralManager(_generalManager).usdx();
    __LiquidityVault_init_unchained(_decimals, _decimalsOffset, assets, assets);
    __UniswapFulfillmentVault_init_unchained(_generalManager, _usdg, _permit2, routers);
  }

  /**
   * @dev Initializes the UniswapFulfillmentVault contract only
   * @param _generalManager The address of the general manager
   * @param _usdg The address of the USDG token
   * @param _permit2 The address of the Permit2 contract
   * @param routers The initial swap router allowlist, as (router, approval mode) pairs
   */
  // solhint-disable-next-line func-name-mixedcase
  function __UniswapFulfillmentVault_init_unchained(
    address _generalManager,
    address _usdg,
    address _permit2,
    RouterConfig[] memory routers
  ) internal onlyInitializing {
    if (_usdg == address(0)) {
      revert InvalidUsdg(_usdg);
    }
    if (_permit2 == address(0)) {
      revert InvalidPermit2(_permit2);
    }
    UniswapFulfillmentVaultStorage storage $ = _getUniswapFulfillmentVaultStorage();
    $._generalManager = _generalManager;
    $._usdx = IGeneralManager(_generalManager).usdx();
    $._usdg = _usdg;
    $._permit2 = _permit2;
    for (uint256 i = 0; i < routers.length; i++) {
      _setRouterApproval(routers[i].router, routers[i].approval);
    }
  }

  /**
   * @notice Initializes the UniswapFulfillmentVault contract
   * @param name The name of the vault
   * @param symbol The symbol of the vault
   * @param _decimals The decimals of the vault
   * @param _decimalsOffset The decimals offset for measuring internal precision of shares
   * @param _generalManager The address of the general manager
   * @param _usdg The address of the USDG token
   * @param _permit2 The address of the Permit2 contract
   * @param routers The initial swap router allowlist, as (router, approval mode) pairs
   * @param admin The address of the admin for the vault
   */
  function initialize(
    string memory name,
    string memory symbol,
    uint8 _decimals,
    uint8 _decimalsOffset,
    address _generalManager,
    address _usdg,
    address _permit2,
    RouterConfig[] memory routers,
    address admin
  ) external initializer {
    __UniswapFulfillmentVault_init(name, symbol, _decimals, _decimalsOffset, _generalManager, _usdg, _permit2, routers);
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) public view override(LiquidityVault) returns (bool) {
    return super.supportsInterface(interfaceId) || interfaceId == type(IUniswapFulfillmentVault).interfaceId;
  }

  /// @inheritdoc LiquidityVault
  /// @dev Both depositable and redeemable assets are the same asset, so we override totalAssets to return the balance of only the redeemable asset.
  function _totalAssets() internal view override returns (uint256) {
    return IERC20(usdx()).balanceOf(address(this));
  }

  /**
   * @dev Blocks share mints, burns, and transfers while a fill is executing, so the transient mid-fill
   *      balance sheet (USDG/collateral in flight) can never price a deposit or redemption.
   * @param from The address the shares are transferred from, or the zero address when minting
   * @param to The address the shares are transferred to, or the zero address when burning
   * @param value The amount of shares transferred
   */
  function _update(address from, address to, uint256 value) internal override {
    if (_reentrancyGuardEntered()) {
      revert ReentrancyGuardReentrantCall();
    }
    super._update(from, to, value);
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function generalManager() public view override returns (address) {
    return _getUniswapFulfillmentVaultStorage()._generalManager;
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function orderPool() public view override returns (address) {
    return IGeneralManager(generalManager()).orderPool();
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function usdx() public view override returns (address) {
    return _getUniswapFulfillmentVaultStorage()._usdx;
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function usdg() public view override returns (address) {
    return _getUniswapFulfillmentVaultStorage()._usdg;
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function collateralRoute(address collateral) public view override returns (CollateralRoute memory) {
    return _getUniswapFulfillmentVaultStorage()._routes[collateral];
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function permit2() public view override returns (address) {
    return _getUniswapFulfillmentVaultStorage()._permit2;
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function routerApproval(address router) public view override returns (RouterApproval) {
    return _getUniswapFulfillmentVaultStorage()._routerApprovals[router];
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function isAllowedRouter(address router) public view override returns (bool) {
    return _getUniswapFulfillmentVaultStorage()._routerApprovals[router] != RouterApproval.None;
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function setCollateralRoute(address collateral, CollateralRoute calldata route)
    external
    override
    onlyRole(DEFAULT_ADMIN_ROLE)
  {
    // An enabled route needs a real oracle and a premium strictly below 100%
    if (route.maxFillCost != 0 && (route.priceOracle == address(0) || route.maxPremiumBps >= Constants.BPS)) {
      revert InvalidCollateralRoute(collateral);
    }
    emit CollateralRouteSet(collateral, route.priceOracle, route.maxPremiumBps, route.maxFillCost);
    _getUniswapFulfillmentVaultStorage()._routes[collateral] = route;
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function setRouterApproval(address router, RouterApproval approval) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    _setRouterApproval(router, approval);
  }

  /**
   * @dev Sets the approval mode for a router. None removes the router from the allowlist.
   * @param router The address of the router
   * @param approval The approval mode for the router
   */
  function _setRouterApproval(address router, RouterApproval approval) internal {
    if (router == address(0)) {
      revert InvalidRouter(router);
    }
    emit RouterApprovalSet(router, approval);
    _getUniswapFulfillmentVaultStorage()._routerApprovals[router] = approval;
  }

  /// @inheritdoc IUniswapFulfillmentVault
  /// @dev Does not need a keeper role or paused-state
  function approveAssetToOrderPool(address asset) external override {
    emit AssetApproved(asset);
    IERC20(asset).approve(orderPool(), type(uint256).max);
  }

  /// @inheritdoc IUniswapFulfillmentVault
  function fillOrder(uint256 index, uint256[] calldata hintPrevIds, address router, bytes calldata swapCalldata)
    external
    override
    onlyRole(KEEPER_ROLE)
    whenNotPaused
    nonReentrant
  {
    // Load the order. The order pool deletes orders before processing, so a zeroed collateral means the
    // index was already processed, cancelled, or never existed.
    PurchaseOrder memory order = IOrderPool(orderPool()).orders(index);
    address collateral = order.mortgageParams.collateral;
    if (collateral == address(0)) {
      revert OrderAlreadyProcessed(index);
    }

    // An expired order is cancelled and refunded by processOrders; buying collateral for it would strand inventory
    bool expired = order.expiration < block.timestamp;
    uint256 collateralNeeded = order.mortgageParams.collateralAmount - order.orderAmounts.collateralCollected;
    uint256 usdgSpent = 0;
    if (!expired && collateralNeeded > 0) {
      usdgSpent =
        _swapForCollateral(collateral, collateralNeeded, order.orderAmounts.purchaseAmount, router, swapCalldata);
    }

    // Deliver. The order pool pulls the collateral via the standing approval and pays the vault the
    // purchase amount of USDX (plus the order's native gas fee).
    uint256 usdxBefore = IERC20(usdx()).balanceOf(address(this));
    _processOrder(index, hintPrevIds);

    if (expired) {
      emit OrderExpiredSwept(index);
    } else {
      emit OrderFilled(
        index, collateral, collateralNeeded, usdgSpent, IERC20(usdx()).balanceOf(address(this)) - usdxBefore
      );
    }

    // Send collected fees to the keeper by sending the native balance
    (bool success,) = _msgSender().call{value: address(this).balance}("");
    if (!success) {
      revert FailedToWithdrawNativeGas(address(this).balance);
    }
  }

  /**
   * @dev Processes a single order through the order pool
   * @param index The index of the order to process
   * @param hintPrevIds The hint prev ids for the relevant mortgage queues
   */
  function _processOrder(uint256 index, uint256[] calldata hintPrevIds) internal {
    uint256[] memory indices = new uint256[](1);
    indices[0] = index;
    uint256[][] memory hintPrevIdsList = new uint256[][](1);
    hintPrevIdsList[0] = hintPrevIds;
    IOrderPool(orderPool()).processOrders(indices, hintPrevIdsList);
  }

  /**
   * @dev Withdraws USDG from USDX, executes the keeper-supplied swap calldata under a scoped approval, and
   *      enforces the oracle-anchored balance-delta invariants. Leftover USDG is redeposited into USDX so
   *      total assets are whole USDX again by the end of the transaction.
   * @param collateral The address of the collateral token
   * @param collateralNeeded The amount of collateral the order requires
   * @param purchaseAmount The amount of USDX the fill will return (the no-loss bound)
   * @param router The allowlisted router to execute the swap calldata against
   * @param swapCalldata The pre-encoded swap call
   * @return usdgSpent The amount of USDG consumed by the swap
   */
  function _swapForCollateral(
    address collateral,
    uint256 collateralNeeded,
    uint256 purchaseAmount,
    address router,
    bytes calldata swapCalldata
  ) internal returns (uint256 usdgSpent) {
    if (_getUniswapFulfillmentVaultStorage()._routerApprovals[router] == RouterApproval.None) {
      revert RouterNotAllowed(router);
    }
    uint256 maxUsdgIn = _withdrawBoundedSwapInput(collateral, collateralNeeded, purchaseAmount);
    usdgSpent = _executeSwap(collateral, collateralNeeded, maxUsdgIn, router, swapCalldata);
  }

  /**
   * @dev Computes the oracle-anchored spend bound for a fill and withdraws it from USDX as USDG
   * @param collateral The address of the collateral token
   * @param collateralNeeded The amount of collateral the order requires
   * @param purchaseAmount The amount of USDX the fill will return (the no-loss bound)
   * @return maxUsdgIn The maximum amount of USDG the swap may consume
   */
  function _withdrawBoundedSwapInput(address collateral, uint256 collateralNeeded, uint256 purchaseAmount)
    internal
    returns (uint256 maxUsdgIn)
  {
    UniswapFulfillmentVaultStorage storage $ = _getUniswapFulfillmentVaultStorage();
    CollateralRoute memory route = $._routes[collateral];
    if (route.maxFillCost == 0) {
      revert RouteNotConfigured(collateral);
    }

    // Oracle anchor. A stale oracle reverts here, so fills fail closed on a dead feed.
    (uint256 anchorCost,) = IPriceOracle(route.priceOracle).cost(collateralNeeded);
    if (anchorCost > route.maxFillCost) {
      revert FillTooLarge(anchorCost, route.maxFillCost);
    }

    // The swap may not consume more USD value than the oracle cost plus the configured premium, and never
    // more than the fill returns (no-loss gate)
    uint256 maxCost = anchorCost.mulDiv(Constants.BPS + route.maxPremiumBps, Constants.BPS);
    if (maxCost > purchaseAmount) {
      maxCost = purchaseAmount;
    }

    // Convert the 18-decimal bound to USDG units, rounding down
    (uint256 numerator, uint256 denominator) = IUSDX($._usdx).tokenScalars($._usdg);
    maxUsdgIn = maxCost.mulDiv(denominator, numerator);
    if (maxUsdgIn > 0) {
      IUSDX($._usdx).withdraw($._usdg, maxUsdgIn);
    }
  }

  /**
   * @dev Executes the keeper-supplied swap calldata under a scoped approval and enforces the balance-delta
   *      invariants. Leftover USDG is redeposited into USDX so total assets are whole USDX again.
   * @param collateral The address of the collateral token
   * @param collateralNeeded The amount of collateral the order requires
   * @param maxUsdgIn The maximum amount of USDG the swap may consume
   * @param router The allowlisted router to execute the swap calldata against
   * @param swapCalldata The pre-encoded swap call
   * @return usdgSpent The amount of USDG consumed by the swap
   */
  function _executeSwap(
    address collateral,
    uint256 collateralNeeded,
    uint256 maxUsdgIn,
    address router,
    bytes calldata swapCalldata
  ) internal returns (uint256 usdgSpent) {
    UniswapFulfillmentVaultStorage storage $ = _getUniswapFulfillmentVaultStorage();
    IERC20 usdg_ = IERC20($._usdg);

    uint256 collateralBefore = IERC20(collateral).balanceOf(address(this));
    uint256 usdgBefore = usdg_.balanceOf(address(this));
    _callRouter(usdg_, router, maxUsdgIn, swapCalldata);

    uint256 usdgAfter = usdg_.balanceOf(address(this));
    usdgSpent = usdgBefore > usdgAfter ? usdgBefore - usdgAfter : 0;
    if (usdgSpent > maxUsdgIn) {
      revert OverSpent(usdgSpent, maxUsdgIn);
    }
    uint256 collateralAfter = IERC20(collateral).balanceOf(address(this));
    uint256 collateralOut = collateralAfter > collateralBefore ? collateralAfter - collateralBefore : 0;
    if (collateralOut < collateralNeeded) {
      revert InsufficientCollateralOut(collateralOut, collateralNeeded);
    }

    // Redeposit leftover USDG into USDX so total assets are whole again. The vault holds IGNORE_CAP_ROLE on
    // USDX so the redeposit cannot be blocked by a supply cap.
    if (usdgAfter > 0) {
      usdg_.forceApprove($._usdx, usdgAfter);
      IUSDX($._usdx).deposit($._usdg, usdgAfter);
    }
  }

  /**
   * @dev Calls the router with a USDG spend of at most maxUsdgIn granted under the router's approval mode, and
   *      revokes it before returning. ERC20 mode approves the router on the token. Permit2 mode approves Permit2
   *      on the token and grants the router a Permit2 allowance expiring at the current timestamp. No allowance
   *      outlives the call.
   * @param usdg_ The USDG token
   * @param router The allowlisted router to call
   * @param maxUsdgIn The maximum amount of USDG the router may pull
   * @param swapCalldata The pre-encoded swap call
   */
  function _callRouter(IERC20 usdg_, address router, uint256 maxUsdgIn, bytes calldata swapCalldata) internal {
    UniswapFulfillmentVaultStorage storage $ = _getUniswapFulfillmentVaultStorage();
    if ($._routerApprovals[router] == RouterApproval.Permit2) {
      address permit2_ = $._permit2;
      usdg_.forceApprove(permit2_, maxUsdgIn);
      IAllowanceTransfer(permit2_).approve(address(usdg_), router, maxUsdgIn.toUint160(), block.timestamp.toUint48());
      router.functionCall(swapCalldata);
      IAllowanceTransfer(permit2_).approve(address(usdg_), router, 0, 0);
      usdg_.forceApprove(permit2_, 0);
    } else {
      usdg_.forceApprove(router, maxUsdgIn);
      router.functionCall(swapCalldata);
      usdg_.forceApprove(router, 0);
    }
  }
}
