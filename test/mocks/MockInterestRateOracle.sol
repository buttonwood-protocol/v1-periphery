// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IInterestRateOracle} from "@core/interfaces/IInterestRateOracle.sol";

contract MockInterestRateOracle is IInterestRateOracle {
  /**
   * @inheritdoc IInterestRateOracle
   */
  mapping(uint8 => mapping(bool => uint16)) public interestRate;

  /// @dev Set the interest rate for a given total periods and hasPaymentPlan
  function setInterestRate(uint8 totalPeriods, bool hasPaymentPlan, uint16 _interestRate) external {
    interestRate[totalPeriods][hasPaymentPlan] = _interestRate;
  }
}
