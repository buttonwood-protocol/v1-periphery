// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @notice How the vault grants a swap router its scoped USDG spend for the duration of a fill
 * @dev None: the router is not allowed. ERC20: a plain token approval to the router (routers that pull with
 *      transferFrom, e.g. SwapRouter02). Permit2: a token approval to Permit2 plus a Permit2 allowance to the
 *      router (routers that pull through Permit2, e.g. Universal Router).
 */
enum RouterApproval {
  None,
  ERC20,
  Permit2
}

/**
 * @notice A router and the approval mode it is allowed under
 * @param router The address of the router
 * @param approval The approval mode for the router
 */
struct RouterConfig {
  address router;
  RouterApproval approval;
}
