// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// forge-lint: disable-next-line(unused-import)
import {BaseTest, console} from "./BaseTest.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {USDX} from "@core/USDX.sol";
import {Roles} from "@core/libraries/Roles.sol";
import {CreationRequest, BaseRequest} from "@core/types/orders/OrderRequests.sol";
import {IOrderPool} from "@core/interfaces/IOrderPool/IOrderPool.sol";
import {ILiquidityVault} from "../src/interfaces/ILiquidityVault/ILiquidityVault.sol";
import {IUniswapFulfillmentVault} from "../src/interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVault.sol";
import {
  IUniswapFulfillmentVaultEvents
} from "../src/interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVaultEvents.sol";
import {
  IUniswapFulfillmentVaultErrors
} from "../src/interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVaultErrors.sol";
import {RouterApproval, RouterConfig} from "../src/interfaces/IUniswapFulfillmentVault/RouterApproval.sol";
import {UniswapFulfillmentVault} from "../src/UniswapFulfillmentVault.sol";
import {Router} from "../src/Router.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {
  MockSwapRouter,
  MockReentrantSwapRouter,
  MockHookedSwapRouter,
  MockVaultDepositor
} from "./mocks/MockSwapRouter.sol";
import {IRolloverVaultErrors} from "../src/interfaces/IRolloverVault/IRolloverVaultErrors.sol";
import {MockPermit2, MockPermit2SwapRouter} from "./mocks/MockPermit2.sol";

contract UniswapFulfillmentVaultTest is BaseTest {
  MockERC20 public usdg; // 6-decimal USD-leg token (scalar 1e12/1 on USDX)
  UniswapFulfillmentVault public ufVault;
  MockSwapRouter public swapRouter; // ERC20 mode
  MockPermit2 public permit2;
  MockPermit2SwapRouter public permit2Router; // Permit2 mode
  Router public periphRouter;

  string UFV_NAME = "Test Uniswap Fulfillment Vault";
  string UFV_SYMBOL = "tUFV";
  uint8 UFV_DECIMALS = 24;
  uint8 UFV_DECIMALS_OFFSET = 6;

  uint256 USER_DEPOSIT = 10_000e18;
  uint256 GAS_FEE = 0.01e18;
  uint256 COLLATERAL_AMOUNT = 100e18;
  uint256 WHYPE_PRICE = 50e18;
  // oracle cost = 100 * $50 = $5000; the general manager's 100 bps price spread makes the order's
  // purchaseAmount $5050, which is the vault's entire spend bound
  uint256 PURCHASE_AMOUNT = 5_050e18;
  uint256 MAX_USDG_IN = 5_050e6;

  function setUp() public {
    setUpCore();

    // USDG is a 6-decimal supported token of USDX
    usdg = new MockERC20("Global Dollar", "USDG", 6);
    vm.label(address(usdg), "USDG");
    vm.startPrank(admin);
    USDX(address(usdx)).addSupportedToken(address(usdg), 1e12, 1);
    vm.stopPrank();

    swapRouter = new MockSwapRouter();
    permit2 = new MockPermit2();
    permit2Router = new MockPermit2SwapRouter(permit2);
    ufVault = _deployVault(address(usdg));

    // The general manager prices orders off this oracle; the vault reads no oracle of its own
    MockPriceOracle(address(whypePriceOracle)).setPrice(WHYPE_PRICE);

    // Prime the vault and fund it with the user's deposit
    _primeVault(ufVault, address(usdg));
    _depositToVault(ufVault, address(usdg), user, USER_DEPOSIT);

    // Deploy the periphery router used to create real purchase orders
    periphRouter = new Router(
      address(whype), address(generalManager), address(rolloverVault), address(ufVault), address(simpleOracle)
    );
    periphRouter.approveCollaterals();
    periphRouter.approveUsdTokens();

    // Lender funds the origination pool with $100k
    deal(address(usdt), lender, 100_000e6);
    vm.startPrank(lender);
    usdt.approve(address(periphRouter), 100_000e6);
    periphRouter.originationPoolDeposit(originationPoolScheduler.configIdAt(0), address(usdt), 100_000e6);
    vm.stopPrank();

    // Skip ahead to the deploy phase of the origination pool
    vm.warp(originationPool.deployPhaseTimestamp());
  }

  /// @dev Deploys, initializes, and wires a UniswapFulfillmentVault around the given USDG token
  function _deployVault(address usdgToken) internal returns (UniswapFulfillmentVault vault) {
    UniswapFulfillmentVault implementation = new UniswapFulfillmentVault();
    RouterConfig[] memory routers = new RouterConfig[](2);
    routers[0] = RouterConfig({router: address(swapRouter), approval: RouterApproval.ERC20});
    routers[1] = RouterConfig({router: address(permit2Router), approval: RouterApproval.Permit2});
    bytes memory initializerData = abi.encodeCall(
      UniswapFulfillmentVault.initialize,
      (
        UFV_NAME,
        UFV_SYMBOL,
        UFV_DECIMALS,
        UFV_DECIMALS_OFFSET,
        address(generalManager),
        usdgToken,
        address(permit2),
        routers,
        admin
      )
    );
    ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializerData);
    vault = UniswapFulfillmentVault(payable(address(proxy)));

    // Roles: keeper on the vault, fulfillment on the order pool, cap bypass on USDX for the redeposit
    vm.startPrank(admin);
    vault.grantRole(vault.KEEPER_ROLE(), keeper);
    IAccessControl(address(orderPool)).grantRole(Roles.FULFILLMENT_ROLE, address(vault));
    IAccessControl(address(usdx)).grantRole(Roles.IGNORE_CAP_ROLE, address(vault));
    vm.stopPrank();

    // Standing collateral approval to the order pool
    vault.approveAssetToOrderPool(address(whype));
  }

  /// @dev Mints usdgToken, wraps it into USDX, and deposits into the vault from the given account
  function _depositToVault(UniswapFulfillmentVault vault, address usdgToken, address account, uint256 usdxAmount)
    internal
  {
    vm.startPrank(account);
    uint256 tokenAmount = usdx.convertUnderlying(usdgToken, usdxAmount);
    MockERC20(usdgToken).mint(account, tokenAmount);
    MockERC20(usdgToken).approve(address(usdx), tokenAmount);
    usdx.deposit(usdgToken, tokenAmount);
    usdx.approve(address(vault), usdxAmount);
    vault.deposit(address(usdx), usdxAmount);
    vm.stopPrank();
  }

  /// @dev Primes the vault with PRIME_AMOUNT of USDX and locks the shares in the vault itself
  function _primeVault(UniswapFulfillmentVault vault, address usdgToken) internal {
    _depositToVault(vault, usdgToken, admin, PRIME_AMOUNT);
    vm.startPrank(admin);
    vault.transfer(address(vault), vault.balanceOf(admin));
    vm.stopPrank();
  }

  /// @dev Creates a BNPL purchase order for collateralAmount of whype and returns its index and purchase amount
  function _createOrder(uint256 collateralAmount) internal returns (uint256 index, uint256 purchaseAmount) {
    CreationRequest memory creationRequest;
    {
      uint256[] memory collateralAmounts = new uint256[](1);
      address[] memory originationPools = new address[](1);
      collateralAmounts[0] = collateralAmount;
      originationPools[0] = address(originationPool);

      creationRequest = CreationRequest({
        base: BaseRequest({
          collateralAmounts: collateralAmounts,
          totalPeriods: 36,
          originationPools: originationPools,
          isCompounding: false,
          expiration: block.timestamp + 10 minutes
        }),
        mortgageId: "Mortgage - 001",
        collateral: address(whype),
        subConsol: address(whypeSubConsol),
        conversionQueues: new address[](0),
        hasPaymentPlan: true
      });
    }

    (, uint256 requiredUsdxCollected,,) = periphRouter.calculateCollectedAmounts(creationRequest);
    deal(borrower, GAS_FEE);
    vm.startPrank(borrower);
    uint256 usdtAmount = periphRouter.convert(address(usdx), address(usdt), requiredUsdxCollected);
    deal(address(usdt), borrower, usdtAmount);
    usdt.approve(address(periphRouter), usdtAmount);
    periphRouter.requestMortgage{value: GAS_FEE}(address(usdt), creationRequest, false, type(uint256).max);
    vm.stopPrank();

    index = orderPool.orderCount() - 1;
    purchaseAmount = orderPool.orders(index).orderAmounts.purchaseAmount;
  }

  /// @dev Seeds the mock swap router with whype inventory
  function _seedRouterWhype(address routerAddress, uint256 amount) internal {
    deal(address(this), amount);
    whype.deposit{value: amount}();
    whype.transfer(routerAddress, amount);
  }

  /// @dev Encodes a MockSwapRouter.swap call pulling amountIn usdg and delivering amountOut whype
  function _swapData(uint256 amountIn, uint256 amountOut) internal view returns (bytes memory) {
    return abi.encodeCall(MockSwapRouter.swap, (IERC20(address(usdg)), amountIn, IERC20(address(whype)), amountOut));
  }

  /// @dev Fills an order through the mock swap router as the keeper
  function _fill(uint256 index, uint256 amountIn, uint256 amountOut) internal {
    _fillVia(address(swapRouter), index, amountIn, amountOut);
  }

  /// @dev Fills an order through the given router as the keeper
  function _fillVia(address routerAddress, uint256 index, uint256 amountIn, uint256 amountOut) internal {
    vm.startPrank(keeper);
    ufVault.fillOrder(index, new uint256[](0), routerAddress, _swapData(amountIn, amountOut));
    vm.stopPrank();
  }

  /// @dev Asserts the vault holds no USDG allowance to the router, to Permit2, or inside Permit2 for the router
  function _assertNoStandingAllowance(address routerAddress) internal view {
    assertEq(usdg.allowance(address(ufVault), routerAddress), 0, "No USDG allowance to the router");
    assertEq(usdg.allowance(address(ufVault), address(permit2)), 0, "No USDG allowance to Permit2");
    (uint160 amount,,) = permit2.allowance(address(ufVault), address(usdg), routerAddress);
    assertEq(amount, 0, "No Permit2 allowance for the router");
  }

  // ---------------------------------------------------------------------------------------------
  // Initialization + views
  // ---------------------------------------------------------------------------------------------

  function test_initialize() public view {
    assertEq(ufVault.name(), UFV_NAME);
    assertEq(ufVault.symbol(), UFV_SYMBOL);
    assertEq(ufVault.decimals(), UFV_DECIMALS);
    assertEq(ufVault.decimalsOffset(), UFV_DECIMALS_OFFSET);
    assertEq(ufVault.totalAssets(), PRIME_AMOUNT + USER_DEPOSIT);
    assertEq(ufVault.depositableAssets()[0], address(usdx));
    assertEq(ufVault.redeemableAssets()[0], address(usdx));
    assertEq(ufVault.generalManager(), address(generalManager));
    assertEq(ufVault.orderPool(), address(orderPool));
    assertEq(ufVault.usdx(), address(usdx));
    assertEq(ufVault.usdg(), address(usdg));
    assertEq(ufVault.permit2(), address(permit2));
    assertTrue(ufVault.routerApproval(address(swapRouter)) == RouterApproval.ERC20);
    assertTrue(ufVault.routerApproval(address(permit2Router)) == RouterApproval.Permit2);
    assertTrue(ufVault.routerApproval(rando) == RouterApproval.None);
    assertTrue(ufVault.isAllowedRouter(address(swapRouter)));
    assertTrue(ufVault.isAllowedRouter(address(permit2Router)));
    assertFalse(ufVault.isAllowedRouter(rando));
    assertTrue(ufVault.hasRole(ufVault.DEFAULT_ADMIN_ROLE(), admin));
    assertFalse(ufVault.paused(), "UniswapFulfillmentVault should not be paused");
  }

  function test_initialize_revertsOnZeroUsdg() public {
    UniswapFulfillmentVault implementation = new UniswapFulfillmentVault();
    bytes memory initializerData = abi.encodeCall(
      UniswapFulfillmentVault.initialize,
      (
        UFV_NAME,
        UFV_SYMBOL,
        UFV_DECIMALS,
        UFV_DECIMALS_OFFSET,
        address(generalManager),
        address(0),
        address(permit2),
        new RouterConfig[](0),
        admin
      )
    );
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.InvalidUsdg.selector, address(0)));
    new ERC1967Proxy(address(implementation), initializerData);
  }

  function test_initialize_revertsOnZeroPermit2() public {
    UniswapFulfillmentVault implementation = new UniswapFulfillmentVault();
    bytes memory initializerData = abi.encodeCall(
      UniswapFulfillmentVault.initialize,
      (
        UFV_NAME,
        UFV_SYMBOL,
        UFV_DECIMALS,
        UFV_DECIMALS_OFFSET,
        address(generalManager),
        address(usdg),
        address(0),
        new RouterConfig[](0),
        admin
      )
    );
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.InvalidPermit2.selector, address(0)));
    new ERC1967Proxy(address(implementation), initializerData);
  }

  function test_initialize_revertsOnZeroRouter() public {
    UniswapFulfillmentVault implementation = new UniswapFulfillmentVault();
    RouterConfig[] memory routers = new RouterConfig[](1);
    routers[0] = RouterConfig({router: address(0), approval: RouterApproval.Permit2});
    bytes memory initializerData = abi.encodeCall(
      UniswapFulfillmentVault.initialize,
      (
        UFV_NAME,
        UFV_SYMBOL,
        UFV_DECIMALS,
        UFV_DECIMALS_OFFSET,
        address(generalManager),
        address(usdg),
        address(permit2),
        routers,
        admin
      )
    );
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.InvalidRouter.selector, address(0)));
    new ERC1967Proxy(address(implementation), initializerData);
  }

  function test_supportedInterfaces_valid() public view {
    assertTrue(ufVault.supportsInterface(type(ILiquidityVault).interfaceId), "Should support ILiquidityVault");
    assertTrue(
      ufVault.supportsInterface(type(IUniswapFulfillmentVault).interfaceId), "Should support IUniswapFulfillmentVault"
    );
    assertTrue(ufVault.supportsInterface(type(IERC165).interfaceId), "Should support IERC165");
    assertTrue(ufVault.supportsInterface(type(IAccessControl).interfaceId), "Should support IAccessControl");
    assertTrue(ufVault.supportsInterface(type(IERC1822Proxiable).interfaceId), "Should support IERC1822Proxiable");
    assertTrue(ufVault.supportsInterface(type(IERC20).interfaceId), "Should support IERC20");
    assertTrue(ufVault.supportsInterface(type(IERC20Metadata).interfaceId), "Should support IERC20Metadata");
  }

  function test_supportedInterfaces_invalid(bytes4 interfaceId) public view {
    vm.assume(
      interfaceId != type(ILiquidityVault).interfaceId && interfaceId != type(IUniswapFulfillmentVault).interfaceId
        && interfaceId != type(IERC165).interfaceId && interfaceId != type(IAccessControl).interfaceId
        && interfaceId != type(IERC1822Proxiable).interfaceId && interfaceId != type(IERC20).interfaceId
        && interfaceId != type(IERC20Metadata).interfaceId
    );
    assertFalse(ufVault.supportsInterface(interfaceId), "Should not support invalid interface");
  }

  function test_approveAssetToOrderPool(address caller) public {
    vm.startPrank(caller);
    ufVault.approveAssetToOrderPool(address(ubtc));
    vm.stopPrank();

    assertEq(ubtc.allowance(address(ufVault), address(orderPool)), type(uint256).max);
  }

  // ---------------------------------------------------------------------------------------------
  // Admin configuration
  // ---------------------------------------------------------------------------------------------

  function test_setRouterApproval_revertsWhenNotAdmin(address caller, uint8 approvalSeed) public {
    vm.assume(ufVault.hasRole(ufVault.DEFAULT_ADMIN_ROLE(), caller) == false);
    RouterApproval approval = RouterApproval(bound(approvalSeed, 0, uint8(type(RouterApproval).max)));

    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ufVault.DEFAULT_ADMIN_ROLE()
      )
    );
    ufVault.setRouterApproval(rando, approval);
    vm.stopPrank();
  }

  function test_setRouterApproval_revertsOnZeroAddress() public {
    vm.startPrank(admin);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.InvalidRouter.selector, address(0)));
    ufVault.setRouterApproval(address(0), RouterApproval.Permit2);
    vm.stopPrank();
  }

  function test_setRouterApproval_setsEachModeAndClears() public {
    // ERC20
    vm.startPrank(admin);
    vm.expectEmit(true, true, true, true);
    emit IUniswapFulfillmentVaultEvents.RouterApprovalSet(rando, RouterApproval.ERC20);
    ufVault.setRouterApproval(rando, RouterApproval.ERC20);
    vm.stopPrank();
    assertTrue(ufVault.routerApproval(rando) == RouterApproval.ERC20);
    assertTrue(ufVault.isAllowedRouter(rando));

    // Permit2
    vm.startPrank(admin);
    vm.expectEmit(true, true, true, true);
    emit IUniswapFulfillmentVaultEvents.RouterApprovalSet(rando, RouterApproval.Permit2);
    ufVault.setRouterApproval(rando, RouterApproval.Permit2);
    vm.stopPrank();
    assertTrue(ufVault.routerApproval(rando) == RouterApproval.Permit2);
    assertTrue(ufVault.isAllowedRouter(rando));

    // None removes the router
    vm.startPrank(admin);
    vm.expectEmit(true, true, true, true);
    emit IUniswapFulfillmentVaultEvents.RouterApprovalSet(rando, RouterApproval.None);
    ufVault.setRouterApproval(rando, RouterApproval.None);
    vm.stopPrank();
    assertTrue(ufVault.routerApproval(rando) == RouterApproval.None);
    assertFalse(ufVault.isAllowedRouter(rando));
  }

  // ---------------------------------------------------------------------------------------------
  // fillOrder gates
  // ---------------------------------------------------------------------------------------------

  function test_fillOrder_revertsWhenDoesNotHaveKeeperRole(address caller, uint256 index) public {
    vm.assume(ufVault.hasRole(ufVault.KEEPER_ROLE(), caller) == false);

    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ufVault.KEEPER_ROLE())
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), "");
    vm.stopPrank();
  }

  function test_fillOrder_revertsWhenPaused(uint256 index) public {
    vm.startPrank(keeper);
    ufVault.setPaused(true);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), "");
    vm.stopPrank();
  }

  function test_fillOrder_revertsOnNonexistentOrder(uint256 index) public {
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.OrderAlreadyProcessed.selector, index));
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), "");
    vm.stopPrank();
  }

  function test_fillOrder_revertsOnDoubleFill() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);
    _fill(index, 5_000e6, COLLATERAL_AMOUNT);

    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.OrderAlreadyProcessed.selector, index));
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  // ---------------------------------------------------------------------------------------------
  // Happy path + share economics
  // ---------------------------------------------------------------------------------------------

  function test_fillOrder_happyPath() public {
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    uint256 usdxBefore = usdx.balanceOf(address(ufVault));
    uint256 supplyBefore = ufVault.totalSupply();
    uint256 amountIn = 5_000e6;

    // USDX is a rebasing shares-based token, so the received balance delta can round a wei below the
    // purchase amount; check the event topics and assert the amounts via balances instead
    vm.expectEmit(true, true, false, false);
    emit IUniswapFulfillmentVaultEvents.OrderFilled(index, address(whype), COLLATERAL_AMOUNT, amountIn, purchaseAmount);
    _fill(index, amountIn, COLLATERAL_AMOUNT);

    // Borrower has the mortgage
    assertEq(mortgageNFT.ownerOf(1), borrower, "Borrower should have received the mortgage nft");

    // The vault burned maxUsdgIn worth of USDX, redeposited the leftover, and received the purchase amount:
    // net = purchaseAmount - amountIn (scaled to 18 decimals), modulo USDX share rounding
    assertApproxEqAbs(
      usdx.balanceOf(address(ufVault)),
      usdxBefore + purchaseAmount - amountIn * 1e12,
      2,
      "Vault USDX should reflect the fill margin"
    );

    // Total assets are pure USDX at the end of the transaction
    assertEq(usdg.balanceOf(address(ufVault)), 0, "Vault should hold no USDG after the fill");
    assertEq(whype.balanceOf(address(ufVault)), 0, "Vault should hold no collateral after the fill");
    assertEq(ufVault.totalAssets(), usdx.balanceOf(address(ufVault)), "Total assets should be the USDX balance");

    // Fill profit accrues to the share price (supply unchanged, assets up)
    assertEq(ufVault.totalSupply(), supplyBefore, "Fill should not mint or burn shares");
    assertGt(ufVault.totalAssets(), usdxBefore, "Share price should increase across a profitable fill");

    // The keeper received the order gas fee
    assertEq(keeper.balance, GAS_FEE, "Keeper should have received the gas fee in native tokens");
  }

  function test_depositRedeem_roundTrip(uint128 amount) public {
    uint256 usdxAmount = bound(amount, 1e18, 1_000_000e18);

    _depositToVault(ufVault, address(usdg), rando, usdxAmount);
    uint256 shares = ufVault.balanceOf(rando);
    assertGt(shares, 0, "Depositor should have received shares");

    // The USDG mint rounds up to whole USDG units, so measure the redeem against the post-deposit balance
    uint256 usdxBalanceAfterDeposit = usdx.balanceOf(rando);

    vm.startPrank(rando);
    ufVault.redeem(shares);
    vm.stopPrank();

    // Round-trip returns the deposit minus share-math and USDX share rounding
    assertApproxEqAbs(
      usdx.balanceOf(rando) - usdxBalanceAfterDeposit, usdxAmount, 2, "Redeem should return the deposit minus rounding"
    );
  }

  function test_fillOrder_leftoverRedeposited() public {
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    uint256 usdxBefore = usdx.balanceOf(address(ufVault));

    // Pull well under the bound so a large leftover has to be redeposited
    uint256 amountIn = 1_000e6;
    _fill(index, amountIn, COLLATERAL_AMOUNT);

    assertEq(usdg.balanceOf(address(ufVault)), 0, "Leftover USDG should be redeposited into USDX");
    assertApproxEqAbs(
      usdx.balanceOf(address(ufVault)),
      usdxBefore + purchaseAmount - amountIn * 1e12,
      2,
      "Only the USDG actually spent should leave the vault"
    );
  }

  // ---------------------------------------------------------------------------------------------
  // Router approval modes: ERC20 vs Permit2
  // ---------------------------------------------------------------------------------------------

  function test_fillOrder_erc20Mode_leavesNoStandingAllowance() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    // Pull under the bound so an unrevoked approval would leave a remainder
    _fill(index, 5_000e6, COLLATERAL_AMOUNT);

    _assertNoStandingAllowance(address(swapRouter));
  }

  function test_fillOrder_permit2Mode_happyPath() public {
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(permit2Router), COLLATERAL_AMOUNT);

    uint256 usdxBefore = usdx.balanceOf(address(ufVault));
    uint256 supplyBefore = ufVault.totalSupply();
    // Pull under the bound (MAX_USDG_IN) so an unrevoked Permit2 allowance would leave a remainder
    uint256 amountIn = 5_000e6;

    vm.expectEmit(true, true, false, false);
    emit IUniswapFulfillmentVaultEvents.OrderFilled(index, address(whype), COLLATERAL_AMOUNT, amountIn, purchaseAmount);
    _fillVia(address(permit2Router), index, amountIn, COLLATERAL_AMOUNT);

    assertEq(permit2Router.callCount(), 1, "The Permit2 router should have been called once");
    assertEq(mortgageNFT.ownerOf(1), borrower, "Borrower should have received the mortgage nft");
    assertApproxEqAbs(
      usdx.balanceOf(address(ufVault)),
      usdxBefore + purchaseAmount - amountIn * 1e12,
      2,
      "Vault USDX should reflect the fill margin"
    );
    assertEq(usdg.balanceOf(address(ufVault)), 0, "Vault should hold no USDG after the fill");
    assertEq(whype.balanceOf(address(ufVault)), 0, "Vault should hold no collateral after the fill");
    assertEq(ufVault.totalSupply(), supplyBefore, "Fill should not mint or burn shares");

    // Both legs of the scoped approval are revoked, and the Permit2 allowance is expired past this block
    _assertNoStandingAllowance(address(permit2Router));
    (, uint48 expiration,) = permit2.allowance(address(ufVault), address(usdg), address(permit2Router));
    assertEq(expiration, block.timestamp, "The revoked Permit2 allowance should expire with this block");
  }

  function test_fillOrder_permit2Mode_overBoundByOne() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(permit2Router), COLLATERAL_AMOUNT);

    // One USDG unit over the bound fails on the scoped Permit2 allowance
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(MockPermit2.InsufficientAllowance.selector, MAX_USDG_IN));
    ufVault.fillOrder(index, new uint256[](0), address(permit2Router), _swapData(MAX_USDG_IN + 1, COLLATERAL_AMOUNT));
    vm.stopPrank();

    // The exact bound succeeds
    _fillVia(address(permit2Router), index, MAX_USDG_IN, COLLATERAL_AMOUNT);
    _assertNoStandingAllowance(address(permit2Router));
  }

  function test_fillOrder_permit2Router_revertsInErc20Mode() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(permit2Router), COLLATERAL_AMOUNT);
    vm.startPrank(admin);
    ufVault.setRouterApproval(address(permit2Router), RouterApproval.ERC20);
    vm.stopPrank();

    // A plain approval to the router grants nothing inside Permit2: the never-set allowance reads as expired
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(MockPermit2.AllowanceExpired.selector, 0));
    ufVault.fillOrder(index, new uint256[](0), address(permit2Router), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  function test_fillOrder_erc20Router_revertsInPermit2Mode() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);
    vm.startPrank(admin);
    ufVault.setRouterApproval(address(swapRouter), RouterApproval.Permit2);
    vm.stopPrank();

    // In Permit2 mode the token approval goes to Permit2, so a direct transferFrom by the router has no allowance
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(swapRouter), 0, 5_000e6)
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  function test_fillOrder_revertsOnNoneMode() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    vm.startPrank(admin);
    ufVault.setRouterApproval(address(permit2Router), RouterApproval.None);
    vm.stopPrank();

    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.RouterNotAllowed.selector, address(permit2Router))
    );
    ufVault.fillOrder(index, new uint256[](0), address(permit2Router), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
    assertEq(permit2Router.callCount(), 0, "A None-mode router should never be called");
  }

  function test_fillOrder_revertsOnDisallowedRouter() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);

    // A router that was never allowlisted
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.RouterNotAllowed.selector, rando));
    ufVault.fillOrder(index, new uint256[](0), rando, _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();

    // A router that was allowlisted and then removed
    vm.startPrank(admin);
    ufVault.setRouterApproval(address(swapRouter), RouterApproval.None);
    vm.stopPrank();
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.RouterNotAllowed.selector, address(swapRouter))
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  function test_fillOrder_permit2Mode_routerCannotPullAfterFill() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(permit2Router), COLLATERAL_AMOUNT);
    _fillVia(address(permit2Router), index, 5_000e6, COLLATERAL_AMOUNT);

    // Give the vault spare USDG and a (hypothetical) leftover token approval to Permit2
    usdg.mint(address(ufVault), 1e6);
    vm.startPrank(address(ufVault));
    usdg.approve(address(permit2), 1e6);
    vm.stopPrank();

    // Same block: the Permit2 allowance amount was revoked to zero
    vm.startPrank(address(permit2Router));
    vm.expectRevert(abi.encodeWithSelector(MockPermit2.InsufficientAllowance.selector, 0));
    permit2.transferFrom(address(ufVault), address(permit2Router), 1, address(usdg));
    vm.stopPrank();

    // Any later block: the allowance has expired regardless of amount
    vm.warp(block.timestamp + 1);
    vm.startPrank(address(permit2Router));
    vm.expectRevert(abi.encodeWithSelector(MockPermit2.AllowanceExpired.selector, block.timestamp - 1));
    permit2.transferFrom(address(ufVault), address(permit2Router), 1, address(usdg));
    vm.stopPrank();
  }

  function test_permit2Allowance_expiresAfterCurrentTimestamp() public {
    // The expiration the vault grants (block.timestamp) is valid for pulls in the same block and dead after it
    usdg.mint(address(ufVault), 2e6);
    vm.startPrank(address(ufVault));
    usdg.approve(address(permit2), 2e6);
    // forge-lint: disable-next-line(unsafe-typecast)
    permit2.approve(address(usdg), rando, 2e6, uint48(block.timestamp));
    vm.stopPrank();

    vm.startPrank(rando);
    permit2.transferFrom(address(ufVault), rando, 1e6, address(usdg));
    vm.stopPrank();
    assertEq(usdg.balanceOf(rando), 1e6, "A same-block pull should succeed");

    uint256 grantedAt = block.timestamp;
    vm.warp(grantedAt + 1);
    vm.startPrank(rando);
    vm.expectRevert(abi.encodeWithSelector(MockPermit2.AllowanceExpired.selector, grantedAt));
    permit2.transferFrom(address(ufVault), rando, 1e6, address(usdg));
    vm.stopPrank();
  }

  // ---------------------------------------------------------------------------------------------
  // The spend bound: the order's purchase amount
  // ---------------------------------------------------------------------------------------------

  function test_fillOrder_boundIsThePurchaseAmount() public {
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    assertEq(purchaseAmount, PURCHASE_AMOUNT, "The order should be priced at the oracle cost plus the price spread");
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    // One USDG unit over the purchase amount starves on the scoped approval
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector, address(swapRouter), MAX_USDG_IN, MAX_USDG_IN + 1
      )
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(MAX_USDG_IN + 1, COLLATERAL_AMOUNT));
    vm.stopPrank();

    // Spending exactly the purchase amount is breakeven: the fill returns what it cost
    uint256 usdxBefore = usdx.balanceOf(address(ufVault));
    _fill(index, MAX_USDG_IN, COLLATERAL_AMOUNT);
    assertApproxEqAbs(
      usdx.balanceOf(address(ufVault)), usdxBefore, 2, "A fill at the bound should leave the vault's USDX whole"
    );
    assertEq(usdg.balanceOf(address(ufVault)), 0, "Vault should hold no USDG after the fill");
  }

  function test_fillOrder_boundTracksTheOrder_notTheLivePrice() public {
    // The bound is fixed at order creation: a price move afterwards moves neither the bound nor the fill
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    MockPriceOracle(address(whypePriceOracle)).setPrice(60e18);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    uint256 boundUsdgIn = purchaseAmount / 1e12;
    assertEq(boundUsdgIn, MAX_USDG_IN, "The bound should still be the original purchase amount");

    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector, address(swapRouter), boundUsdgIn, boundUsdgIn + 1
      )
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(boundUsdgIn + 1, COLLATERAL_AMOUNT));
    vm.stopPrank();

    uint256 usdxBefore = usdx.balanceOf(address(ufVault));
    _fill(index, boundUsdgIn, COLLATERAL_AMOUNT);
    assertApproxEqAbs(usdx.balanceOf(address(ufVault)), usdxBefore, 2, "The fill should still be breakeven");
  }

  // ---------------------------------------------------------------------------------------------
  // Delta invariants
  // ---------------------------------------------------------------------------------------------

  function test_fillOrder_revertsOnInsufficientCollateralOut() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IUniswapFulfillmentVaultErrors.InsufficientCollateralOut.selector, COLLATERAL_AMOUNT - 1, COLLATERAL_AMOUNT
      )
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT - 1));
    vm.stopPrank();
  }

  function test_fillOrder_revertsWhenRouterConsumesApprovalAndDeliversNothing() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);

    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.InsufficientCollateralOut.selector, 0, COLLATERAL_AMOUNT)
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, 0));
    vm.stopPrank();
  }

  function test_fillOrder_revertsOnOverSpent() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);

    // Misconfiguration drill: the token itself is allowlisted as a "router", so the swap calldata can move
    // vault USDG beyond the scoped approval. The over-spend invariant still catches it at the purchase amount.
    vm.startPrank(admin);
    ufVault.setRouterApproval(address(usdg), RouterApproval.ERC20);
    vm.stopPrank();
    usdg.mint(address(ufVault), 100e6);

    bytes memory swapCalldata = abi.encodeCall(IERC20.transfer, (rando, MAX_USDG_IN + 100e6));
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.OverSpent.selector, MAX_USDG_IN + 100e6, MAX_USDG_IN)
    );
    ufVault.fillOrder(index, new uint256[](0), address(usdg), swapCalldata);
    vm.stopPrank();
  }

  // ---------------------------------------------------------------------------------------------
  // Expiry sweep
  // ---------------------------------------------------------------------------------------------

  function test_fillOrder_expiredOrderSweptWithoutSwapping() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    uint256 usdxBefore = usdx.balanceOf(address(ufVault));
    // The refund goes to the order's owner, which for router-created orders is the router itself
    address orderOwner = orderPool.orders(index).mortgageParams.owner;
    uint256 ownerUsdxBefore = usdx.balanceOf(orderOwner);
    uint256 usdxCollected = orderPool.orders(index).orderAmounts.usdxCollected;
    assertGt(usdxCollected, 0, "The order should have collected assets to refund");

    // Let the order expire
    vm.warp(block.timestamp + 11 minutes);

    // The sweep never validates the route or router and never calls it: a disallowed router address proves it
    vm.startPrank(keeper);
    vm.expectEmit(true, true, true, true);
    emit IUniswapFulfillmentVaultEvents.OrderExpiredSwept(index);
    ufVault.fillOrder(index, new uint256[](0), rando, _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();

    assertEq(swapRouter.callCount(), 0, "The sweep should not perform any router calls");
    assertEq(usdx.balanceOf(address(ufVault)), usdxBefore, "The sweep should not touch the vault's USDX");
    assertApproxEqAbs(
      usdx.balanceOf(orderOwner),
      ownerUsdxBefore + usdxCollected,
      2,
      "The order owner should be refunded the collected assets"
    );
    assertEq(keeper.balance, GAS_FEE, "Keeper should have received the gas fee for the sweep");
    assertEq(
      orderPool.orders(index).mortgageParams.collateral, address(0), "The order should be deleted after the sweep"
    );
  }

  // ---------------------------------------------------------------------------------------------
  // Reentrancy
  // ---------------------------------------------------------------------------------------------

  function _setUpReentrantRouter() internal returns (MockReentrantSwapRouter reentrantRouter, uint256 index) {
    reentrantRouter = new MockReentrantSwapRouter();
    vm.startPrank(admin);
    ufVault.setRouterApproval(address(reentrantRouter), RouterApproval.ERC20);
    vm.stopPrank();
    (index,) = _createOrder(COLLATERAL_AMOUNT);
  }

  function test_fillOrder_reentrancy_fillOrder() public {
    (MockReentrantSwapRouter reentrantRouter, uint256 index) = _setUpReentrantRouter();

    // Even a router holding the keeper role cannot re-enter fillOrder
    vm.startPrank(admin);
    ufVault.grantRole(ufVault.KEEPER_ROLE(), address(reentrantRouter));
    vm.stopPrank();
    reentrantRouter.setReentryData(
      abi.encodeCall(ufVault.fillOrder, (index, new uint256[](0), address(reentrantRouter), ""))
    );

    vm.startPrank(keeper);
    vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
    ufVault.fillOrder(index, new uint256[](0), address(reentrantRouter), _swapData(0, 0));
    vm.stopPrank();
  }

  function test_fillOrder_reentrancy_deposit() public {
    (MockReentrantSwapRouter reentrantRouter, uint256 index) = _setUpReentrantRouter();
    reentrantRouter.setReentryData(abi.encodeCall(ILiquidityVault.deposit, (address(usdx), 0)));

    vm.startPrank(keeper);
    vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
    ufVault.fillOrder(index, new uint256[](0), address(reentrantRouter), _swapData(0, 0));
    vm.stopPrank();
  }

  function test_fillOrder_reentrancy_redeem() public {
    (MockReentrantSwapRouter reentrantRouter, uint256 index) = _setUpReentrantRouter();
    reentrantRouter.setReentryData(abi.encodeCall(ILiquidityVault.redeem, (0)));

    vm.startPrank(keeper);
    vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
    ufVault.fillOrder(index, new uint256[](0), address(reentrantRouter), _swapData(0, 0));
    vm.stopPrank();
  }

  // ---------------------------------------------------------------------------------------------
  // Scalar conversion
  // ---------------------------------------------------------------------------------------------

  /// forge-config: default.fuzz.runs = 64
  function test_fillOrder_scalarConversion_fuzz(uint256 collateralAmount, uint256 price) public {
    // Keep the oracle cost within [~$4, $9k] so the origination pool's minimum and maximum caps never bind
    price = bound(price, 1e18, 90e18);
    collateralAmount = bound(collateralAmount, 4e18, Math.mulDiv(9_000e18, 1e18, price));
    MockPriceOracle(address(whypePriceOracle)).setPrice(price);

    (uint256 index, uint256 purchaseAmount) = _createOrder(collateralAmount);
    _seedRouterWhype(address(swapRouter), collateralAmount);

    // The bound is the order's own purchase amount, floored to USDG units
    uint256 expectedMaxUsdgIn = purchaseAmount / 1e12;

    // One USDG unit over the bound fails on the scoped approval
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector, address(swapRouter), expectedMaxUsdgIn, expectedMaxUsdgIn + 1
      )
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(expectedMaxUsdgIn + 1, collateralAmount));
    vm.stopPrank();

    // The exact bound succeeds and the accounting is whole
    uint256 usdxBefore = usdx.balanceOf(address(ufVault));
    _fill(index, expectedMaxUsdgIn, collateralAmount);
    assertEq(usdg.balanceOf(address(ufVault)), 0, "Vault should hold no USDG after the fill");
    assertApproxEqAbs(
      usdx.balanceOf(address(ufVault)),
      usdxBefore + purchaseAmount - expectedMaxUsdgIn * 1e12,
      2,
      "Vault USDX should reflect exactly the USDG spent and the purchase amount received"
    );
  }

  function test_fillOrder_twelveDecimalUsdg() public {
    // A 12-decimal USD-leg token (scalar 1e6/1) proves the conversion is scalar-driven, not hardcoded 1e12
    MockERC20 usdg12 = new MockERC20("Global Dollar 12", "USDG12", 12);
    vm.startPrank(admin);
    USDX(address(usdx)).addSupportedToken(address(usdg12), 1e6, 1);
    vm.stopPrank();

    UniswapFulfillmentVault vault12 = _deployVault(address(usdg12));
    _depositToVault(vault12, address(usdg12), user, USER_DEPOSIT);

    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    // bound = the $5050 purchase amount in 12-decimal units
    uint256 maxUsdgIn = purchaseAmount / 1e6;
    uint256 usdxBefore = usdx.balanceOf(address(vault12));

    vm.startPrank(keeper);
    vault12.fillOrder(
      index,
      new uint256[](0),
      address(swapRouter),
      abi.encodeCall(
        MockSwapRouter.swap, (IERC20(address(usdg12)), maxUsdgIn, IERC20(address(whype)), COLLATERAL_AMOUNT)
      )
    );
    vm.stopPrank();

    assertEq(usdg12.balanceOf(address(vault12)), 0, "Vault should hold no USDG12 after the fill");
    assertApproxEqAbs(
      usdx.balanceOf(address(vault12)),
      usdxBefore + purchaseAmount - maxUsdgIn * 1e6,
      2,
      "Vault USDX should reflect the 12-decimal scalar conversion"
    );
  }

  /// forge-config: default.fuzz.runs = 24
  function test_fillOrder_boundIsPurchaseAmountUnderAnyScalar_fuzz(uint8 usdgDecimals) public {
    // Any USD-leg decimals: the bound is always the purchase amount pushed through USDX's scalars
    usdgDecimals = uint8(bound(usdgDecimals, 2, 18));
    uint256 numerator = 10 ** (18 - uint256(usdgDecimals));
    MockERC20 usdgN = new MockERC20("Global Dollar N", "USDGN", usdgDecimals);
    vm.startPrank(admin);
    USDX(address(usdx)).addSupportedToken(address(usdgN), numerator, 1);
    vm.stopPrank();

    UniswapFulfillmentVault vaultN = _deployVault(address(usdgN));
    _depositToVault(vaultN, address(usdgN), user, USER_DEPOSIT);

    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);
    uint256 expectedMaxIn = purchaseAmount / numerator;

    // One unit over the converted bound starves on the scoped approval
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector, address(swapRouter), expectedMaxIn, expectedMaxIn + 1
      )
    );
    vaultN.fillOrder(
      index,
      new uint256[](0),
      address(swapRouter),
      abi.encodeCall(
        MockSwapRouter.swap, (IERC20(address(usdgN)), expectedMaxIn + 1, IERC20(address(whype)), COLLATERAL_AMOUNT)
      )
    );
    vm.stopPrank();

    // The converted bound itself is spendable and the accounting is whole
    uint256 usdxBefore = usdx.balanceOf(address(vaultN));
    vm.startPrank(keeper);
    vaultN.fillOrder(
      index,
      new uint256[](0),
      address(swapRouter),
      abi.encodeCall(
        MockSwapRouter.swap, (IERC20(address(usdgN)), expectedMaxIn, IERC20(address(whype)), COLLATERAL_AMOUNT)
      )
    );
    vm.stopPrank();

    assertEq(usdgN.balanceOf(address(vaultN)), 0, "Vault should hold no USD-leg token after the fill");
    assertApproxEqAbs(
      usdx.balanceOf(address(vaultN)),
      usdxBefore + purchaseAmount - expectedMaxIn * numerator,
      2,
      "Vault USDX should reflect exactly the scalar-converted spend and the purchase amount received"
    );
  }

  // ---------------------------------------------------------------------------------------------
  // Callback fills: the general manager advances the purchase amount, the vault needs no USDX
  // ---------------------------------------------------------------------------------------------

  // The advance is the purchase amount less the general manager's holdback, floored to USDG units
  uint256 MAX_USDG_IN_CALLBACK = 5_049_999_999;

  /// @dev Deploys a vault that holds no USDX, no USDG, and no collateral
  function _deployEmptyVault() internal returns (UniswapFulfillmentVault vault) {
    vault = _deployVault(address(usdg));
    assertEq(usdx.balanceOf(address(vault)), 0, "Vault should start with no USDX");
    assertEq(vault.totalSupply(), 0, "Vault should start with no shares");
  }

  function _fillWithCallback(UniswapFulfillmentVault vault, address routerAddress, uint256 index, uint256 amountIn)
    internal
  {
    vm.startPrank(keeper);
    vault.fillOrderWithCallback(index, new uint256[](0), routerAddress, _swapData(amountIn, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_revertsWhenDoesNotHaveKeeperRole(address caller, uint256 index) public {
    vm.assume(!ufVault.hasRole(ufVault.KEEPER_ROLE(), caller));
    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ufVault.KEEPER_ROLE())
    );
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(swapRouter), "");
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_revertsWhenPaused(uint256 index) public {
    vm.startPrank(keeper);
    ufVault.setPaused(true);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(swapRouter), "");
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_revertsOnNonexistentOrder(uint256 index) public {
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.OrderAlreadyProcessed.selector, index));
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(swapRouter), "");
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_zeroUsdxVault() public {
    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);
    uint256 amountIn = 5_000e6;

    vm.expectEmit(true, true, false, false);
    emit IUniswapFulfillmentVaultEvents.OrderFilled(index, address(whype), COLLATERAL_AMOUNT, amountIn, purchaseAmount);
    _fillWithCallback(vault, address(swapRouter), index, amountIn);

    // Borrower has the mortgage, bought entirely with the advance
    assertEq(mortgageNFT.ownerOf(1), borrower, "Borrower should have received the mortgage nft");
    assertEq(swapRouter.callCount(), 1, "The router should have been called once");

    // The vault keeps the purchase amount less what the swap cost, and nothing else
    assertApproxEqAbs(
      usdx.balanceOf(address(vault)), purchaseAmount - amountIn * 1e12, 2, "Vault USDX should be the fill margin"
    );
    assertEq(usdg.balanceOf(address(vault)), 0, "Vault should hold no USDG after the fill");
    assertEq(whype.balanceOf(address(vault)), 0, "Vault should hold no collateral after the fill");
    assertEq(usdx.balanceOf(address(generalManager)), 0, "The general manager should hold no USDX");
    assertEq(whype.balanceOf(address(generalManager)), 0, "The general manager should hold no collateral");
    assertEq(whype.allowance(address(vault), address(generalManager)), 0, "No collateral allowance is left behind");
    _assertNoStandingAllowanceOf(vault, address(swapRouter));

    // The keeper received the order gas fee
    assertEq(keeper.balance, GAS_FEE, "Keeper should have received the gas fee in native tokens");
  }

  function test_fillOrderWithCallback_reportsThePurchaseAmountReceived() public {
    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    vm.recordLogs();
    _fillWithCallback(vault, address(swapRouter), index, 5_000e6);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    bool found;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == address(vault) && logs[i].topics[0] == IUniswapFulfillmentVaultEvents.OrderFilled.selector)
      {
        (uint256 collateralPurchased, uint256 usdgSpent, uint256 purchaseAmountReceived) =
          abi.decode(logs[i].data, (uint256, uint256, uint256));
        assertEq(collateralPurchased, COLLATERAL_AMOUNT, "collateralPurchased");
        assertEq(usdgSpent, 5_000e6, "usdgSpent");
        assertApproxEqAbs(purchaseAmountReceived, purchaseAmount, 2, "purchaseAmountReceived");
        found = true;
      }
    }
    assertTrue(found, "OrderFilled should be emitted");
  }

  function test_fillOrderWithCallback_permit2Mode_zeroUsdxVault() public {
    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(permit2Router), COLLATERAL_AMOUNT);

    _fillWithCallback(vault, address(permit2Router), index, 5_000e6);

    assertEq(permit2Router.callCount(), 1, "The Permit2 router should have been called once");
    assertEq(mortgageNFT.ownerOf(1), borrower, "Borrower should have received the mortgage nft");
    assertApproxEqAbs(
      usdx.balanceOf(address(vault)), purchaseAmount - 5_000e6 * 1e12, 2, "Vault USDX should be the fill margin"
    );
    _assertNoStandingAllowanceOf(vault, address(permit2Router));
  }

  function test_fillOrderWithCallback_boundIsTheAdvance() public {
    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    // One USDG unit over the advance starves on the scoped approval
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector,
        address(swapRouter),
        MAX_USDG_IN_CALLBACK,
        MAX_USDG_IN_CALLBACK + 1
      )
    );
    vault.fillOrderWithCallback(
      index, new uint256[](0), address(swapRouter), _swapData(MAX_USDG_IN_CALLBACK + 1, COLLATERAL_AMOUNT)
    );
    vm.stopPrank();

    // The whole advance is spendable; the vault ends with the unspent dust and the holdback
    _fillWithCallback(vault, address(swapRouter), index, MAX_USDG_IN_CALLBACK);
    assertApproxEqAbs(
      usdx.balanceOf(address(vault)),
      purchaseAmount - MAX_USDG_IN_CALLBACK * 1e12,
      2,
      "Vault USDX should be the unspent remainder"
    );
  }

  function test_fillOrderWithCallback_cannotSpendVaultInventoryBeyondTheAdvance() public {
    // ufVault holds depositor USDX; a callback fill still cannot spend more than the advance
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector,
        address(swapRouter),
        MAX_USDG_IN_CALLBACK,
        MAX_USDG_IN_CALLBACK + 1
      )
    );
    ufVault.fillOrderWithCallback(
      index, new uint256[](0), address(swapRouter), _swapData(MAX_USDG_IN_CALLBACK + 1, COLLATERAL_AMOUNT)
    );
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_revertsOnOverSpent() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);

    // Misconfiguration drill, as for fillOrder: the token is allowlisted as a "router" and moves stray USDG
    vm.startPrank(admin);
    ufVault.setRouterApproval(address(usdg), RouterApproval.ERC20);
    vm.stopPrank();
    usdg.mint(address(ufVault), 100e6);

    bytes memory swapCalldata = abi.encodeCall(IERC20.transfer, (rando, MAX_USDG_IN_CALLBACK + 100e6));
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IUniswapFulfillmentVaultErrors.OverSpent.selector, MAX_USDG_IN_CALLBACK + 100e6, MAX_USDG_IN_CALLBACK
      )
    );
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(usdg), swapCalldata);
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_inventoryVaultNeverLosesUsdx() public {
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);
    uint256 usdxBefore = usdx.balanceOf(address(ufVault));
    uint256 supplyBefore = ufVault.totalSupply();

    _fillWithCallback(ufVault, address(swapRouter), index, 5_000e6);

    assertApproxEqAbs(
      usdx.balanceOf(address(ufVault)),
      usdxBefore + purchaseAmount - 5_000e6 * 1e12,
      2,
      "Vault USDX should grow by the fill margin"
    );
    assertEq(ufVault.totalSupply(), supplyBefore, "Fill should not mint or burn shares");
  }

  function test_fillOrderWithCallback_revertsOnInsufficientCollateralOut() public {
    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IUniswapFulfillmentVaultErrors.InsufficientCollateralOut.selector, COLLATERAL_AMOUNT - 1, COLLATERAL_AMOUNT
      )
    );
    vault.fillOrderWithCallback(
      index,
      new uint256[](0),
      address(swapRouter),
      abi.encodeCall(
        MockSwapRouter.swap, (IERC20(address(usdg)), 5_000e6, IERC20(address(whype)), COLLATERAL_AMOUNT - 1)
      )
    );
    vm.stopPrank();

    // The failed fill left nothing behind
    assertEq(usdx.balanceOf(address(vault)), 0, "No USDX should be left in the vault");
    assertEq(orderPool.orders(index).mortgageParams.collateral, address(whype), "The order should be intact");
  }

  function test_fillOrderWithCallback_revertsOnDisallowedRouter() public {
    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);

    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.RouterNotAllowed.selector, rando));
    vault.fillOrderWithCallback(index, new uint256[](0), rando, _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_revertsOnDoubleFill() public {
    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);
    _fillWithCallback(vault, address(swapRouter), index, 5_000e6);

    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.OrderAlreadyProcessed.selector, index));
    vault.fillOrderWithCallback(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_expiredOrderSweptWithoutSwapping() public {
    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    address orderOwner = orderPool.orders(index).mortgageParams.owner;
    uint256 ownerUsdxBefore = usdx.balanceOf(orderOwner);
    uint256 usdxCollected = orderPool.orders(index).orderAmounts.usdxCollected;

    vm.warp(block.timestamp + 11 minutes);

    // The sweep never validates or calls the router: a disallowed router address proves it
    vm.startPrank(keeper);
    vm.expectEmit(true, true, true, true);
    emit IUniswapFulfillmentVaultEvents.OrderExpiredSwept(index);
    vault.fillOrderWithCallback(index, new uint256[](0), rando, _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();

    assertEq(swapRouter.callCount(), 0, "The sweep should not perform any router calls");
    assertEq(usdx.balanceOf(address(vault)), 0, "The sweep should not move any USDX into the vault");
    assertApproxEqAbs(
      usdx.balanceOf(orderOwner), ownerUsdxBefore + usdxCollected, 2, "The order owner should be refunded"
    );
    assertEq(keeper.balance, GAS_FEE, "Keeper should have received the gas fee for the sweep");

    // The sweep leaves no commitment behind for a later callback to match
    vm.startPrank(address(generalManager));
    vm.expectRevert(IUniswapFulfillmentVaultErrors.UnexpectedFillCallback.selector);
    vault.orderFulfillmentCallback(
      1, address(whype), COLLATERAL_AMOUNT, 0, abi.encodePacked(rando, _swapData(5_000e6, COLLATERAL_AMOUNT))
    );
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_revertsIfCallbackNeverRuns() public {
    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);

    // An order pool that reports success without the general manager ever calling back
    vm.mockCall(address(orderPool), abi.encodeWithSelector(IOrderPool.processOrdersWithCallback.selector), "");
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.FillCallbackNotExecuted.selector, index));
    vault.fillOrderWithCallback(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  function test_orderFulfillmentCallback_revertsWhenNotGeneralManager(address caller) public {
    vm.assume(caller != address(generalManager));
    vm.startPrank(caller);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.OnlyGeneralManager.selector, caller));
    ufVault.orderFulfillmentCallback(1, address(whype), COLLATERAL_AMOUNT, PURCHASE_AMOUNT, "");
    vm.stopPrank();
  }

  function test_orderFulfillmentCallback_revertsWithNoFillInFlight() public {
    // Even the general manager cannot make the vault swap outside a fill the keeper started
    vm.startPrank(address(generalManager));
    vm.expectRevert(IUniswapFulfillmentVaultErrors.UnexpectedFillCallback.selector);
    ufVault.orderFulfillmentCallback(
      1,
      address(whype),
      COLLATERAL_AMOUNT,
      PURCHASE_AMOUNT,
      abi.encodePacked(address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT))
    );
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_reentrancy_fillOrderWithCallback() public {
    (MockReentrantSwapRouter reentrantRouter, uint256 index) = _setUpReentrantRouter();
    vm.startPrank(admin);
    ufVault.grantRole(ufVault.KEEPER_ROLE(), address(reentrantRouter));
    vm.stopPrank();
    reentrantRouter.setReentryData(
      abi.encodeCall(ufVault.fillOrderWithCallback, (index, new uint256[](0), address(reentrantRouter), ""))
    );

    vm.startPrank(keeper);
    vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(reentrantRouter), _swapData(0, 0));
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_reentrancy_fillOrder() public {
    (MockReentrantSwapRouter reentrantRouter, uint256 index) = _setUpReentrantRouter();
    vm.startPrank(admin);
    ufVault.grantRole(ufVault.KEEPER_ROLE(), address(reentrantRouter));
    vm.stopPrank();
    reentrantRouter.setReentryData(
      abi.encodeCall(ufVault.fillOrder, (index, new uint256[](0), address(reentrantRouter), ""))
    );

    vm.startPrank(keeper);
    vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(reentrantRouter), _swapData(0, 0));
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_reentrancy_deposit() public {
    (MockReentrantSwapRouter reentrantRouter, uint256 index) = _setUpReentrantRouter();
    reentrantRouter.setReentryData(abi.encodeCall(ILiquidityVault.deposit, (address(usdx), 0)));

    vm.startPrank(keeper);
    vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(reentrantRouter), _swapData(0, 0));
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_reentrancy_redeem() public {
    (MockReentrantSwapRouter reentrantRouter, uint256 index) = _setUpReentrantRouter();
    reentrantRouter.setReentryData(abi.encodeCall(ILiquidityVault.redeem, (0)));

    vm.startPrank(keeper);
    vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(reentrantRouter), _swapData(0, 0));
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_reentrancy_callback() public {
    // The router replays the fulfillment callback mid-swap: it is not the general manager
    (MockReentrantSwapRouter reentrantRouter, uint256 index) = _setUpReentrantRouter();
    reentrantRouter.setReentryData(
      abi.encodeCall(ufVault.orderFulfillmentCallback, (1, address(whype), COLLATERAL_AMOUNT, PURCHASE_AMOUNT, ""))
    );

    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.OnlyGeneralManager.selector, address(reentrantRouter))
    );
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(reentrantRouter), _swapData(0, 0));
    vm.stopPrank();
  }

  function test_fillOrder_stillFillsFromInventory() public {
    // The inventory path is unchanged next to the callback path, and an empty vault cannot use it
    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    vm.startPrank(keeper);
    vm.expectRevert();
    vault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();

    _fill(index, 5_000e6, COLLATERAL_AMOUNT);
    assertEq(mortgageNFT.ownerOf(1), borrower, "Borrower should have received the mortgage nft");
  }

  function test_fillOrderWithCallback_scalarConversion_fuzz(uint256 collateralAmount, uint256 price, uint256 spendBps)
    public
  {
    // Keep the oracle cost within [~$4, $9k] so the origination pool's minimum and maximum caps never bind
    price = bound(price, 1e18, 90e18);
    collateralAmount = bound(collateralAmount, 4e18, Math.mulDiv(9_000e18, 1e18, price));
    spendBps = bound(spendBps, 0, 10_000);
    MockPriceOracle(address(whypePriceOracle)).setPrice(price);

    UniswapFulfillmentVault vault = _deployEmptyVault();
    (uint256 index, uint256 purchaseAmount) = _createOrder(collateralAmount);
    _seedRouterWhype(address(swapRouter), collateralAmount);

    // Spend any share of the advance, up to all of it
    uint256 maxUsdgIn = (purchaseAmount - 1000) / 1e12;
    uint256 amountIn = maxUsdgIn * spendBps / 10_000;

    vm.startPrank(keeper);
    vault.fillOrderWithCallback(
      index,
      new uint256[](0),
      address(swapRouter),
      abi.encodeCall(MockSwapRouter.swap, (IERC20(address(usdg)), amountIn, IERC20(address(whype)), collateralAmount))
    );
    vm.stopPrank();

    assertApproxEqAbs(
      usdx.balanceOf(address(vault)), purchaseAmount - amountIn * 1e12, 2, "Vault USDX should be the fill margin"
    );
    assertEq(usdg.balanceOf(address(vault)), 0, "Vault should hold no USDG after the fill");
    assertEq(whype.balanceOf(address(vault)), 0, "Vault should hold no collateral after the fill");
  }

  // ---------------------------------------------------------------------------------------------
  // The rollover vault cannot be priced from inside the callback
  // ---------------------------------------------------------------------------------------------

  /// @dev The rollover vault's share of the pool, as USDX
  function _rolloverClaim(address account) internal view returns (uint256) {
    return rolloverVault.balanceOf(account) * rolloverVault.totalAssets() / rolloverVault.totalSupply();
  }

  /// @dev A rollover vault whose only depositor is rolled into the origination pool, a large order against
  ///      that pool, and a third party holding USDX that a hooked route can reach mid-swap
  function _setUpHookedFill()
    internal
    returns (MockHookedSwapRouter hookedRouter, MockVaultDepositor depositor, uint256 index, bytes memory swapData)
  {
    uint256 collateralAmount = 1_000e18;
    setUpRolloverVault();
    _depositUsdxInto(address(rolloverVault), user, 5_000e18);

    uint256 timestamp = block.timestamp;
    vm.warp(originationPool.deployPhaseTimestamp() - 1);
    vm.startPrank(keeper);
    rolloverVault.setPaused(true);
    rolloverVault.depositOriginationPool(address(originationPool), 5_000e18);
    rolloverVault.setPaused(false);
    vm.stopPrank();
    vm.warp(timestamp);

    hookedRouter = new MockHookedSwapRouter();
    vm.startPrank(admin);
    ufVault.setRouterApproval(address(hookedRouter), RouterApproval.ERC20);
    generalManager.setMaximumCap(address(whype), 1e24);
    vm.stopPrank();

    depositor = new MockVaultDepositor(IERC20(address(usdx)), address(rolloverVault));
    vm.startPrank(address(depositor));
    uint256 usdgAmount = usdx.convertUnderlying(address(usdg), 100_000e18);
    usdg.mint(address(depositor), usdgAmount);
    usdg.approve(address(usdx), usdgAmount);
    usdx.deposit(address(usdg), usdgAmount);
    vm.stopPrank();

    (index,) = _createOrder(collateralAmount);
    _seedRouterWhype(address(hookedRouter), collateralAmount);
    swapData = abi.encodeCall(
      MockHookedSwapRouter.swap, (IERC20(address(usdg)), 50_000e6, IERC20(address(whype)), collateralAmount)
    );
  }

  /// @dev Wraps USDG into USDX and deposits it into a vault from the given account
  function _depositUsdxInto(address vault, address account, uint256 usdxAmount) internal {
    vm.startPrank(account);
    uint256 usdgAmount = usdx.convertUnderlying(address(usdg), usdxAmount);
    usdg.mint(account, usdgAmount);
    usdg.approve(address(usdx), usdgAmount);
    usdx.deposit(address(usdg), usdgAmount);
    usdx.approve(vault, usdxAmount);
    ILiquidityVault(vault).deposit(address(usdx), usdxAmount);
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_rolloverVaultRejectsDepositsMidSwap() public {
    (MockHookedSwapRouter hookedRouter, MockVaultDepositor depositor, uint256 index, bytes memory swapData) =
      _setUpHookedFill();

    // Mid-swap the origination pool has lent its USDX and holds no Consol for it yet, so the rollover
    // vault's total assets are understated. A deposit priced there would dilute the existing depositor.
    hookedRouter.setHook(address(depositor), abi.encodeCall(MockVaultDepositor.depositAll, ()));
    vm.startPrank(keeper);
    vm.expectRevert(IRolloverVaultErrors.GeneralManagerExecuting.selector);
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(hookedRouter), swapData);
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_rolloverVaultRejectsRedeemsAndTransfersMidSwap() public {
    (MockHookedSwapRouter hookedRouter,, uint256 index, bytes memory swapData) = _setUpHookedFill();

    // The existing depositor has approved the router's hook target to move its shares
    vm.startPrank(user);
    rolloverVault.approve(address(hookedRouter), type(uint256).max);
    vm.stopPrank();
    hookedRouter.setHook(address(rolloverVault), abi.encodeCall(IERC20.transferFrom, (user, address(hookedRouter), 1)));
    vm.startPrank(keeper);
    vm.expectRevert(IRolloverVaultErrors.GeneralManagerExecuting.selector);
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(hookedRouter), swapData);
    vm.stopPrank();
  }

  function test_fillOrderWithCallback_rolloverVaultDepositorsKeepTheirClaimAcrossAFill() public {
    (MockHookedSwapRouter hookedRouter, MockVaultDepositor depositor, uint256 index, bytes memory swapData) =
      _setUpHookedFill();
    uint256 claimBefore = _rolloverClaim(user);

    // A deposit before the fill is priced fairly, and the fill then pays the pool its fee
    depositor.depositAll();
    vm.startPrank(keeper);
    ufVault.fillOrderWithCallback(index, new uint256[](0), address(hookedRouter), swapData);
    vm.stopPrank();

    assertGe(_rolloverClaim(user), claimBefore, "The existing depositor should not be diluted");
    assertFalse(generalManager.reentrancyGuardEntered(), "The guard should be released after the fill");

    // Deposits work again once the fill is over
    _depositUsdxInto(address(rolloverVault), rando, 10e18);
    assertGt(rolloverVault.balanceOf(rando), 0, "Deposits should work after the fill");
  }

  /// @dev Asserts a vault holds no USDG allowance to the router, to Permit2, or inside Permit2 for the router
  function _assertNoStandingAllowanceOf(UniswapFulfillmentVault vault, address routerAddress) internal view {
    assertEq(usdg.allowance(address(vault), routerAddress), 0, "No USDG allowance to the router");
    assertEq(usdg.allowance(address(vault), address(permit2)), 0, "No USDG allowance to Permit2");
    (uint160 amount,,) = permit2.allowance(address(vault), address(usdg), routerAddress);
    assertEq(amount, 0, "No Permit2 allowance for the router");
  }
}
