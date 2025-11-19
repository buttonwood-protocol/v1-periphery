// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IRolloverVault} from "./interfaces/IRolloverVault/IRolloverVault.sol";
import {IERC165, LiquidityVault} from "./LiquidityVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGeneralManager} from "@core/interfaces/IGeneralManager/IGeneralManager.sol";
import {IOriginationPool} from "@core/interfaces/IOriginationPool/IOriginationPool.sol";
import {IOriginationPoolScheduler} from "@core/interfaces/IOriginationPoolScheduler/IOriginationPoolScheduler.sol";

/**
 * @title FulfillmentVault
 * @author @SocksNFlops
 * @notice The RolloverVault contract used to automatically rotate unused assets into origination pools.
 */
contract RolloverVault is LiquidityVault, IRolloverVault {
  using Math for uint256;

  /// @notice Allow the contract to receive network native tokens (HYPE bridged from Core)
  receive() external payable {}

  /**
   * @custom:storage-location erc7201:buttonwood.storage.RolloverVault
   * @notice The storage for the RolloverVault contract
   * @param _usdx The address of the USDX token
   * @param _consol The address of the consol token
   * @param _generalManager The address of the general manager
   * @param _originationPools The addresses of the origination pools the rollover vault currently has a balance in
   * @param _poolIndex Mapping of origination pool addresses to their index in the _originationPools array (offset by 1)
   */
  struct RolloverVaultStorage {
    address _usdx;
    address _consol;
    address _generalManager;
    address[] _originationPools;
    mapping(address => uint256) _poolIndex;
  }

  /**
   * @notice The storage location of the RolloverVault contract
   * @dev keccak256(abi.encode(uint256(keccak256("buttonwood.storage.RolloverVault")) - 1)) & ~bytes32(uint256(0xff))
   */
  // solhint-disable-next-line const-name-snakecase
  bytes32 private constant RolloverVaultStorageLocation =
    0x3f3d57a95a7cc1b3218bff2f60330bfeb789b9a101fe5e689535b16f8256e000;

  /**
   * @dev Gets the storage location of the RolloverVault contract
   * @return $ The storage location of the RolloverVault contract
   */
  function _getRolloverVaultStorage() private pure returns (RolloverVaultStorage storage $) {
    // solhint-disable-next-line no-inline-assembly
    assembly {
      $.slot := RolloverVaultStorageLocation
    }
  }

  /**
   * @dev Initializes the RolloverVault contract and calls parent initializers
   * @param name The name of the rollover vault
   * @param symbol The symbol of the rollover vault
   * @param _decimals The decimals of the rollover vault
   * @param _decimalsOffset The decimals offset for measuring internal precision of shares
   * @param _generalManager The address of the general manager
   */
  // solhint-disable-next-line func-name-mixedcase
  function __RolloverVault_init(
    string memory name,
    string memory symbol,
    uint8 _decimals,
    uint8 _decimalsOffset,
    address _generalManager
  ) internal onlyInitializing {
    __ERC20_init_unchained(name, symbol);
    address[] memory depositableAssets = new address[](1);
    depositableAssets[0] = IGeneralManager(_generalManager).usdx();
    address[] memory redeemableAssets = new address[](2);
    redeemableAssets[0] = IGeneralManager(_generalManager).usdx();
    redeemableAssets[1] = IGeneralManager(_generalManager).consol();
    __LiquidityVault_init_unchained(_decimals, _decimalsOffset, depositableAssets, redeemableAssets);
    __RolloverVault_init_unchained(_generalManager);
  }

  /**
   * @dev Initializes the RolloverVault contract only
   * @param _generalManager The address of the general manager
   */
  // solhint-disable-next-line func-name-mixedcase
  function __RolloverVault_init_unchained(address _generalManager) internal onlyInitializing {
    RolloverVaultStorage storage $ = _getRolloverVaultStorage();
    $._generalManager = _generalManager;
    $._usdx = IGeneralManager(_generalManager).usdx();
    $._consol = IGeneralManager(_generalManager).consol();
  }

  /**
   * @notice Initializes the RolloverVault contract
   * @param name The name of the rollover vault
   * @param symbol The symbol of the rollover vault
   * @param _decimals The decimals of the rollover vault
   * @param _decimalsOffset The decimals offset for measuring internal precision of shares
   * @param _generalManager The address of the general manager
   * @param admin The address of the admin for the rollover vault
   */
  function initialize(
    string memory name,
    string memory symbol,
    uint8 _decimals,
    uint8 _decimalsOffset,
    address _generalManager,
    address admin
  ) external initializer {
    __RolloverVault_init(name, symbol, _decimals, _decimalsOffset, _generalManager);
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) public view override(LiquidityVault) returns (bool) {
    return super.supportsInterface(interfaceId) || interfaceId == type(IRolloverVault).interfaceId;
  }

  /// @inheritdoc LiquidityVault
  function _totalAssets() internal view override returns (uint256) {
    RolloverVaultStorage storage $ = _getRolloverVaultStorage();
    uint256 total = 0;
    // Iterate over all of the origination pools and add of the USDX and Consol balances that will be redeemed by the rollover vault
    for (uint256 i = 0; i < $._originationPools.length; i++) {
      IOriginationPool ogPool = IOriginationPool($._originationPools[i]);
      uint256 ogPoolTotalSupply = ogPool.totalSupply();
      uint256 ogPoolUsdxBalance = IERC20(usdx()).balanceOf(address(ogPool));
      uint256 ogPoolConsolBalance = IERC20(consol()).balanceOf(address(ogPool));
      uint256 ogPoolBalance = ogPool.balanceOf(address(this));
      total += Math.mulDiv(ogPoolBalance, ogPoolUsdxBalance, ogPoolTotalSupply)
        + Math.mulDiv(ogPoolBalance, ogPoolConsolBalance, ogPoolTotalSupply);
    }
    // Add the USDX and Consol balances that are currently in the rollover vault
    total += IERC20(usdx()).balanceOf(address(this)) + IERC20(consol()).balanceOf(address(this));
    // Return the total assets
    return total;
  }

  /// @inheritdoc IRolloverVault
  function usdx() public view override returns (address) {
    return _getRolloverVaultStorage()._usdx;
  }

  /// @inheritdoc IRolloverVault
  function consol() public view override returns (address) {
    return _getRolloverVaultStorage()._consol;
  }

  /// @inheritdoc IRolloverVault
  function generalManager() public view override returns (address) {
    return _getRolloverVaultStorage()._generalManager;
  }

  /// @inheritdoc IRolloverVault
  function originationPoolScheduler() public view returns (address) {
    return IGeneralManager(generalManager()).originationPoolScheduler();
  }

  /// @inheritdoc IRolloverVault
  function originationPools() external view override returns (address[] memory) {
    return _getRolloverVaultStorage()._originationPools;
  }

  /// @inheritdoc IRolloverVault
  function isTracked(address originationPool) external view returns (bool) {
    return _getRolloverVaultStorage()._poolIndex[originationPool] != 0;
  }

  /// @inheritdoc IRolloverVault
  function depositOriginationPool(address originationPool, uint256 amount) external onlyRole(KEEPER_ROLE) whenPaused {
    // Get the storage
    RolloverVaultStorage storage $ = _getRolloverVaultStorage();

    // Validate that the origination pool is registered
    if (!IOriginationPoolScheduler(originationPoolScheduler()).isRegistered(originationPool)) {
      revert OriginationPoolNotRegistered(originationPool);
    }

    // Validate that the amount is not zero
    if (amount == 0) {
      revert AmountIsZero();
    }

    // Check if the origination pool is already being tracked. If not, add it to the maps
    if ($._poolIndex[originationPool] == 0) {
      $._poolIndex[originationPool] = $._originationPools.length + 1;
      $._originationPools.push(originationPool);
      // Update the assets
      _updateAssets(originationPool, true, true);
      // Emit the origination pool added event
      emit OriginationPoolAdded(originationPool);
    }

    // Emit the deposit event
    emit OriginationPoolDeposited(originationPool, amount);

    // Deposit usdx into the origination pool
    IERC20(usdx()).approve(originationPool, amount);
    IOriginationPool(originationPool).deposit(amount);
  }

  /// @inheritdoc IRolloverVault
  function redeemOriginationPool(address originationPool) external onlyRole(KEEPER_ROLE) whenPaused {
    // Get the storage
    RolloverVaultStorage storage $ = _getRolloverVaultStorage();

    // Validate the the origination pool is being tracked
    if ($._poolIndex[originationPool] == 0) {
      revert OriginationPoolNotTracked(originationPool);
    }

    // Replace the origination pool with the last origination pool in the list
    $._originationPools[$._poolIndex[originationPool] - 1] = $._originationPools[$._originationPools.length - 1];
    $._poolIndex[$._originationPools[$._poolIndex[originationPool] - 1]] = $._poolIndex[originationPool];
    delete $._poolIndex[originationPool];
    $._originationPools.pop();

    // Update the assets
    _updateAssets(originationPool, true, false);

    // Emit the redeem event
    uint256 ogPoolBalance = IOriginationPool(originationPool).balanceOf(address(this));
    emit OriginationPoolRedeemed(originationPool, ogPoolBalance);

    // Redeem entire balance of origination pool
    IOriginationPool(originationPool).redeem(ogPoolBalance);
  }
}
