// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Swap venue stand-in. Pulls exactly amountIn of tokenIn from the caller's approval and pays out
///      amountOut of tokenOut from its own seeded balance, so tests control both deltas via calldata.
contract MockSwapRouter {
  uint256 public callCount;

  function swap(IERC20 tokenIn, uint256 amountIn, IERC20 tokenOut, uint256 amountOut) external {
    callCount++;
    if (amountIn > 0) {
      // forge-lint: disable-next-line(erc20-unchecked-transfer)
      tokenIn.transferFrom(msg.sender, address(this), amountIn);
    }
    if (amountOut > 0) {
      // forge-lint: disable-next-line(erc20-unchecked-transfer)
      tokenOut.transfer(msg.sender, amountOut);
    }
  }
}

/// @dev Malicious router that re-enters the caller with pre-set calldata during the swap, bubbling any revert.
contract MockReentrantSwapRouter {
  bytes public reentryData;

  function setReentryData(bytes calldata data) external {
    reentryData = data;
  }

  function swap(IERC20, uint256, IERC20, uint256) external {
    (bool success, bytes memory returndata) = msg.sender.call(reentryData);
    if (!success) {
      // solhint-disable-next-line no-inline-assembly
      assembly {
        revert(add(returndata, 0x20), mload(returndata))
      }
    }
  }
}
