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
   * @param from The address points would move from
   * @param to The address points would move to
   * @param value The amount that would move
   */
  error TransfersDisabled(address from, address to, uint256 value);

  /**
   * @notice Thrown on any attempt to set an allowance
   * @param owner The address that would grant the allowance
   * @param spender The address that would receive the allowance
   * @param value The allowance that would be set
   */
  error ApprovalsDisabled(address owner, address spender, uint256 value);
}
