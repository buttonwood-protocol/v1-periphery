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

/// @notice A swap router whose route reaches third-party code between pulling the input and delivering the
///         output, as a v4 hook or a callback token on a multi-hop path does.
contract MockHookedSwapRouter {
  address public hook;
  bytes public hookData;

  /// @notice Sets the call made mid-swap
  /// @param hook_ The address called mid-swap
  /// @param data The calldata of the mid-swap call
  function setHook(address hook_, bytes calldata data) external {
    hook = hook_;
    hookData = data;
  }

  /// @notice Pulls amountIn of tokenIn, calls the hook, and delivers amountOut of tokenOut
  /// @param tokenIn The token to pull from the caller
  /// @param amountIn The amount of tokenIn to pull
  /// @param tokenOut The token to send to the caller
  /// @param amountOut The amount of tokenOut to send
  function swap(IERC20 tokenIn, uint256 amountIn, IERC20 tokenOut, uint256 amountOut) external {
    // forge-lint: disable-next-line(erc20-unchecked-transfer)
    tokenIn.transferFrom(msg.sender, address(this), amountIn);
    if (hook != address(0)) {
      (bool success, bytes memory returndata) = hook.call(hookData);
      if (!success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
          revert(add(returndata, 0x20), mload(returndata))
        }
      }
    }
    // forge-lint: disable-next-line(erc20-unchecked-transfer)
    tokenOut.transfer(msg.sender, amountOut);
  }
}

/// @notice Deposits its whole USDX balance into a vault when poked
contract MockVaultDepositor {
  IERC20 public immutable usdx;
  address public immutable vault;

  constructor(IERC20 usdx_, address vault_) {
    usdx = usdx_;
    vault = vault_;
  }

  /// @notice Deposits the whole USDX balance into the vault
  function depositAll() external {
    uint256 balance = usdx.balanceOf(address(this));
    usdx.approve(vault, balance);
    (bool success, bytes memory returndata) =
      vault.call(abi.encodeWithSignature("deposit(address,uint256)", address(usdx), balance));
    if (!success) {
      // solhint-disable-next-line no-inline-assembly
      assembly {
        revert(add(returndata, 0x20), mload(returndata))
      }
    }
  }
}
