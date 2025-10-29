// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IFulfillmentVault} from "./interfaces/IFulfillmentVault/IFulfillmentVault.sol";
import {IERC165, LiquidityVault} from "./LiquidityVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoreWriterLib, HLConstants, HLConversions} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
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
   * @param _nonce The ongoing nonce that generates distinct cloid values for exchanges on core
   */
  struct FulfillmentVaultStorage {
    address _wrappedNativeToken;
    address _generalManager;
    address _usdx;
    uint128 _nonce;
  }

  /**
   * @dev The storage location of the FulfillmentVault contract
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
   */
  // solhint-disable-next-line func-name-mixedcase
  function __FulfillmentVault_init_unchained(address _wrappedNativeToken, address _generalManager) internal onlyInitializing {
    FulfillmentVaultStorage storage $ = _getFulfillmentVaultStorage();
    $._wrappedNativeToken = _wrappedNativeToken;
    $._generalManager = _generalManager;
    $._usdx = IGeneralManager(generalManager()).usdx();
  }

  /**
   * @notice Initializes the FulfillmentVault contract
   * @param name The name of the liquidity vault
   * @param symbol The symbol of the liquidity vault
   * @param _decimals The decimals of the liquidity vault
   * @param _decimalsOffset The decimals offset for measuring internal precision of shares
   * @param _wrappedNativeToken The address of the wrapped native token
   * @param _generalManager The address of the general manager
   * @param admin The address of the admin
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
  function approveWhype() external {
    IWNT(wrappedNativeToken()).approve(orderPool(), type(uint256).max);
  }

  /// @inheritdoc IFulfillmentVault
  /// @dev Does not need a keeper role or paused-state
  function wrapHype() external {
    IWNT(wrappedNativeToken()).deposit{value: address(this).balance}();
  }

  /// @inheritdoc IFulfillmentVault
  function bridgeHypeFromCoreToEvm(uint256 amount) external override onlyRole(KEEPER_ROLE) whenPaused 
  {
    CoreWriterLib.bridgeToEvm(HLConstants.hypeTokenIndex(), amount, true);
  }

  /// @inheritdoc IFulfillmentVault
  function burnUsdx(uint256 amount) external override onlyRole(KEEPER_ROLE) whenPaused {
    IUSDX(usdx()).burn(amount);
  }

  // @inheritdoc IFulfillmentVault
  function withdrawUsdTokenFromUsdx(address usdToken, uint256 amount) external override onlyRole(KEEPER_ROLE) whenPaused {
    IUSDX(usdx()).withdraw(usdToken, amount);
  }

  /// @inheritdoc IFulfillmentVault
  function bridgeUsdTokenToCore(address usdToken, uint256 amount) external override onlyRole(KEEPER_ROLE) whenPaused {
    CoreWriterLib.bridgeToCore(usdToken, amount);
  }

  /// @inheritdoc IFulfillmentVault
  function tradeOnCore(uint32 index, bool isBuy, uint32 limitPx, uint64 sz) external override onlyRole(KEEPER_ROLE) whenPaused {
    // Get storage
    FulfillmentVaultStorage storage $ = _getFulfillmentVaultStorage();
    // Place an IOC limit order to trade usdc for asset on core
    CoreWriterLib.placeLimitOrder(HLConversions.spotToAssetId(index), isBuy, limitPx, sz, false, 3, $._nonce);
    $._nonce++;
  }

  /// @inheritdoc IFulfillmentVault
  function fillOrder(uint256 index, uint256[] memory hintPrevIds) external override onlyRole(KEEPER_ROLE) whenPaused {
    uint256[] memory indices = new uint256[](1);
    indices[0] = index;
    uint256[][] memory hintPrevIdsList = new uint256[][](1);
    hintPrevIdsList[0] = hintPrevIds;
    IOrderPool(orderPool()).processOrders(indices, hintPrevIdsList);
  }
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
