// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {LiquidityVault} from "../../src/LiquidityVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockLiquidityVault2 is LiquidityVault {
  function _totalAssets() internal view override returns (uint256) {
    address[] memory depositableAssets = depositableAssets();
    address[] memory redeemableAssets = redeemableAssets();
    uint256 total = 0;
    for (uint256 i = 0; i < depositableAssets.length; i++) {
      total += IERC20(depositableAssets[i]).balanceOf(address(this));
    }
    for (uint256 i = 0; i < redeemableAssets.length; i++) {
      total += IERC20(redeemableAssets[i]).balanceOf(address(this));
    }
    return total;
  }

  function newFunction() public pure returns (bool) {
    return true;
  }
}
