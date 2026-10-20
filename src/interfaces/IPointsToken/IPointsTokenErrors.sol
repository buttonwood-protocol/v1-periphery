// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title IPointsTokenErrors
 * @author @SocksNFlops
 * @notice Interface for errors emitted by the PointsToken.
 */
interface IPointsTokenErrors {
  /**
   * @notice Thrown on any attempt to move points between two non-zero addresses
   */
  error TransfersDisabled();

  /**
   * @notice Thrown on any attempt to set an allowance
   */
  error ApprovalsDisabled();
}
