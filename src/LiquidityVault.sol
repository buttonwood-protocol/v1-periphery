// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ILiquidityVault} from "./interfaces/ILiquidityVault/ILiquidityVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LiquidityVault is ILiquidityVault, ERC20 {
  constructor(string memory name, string memory symbol) ERC20(name, symbol) {
    // constructor
  }
}