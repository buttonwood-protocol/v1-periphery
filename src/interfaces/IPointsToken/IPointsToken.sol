// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IPointsTokenErrors} from "./IPointsTokenErrors.sol";

/**
 * @title IPointsToken
 * @author @SocksNFlops
 * @notice Interface for the PointsToken, a permanently non-transferable ERC-20 that can only be minted and burned.
 */
interface IPointsToken is IPointsTokenErrors {
  /**
   * @notice The role allowed to mint points
   * @return The role allowed to mint points
   */
  // solhint-disable-next-line func-name-mixedcase
  function MINTER_ROLE() external view returns (bytes32);

  /**
   * @notice The role allowed to burn points
   * @return The role allowed to burn points
   */
  // solhint-disable-next-line func-name-mixedcase
  function BURNER_ROLE() external view returns (bytes32);

  /**
   * @notice Mints points to a wallet
   * @param to The wallet receiving the points
   * @param amount The amount of points to mint
   */
  function mint(address to, uint256 amount) external;

  /**
   * @notice Burns points from a wallet without needing an allowance
   * @param from The wallet whose points are burned
   * @param amount The amount of points to burn
   */
  function burn(address from, uint256 amount) external;
}
