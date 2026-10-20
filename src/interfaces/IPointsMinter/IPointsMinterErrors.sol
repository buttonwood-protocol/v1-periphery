// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title IPointsMinterErrors
 * @author @SocksNFlops
 * @notice Interface for errors emitted by the PointsMinter.
 */
interface IPointsMinterErrors {
  /**
   * @notice Thrown when a wallet that already holds a whitelist number tries to register again
   * @param wallet The wallet that is already registered
   */
  error AlreadyRegistered(address wallet);

  /**
   * @notice Thrown when a registration attestation is past its expiry
   * @param expiry The expiry of the attestation
   */
  error AttestationExpired(uint256 expiry);

  /**
   * @notice Thrown when a registration attestation was not signed by the attestation signer
   * @param signer The address recovered from the signature
   */
  error InvalidAttestation(address signer);

  /**
   * @notice Thrown when a loan has already been credited
   * @param tokenId The mortgage token id
   */
  error LoanAlreadyCredited(uint256 tokenId);

  /**
   * @notice Thrown when a loan was not originated inside the program window
   * @param tokenId The mortgage token id
   * @param dateOriginated The origination timestamp of the loan
   */
  error LoanOutsideProgram(uint256 tokenId, uint256 dateOriginated);

  /**
   * @notice Thrown when a credit targets a blocked wallet
   * @param wallet The blocked wallet
   */
  error WalletBlocked(address wallet);

  /**
   * @notice Thrown when the users and points arrays of a lend credit differ in length
   */
  error LengthMismatch();

  /**
   * @notice Thrown when a lend day is outside the program window or has not finished yet
   * @param day The day index
   */
  error DayNotCreditable(uint256 day);

  /**
   * @notice Thrown when a wallet has already been credited for a lend day
   * @param day The day index
   * @param wallet The wallet already credited
   */
  error LendAlreadyCredited(uint256 day, address wallet);

  /**
   * @notice Thrown when the points credited for a lend day would exceed that day's cap
   * @param day The day index
   * @param total The total points the day would reach
   * @param cap The cap for the day
   */
  error LendCapExceeded(uint256 day, uint256 total, uint256 cap);

  /**
   * @notice Thrown when a configuration fails validation
   */
  error InvalidConfig();
}
