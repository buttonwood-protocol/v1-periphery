// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is IERC20Metadata, ERC20 {
  uint8 private immutable decimals_;

  constructor(string memory name, string memory symbol, uint8 _decimals) ERC20(name, symbol) {
    decimals_ = _decimals;
  }

  function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
    return decimals_;
  }

  function mint(address account, uint256 amount) external {
    _mint(account, amount);
  }

  function burn(address account, uint256 amount) external {
    _burn(account, amount);
  }
}
