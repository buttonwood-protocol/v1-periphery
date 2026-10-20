// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IPointsMinterEvents} from "./IPointsMinterEvents.sol";
import {IPointsMinterErrors} from "./IPointsMinterErrors.sol";
import {PointsMinterConfig, WalletRecord, LendDay} from "./PointsMinterTypes.sol";

/**
 * @title IPointsMinter
 * @author @SocksNFlops
 * @notice Interface for the PointsMinter, which registers wallets and mints PointsToken for borrowing and lending.
 */
interface IPointsMinter is IPointsMinterEvents, IPointsMinterErrors {
  /**
   * @notice The role allowed to submit lend credits
   * @return The role allowed to submit lend credits
   */
  // solhint-disable-next-line func-name-mixedcase
  function LEND_CREDITOR_ROLE() external view returns (bytes32);

  /**
   * @notice The EIP-712 typehash of a registration attestation
   * @return The typehash of `Registration(address wallet,uint256 expiry)`
   */
  // solhint-disable-next-line func-name-mixedcase
  function REGISTRATION_TYPEHASH() external view returns (bytes32);

  /**
   * @notice Registers the caller with an attestation from the attestation signer and assigns the next whitelist number
   * @param expiry The attestation expiry timestamp
   * @param signature The EIP-712 signature over `Registration(wallet, expiry)`
   * @return number The whitelist number assigned
   */
  function register(uint256 expiry, bytes calldata signature) external returns (uint256 number);

  /**
   * @notice Credits a loan to the current owner of its mortgage NFT. Callable by anyone, once per loan.
   * @param tokenId The mortgage token id
   * @return minted The points minted
   */
  function creditBorrow(uint256 tokenId) external returns (uint256 minted);

  /**
   * @notice Credits lend points for a day. Each (day, wallet) pair can be credited once; a day may span several calls.
   * @param day The day index since program start
   * @param users The wallets to credit
   * @param points The base points for each wallet
   */
  function creditLend(uint256 day, address[] calldata users, uint256[] calldata points) external;

  /**
   * @notice Sets or clears a wallet's revoked flag. A revoked wallet keeps its number but mints at 1.0x.
   * @param wallet The wallet
   * @param revoked Whether the wallet's boosters are revoked
   */
  function setRevoked(address wallet, bool revoked) external;

  /**
   * @notice Sets or clears a wallet's blocked flag. A blocked wallet receives no credits.
   * @param wallet The wallet
   * @param blocked Whether the wallet is blocked
   */
  function setBlocked(address wallet, bool blocked) external;

  /**
   * @notice Sets the program configuration
   * @param config The new configuration
   */
  function setConfig(PointsMinterConfig calldata config) external;

  /**
   * @notice Pauses or unpauses registration and all credits
   * @param paused Whether to pause
   */
  function setPaused(bool paused) external;

  /**
   * @notice The PointsToken minted by this contract
   * @return The PointsToken address
   */
  function pointsToken() external view returns (address);

  /**
   * @notice The smallest unit of one whole point (10 ** token decimals)
   * @return The point unit
   */
  function pointUnit() external view returns (uint256);

  /**
   * @notice The program configuration
   * @return The configuration
   */
  function config() external view returns (PointsMinterConfig memory);

  /**
   * @notice The number of wallets registered so far (also the last whitelist number assigned)
   * @return The number of registered wallets
   */
  function registeredCount() external view returns (uint256);

  /**
   * @notice The points record of a wallet
   * @param wallet The wallet
   * @return The wallet's record
   */
  function earned(address wallet) external view returns (WalletRecord memory);

  /**
   * @notice The deposit and borrow tiers (0..3) of a wallet, from its genesis points
   * @param wallet The wallet
   * @return depositTier The deposit tier
   * @return borrowTier The borrow tier
   */
  function tierOf(address wallet) external view returns (uint256 depositTier, uint256 borrowTier);

  /**
   * @notice Whether a wallet holds a whitelist number (true also while revoked)
   * @param wallet The wallet
   * @return Whether the wallet is registered
   */
  function isRegistered(address wallet) external view returns (bool);

  /**
   * @notice The multiplier applied to a wallet's next mint, in basis points (10_000 = 1.0x)
   * @param wallet The wallet
   * @return The multiplier in basis points
   */
  function multiplier(address wallet) external view returns (uint256);

  /**
   * @notice Whether a loan has been credited
   * @param tokenId The mortgage token id
   * @return Whether the loan has been credited
   */
  function isLoanCredited(uint256 tokenId) external view returns (bool);

  /**
   * @notice Whether a wallet has been credited (or skipped) for a lend day
   * @param day The day index
   * @param wallet The wallet
   * @return Whether the wallet is done for the day
   */
  function isLendCredited(uint256 day, address wallet) external view returns (bool);

  /**
   * @notice The lend accounting of a day
   * @param day The day index
   * @return The day's cap and running total
   */
  function lendDay(uint256 day) external view returns (LendDay memory);
}
