// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// forge-lint: disable-next-line(unused-import)
import {BaseTest, console} from "./BaseTest.t.sol";
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
import {Constants} from "@core/libraries/Constants.sol";
import {CreationRequest, BaseRequest} from "@core/types/orders/OrderRequests.sol";
import {ILiquidityVault} from "../src/interfaces/ILiquidityVault/ILiquidityVault.sol";
import {
  CollateralRoute,
  IUniswapFulfillmentVault
} from "../src/interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVault.sol";
import {
  IUniswapFulfillmentVaultEvents
} from "../src/interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVaultEvents.sol";
import {
  IUniswapFulfillmentVaultErrors
} from "../src/interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVaultErrors.sol";
import {UniswapFulfillmentVault} from "../src/UniswapFulfillmentVault.sol";
import {Router} from "../src/Router.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockStalePriceOracle} from "./mocks/MockStalePriceOracle.sol";
import {MockSwapRouter, MockReentrantSwapRouter} from "./mocks/MockSwapRouter.sol";

contract UniswapFulfillmentVaultTest is BaseTest {
  MockERC20 public usdg; // 6-decimal USD-leg token (scalar 1e12/1 on USDX)
  UniswapFulfillmentVault public ufVault;
  MockSwapRouter public swapRouter;
  Router public periphRouter;

  string UFV_NAME = "Test Uniswap Fulfillment Vault";
  string UFV_SYMBOL = "tUFV";
  uint8 UFV_DECIMALS = 24;
  uint8 UFV_DECIMALS_OFFSET = 6;

  uint16 ROUTE_PREMIUM_BPS = 50;
  uint256 ROUTE_MAX_FILL_COST = 1_000_000e18;
  uint256 USER_DEPOSIT = 10_000e18;
  uint256 GAS_FEE = 0.01e18;
  uint256 COLLATERAL_AMOUNT = 100e18;
  uint256 WHYPE_PRICE = 50e18;
  // anchor = 100 * $50 = $5000; bound = anchor * 1.005 = $5025; purchase = anchor * 1.01 = $5050
  uint256 ANCHOR_COST = 5_000e18;
  uint256 MAX_USDG_IN = 5_025e6;

  function setUp() public {
    setUpCore();

    // USDG is a 6-decimal supported token of USDX
    usdg = new MockERC20("Global Dollar", "USDG", 6);
    vm.label(address(usdg), "USDG");
    vm.startPrank(admin);
    USDX(address(usdx)).addSupportedToken(address(usdg), 1e12, 1);
    vm.stopPrank();

    swapRouter = new MockSwapRouter();
    ufVault = _deployVault(address(usdg));

    // Configure the whype route against the mock oracle
    MockPriceOracle(address(whypePriceOracle)).setPrice(WHYPE_PRICE);
    vm.startPrank(admin);
    ufVault.setCollateralRoute(
      address(whype),
      CollateralRoute({
        priceOracle: address(whypePriceOracle), maxPremiumBps: ROUTE_PREMIUM_BPS, maxFillCost: ROUTE_MAX_FILL_COST
      })
    );
    vm.stopPrank();

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
    address[] memory allowedRouters = new address[](1);
    allowedRouters[0] = address(swapRouter);
    bytes memory initializerData = abi.encodeCall(
      UniswapFulfillmentVault.initialize,
      (
        UFV_NAME,
        UFV_SYMBOL,
        UFV_DECIMALS,
        UFV_DECIMALS_OFFSET,
        address(generalManager),
        usdgToken,
        allowedRouters,
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
    vm.startPrank(keeper);
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(amountIn, amountOut));
    vm.stopPrank();
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
    assertTrue(ufVault.isAllowedRouter(address(swapRouter)));
    assertFalse(ufVault.isAllowedRouter(rando));
    assertTrue(ufVault.hasRole(ufVault.DEFAULT_ADMIN_ROLE(), admin));
    assertFalse(ufVault.paused(), "UniswapFulfillmentVault should not be paused");

    CollateralRoute memory route = ufVault.collateralRoute(address(whype));
    assertEq(route.priceOracle, address(whypePriceOracle));
    assertEq(route.maxPremiumBps, ROUTE_PREMIUM_BPS);
    assertEq(route.maxFillCost, ROUTE_MAX_FILL_COST);
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
        new address[](0),
        admin
      )
    );
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.InvalidUsdg.selector, address(0)));
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

  function test_setCollateralRoute_revertsWhenNotAdmin(address caller) public {
    vm.assume(ufVault.hasRole(ufVault.DEFAULT_ADMIN_ROLE(), caller) == false);

    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ufVault.DEFAULT_ADMIN_ROLE()
      )
    );
    ufVault.setCollateralRoute(
      address(ubtc), CollateralRoute({priceOracle: address(ubtcPriceOracle), maxPremiumBps: 50, maxFillCost: 1e18})
    );
    vm.stopPrank();
  }

  function test_setCollateralRoute_revertsOnZeroOracle() public {
    vm.startPrank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.InvalidCollateralRoute.selector, address(ubtc))
    );
    ufVault.setCollateralRoute(
      address(ubtc), CollateralRoute({priceOracle: address(0), maxPremiumBps: 50, maxFillCost: 1e18})
    );
    vm.stopPrank();
  }

  function test_setCollateralRoute_revertsOnPremiumAtOrAboveBps(uint16 premiumBps) public {
    premiumBps = uint16(bound(premiumBps, Constants.BPS, type(uint16).max));

    vm.startPrank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.InvalidCollateralRoute.selector, address(ubtc))
    );
    ufVault.setCollateralRoute(
      address(ubtc),
      CollateralRoute({priceOracle: address(ubtcPriceOracle), maxPremiumBps: premiumBps, maxFillCost: 1e18})
    );
    vm.stopPrank();
  }

  function test_setCollateralRoute_setAndDisable() public {
    // Set the route and validate the view round-trips
    vm.startPrank(admin);
    vm.expectEmit(true, true, true, true);
    emit IUniswapFulfillmentVaultEvents.CollateralRouteSet(address(ubtc), address(ubtcPriceOracle), 25, 500e18);
    ufVault.setCollateralRoute(
      address(ubtc), CollateralRoute({priceOracle: address(ubtcPriceOracle), maxPremiumBps: 25, maxFillCost: 500e18})
    );
    vm.stopPrank();

    CollateralRoute memory route = ufVault.collateralRoute(address(ubtc));
    assertEq(route.priceOracle, address(ubtcPriceOracle));
    assertEq(route.maxPremiumBps, 25);
    assertEq(route.maxFillCost, 500e18);

    // Disabling with a zero maxFillCost skips oracle/premium validation
    vm.startPrank(admin);
    ufVault.setCollateralRoute(
      address(ubtc), CollateralRoute({priceOracle: address(0), maxPremiumBps: 0, maxFillCost: 0})
    );
    vm.stopPrank();

    route = ufVault.collateralRoute(address(ubtc));
    assertEq(route.maxFillCost, 0);
  }

  function test_setRouterAllowed_revertsWhenNotAdmin(address caller) public {
    vm.assume(ufVault.hasRole(ufVault.DEFAULT_ADMIN_ROLE(), caller) == false);

    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ufVault.DEFAULT_ADMIN_ROLE()
      )
    );
    ufVault.setRouterAllowed(rando, true);
    vm.stopPrank();
  }

  function test_setRouterAllowed_revertsOnZeroAddress() public {
    vm.startPrank(admin);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.InvalidRouter.selector, address(0)));
    ufVault.setRouterAllowed(address(0), true);
    vm.stopPrank();
  }

  function test_setRouterAllowed_toggles() public {
    vm.startPrank(admin);
    vm.expectEmit(true, true, true, true);
    emit IUniswapFulfillmentVaultEvents.RouterAllowedSet(rando, true);
    ufVault.setRouterAllowed(rando, true);
    vm.stopPrank();
    assertTrue(ufVault.isAllowedRouter(rando));

    vm.startPrank(admin);
    ufVault.setRouterAllowed(rando, false);
    vm.stopPrank();
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
  // Bounds: premium, no-loss gate, maxFillCost
  // ---------------------------------------------------------------------------------------------

  function test_fillOrder_premiumBoundary_exact() public {
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    uint256 usdxBefore = usdx.balanceOf(address(ufVault));

    // Pull exactly the oracle-anchored bound
    _fill(index, MAX_USDG_IN, COLLATERAL_AMOUNT);

    assertApproxEqAbs(
      usdx.balanceOf(address(ufVault)),
      usdxBefore + purchaseAmount - MAX_USDG_IN * 1e12,
      2,
      "Fill at the exact bound should succeed"
    );
  }

  function test_fillOrder_premiumBoundary_overByOne() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    // One USDG unit over the bound fails on the scoped approval
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector, address(swapRouter), MAX_USDG_IN, MAX_USDG_IN + 1
      )
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(MAX_USDG_IN + 1, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  function test_fillOrder_noLossGate() public {
    // Order created at $50; price then rises so the premium bound exceeds the purchase amount
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    MockPriceOracle(address(whypePriceOracle)).setPrice(60e18);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    // anchor = $6000, premium bound = $6030, purchaseAmount = $5050 -> the gate binds at purchaseAmount
    uint256 gateUsdgIn = purchaseAmount / 1e12;

    // One unit over the gate fails on the scoped approval
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector, address(swapRouter), gateUsdgIn, gateUsdgIn + 1
      )
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(gateUsdgIn + 1, COLLATERAL_AMOUNT));
    vm.stopPrank();

    // At the gate the fill is breakeven (modulo USDX share rounding)
    uint256 usdxBefore = usdx.balanceOf(address(ufVault));
    _fill(index, gateUsdgIn, COLLATERAL_AMOUNT);
    assertApproxEqAbs(
      usdx.balanceOf(address(ufVault)), usdxBefore, 2, "The no-loss gate should cap the spend at the purchase amount"
    );
  }

  function test_fillOrder_revertsOnFillTooLarge() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    vm.startPrank(admin);
    ufVault.setCollateralRoute(
      address(whype),
      CollateralRoute({priceOracle: address(whypePriceOracle), maxPremiumBps: ROUTE_PREMIUM_BPS, maxFillCost: 4_000e18})
    );
    vm.stopPrank();

    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.FillTooLarge.selector, ANCHOR_COST, 4_000e18));
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  function test_fillOrder_revertsOnDisabledRoute() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    vm.startPrank(admin);
    ufVault.setCollateralRoute(
      address(whype), CollateralRoute({priceOracle: address(0), maxPremiumBps: 0, maxFillCost: 0})
    );
    vm.stopPrank();

    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.RouteNotConfigured.selector, address(whype)));
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
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
    ufVault.setRouterAllowed(address(swapRouter), false);
    vm.stopPrank();
    vm.startPrank(keeper);
    vm.expectRevert(
      abi.encodeWithSelector(IUniswapFulfillmentVaultErrors.RouterNotAllowed.selector, address(swapRouter))
    );
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
  }

  function test_fillOrder_staleOracleFailsClosed() public {
    (uint256 index,) = _createOrder(COLLATERAL_AMOUNT);
    MockStalePriceOracle staleOracle = new MockStalePriceOracle(18);
    vm.startPrank(admin);
    ufVault.setCollateralRoute(
      address(whype),
      CollateralRoute({
        priceOracle: address(staleOracle), maxPremiumBps: ROUTE_PREMIUM_BPS, maxFillCost: ROUTE_MAX_FILL_COST
      })
    );
    vm.stopPrank();

    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(MockStalePriceOracle.StalePrice.selector, 2 days, 1 days));
    ufVault.fillOrder(index, new uint256[](0), address(swapRouter), _swapData(5_000e6, COLLATERAL_AMOUNT));
    vm.stopPrank();
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
    // vault USDG beyond the scoped approval. The over-spend invariant still catches it.
    vm.startPrank(admin);
    ufVault.setRouterAllowed(address(usdg), true);
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
    ufVault.setRouterAllowed(address(reentrantRouter), true);
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

    // Recompute the bound the way the vault does: oracle anchor, premium, no-loss gate, floor to USDG units
    uint256 anchorCost = Math.mulDiv(collateralAmount, price, 1e18);
    uint256 maxCost = Math.mulDiv(anchorCost, Constants.BPS + ROUTE_PREMIUM_BPS, Constants.BPS);
    if (maxCost > purchaseAmount) {
      maxCost = purchaseAmount;
    }
    uint256 expectedMaxUsdgIn = maxCost / 1e12;

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
    vm.startPrank(admin);
    vault12.setCollateralRoute(
      address(whype),
      CollateralRoute({
        priceOracle: address(whypePriceOracle), maxPremiumBps: ROUTE_PREMIUM_BPS, maxFillCost: ROUTE_MAX_FILL_COST
      })
    );
    vm.stopPrank();
    _depositToVault(vault12, address(usdg12), user, USER_DEPOSIT);

    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT);
    _seedRouterWhype(address(swapRouter), COLLATERAL_AMOUNT);

    // bound = $5025 in 12-decimal units
    uint256 maxUsdgIn = 5_025e18 / 1e6;
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
}
