// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVaultEvents} from "./ILiquidityVaultEvents.sol";
import {ILiquidityVaultErrors} from "./ILiquidityVaultErrors.sol";


/**
 * @title ILiquidityVault
 * @author @SocksNFlops 
 * @notice Interface for LiquidityVault, a yield-bearing vault that enables depositing tokens and receiving yield.
 */
interface ILiquidityVault is IERC20, ILiquidityVaultEvents, ILiquidityVaultErrors {

}