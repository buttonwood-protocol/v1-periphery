// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IPointsMinter} from "../interfaces/IPointsMinter/IPointsMinter.sol";
import {PointsMinterConfig, WalletRecord, LendDay} from "../interfaces/IPointsMinter/PointsMinterTypes.sol";
import {IPointsToken} from "../interfaces/IPointsToken/IPointsToken.sol";
import {ILiquidityVault} from "../interfaces/ILiquidityVault/ILiquidityVault.sol";
import {ILoanManager} from "@core/interfaces/ILoanManager/ILoanManager.sol";
import {MortgagePosition} from "@core/types/MortgagePosition.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title PointsMinter
 * @author @SocksNFlops
 * @notice Registers wallets and mints PointsToken. Borrow credits are read from the LoanManager (one per loan, clipped
 * per wallet); lend credits are submitted per day by LEND_CREDITOR_ROLE and bounded by the RolloverVault's total
 * assets / 7. Every mint is base points times the wallet's multiplier at that moment, computed before the credit is
 * recorded, so boosters never apply retroactively. Tiers read only points for activity before genesis close: loans
 * originated before it and lend days that start before it, whenever they are credited.
 */
contract PointsMinter is
  IPointsMinter,
  AccessControlUpgradeable,
  EIP712Upgradeable,
  PausableUpgradeable,
  UUPSUpgradeable
{
  /// @inheritdoc IPointsMinter
  bytes32 public constant LEND_CREDITOR_ROLE = keccak256("LEND_CREDITOR_ROLE");

  /// @inheritdoc IPointsMinter
  bytes32 public constant REGISTRATION_TYPEHASH = keccak256("Registration(address wallet,uint256 expiry)");

  /// @dev Basis points denominator; a multiplier of BPS is 1.0x
  uint256 private constant BPS = 10_000;

  /// @dev Upper bound on any multiplier (1.45x)
  uint256 private constant MAX_MULTIPLIER_BPS = 14_500;

  /// @dev Upper bound on the lend tolerance (10%)
  uint256 private constant MAX_LEND_TOLERANCE_BPS = 1_000;

  /// @dev One dollar in USDX units (USDX, Consol and loan amounts use 18 decimals)
  uint256 private constant USD_UNIT = 1e18;

  /// @dev Lend points accrue at one point per dollar per this many days
  uint256 private constant LEND_DAYS_PER_POINT = 7;

  /**
   * @custom:storage-location erc7201:buttonwood.storage.PointsMinter
   * @notice The storage for the PointsMinter contract
   * @param _pointsToken The PointsToken minted by this contract
   * @param _pointUnit The smallest unit of one whole point
   * @param _config The program configuration
   * @param _registeredCount The number of wallets registered (the last whitelist number assigned)
   * @param _wallets The points record of each wallet
   * @param _creditedLoan Whether each mortgage token id has been credited
   * @param _lendCredited Whether each (day, wallet) pair has been credited
   * @param _lendDays The lend accounting of each day
   */
  struct PointsMinterStorage {
    address _pointsToken;
    uint256 _pointUnit;
    PointsMinterConfig _config;
    uint256 _registeredCount;
    mapping(address => WalletRecord) _wallets;
    mapping(uint256 => bool) _creditedLoan;
    mapping(uint256 => mapping(address => bool)) _lendCredited;
    mapping(uint256 => LendDay) _lendDays;
  }

  /**
   * @notice The storage location of the PointsMinter contract
   * @dev keccak256(abi.encode(uint256(keccak256("buttonwood.storage.PointsMinter")) - 1)) & ~bytes32(uint256(0xff))
   */
  // solhint-disable-next-line const-name-snakecase
  bytes32 private constant PointsMinterStorageLocation =
    0x4de64b8f9574cc39251469a79c0f10af4bc675a4d84ab1d0e0e2059d2850ce00;

  /**
   * @dev Gets the storage location of the PointsMinter contract
   * @return $ The storage location of the PointsMinter contract
   */
  function _getPointsMinterStorage() private pure returns (PointsMinterStorage storage $) {
    // solhint-disable-next-line no-inline-assembly
    assembly {
      $.slot := PointsMinterStorageLocation
    }
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @notice Initializes the PointsMinter contract
   * @param _pointsToken The PointsToken to mint; its decimals fix the point unit
   * @param _config The initial program configuration
   * @param admin The address granted DEFAULT_ADMIN_ROLE
   */
  function initialize(address _pointsToken, PointsMinterConfig calldata _config, address admin) external initializer {
    __AccessControl_init();
    __EIP712_init("PointsMinter", "1");
    __Pausable_init();
    __UUPSUpgradeable_init();
    PointsMinterStorage storage $ = _getPointsMinterStorage();
    $._pointsToken = _pointsToken;
    $._pointUnit = 10 ** IERC20Metadata(_pointsToken).decimals();
    _setConfig(_config);
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
    return super.supportsInterface(interfaceId) || interfaceId == type(IPointsMinter).interfaceId;
  }

  /// @inheritdoc UUPSUpgradeable
  // solhint-disable-next-line no-empty-blocks
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  /// @inheritdoc IPointsMinter
  function register(uint256 expiry, bytes calldata signature) external whenNotPaused returns (uint256 number) {
    PointsMinterStorage storage $ = _getPointsMinterStorage();
    address wallet = _msgSender();
    WalletRecord storage record = $._wallets[wallet];
    if (record.whitelistNumber != 0) revert AlreadyRegistered(wallet);
    if (block.timestamp > expiry) revert AttestationExpired(expiry);
    bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(REGISTRATION_TYPEHASH, wallet, expiry)));
    address signer = ECDSA.recover(digest, signature);
    if (signer != $._config.attestationSigner) revert InvalidAttestation(signer);
    number = ++$._registeredCount;
    // casting to uint64 is safe because the count grows by one per registration
    // forge-lint: disable-next-line(unsafe-typecast)
    record.whitelistNumber = uint64(number);
    record.registeredAt = uint64(block.timestamp);
    emit Registered(wallet, number);
  }

  /// @inheritdoc IPointsMinter
  function creditBorrow(uint256 tokenId) external whenNotPaused returns (uint256 minted) {
    PointsMinterStorage storage $ = _getPointsMinterStorage();
    PointsMinterConfig storage c = $._config;
    if ($._creditedLoan[tokenId]) revert LoanAlreadyCredited(tokenId);
    ILoanManager loanManager = ILoanManager(c.loanManager);
    MortgagePosition memory position = loanManager.getMortgagePosition(tokenId);
    if (position.dateOriginated < c.programStart || position.dateOriginated >= c.programEnd) {
      revert LoanOutsideProgram(tokenId, position.dateOriginated);
    }
    address wallet = IERC721(loanManager.nft()).ownerOf(tokenId);
    WalletRecord storage record = $._wallets[wallet];
    if (record.blocked) revert WalletBlocked(wallet);
    $._creditedLoan[tokenId] = true;

    uint256 clip = uint256(c.borrowClip) * $._pointUnit;
    uint256 room = record.borrowPoints >= clip ? 0 : clip - record.borrowPoints;
    uint256 points = Math.min(Math.mulDiv(position.amountBorrowed, $._pointUnit, USD_UNIT), room);
    uint256 multiplierBps = multiplier(wallet);
    record.borrowPoints += points;
    if (position.dateOriginated < c.genesisCloseAt) record.genesisBorrowPoints += points;
    minted = _mint(wallet, points, multiplierBps);
    emit BorrowCredited(tokenId, wallet, position.amountBorrowed, points, minted, multiplierBps);
  }

  /// @inheritdoc IPointsMinter
  function creditLend(uint256 day, address[] calldata users, uint256[] calldata points)
    external
    onlyRole(LEND_CREDITOR_ROLE)
    whenNotPaused
  {
    if (users.length != points.length) revert LengthMismatch();
    PointsMinterStorage storage $ = _getPointsMinterStorage();
    PointsMinterConfig storage c = $._config;
    if (day >= Math.ceilDiv(c.programEnd - c.programStart, 1 days)) revert DayNotCreditable(day);
    if (uint256(c.programStart) + (day + 1) * 1 days > block.timestamp) revert DayNotCreditable(day);

    LendDay storage lend = $._lendDays[day];
    if (!lend.opened) {
      uint256 assets = ILiquidityVault(c.rolloverVault).totalAssets();
      lend.opened = true;
      lend.cap = Math.mulDiv(assets, $._pointUnit * (BPS + c.lendToleranceBps), USD_UNIT * LEND_DAYS_PER_POINT * BPS);
      emit LendDayOpened(day, assets, lend.cap);
    }

    uint256 total = lend.total;
    bool genesis = uint256(c.programStart) + day * 1 days < c.genesisCloseAt;
    for (uint256 i = 0; i < users.length; i++) {
      total += _creditLend($, day, users[i], points[i], genesis);
    }
    if (total > lend.cap) revert LendCapExceeded(day, total, lend.cap);
    lend.total = total;
  }

  /// @inheritdoc IPointsMinter
  function setRevoked(address wallet, bool revoked) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _getPointsMinterStorage()._wallets[wallet].revoked = revoked;
    emit RevokedSet(wallet, revoked);
  }

  /// @inheritdoc IPointsMinter
  function setBlocked(address wallet, bool blocked) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _getPointsMinterStorage()._wallets[wallet].blocked = blocked;
    emit BlockedSet(wallet, blocked);
  }

  /// @inheritdoc IPointsMinter
  function setConfig(PointsMinterConfig calldata _config) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setConfig(_config);
  }

  /// @inheritdoc IPointsMinter
  function setPaused(bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (paused) _pause();
    else _unpause();
  }

  /// @inheritdoc IPointsMinter
  function pointsToken() external view returns (address) {
    return _getPointsMinterStorage()._pointsToken;
  }

  /// @inheritdoc IPointsMinter
  function pointUnit() external view returns (uint256) {
    return _getPointsMinterStorage()._pointUnit;
  }

  /// @inheritdoc IPointsMinter
  function config() external view returns (PointsMinterConfig memory) {
    return _getPointsMinterStorage()._config;
  }

  /// @inheritdoc IPointsMinter
  function registeredCount() external view returns (uint256) {
    return _getPointsMinterStorage()._registeredCount;
  }

  /// @inheritdoc IPointsMinter
  function earned(address wallet) external view returns (WalletRecord memory) {
    return _getPointsMinterStorage()._wallets[wallet];
  }

  /// @inheritdoc IPointsMinter
  function tierOf(address wallet) public view returns (uint256 depositTier, uint256 borrowTier) {
    WalletRecord storage record = _getPointsMinterStorage()._wallets[wallet];
    depositTier = _tier(record.genesisDepositPoints);
    borrowTier = _tier(record.genesisBorrowPoints);
  }

  /// @inheritdoc IPointsMinter
  function isRegistered(address wallet) external view returns (bool) {
    return _getPointsMinterStorage()._wallets[wallet].whitelistNumber != 0;
  }

  /// @inheritdoc IPointsMinter
  function multiplier(address wallet) public view returns (uint256) {
    PointsMinterStorage storage $ = _getPointsMinterStorage();
    WalletRecord storage record = $._wallets[wallet];
    if (record.whitelistNumber == 0 || record.revoked || record.blocked) return BPS;
    (uint256 depositTier, uint256 borrowTier) = tierOf(wallet);
    uint256 bps = BPS + _tierBps(depositTier) + _tierBps(borrowTier);
    if (record.whitelistNumber <= $._config.firstN) bps += $._config.firstNBonusBps;
    return bps;
  }

  /// @inheritdoc IPointsMinter
  function isLoanCredited(uint256 tokenId) external view returns (bool) {
    return _getPointsMinterStorage()._creditedLoan[tokenId];
  }

  /// @inheritdoc IPointsMinter
  function isLendCredited(uint256 day, address wallet) external view returns (bool) {
    return _getPointsMinterStorage()._lendCredited[day][wallet];
  }

  /// @inheritdoc IPointsMinter
  function lendDay(uint256 day) external view returns (LendDay memory) {
    return _getPointsMinterStorage()._lendDays[day];
  }

  /**
   * @dev Credits one wallet for a lend day; a blocked wallet is marked done and skipped
   * @param $ The storage
   * @param day The day index
   * @param wallet The wallet
   * @param points The base points
   * @param genesis Whether the day starts before genesis close, so the credit counts toward tiers
   * @return counted The base points counted toward the day's total
   */
  function _creditLend(PointsMinterStorage storage $, uint256 day, address wallet, uint256 points, bool genesis)
    private
    returns (uint256 counted)
  {
    if ($._lendCredited[day][wallet]) revert LendAlreadyCredited(day, wallet);
    $._lendCredited[day][wallet] = true;
    WalletRecord storage record = $._wallets[wallet];
    if (record.blocked) {
      emit LendSkipped(day, wallet, points);
      return 0;
    }
    uint256 multiplierBps = multiplier(wallet);
    record.depositPoints += points;
    if (genesis) record.genesisDepositPoints += points;
    emit LendCredited(day, wallet, points, _mint(wallet, points, multiplierBps), multiplierBps);
    return points;
  }

  /**
   * @dev Mints base points times a multiplier to a wallet
   * @param wallet The wallet receiving the points
   * @param points The base points
   * @param multiplierBps The multiplier in basis points
   * @return minted The points minted
   */
  function _mint(address wallet, uint256 points, uint256 multiplierBps) private returns (uint256 minted) {
    minted = Math.mulDiv(points, multiplierBps, BPS);
    if (minted != 0) IPointsToken(_getPointsMinterStorage()._pointsToken).mint(wallet, minted);
  }

  /**
   * @dev The tier (0..3) reached by an amount of genesis points
   * @param points The genesis points, in point units
   * @return tier The tier
   */
  function _tier(uint256 points) private view returns (uint256 tier) {
    PointsMinterStorage storage $ = _getPointsMinterStorage();
    for (uint256 i = 0; i < 3; i++) {
      if (points >= uint256($._config.tierThresholds[i]) * $._pointUnit) tier = i + 1;
    }
  }

  /**
   * @dev The bonus of a tier
   * @param tier The tier (0..3)
   * @return The bonus in basis points
   */
  function _tierBps(uint256 tier) private view returns (uint256) {
    return tier == 0 ? 0 : _getPointsMinterStorage()._config.tierBps[tier - 1];
  }

  /**
   * @dev Validates and stores a configuration. programStart cannot move once reached, so day indices stay fixed.
   * @param _config The new configuration
   */
  function _setConfig(PointsMinterConfig calldata _config) private {
    PointsMinterConfig storage current = _getPointsMinterStorage()._config;
    bool startLocked = current.programStart != 0 && block.timestamp >= current.programStart;
    if (
      _config.loanManager == address(0) || _config.rolloverVault == address(0) || _config.programStart == 0
        || _config.programStart >= _config.programEnd || _config.genesisCloseAt < _config.programStart
        || _config.genesisCloseAt > _config.programEnd || _config.lendToleranceBps > MAX_LEND_TOLERANCE_BPS
        || (startLocked && _config.programStart != current.programStart) || _config.tierThresholds[0] == 0
        || _config.tierThresholds[0] >= _config.tierThresholds[1]
        || _config.tierThresholds[1] >= _config.tierThresholds[2] || _config.tierBps[0] > _config.tierBps[1]
        || _config.tierBps[1] > _config.tierBps[2]
        || BPS + 2 * uint256(_config.tierBps[2]) + _config.firstNBonusBps > MAX_MULTIPLIER_BPS
    ) revert InvalidConfig();
    _getPointsMinterStorage()._config = _config;
    emit ConfigSet(_config);
  }
}
