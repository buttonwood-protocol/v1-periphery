// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PointsMinterConfig} from "./PointsMinterTypes.sol";

/**
 * @title IPointsMinterEvents
 * @author @SocksNFlops
 * @notice Interface for events emitted by the PointsMinter.
 */
interface IPointsMinterEvents {
  /**
   * @notice Emitted when a wallet registers
   * @param wallet The wallet that registered
   * @param number The whitelist number assigned to the wallet
   */
  event Registered(address indexed wallet, uint256 number);

  /**
   * @notice Emitted when a loan is credited
   * @param tokenId The mortgage token id
   * @param wallet The owner of the mortgage NFT that received the credit
   * @param amountBorrowed The amount borrowed on the loan, in USDX units
   * @param points The base points credited to the wallet's borrow record after the clip
   * @param minted The points minted (base points times the multiplier)
   * @param multiplierBps The multiplier applied, in basis points
   */
  event BorrowCredited(
    uint256 indexed tokenId,
    address indexed wallet,
    uint256 amountBorrowed,
    uint256 points,
    uint256 minted,
    uint256 multiplierBps
  );

  /**
   * @notice Emitted when the cap for a lend day is snapshotted by the first credit of that day
   * @param day The day index
   * @param totalAssets The RolloverVault's total assets at the snapshot, in USDX units
   * @param cap The maximum base points creditable for the day
   */
  event LendDayOpened(uint256 indexed day, uint256 totalAssets, uint256 cap);

  /**
   * @notice Emitted when a wallet is credited for a lend day
   * @param day The day index
   * @param wallet The wallet credited
   * @param points The base points credited to the wallet's deposit record
   * @param minted The points minted (base points times the multiplier)
   * @param multiplierBps The multiplier applied, in basis points
   */
  event LendCredited(
    uint256 indexed day, address indexed wallet, uint256 points, uint256 minted, uint256 multiplierBps
  );

  /**
   * @notice Emitted when a blocked wallet is skipped in a lend credit; the wallet is marked done for the day
   * @param day The day index
   * @param wallet The blocked wallet
   * @param points The base points that were not credited
   */
  event LendSkipped(uint256 indexed day, address indexed wallet, uint256 points);

  /**
   * @notice Emitted when a wallet's revoked flag changes
   * @param wallet The wallet
   * @param revoked Whether the wallet's boosters are revoked
   */
  event RevokedSet(address indexed wallet, bool revoked);

  /**
   * @notice Emitted when a wallet's blocked flag changes
   * @param wallet The wallet
   * @param blocked Whether the wallet is blocked from all credits
   */
  event BlockedSet(address indexed wallet, bool blocked);

  /**
   * @notice Emitted when the configuration is set
   * @param config The new configuration
   */
  event ConfigSet(PointsMinterConfig config);
}
