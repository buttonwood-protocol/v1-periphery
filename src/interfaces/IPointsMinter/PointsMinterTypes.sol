// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @notice The program configuration of the PointsMinter. Point amounts are whole points and are scaled by the
 * minter's point unit (10 ** token decimals) when used.
 * @param loanManager The LoanManager whose mortgage positions back borrow credits
 * @param rolloverVault The RolloverVault whose total assets bound lend credits
 * @param attestationSigner The signer of registration attestations
 * @param programStart Timestamp the program starts; lend day 0 begins here. Cannot change once reached.
 * @param programEnd Timestamp the program ends (exclusive)
 * @param genesisCloseAt Loans originated and lend days starting before this timestamp count toward tiers
 * @param lendToleranceBps Allowance above totalAssets / 7 for NAV drift, in basis points
 * @param firstNBonusBps Bonus for whitelist numbers 1..firstN, in basis points
 * @param firstN The highest whitelist number that earns the first-N bonus
 * @param borrowClip Maximum borrow points per wallet, in whole points
 * @param tierThresholds Genesis points needed for tiers 1..3, in whole points, strictly ascending
 * @param tierBps Bonus for tiers 1..3, in basis points, non-decreasing
 */
struct PointsMinterConfig {
  address loanManager;
  address rolloverVault;
  address attestationSigner;
  uint64 programStart;
  uint64 programEnd;
  uint64 genesisCloseAt;
  uint16 lendToleranceBps;
  uint16 firstNBonusBps;
  uint32 firstN;
  uint32 borrowClip;
  uint32[3] tierThresholds;
  uint16[3] tierBps;
}

/**
 * @notice The points record of a wallet
 * @param whitelistNumber The whitelist number, 0 if not registered
 * @param registeredAt The registration timestamp, 0 if not registered
 * @param revoked Whether the wallet's boosters are revoked (the number is kept)
 * @param blocked Whether the wallet is blocked from all credits
 * @param depositPoints Base points credited from lending
 * @param borrowPoints Base points credited from borrowing, never above the borrow clip
 * @param genesisDepositPoints Base lend points for days starting before genesis close (the deposit tier input)
 * @param genesisBorrowPoints Base borrow points for loans originated before genesis close (the borrow tier input)
 */
struct WalletRecord {
  uint64 whitelistNumber;
  uint64 registeredAt;
  bool revoked;
  bool blocked;
  uint256 depositPoints;
  uint256 borrowPoints;
  uint256 genesisDepositPoints;
  uint256 genesisBorrowPoints;
}

/**
 * @notice The lend accounting of a day
 * @param opened Whether the day's cap has been snapshotted
 * @param cap The maximum base points creditable for the day
 * @param total The base points credited for the day so far
 */
struct LendDay {
  bool opened;
  uint256 cap;
  uint256 total;
}
