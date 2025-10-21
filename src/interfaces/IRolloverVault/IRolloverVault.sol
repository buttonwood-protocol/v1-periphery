// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ILiquidityVault} from "../ILiquidityVault/ILiquidityVault.sol";

/**
 * @title IRolloverVault
 * @author @SocksNFlops
 * @notice Interface for RolloverVault, a vault that facilitates automatically rotates unused assets into origination pools.
 */
interface IRolloverVault is ILiquidityVault {
}


/**
 * RolloverVault:
 * - Keeper Functions:
 *   - Enter origination pool
 *   - Exit origination pool [Permissionless]
 * - Special Considerations:
 *   - Not just withdrawing usdx + consol, but also all of the OGPool receipt tokens
 *   - Need to configure a % usable in each epoch (this way there is always an ogpool available)
 */