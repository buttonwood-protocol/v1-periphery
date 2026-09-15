// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IPriceOracle} from "@core/interfaces/IPriceOracle.sol";

/// @dev Oracle stand-in that always reverts like ChainlinkPriceOracle does past maxAge.
contract MockStalePriceOracle is IPriceOracle {
  error StalePrice(uint256 age, uint256 maxAge);

  /// @inheritdoc IPriceOracle
  uint8 public immutable collateralDecimals;

  constructor(uint8 _collateralDecimals) {
    collateralDecimals = _collateralDecimals;
  }

  /// @inheritdoc IPriceOracle
  function price() external pure returns (uint256) {
    revert StalePrice(2 days, 1 days);
  }

  /// @inheritdoc IPriceOracle
  function cost(uint256) external pure returns (uint256, uint8) {
    revert StalePrice(2 days, 1 days);
  }
}
