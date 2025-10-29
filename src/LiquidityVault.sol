// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ILiquidityVault} from "./interfaces/ILiquidityVault/ILiquidityVault.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LiquidityVault
 * @author @SocksNFlops
 * @notice The base liquidity vault contract used by FulfillmentVault and RolloverVault
 */
abstract contract LiquidityVault is
  ILiquidityVault,
  ERC165Upgradeable,
  AccessControlUpgradeable,
  PausableUpgradeable,
  UUPSUpgradeable,
  ERC20Upgradeable
{
  using Math for uint256;
  using SafeERC20 for IERC20;

  /// @inheritdoc ILiquidityVault
  bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

  /// @inheritdoc ILiquidityVault
  bytes32 public constant WHITELIST_ROLE = keccak256("WHITELIST_ROLE");

  /**
   * @custom:storage-location erc7201:buttonwood.storage.LiquidityVault
   * @notice The storage for the LiquidityVault contract
   * @param _decimals The decimals of the vault
   * @param _decimalsOffset The decimals offset for measuring internal precision of shares
   * @param _depositableAssets The addresses of the depositable assets
   * @param _depositableAssetIndex The index of the depositable assets (one-indexed)
   * @param _redeemableAssets The addresses of the redeemable assets
   * @param _redeemableAssetIndex The index of the redeemable assets (one-indexed)
   */
  struct LiquidityVaultStorage {
    uint8 _decimals;
    uint8 _decimalsOffset;
    address[] _depositableAssets;
    mapping(address => uint256) _depositableAssetIndex;
    address[] _redeemableAssets;
    mapping(address => uint256) _redeemableAssetIndex;
    bool _whitelistEnforced;
  }

  /**
   * @dev The storage location of the LiquidityVault contract
   * @dev keccak256(abi.encode(uint256(keccak256("buttonwood.storage.LiquidityVault")) - 1)) & ~bytes32(uint256(0xff))
   */
  // solhint-disable-next-line const-name-snakecase
  bytes32 private constant LiquidityVaultStorageLocation =
    0x279d7268e134fe9470212f64c617da0df55170c0eafa03169b80558ce404b000;

  /**
   * @dev Gets the storage location of the LiquidityVault contract
   * @return $ The storage location of the LiquidityVault contract
   */
  function _getLiquidityVaultStorage() private pure returns (LiquidityVaultStorage storage $) {
    // solhint-disable-next-line no-inline-assembly
    assembly {
      $.slot := LiquidityVaultStorageLocation
    }
  }

  /**
   * @dev Initializes the LiquidityVault contract and calls parent initializers
   */
  // solhint-disable-next-line func-name-mixedcase
  function __LiquidityVault_init(
    string memory name,
    string memory symbol,
    uint8 _decimals,
    uint8 _decimalsOffset,
    address[] memory _depositableAssets,
    address[] memory _redeemableAssets
  ) internal onlyInitializing {
    __ERC20_init_unchained(name, symbol);
    __LiquidityVault_init_unchained(_decimals, _decimalsOffset, _depositableAssets, _redeemableAssets);
  }

  /**
   * @dev Initializes the LiquidityVault contract only
   */
  // solhint-disable-next-line func-name-mixedcase
  function __LiquidityVault_init_unchained(
    uint8 _decimals,
    uint8 _decimalsOffset,
    address[] memory _depositableAssets,
    address[] memory _redeemableAssets
  ) internal onlyInitializing {
    LiquidityVaultStorage storage $ = _getLiquidityVaultStorage();
    $._decimals = _decimals;
    $._decimalsOffset = _decimalsOffset;
    $._depositableAssets = _depositableAssets;
    for (uint256 i = 0; i < _depositableAssets.length; i++) {
      $._depositableAssetIndex[_depositableAssets[i]] = i + 1;
    }
    $._redeemableAssets = _redeemableAssets;
    for (uint256 i = 0; i < _redeemableAssets.length; i++) {
      $._redeemableAssetIndex[_redeemableAssets[i]] = i + 1;
    }
    $._whitelistEnforced = false;
  }

  /**
   * @notice Initializes the LiquidityVault contract
   * @param name The name of the liquidity vault
   * @param symbol The symbol of the liquidity vault
   * @param _decimals The decimals of the liquidity vault
   * @param _decimalsOffset The decimals offset for measuring internal precision of shares
   * @param _depositableAssets The addresses of the depositable assets
   * @param _redeemableAssets The addresses of the redeemable assets
   */
  function initialize(
    string memory name,
    string memory symbol,
    uint8 _decimals,
    uint8 _decimalsOffset,
    address[] memory _depositableAssets,
    address[] memory _redeemableAssets,
    address admin
  ) external virtual initializer {
    __LiquidityVault_init(name, symbol, _decimals, _decimalsOffset, _depositableAssets, _redeemableAssets);
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId)
    public
    view
    virtual
    override(AccessControlUpgradeable, ERC165Upgradeable)
    returns (bool)
  {
    return super.supportsInterface(interfaceId) || interfaceId == type(ILiquidityVault).interfaceId
      || interfaceId == type(IERC165).interfaceId || interfaceId == type(IAccessControl).interfaceId
      || interfaceId == type(IERC1822Proxiable).interfaceId || interfaceId == type(IERC20).interfaceId
      || interfaceId == type(IERC20Metadata).interfaceId;
  }

  /**
   * @dev Authorizes the upgrade of the contract. Only the admin can authorize the upgrade
   * @param newImplementation The address of the new implementation
   */
  // solhint-disable-next-line no-empty-blocks
  function _authorizeUpgrade(address newImplementation) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}

  /// @dev When whitelist is enforced, the sender must have the WHITELIST_ROLE. Otherwise, WHITELIST_ROLE is not required.
  modifier checkWhitelistEnforced() {
    if (_getLiquidityVaultStorage()._whitelistEnforced) {
      _checkRole(WHITELIST_ROLE, _msgSender());
    }
    _;
  }

  /// @inheritdoc ILiquidityVault
  function whitelistEnforced() public view virtual override returns (bool) {
    return _getLiquidityVaultStorage()._whitelistEnforced;
  }

  /// @inheritdoc ILiquidityVault
  function setWhitelistEnforced(bool enforced) external virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
    emit WhitelistEnforced(enforced);
    _getLiquidityVaultStorage()._whitelistEnforced = enforced;
  }

  /// @inheritdoc IERC20Metadata
  function decimals() public view virtual override returns (uint8) {
    return _getLiquidityVaultStorage()._decimals;
  }

  /// @inheritdoc ILiquidityVault
  function decimalsOffset() public view virtual override returns (uint8) {
    return _getLiquidityVaultStorage()._decimalsOffset;
  }

  /// @inheritdoc ILiquidityVault
  function depositableAssets() public view virtual override returns (address[] memory) {
    return _getLiquidityVaultStorage()._depositableAssets;
  }

  /// @inheritdoc ILiquidityVault
  function redeemableAssets() public view virtual override returns (address[] memory) {
    return _getLiquidityVaultStorage()._redeemableAssets;
  }

  function _updateAssets(address asset, bool isRedeemable, bool add) internal {
    // Fetch storage
    LiquidityVaultStorage storage $ = _getLiquidityVaultStorage();

    if (isRedeemable) {
      if (add) {
        $._redeemableAssets.push(asset);
        $._redeemableAssetIndex[asset] = $._redeemableAssets.length;
      } else {
        $._redeemableAssets[$._redeemableAssetIndex[asset] - 1] = $._redeemableAssets[$._redeemableAssets.length - 1];
        $._redeemableAssetIndex[$._redeemableAssets[$._redeemableAssets.length - 1]] = $._redeemableAssetIndex[asset];
        $._redeemableAssets.pop();
        $._redeemableAssetIndex[asset] = 0;
      }
      emit RedeemableAssetsUpdated($._redeemableAssets);
    } else {
      if (add) {
        $._depositableAssets.push(asset);
        $._depositableAssetIndex[asset] = $._depositableAssets.length;
      } else {
        $._depositableAssets[$._depositableAssetIndex[asset] - 1] = $._depositableAssets[$._depositableAssets.length - 1];
        $._depositableAssetIndex[$._depositableAssets[$._depositableAssets.length - 1]] = $._depositableAssetIndex[asset];
        $._depositableAssets.pop();
        $._depositableAssetIndex[asset] = 0;
      }
      emit DepositableAssetsUpdated($._depositableAssets);
    }
  }

  function _totalAssets() internal view virtual returns (uint256);

  /// @inheritdoc ILiquidityVault
  function totalAssets() public view virtual override returns (uint256) {
    return _totalAssets();
  }

  /// @dev Internal conversion function (from assets to shares) with support for rounding direction.
  function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual returns (uint256) {
    return assets.mulDiv(totalSupply() + 10 ** decimalsOffset(), totalAssets() + 1, rounding);
  }

  /// @dev Internal conversion function (from shares to assets) with support for rounding direction.
  function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256[] memory) {
    uint256[] memory assets = new uint256[](redeemableAssets().length);
    for (uint256 i = 0; i < redeemableAssets().length; i++) {
      assets[i] = shares.mulDiv(IERC20(redeemableAssets()[i]).balanceOf(address(this)) + 1, totalSupply() + 10 ** decimalsOffset(), rounding);
    }
    return assets;
  }

  /// @inheritdoc ILiquidityVault
  function setPaused(bool paused) external virtual override onlyRole(KEEPER_ROLE) {
    if (paused) {
      _pause();
    } else {
      _unpause();
    }
  }

  /// @inheritdoc ILiquidityVault
  function deposit(address depositableAsset, uint256 assets) external virtual override whenNotPaused checkWhitelistEnforced {
    // Validate the depositable asset is in the depositable assets list
    if (_getLiquidityVaultStorage()._depositableAssetIndex[depositableAsset] == 0) {
      revert AssetNotDepositable(depositableAsset);
    }
    // Calculate the corresponding amount of shares for the deposited amount
    uint256 shares = _convertToShares(assets, Math.Rounding.Floor);
    // Mint the corresponding amount of shares to the sender
    _mint(msg.sender, shares);
    // Emit the deposited event
    emit Deposited(msg.sender, depositableAsset, assets, shares);
    // Transfer the depositable asset from the sender to the vault
    IERC20(depositableAsset).safeTransferFrom(msg.sender, address(this), assets);
  }

  /// @inheritdoc ILiquidityVault
  /// @dev No whitelist enforcement for redeeming. This prevents funds from being locked in the vault.
  function redeem(uint256 shares) external virtual override whenNotPaused {
    // Calculate the corresponding amount of assets for the redeemed shares
    uint256[] memory assetAmounts = _convertToAssets(shares, Math.Rounding.Floor);
    // Burn the corresponding amount of shares
    _burn(msg.sender, shares);

    // Cache the redeemable assets array
    address[] memory rAssets = redeemableAssets();

    // Emit the redeemed event
    emit Redeemed(msg.sender, rAssets, assetAmounts, shares);

    // Transfer the corresponding amount of redeemable assets to the sender
    for (uint256 i = 0; i < rAssets.length; i++) {
      IERC20(rAssets[i]).safeTransfer(msg.sender, assetAmounts[i]);
    }
  }
}
