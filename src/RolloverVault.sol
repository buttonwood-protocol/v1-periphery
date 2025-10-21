// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IFulfillmentVault} from "./interfaces/IFulfillmentVault/IFulfillmentVault.sol";
import {IERC165, LiquidityVault} from "./LiquidityVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FulfillmentVault
 * @author @SocksNFlops
 * @notice The RolloverVault contract used to automatically rotate unused assets into origination pools.
 */
contract RolloverVault is LiquidityVault{
  using Math for uint256;

  /**
   * @dev Initializes the FulfillmentVault contract and calls parent initializers
   */
  // solhint-disable-next-line func-name-mixedcase
  function __FulfillmentVault_init(string memory name, string memory symbol, uint8 _decimals, uint8 _decimalsOffset, address _depositableAsset, address _redeemableAsset) internal onlyInitializing {
    __ERC20_init_unchained(name, symbol);
    __LiquidityVault_init_unchained(_decimals, _decimalsOffset, _depositableAsset, _redeemableAsset);
  }

  /**
   * @dev Initializes the FulfillmentVault contract only
   */
  // solhint-disable-next-line func-name-mixedcase
  function __FulfillmentVault_init_unchained() internal onlyInitializing {}

  /**
   * @notice Initializes the FulfillmentVault contract
   * @param name The name of the liquidity vault
   * @param symbol The symbol of the liquidity vault
   * @param _decimals The decimals of the liquidity vault
   * @param _decimalsOffset The decimals offset for measuring internal precision of shares
   * @param _depositableAsset The address of the depositable asset
   * @param _redeemableAsset The address of the redeemable asset
   */
  function initialize(string memory name, string memory symbol, uint8 _decimals, uint8 _decimalsOffset, address _depositableAsset, address _redeemableAsset) external override initializer {
    __FulfillmentVault_init(name, symbol, _decimals, _decimalsOffset, _depositableAsset, _redeemableAsset);
    __LiquidityVault_init_unchained(_decimals, _decimalsOffset, _depositableAsset, _redeemableAsset);
    _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId)
    public
    view
    override(LiquidityVault)
    returns (bool)
  {
    return super.supportsInterface(interfaceId) || interfaceId == type(IFulfillmentVault).interfaceId;
  }

  /**
   * @dev Authorizes the upgrade of the contract. Only the admin can authorize the upgrade
   * @param newImplementation The address of the new implementation
   */
  // solhint-disable-next-line no-empty-blocks
  function _authorizeUpgrade(address newImplementation) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}


  /// @inheritdoc LiquidityVault
  function _totalAssets() internal view override returns (uint256) {
    revert("Not implemented");
  }
}

/**
 * RolloverVault:
 * - Keeper Functions:
 *   - Enter origination pool
 *   - Exit origination pool [Permissionless]
 * - Special Considerations:
 *   - Not just withdrawing usdx + consol, but also all of the OGPool receipt tokens
 *   - Need to configure a % usable in each epoch (this way there is always an ogpool available)
 *
 */