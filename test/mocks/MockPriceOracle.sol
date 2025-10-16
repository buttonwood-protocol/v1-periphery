// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IPriceOracle} from "@core/interfaces/IPriceOracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockPriceOracle is IPriceOracle {
  /// @inheritdoc IPriceOracle
  uint8 public immutable collateralDecimals;
  /// @dev Mapping of collateral => price
  uint256 public price;

  constructor(uint8 _collateralDecimals) {
    collateralDecimals = _collateralDecimals;
  }

  /// @dev Set the price for a given collateral
  function setPrice(uint256 _price) external {
    price = _price;
  }

  /// @inheritdoc IPriceOracle
  function cost(uint256 collateralAmount) external view returns (uint256 totalCost, uint8 _collateralDecimals) {
    totalCost = Math.mulDiv(collateralAmount, price, (10 ** collateralDecimals));
    _collateralDecimals = collateralDecimals;
  }
}
