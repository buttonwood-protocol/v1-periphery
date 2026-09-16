// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Permit2 AllowanceTransfer stand-in mirroring the real semantics: a zero expiration is stored as
///      block.timestamp, a pull reverts when block.timestamp > expiration, and a max-uint160 amount is not
///      decremented. The underlying pull uses the owner's token approval to this contract.
contract MockPermit2 {
  using SafeERC20 for IERC20;

  error AllowanceExpired(uint256 deadline);
  error InsufficientAllowance(uint256 amount);

  struct PackedAllowance {
    uint160 amount;
    uint48 expiration;
    uint48 nonce;
  }

  mapping(address owner => mapping(address token => mapping(address spender => PackedAllowance))) public allowance;

  function approve(address token, address spender, uint160 amount, uint48 expiration) external {
    PackedAllowance storage allowed = allowance[msg.sender][token][spender];
    // forge-lint: disable-next-line(unsafe-typecast)
    allowed.expiration = expiration == 0 ? uint48(block.timestamp) : expiration;
    allowed.amount = amount;
  }

  function transferFrom(address from, address to, uint160 amount, address token) external {
    PackedAllowance storage allowed = allowance[from][token][msg.sender];
    if (block.timestamp > allowed.expiration) {
      revert AllowanceExpired(allowed.expiration);
    }
    uint256 maxAmount = allowed.amount;
    if (maxAmount != type(uint160).max) {
      if (amount > maxAmount) {
        revert InsufficientAllowance(maxAmount);
      }
      unchecked {
        // forge-lint: disable-next-line(unsafe-typecast)
        allowed.amount = uint160(maxAmount) - amount;
      }
    }
    IERC20(token).safeTransferFrom(from, to, amount);
  }
}

/// @dev Swap venue stand-in that pulls its input through Permit2 (as Universal Router does with payerIsUser),
///      and pays out amountOut of tokenOut from its own seeded balance. Same swap signature as MockSwapRouter.
contract MockPermit2SwapRouter {
  MockPermit2 public immutable PERMIT2;
  uint256 public callCount;

  constructor(MockPermit2 permit2_) {
    PERMIT2 = permit2_;
  }

  function swap(IERC20 tokenIn, uint256 amountIn, IERC20 tokenOut, uint256 amountOut) external {
    callCount++;
    if (amountIn > 0) {
      // forge-lint: disable-next-line(unsafe-typecast)
      PERMIT2.transferFrom(msg.sender, address(this), uint160(amountIn), address(tokenIn));
    }
    if (amountOut > 0) {
      // forge-lint: disable-next-line(erc20-unchecked-transfer)
      tokenOut.transfer(msg.sender, amountOut);
    }
  }
}
