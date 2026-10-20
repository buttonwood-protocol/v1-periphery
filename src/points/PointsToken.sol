// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IPointsToken} from "../interfaces/IPointsToken/IPointsToken.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title PointsToken
 * @author @SocksNFlops
 * @notice A permanently non-transferable ERC-20. Balances change only through `mint` (MINTER_ROLE) and `burn`
 * (BURNER_ROLE). `transfer`, `transferFrom` and `approve` always revert and `allowance` is always zero, so wallets
 * cannot build a working send or approval for it. There is no permit and no admin override.
 */
contract PointsToken is IPointsToken, AccessControlUpgradeable, UUPSUpgradeable, ERC20Upgradeable {
  /// @inheritdoc IPointsToken
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

  /// @inheritdoc IPointsToken
  bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

  /**
   * @custom:storage-location erc7201:buttonwood.storage.PointsToken
   * @notice The storage for the PointsToken contract
   * @param _decimals The decimals of the token
   */
  struct PointsTokenStorage {
    uint8 _decimals;
  }

  /**
   * @notice The storage location of the PointsToken contract
   * @dev keccak256(abi.encode(uint256(keccak256("buttonwood.storage.PointsToken")) - 1)) & ~bytes32(uint256(0xff))
   */
  // solhint-disable-next-line const-name-snakecase
  bytes32 private constant PointsTokenStorageLocation =
    0x610dc46ab039d4b6d6c0030441693d9675226bbe8c976e204412a1760dab4500;

  /**
   * @dev Gets the storage location of the PointsToken contract
   * @return $ The storage location of the PointsToken contract
   */
  function _getPointsTokenStorage() private pure returns (PointsTokenStorage storage $) {
    // solhint-disable-next-line no-inline-assembly
    assembly {
      $.slot := PointsTokenStorageLocation
    }
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @notice Initializes the PointsToken contract
   * @param name The name of the token
   * @param symbol The symbol of the token
   * @param _decimals The decimals of the token
   * @param admin The address granted DEFAULT_ADMIN_ROLE
   */
  function initialize(string memory name, string memory symbol, uint8 _decimals, address admin) external initializer {
    __ERC20_init(name, symbol);
    __AccessControl_init();
    __UUPSUpgradeable_init();
    _getPointsTokenStorage()._decimals = _decimals;
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
    return super.supportsInterface(interfaceId) || interfaceId == type(IPointsToken).interfaceId
      || interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC20Metadata).interfaceId;
  }

  /// @inheritdoc UUPSUpgradeable
  // solhint-disable-next-line no-empty-blocks
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  /// @inheritdoc IERC20Metadata
  function decimals() public view override returns (uint8) {
    return _getPointsTokenStorage()._decimals;
  }

  /// @inheritdoc IPointsToken
  function mint(address to, uint256 amount) external override onlyRole(MINTER_ROLE) {
    _mint(to, amount);
  }

  /// @inheritdoc IPointsToken
  function burn(address from, uint256 amount) external override onlyRole(BURNER_ROLE) {
    _burn(from, amount);
  }

  /**
   * @notice Always reverts: points cannot be transferred
   * @param to The would-be receiver
   * @param value The would-be amount
   * @return Never returns
   */
  function transfer(address to, uint256 value) public view override returns (bool) {
    revert TransfersDisabled(_msgSender(), to, value);
  }

  /**
   * @notice Always reverts: points cannot be transferred
   * @param from The would-be sender
   * @param to The would-be receiver
   * @param value The would-be amount
   * @return Never returns
   */
  function transferFrom(address from, address to, uint256 value) public pure override returns (bool) {
    revert TransfersDisabled(from, to, value);
  }

  /**
   * @notice Always reverts: points have no allowances
   * @param spender The would-be spender
   * @param value The would-be allowance
   * @return Never returns
   */
  function approve(address spender, uint256 value) public view override returns (bool) {
    revert ApprovalsDisabled(_msgSender(), spender, value);
  }

  /**
   * @dev Rejects every balance change that is not a mint (from zero) or a burn (to zero)
   * @param from The sender, zero for a mint
   * @param to The receiver, zero for a burn
   * @param value The amount moved
   */
  function _update(address from, address to, uint256 value) internal override {
    if (from != address(0) && to != address(0)) {
      revert TransfersDisabled(from, to, value);
    }
    super._update(from, to, value);
  }
}
