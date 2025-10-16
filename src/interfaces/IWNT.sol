pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWNT is IERC20 {
  /**
   * @notice Deposit native tokens into the WNT contract
   */
  function deposit() external payable;

  /**
   * @notice Approve a spender to spend a certain amount of WNT
   * @param guy The address of the spender
   * @param wad The amount of WNT to approve
   * @return bool Whether the approval was successful
   */
  function approve(address guy, uint256 wad) external returns (bool);
}
