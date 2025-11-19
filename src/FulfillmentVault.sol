// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IFulfillmentVault} from "./interfaces/IFulfillmentVault/IFulfillmentVault.sol";
import {IERC165, LiquidityVault} from "./LiquidityVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoreWriterLib, HLConversions} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {IWNT} from "./interfaces/IWNT.sol";
import {IFulfillmentVault} from "./interfaces/IFulfillmentVault/IFulfillmentVault.sol";
import {IUSDX} from "@core/interfaces/IUSDX/IUSDX.sol";
import {IOrderPool} from "@core/interfaces/IOrderPool/IOrderPool.sol";
import {IGeneralManager} from "@core/interfaces/IGeneralManager/IGeneralManager.sol";

/**
 * @title FulfillmentVault
 * @author @SocksNFlops
 * @notice The FulfillmentVault contract used to fulfill orders on the protocol
 */
contract FulfillmentVault is LiquidityVault, IFulfillmentVault {
  using Math for uint256;
  using CoreWriterLib for *;

  /// @notice Allow the contract to receive network native tokens (HYPE bridged from Core)
  receive() external payable {}

  /**
   * @custom:storage-location erc7201:buttonwood.storage.FulfillmentVault
   * @notice The storage for the FulfillmentVault contract
   * @param _wrappedNativeToken The address of the wrapped native token
   * @param _generalManager The address of the general manager
   * @param _usdx The address of the USDX token
   * @param _nonce The ongoing nonce that generates distinct cloid values for exchanges on core
   */
  struct FulfillmentVaultStorage {
    address _wrappedNativeToken;
    address _generalManager;
    address _usdx;
    uint128 _nonce;
  }

  /**
   * @notice The storage location of the FulfillmentVault contract
   * @dev keccak256(abi.encode(uint256(keccak256("buttonwood.storage.FulfillmentVault")) - 1)) & ~bytes32(uint256(0xff))
   */
  // solhint-disable-next-line const-name-snakecase
  bytes32 private constant FulfillmentVaultStorageLocation =
    0x4b57f16710661390ada38fe64129442a589f51d339ba23973c82ad806b168200;

  /**
   * @dev Gets the storage location of the FulfillmentVault contract
   * @return $ The storage location of the FulfillmentVault contract
   */
  function _getFulfillmentVaultStorage() private pure returns (FulfillmentVaultStorage storage $) {
    // solhint-disable-next-line no-inline-assembly
    assembly {
      $.slot := FulfillmentVaultStorageLocation
    }
  }

  /**
   * @dev Initializes the FulfillmentVault contract and calls parent initializers
   * @param name The name of the fulfillment vault
   * @param symbol The symbol of the fulfillment vault
   * @param _decimals The decimals of the fulfillment vault
   * @param _decimalsOffset The decimals offset for measuring internal precision of shares
   * @param _wrappedNativeToken The address of the wrapped native token
   * @param _generalManager The address of the general manager
   */
  // solhint-disable-next-line func-name-mixedcase
  function __FulfillmentVault_init(
    string memory name,
    string memory symbol,
    uint8 _decimals,
    uint8 _decimalsOffset,
    address _wrappedNativeToken,
    address _generalManager
  ) internal onlyInitializing {
    __ERC20_init_unchained(name, symbol);
    address[] memory assets = new address[](1);
    assets[0] = IGeneralManager(_generalManager).usdx();
    __LiquidityVault_init_unchained(_decimals, _decimalsOffset, assets, assets);
    __FulfillmentVault_init_unchained(_wrappedNativeToken, _generalManager);
  }

  /**
   * @dev Initializes the FulfillmentVault contract only
   * @param _wrappedNativeToken The address of the wrapped native token
   * @param _generalManager The address of the general manager
   */
  // solhint-disable-next-line func-name-mixedcase
  function __FulfillmentVault_init_unchained(address _wrappedNativeToken, address _generalManager)
    internal
    onlyInitializing
  {
    FulfillmentVaultStorage storage $ = _getFulfillmentVaultStorage();
    $._wrappedNativeToken = _wrappedNativeToken;
    $._generalManager = _generalManager;
    $._usdx = IGeneralManager(generalManager()).usdx();
  }

  /**
   * @notice Initializes the FulfillmentVault contract
   * @param name The name of the fulfillment vault
   * @param symbol The symbol of the fulfillment vault
   * @param _decimals The decimals of the fulfillment vault
   * @param _decimalsOffset The decimals offset for measuring internal precision of shares
   * @param _wrappedNativeToken The address of the wrapped native token
   * @param _generalManager The address of the general manager
   * @param admin The address of the admin for the fulfillment vault
   */
  function initialize(
    string memory name,
    string memory symbol,
    uint8 _decimals,
    uint8 _decimalsOffset,
    address _wrappedNativeToken,
    address _generalManager,
    address admin
  ) external initializer {
    __FulfillmentVault_init(name, symbol, _decimals, _decimalsOffset, _wrappedNativeToken, _generalManager);
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) public view override(LiquidityVault) returns (bool) {
    return super.supportsInterface(interfaceId) || interfaceId == type(IFulfillmentVault).interfaceId;
  }

  /// @inheritdoc LiquidityVault
  /// @dev Both depositable and redeemable assets are the same asset, so we override totalAssets to return the balance of only the redeemable asset.
  function _totalAssets() internal view override returns (uint256) {
    return IERC20(usdx()).balanceOf(address(this));
  }

  /// @inheritdoc IFulfillmentVault
  function wrappedNativeToken() public view override returns (address) {
    return _getFulfillmentVaultStorage()._wrappedNativeToken;
  }

  /// @inheritdoc IFulfillmentVault
  function generalManager() public view override returns (address) {
    return _getFulfillmentVaultStorage()._generalManager;
  }

  /// @inheritdoc IFulfillmentVault
  function orderPool() public view override returns (address) {
    return IGeneralManager(generalManager()).orderPool();
  }

  /// @inheritdoc IFulfillmentVault
  function usdx() public view override returns (address) {
    return _getFulfillmentVaultStorage()._usdx;
  }

  /// @inheritdoc IFulfillmentVault
  function nonce() public view override returns (uint128) {
    return _getFulfillmentVaultStorage()._nonce;
  }

  /// @inheritdoc IFulfillmentVault
  /// @dev Does not need a keeper role or paused-state
  function approveAssetToOrderPool(address asset) external {
    emit AssetApproved(asset);
    IERC20(asset).approve(orderPool(), type(uint256).max);
  }

  /// @inheritdoc IFulfillmentVault
  /// @dev Does not need a keeper role or paused-state
  function wrapHype() external {
    emit HypeWrapped(address(this).balance);
    IWNT(wrappedNativeToken()).deposit{value: address(this).balance}();
  }

  /// @inheritdoc IFulfillmentVault
  /// @dev Does not need a keeper role or paused-state
  function unwrapHype() external {
    uint256 whypeBalance = IERC20(wrappedNativeToken()).balanceOf(address(this));
    emit WhypeUnwrapped(whypeBalance);
    IWNT(wrappedNativeToken()).withdraw(whypeBalance);
  }

  /// @inheritdoc IFulfillmentVault
  function bridgeAssetFromCoreToEvm(uint64 assetIndex, uint256 amount)
    external
    override
    onlyRole(KEEPER_ROLE)
    whenPaused
  {
    emit AssetBridgedFromCoreToEvm(assetIndex, amount);
    CoreWriterLib.bridgeToEvm(assetIndex, amount, true);
  }

  /// @inheritdoc IFulfillmentVault
  function burnUsdx(uint256 amount) external override onlyRole(KEEPER_ROLE) whenPaused {
    emit UsdxBurned(amount);
    IUSDX(usdx()).burn(amount);
  }

  /// @inheritdoc IFulfillmentVault
  function withdrawUsdTokenFromUsdx(address usdToken, uint256 amount)
    external
    override
    onlyRole(KEEPER_ROLE)
    whenPaused
  {
    emit UsdTokenWithdrawnFromUsdx(usdToken, amount);
    IUSDX(usdx()).withdraw(usdToken, amount);
  }

  /// @inheritdoc IFulfillmentVault
  function depositUsdTokenToUsdx(address usdToken, uint256 amount) external override onlyRole(KEEPER_ROLE) whenPaused {
    emit UsdTokenDepositedToUsdx(usdToken, amount);
    IERC20(usdToken).approve(address(usdx()), amount);
    IUSDX(usdx()).deposit(usdToken, amount);
  }

  /// @inheritdoc IFulfillmentVault
  function bridgeAssetFromEvmToCore(address asset, uint256 amount) external override onlyRole(KEEPER_ROLE) whenPaused {
    emit AssetBridgedFromEvmToCore(asset, amount);
    CoreWriterLib.bridgeToCore(asset, amount);
  }

  /// @inheritdoc IFulfillmentVault
  function tradeOnCore(uint32 spotId, bool isBuy, uint64 limitPx, uint64 sz)
    external
    override
    onlyRole(KEEPER_ROLE)
    whenPaused
  {
    // Get storage
    FulfillmentVaultStorage storage $ = _getFulfillmentVaultStorage();
    // Emit event
    emit TradeOnCore(spotId, isBuy, limitPx, sz, $._nonce);
    // Place an IOC limit order to trade usdc for asset on core
    CoreWriterLib.placeLimitOrder(HLConversions.spotToAssetId(spotId), isBuy, limitPx, sz, false, 3, $._nonce);
    $._nonce++;
  }

  /// @inheritdoc IFulfillmentVault
  function fillOrder(uint256 index, uint256[] memory hintPrevIds) external override onlyRole(KEEPER_ROLE) whenPaused {
    uint256[] memory indices = new uint256[](1);
    indices[0] = index;
    uint256[][] memory hintPrevIdsList = new uint256[][](1);
    hintPrevIdsList[0] = hintPrevIds;
    // Emit event
    emit OrderFilled(index, hintPrevIds);
    IOrderPool(orderPool()).processOrders(indices, hintPrevIdsList);
  }
}
