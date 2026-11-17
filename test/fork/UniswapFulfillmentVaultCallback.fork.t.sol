// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Roles} from "@core/libraries/Roles.sol";
import {Constants} from "@core/libraries/Constants.sol";
import {RouterApproval, RouterConfig} from "../../src/interfaces/IUniswapFulfillmentVault/RouterApproval.sol";
import {UniswapFulfillmentVault} from "../../src/UniswapFulfillmentVault.sol";
import {UniswapFulfillmentVaultForkFixture} from "./UniswapFulfillmentVault.fork.t.sol";

/**
 * @title UniswapFulfillmentVaultCallbackForkTest
 * @notice Callback fills from a vault that holds no USDX, through the real SwapRouter02 and Universal Router
 *         2.1.2 over the live v3 and v4 pools: the general manager's advance is the only money in the fill.
 */
contract UniswapFulfillmentVaultCallbackForkTest is UniswapFulfillmentVaultForkFixture {
  function _forkBlock() internal pure override returns (uint256) {
    return FORK_BLOCK_212;
  }

  /// @dev Replaces the fixture's funded vault with one that holds nothing
  function _useEmptyVault() internal {
    UniswapFulfillmentVault implementation = new UniswapFulfillmentVault();
    RouterConfig[] memory routers = new RouterConfig[](2);
    routers[0] = RouterConfig({router: SWAP_ROUTER02_ADDRESS, approval: RouterApproval.ERC20});
    routers[1] = RouterConfig({router: UNIVERSAL_ROUTER_212_ADDRESS, approval: RouterApproval.Permit2});
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(implementation),
      abi.encodeCall(
        UniswapFulfillmentVault.initialize,
        (
          "Empty Uniswap Fulfillment Vault",
          "eUFV",
          24,
          6,
          address(generalManager),
          USDG_ADDRESS,
          PERMIT2_ADDRESS,
          routers,
          admin
        )
      )
    );
    ufVault = UniswapFulfillmentVault(payable(address(proxy)));
    vm.startPrank(admin);
    ufVault.grantRole(ufVault.KEEPER_ROLE(), keeper);
    IAccessControl(address(orderPool)).grantRole(Roles.FULFILLMENT_ROLE, address(ufVault));
    IAccessControl(address(usdx)).grantRole(Roles.IGNORE_CAP_ROLE, address(ufVault));
    vm.stopPrank();

    assertEq(usdx.balanceOf(address(ufVault)), 0, "Vault should hold no USDX");
    assertEq(usdg.balanceOf(address(ufVault)), 0, "Vault should hold no USDG");
    assertEq(ufVault.totalSupply(), 0, "Vault should have no depositors");
  }

  /// @dev The callback path's spend bound: the advance (purchase amount less the holdback), floored to USDG units
  function _maxUsdgInCallback(uint256 purchaseAmount) internal pure returns (uint256) {
    return (purchaseAmount - Constants.FULFILLMENT_HOLDBACK_PER_POOL) / 1e12;
  }

  /// @dev Asserts the end state of a fill that started from an empty vault
  function _assertFilledFromNothing(IERC20 collateral, uint256 purchaseAmount) internal view {
    assertEq(mortgageNFT.ownerOf(1), borrower, "Borrower should have received the mortgage nft");
    assertGt(usdx.balanceOf(address(ufVault)), 0, "Vault should keep the fill margin");
    assertLt(usdx.balanceOf(address(ufVault)), purchaseAmount, "The swap should have cost part of the advance");
    assertEq(usdg.balanceOf(address(ufVault)), 0, "Vault should hold no USDG after the fill");
    assertEq(collateral.balanceOf(address(ufVault)), 0, "Vault should hold no collateral after the fill");
    assertEq(usdx.balanceOf(address(generalManager)), 0, "The general manager should hold no USDX");
    assertEq(collateral.balanceOf(address(generalManager)), 0, "The general manager should hold no collateral");
    assertEq(keeper.balance, GAS_FEE, "Keeper should have received the gas fee");
  }

  function test_fork_fillOrderWithCallback_swapRouter02_zeroUsdxVault() public {
    if (!forkEnabled) {
      vm.skip(true);
    }
    _useEmptyVault();

    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT, block.timestamp + 10 minutes);
    vm.startPrank(keeper);
    ufVault.fillOrderWithCallback(
      index,
      new uint256[](0),
      SWAP_ROUTER02_ADDRESS,
      _swapCalldata(COLLATERAL_AMOUNT, _maxUsdgInCallback(purchaseAmount))
    );
    vm.stopPrank();

    _assertFilledFromNothing(nvda, purchaseAmount);
    _assertNoStandingAllowance(SWAP_ROUTER02_ADDRESS);
  }

  function test_fork_fillOrderWithCallback_universalRouter212V3_zeroUsdxVault() public {
    if (!forkEnabled) {
      vm.skip(true);
    }
    _useEmptyVault();

    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT, block.timestamp + 10 minutes);
    vm.startPrank(keeper);
    ufVault.fillOrderWithCallback(
      index,
      new uint256[](0),
      UNIVERSAL_ROUTER_212_ADDRESS,
      _urV3ExactOutCalldata(COLLATERAL_AMOUNT, _maxUsdgInCallback(purchaseAmount))
    );
    vm.stopPrank();

    _assertFilledFromNothing(nvda, purchaseAmount);
    _assertNoStandingAllowance(UNIVERSAL_ROUTER_212_ADDRESS);
  }

  function test_fork_fillOrderWithCallback_universalRouter212V4_zeroUsdxVault() public {
    if (!forkEnabled) {
      vm.skip(true);
    }
    _useEmptyVault();

    (uint256 index, uint256 purchaseAmount) =
      _createOrderFor(SPY_ADDRESS, address(spySubConsol), SPY_COLLATERAL_AMOUNT, block.timestamp + 10 minutes);
    uint256 poolManagerUsdgBefore = usdg.balanceOf(POOL_MANAGER_ADDRESS);
    vm.startPrank(keeper);
    ufVault.fillOrderWithCallback(
      index,
      new uint256[](0),
      UNIVERSAL_ROUTER_212_ADDRESS,
      _urV4ExactOutCalldata(SPY_COLLATERAL_AMOUNT, _maxUsdgInCallback(purchaseAmount))
    );
    vm.stopPrank();

    assertGt(usdg.balanceOf(POOL_MANAGER_ADDRESS), poolManagerUsdgBefore, "USDG should settle into the PoolManager");
    _assertFilledFromNothing(spy, purchaseAmount);
    _assertNoStandingAllowance(UNIVERSAL_ROUTER_212_ADDRESS);
  }

  /// @dev A route asking for more than the advance cannot be paid for: there is no inventory to dip into
  function test_fork_fillOrderWithCallback_cannotSpendMoreThanTheAdvance() public {
    if (!forkEnabled) {
      vm.skip(true);
    }
    _useEmptyVault();

    // Ask for twice the order's collateral, which costs more than the whole advance
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT, block.timestamp + 10 minutes);
    vm.startPrank(keeper);
    vm.expectRevert();
    ufVault.fillOrderWithCallback(
      index, new uint256[](0), SWAP_ROUTER02_ADDRESS, _swapCalldata(2 * COLLATERAL_AMOUNT, 2 * purchaseAmount / 1e12)
    );
    vm.stopPrank();

    assertEq(usdx.balanceOf(address(ufVault)), 0, "Nothing should be left in the vault");
    assertEq(orderPool.orders(index).mortgageParams.collateral, NVDA_ADDRESS, "The order should be intact");
  }
}
