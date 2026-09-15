// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// forge-lint: disable-next-line(unused-import)
import {BaseTest, console} from "../BaseTest.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {USDX} from "@core/USDX.sol";
import {SubConsol} from "@core/SubConsol.sol";
import {ChainlinkPriceOracle} from "@core/ChainlinkPriceOracle.sol";
import {IPriceOracle} from "@core/interfaces/IPriceOracle.sol";
import {Roles} from "@core/libraries/Roles.sol";
import {Constants} from "@core/libraries/Constants.sol";
import {CreationRequest, BaseRequest} from "@core/types/orders/OrderRequests.sol";
import {
  CollateralRoute,
  IUniswapFulfillmentVault
} from "../../src/interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVault.sol";
import {
  IUniswapFulfillmentVaultEvents
} from "../../src/interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVaultEvents.sol";
import {RouterApproval, RouterConfig} from "../../src/interfaces/IUniswapFulfillmentVault/RouterApproval.sol";
import {UniswapFulfillmentVault} from "../../src/UniswapFulfillmentVault.sol";
import {Router} from "../../src/Router.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {MockSimpleOracle} from "../mocks/MockSimpleOracle.sol";

/// @dev Minimal SwapRouter02 surface for encoding the keeper's swap calldata. The vault treats it as
///      opaque bytes; only the test needs the type.
interface ISwapRouter02 {
  struct ExactOutputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 amountOut;
    uint256 amountInMaximum;
    uint160 sqrtPriceLimitX96;
  }

  function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/// @dev Minimal Universal Router surface for encoding the keeper's swap calldata
interface IUniversalRouter {
  function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev Minimal Permit2 AllowanceTransfer surface for reading and exercising allowances
interface IPermit2 {
  function allowance(address owner, address token, address spender)
    external
    view
    returns (uint160 amount, uint48 expiration, uint48 nonce);

  function approve(address token, address spender, uint160 amount, uint48 expiration) external;

  function transferFrom(address from, address to, uint160 amount, address token) external;
}

/// @dev Minimal v4 StateView surface for pool discovery checks
interface IStateView {
  function getSlot0(bytes32 poolId)
    external
    view
    returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

  function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

/// @dev v4-core PoolKey layout
struct V4PoolKey {
  address currency0;
  address currency1;
  uint24 fee;
  int24 tickSpacing;
  address hooks;
}

/// @dev v4-periphery IV4Router.ExactOutputSingleParams layout for the deployed (2.1+) router
struct V4ExactOutputSingleParams {
  V4PoolKey poolKey;
  bool zeroForOne;
  uint128 amountOut;
  uint128 amountInMaximum;
  uint256 minHopPriceX36;
  bytes hookData;
}

/**
 * @title UniswapFulfillmentVaultForkTest
 * @notice End-to-end fills against live Robinhood Chain (4663) state: real USDG, real NVDA and SPY, the real
 *         Chainlink feeds through the ChainlinkPriceOracle adapter, the real SwapRouter02 (ERC20 mode), and the
 *         real Universal Router with Permit2 (Permit2 mode) over v3 and v4 pools.
 * @dev Network-gated: the default suite skips these tests so CI stays network-free. Run with
 *      `RUN_FORK_TESTS=true forge test --match-path test/fork/UniswapFulfillmentVault.fork.t.sol`
 */
contract UniswapFulfillmentVaultForkTest is BaseTest {
  string constant FORK_URL = "https://robinhood.drpc.org";
  uint256 constant FORK_BLOCK = 63753466; // 2026-09-15, pinned for reproducibility

  // Live 4663 addresses
  address constant USDG_ADDRESS = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
  address constant NVDA_ADDRESS = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // 18 decimals
  address constant NVDA_FEED_ADDRESS = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15; // 8 decimals
  address constant SPY_ADDRESS = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C; // 18 decimals
  address constant SPY_FEED_ADDRESS = 0x319724394D3A0e3669269846abE664Cd621f9f6A; // 8 decimals
  address constant SWAP_ROUTER02_ADDRESS = 0xCaf681a66D020601342297493863E78C959E5cb2;
  address constant NVDA_USDG_V3_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // 0.05% fee tier
  uint24 constant NVDA_POOL_FEE = 500;
  address constant UNIVERSAL_ROUTER_ADDRESS = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
  address constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
  address constant POOL_MANAGER_ADDRESS = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
  address constant STATE_VIEW_ADDRESS = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

  // The deepest SPY/USDG v4 pool, discovered from PoolManager Initialize events and StateView liquidity:
  // currency0 = SPY, currency1 = USDG, fee 0.30%, tickSpacing 60, no hooks
  uint24 constant SPY_V4_POOL_FEE = 3000;
  int24 constant SPY_V4_POOL_TICK_SPACING = 60;
  bytes32 constant SPY_V4_POOL_ID = 0xfe2a80bb5618fd14984b92ca6d45bf5ba67443ddb1435e28b2e48df2fc1526cd;

  // Universal Router command bytes (universal-router Commands.sol, identical across tags 2.0.0-2.2.0)
  uint8 constant UR_V3_SWAP_EXACT_OUT = 0x01;
  uint8 constant UR_V4_SWAP = 0x10;
  // v4-periphery Actions.sol at the commits pinned by universal-router 2.1.1 and 2.2.0
  uint8 constant V4_SWAP_EXACT_OUT_SINGLE = 0x08;
  uint8 constant V4_SETTLE_ALL = 0x0c;
  uint8 constant V4_TAKE_ALL = 0x0f;

  uint256 constant FEED_MAX_AGE = 7 days;
  uint16 constant ROUTE_PREMIUM_BPS = 50;
  // The SPY v4 pool charges 0.30% and sat ~0.17% above the feed at the fork block, so 50 bps leaves no margin
  uint16 constant SPY_ROUTE_PREMIUM_BPS = 100;
  uint256 constant ROUTE_MAX_FILL_COST = 1_000_000e18;
  uint256 constant COLLATERAL_AMOUNT = 0.05e18; // ~ $10 of NVDA: negligible pool impact
  uint256 constant SPY_COLLATERAL_AMOUNT = 0.015e18; // ~ $11 of SPY: negligible pool impact
  uint256 constant USER_DEPOSIT = 1_000e18;
  uint256 constant GAS_FEE = 0.01e18;

  IERC20 public usdg = IERC20(USDG_ADDRESS);
  IERC20 public nvda = IERC20(NVDA_ADDRESS);
  IERC20 public spy = IERC20(SPY_ADDRESS);
  SubConsol public nvdaSubConsol;
  ChainlinkPriceOracle public nvdaChainlinkOracle;
  SubConsol public spySubConsol;
  ChainlinkPriceOracle public spyChainlinkOracle;
  UniswapFulfillmentVault public ufVault;
  Router public periphRouter;

  bool internal forkEnabled;

  function setUp() public {
    forkEnabled = vm.envOr("RUN_FORK_TESTS", false);
    if (!forkEnabled) {
      return;
    }
    vm.createSelectFork(FORK_URL, FORK_BLOCK);

    // Pool phases anchor to the current daily epoch start, which lies in the past. Size the deposit
    // phase so it is still open now and the deploy phase starts two hours from the fork timestamp,
    // keeping the live feed well within maxAge after the warp.
    uint256 epochElapsed = (block.timestamp - Constants.EPOCH_OFFSET) % Constants.EPOCH_DURATION;
    ogDepositPhaseDuration = uint32(epochElapsed + 2 hours);

    // Core stack as setUpCore builds it, minus its 55-year skip (the fork timestamp must stay live for
    // the Chainlink feed)
    _deployWHype();
    _setupCollaterals();
    _createForfeitedAssetsPool();
    _createUSDX();
    _createSubConsols();
    _createConsol();
    _createGeneralManager();
    _createLoanManager();
    _createOriginationPoolSchedulerAndPools();
    _createOrderPool();
    _createConversionQueues();
    _setupOracles();
    _updateSupportedTotalPeriods();
    _updateMinMaxBorrowCaps();
    vm.startPrank(admin);
    generalManager.setOriginationPoolScheduler(address(originationPoolScheduler));
    vm.stopPrank();

    // Real USDG as a supported token of the test USDX (6 decimals -> 1e12/1 scalars, per deploy convention)
    assertEq(IERC20Metadata(USDG_ADDRESS).decimals(), 6, "USDG should have 6 decimals");
    vm.startPrank(admin);
    USDX(address(usdx)).addSupportedToken(USDG_ADDRESS, 1e12, 1);
    vm.stopPrank();

    // Real NVDA and SPY as collaterals, priced by the real Chainlink feeds through the consol adapter
    (nvdaSubConsol, nvdaChainlinkOracle) = _listCollateral(NVDA_ADDRESS, NVDA_FEED_ADDRESS, "NVDA");
    (spySubConsol, spyChainlinkOracle) = _listCollateral(SPY_ADDRESS, SPY_FEED_ADDRESS, "SPY");

    // Vault with the real SwapRouter02 (plain ERC20 pull) and the real Universal Router (Permit2 pull)
    UniswapFulfillmentVault implementation = new UniswapFulfillmentVault();
    RouterConfig[] memory routers = new RouterConfig[](2);
    routers[0] = RouterConfig({router: SWAP_ROUTER02_ADDRESS, approval: RouterApproval.ERC20});
    routers[1] = RouterConfig({router: UNIVERSAL_ROUTER_ADDRESS, approval: RouterApproval.Permit2});
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(implementation),
      abi.encodeCall(
        UniswapFulfillmentVault.initialize,
        (
          "Fork Uniswap Fulfillment Vault",
          "fUFV",
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
    ufVault.setCollateralRoute(
      NVDA_ADDRESS,
      CollateralRoute({
        priceOracle: address(nvdaChainlinkOracle), maxPremiumBps: ROUTE_PREMIUM_BPS, maxFillCost: ROUTE_MAX_FILL_COST
      })
    );
    ufVault.setCollateralRoute(
      SPY_ADDRESS,
      CollateralRoute({
        priceOracle: address(spyChainlinkOracle), maxPremiumBps: SPY_ROUTE_PREMIUM_BPS, maxFillCost: ROUTE_MAX_FILL_COST
      })
    );
    vm.stopPrank();
    ufVault.approveAssetToOrderPool(NVDA_ADDRESS);
    ufVault.approveAssetToOrderPool(SPY_ADDRESS);

    // Fund the vault: prime plus a user deposit
    _depositToVault(admin, PRIME_AMOUNT);
    vm.startPrank(admin);
    ufVault.transfer(address(ufVault), ufVault.balanceOf(admin));
    vm.stopPrank();
    _depositToVault(user, USER_DEPOSIT);

    // Periphery router for creating real purchase orders; lender funds the origination pool with USDG
    simpleOracle = new MockSimpleOracle(simpleOracleSigner);
    periphRouter = new Router(
      address(whype), address(generalManager), address(rolloverVault), address(ufVault), address(simpleOracle)
    );
    periphRouter.approveCollaterals();
    periphRouter.approveUsdTokens();
    _dealUsdg(lender, 1_000e6);
    vm.startPrank(lender);
    usdg.approve(address(periphRouter), 1_000e6);
    periphRouter.originationPoolDeposit(originationPoolScheduler.configIdAt(0), USDG_ADDRESS, 1_000e6);
    vm.stopPrank();

    vm.warp(originationPool.deployPhaseTimestamp());
  }

  /// @dev Lists a real 18-decimal stock token as a collateral priced by its real Chainlink feed
  function _listCollateral(address token, address feed, string memory ticker)
    internal
    returns (SubConsol subConsol, ChainlinkPriceOracle oracle)
  {
    assertEq(IERC20Metadata(token).decimals(), 18, "Collateral should have 18 decimals");
    oracle = new ChainlinkPriceOracle(feed, 18, FEED_MAX_AGE);
    subConsol = new SubConsol(string.concat(ticker, " SubConsol"), string.concat(ticker, "-SUBCONSOL"), admin, token);
    vm.startPrank(admin);
    consol.addSupportedToken(address(subConsol));
    IAccessControl(address(subConsol)).grantRole(Roles.ACCOUNTING_ROLE, address(loanManager));
    generalManager.setPriceOracle(token, address(oracle));
    generalManager.updateSupportedMortgagePeriodTerms(token, 36, true);
    generalManager.setMinimumCap(token, 1e18);
    generalManager.setMaximumCap(token, 100_000e18);
    vm.stopPrank();
  }

  /// @dev USDG cannot be minted, so borrow it from the deep NVDA/USDG v3 pool's balance
  function _dealUsdg(address to, uint256 amount) internal {
    vm.prank(NVDA_USDG_V3_POOL);
    usdg.transfer(to, amount);
  }

  /// @dev Wraps USDG into the test USDX and deposits into the vault from the given account
  function _depositToVault(address account, uint256 usdxAmount) internal {
    uint256 usdgAmount = usdx.convertUnderlying(USDG_ADDRESS, usdxAmount);
    _dealUsdg(account, usdgAmount);
    vm.startPrank(account);
    usdg.approve(address(usdx), usdgAmount);
    usdx.deposit(USDG_ADDRESS, usdgAmount);
    usdx.approve(address(ufVault), usdxAmount);
    ufVault.deposit(address(usdx), usdxAmount);
    vm.stopPrank();
  }

  /// @dev Creates a real NVDA BNPL purchase order through the router, collecting USDG from the borrower
  function _createOrder(uint256 collateralAmount, uint256 expiration)
    internal
    returns (uint256 index, uint256 purchaseAmount)
  {
    return _createOrderFor(NVDA_ADDRESS, address(nvdaSubConsol), collateralAmount, expiration);
  }

  /// @dev Creates a real BNPL purchase order for the given collateral through the router
  function _createOrderFor(address collateral, address subConsol, uint256 collateralAmount, uint256 expiration)
    internal
    returns (uint256 index, uint256 purchaseAmount)
  {
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
          expiration: expiration
        }),
        mortgageId: "Fork Mortgage - 001",
        collateral: collateral,
        subConsol: subConsol,
        conversionQueues: new address[](0),
        hasPaymentPlan: true
      });
    }

    (, uint256 requiredUsdxCollected,,) = periphRouter.calculateCollectedAmounts(creationRequest);
    deal(borrower, GAS_FEE);
    uint256 usdgAmount = periphRouter.convert(address(usdx), USDG_ADDRESS, requiredUsdxCollected);
    _dealUsdg(borrower, usdgAmount);
    vm.startPrank(borrower);
    usdg.approve(address(periphRouter), usdgAmount);
    periphRouter.requestMortgage{value: GAS_FEE}(USDG_ADDRESS, creationRequest, false, type(uint256).max);
    vm.stopPrank();

    index = orderPool.orderCount() - 1;
    purchaseAmount = orderPool.orders(index).orderAmounts.purchaseAmount;
  }

  /// @dev Recomputes the vault's NVDA spend bound
  function _computeMaxUsdgIn(uint256 collateralNeeded, uint256 purchaseAmount) internal view returns (uint256) {
    return _computeMaxUsdgInFor(NVDA_ADDRESS, collateralNeeded, purchaseAmount);
  }

  /// @dev Recomputes the vault's spend bound (anchor, premium, no-loss gate, floor to USDG units)
  function _computeMaxUsdgInFor(address collateral, uint256 collateralNeeded, uint256 purchaseAmount)
    internal
    view
    returns (uint256)
  {
    CollateralRoute memory route = ufVault.collateralRoute(collateral);
    (uint256 anchorCost,) = IPriceOracle(route.priceOracle).cost(collateralNeeded);
    uint256 maxCost = Math.mulDiv(anchorCost, Constants.BPS + route.maxPremiumBps, Constants.BPS);
    if (maxCost > purchaseAmount) {
      maxCost = purchaseAmount;
    }
    return maxCost / 1e12;
  }

  /// @dev Encodes real SwapRouter02 exactOutputSingle calldata for the keeper leg
  function _swapCalldata(uint256 amountOut, uint256 amountInMaximum) internal view returns (bytes memory) {
    return abi.encodeCall(
      ISwapRouter02.exactOutputSingle,
      (ISwapRouter02.ExactOutputSingleParams({
          tokenIn: USDG_ADDRESS,
          tokenOut: NVDA_ADDRESS,
          fee: NVDA_POOL_FEE,
          recipient: address(ufVault),
          amountOut: amountOut,
          amountInMaximum: amountInMaximum,
          sqrtPriceLimitX96: 0
        }))
    );
  }

  /// @dev Encodes a real Universal Router V3_SWAP_EXACT_OUT for USDG -> NVDA paid by the vault (payerIsUser).
  ///      The deployed router is a 2.1+ build, whose input carries a trailing minHopPriceX36 array.
  ///      Exact-output paths are reversed: tokenOut, fee, tokenIn.
  function _urV3ExactOutCalldata(uint256 amountOut, uint256 amountInMax) internal view returns (bytes memory) {
    bytes[] memory inputs = new bytes[](1);
    inputs[0] = abi.encode(
      address(ufVault),
      amountOut,
      amountInMax,
      abi.encodePacked(NVDA_ADDRESS, NVDA_POOL_FEE, USDG_ADDRESS),
      true,
      new uint256[](0)
    );
    return abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(UR_V3_SWAP_EXACT_OUT), inputs, block.timestamp));
  }

  /// @dev The SPY/USDG v4 pool key. Currencies are sorted by address: SPY (0x117c...) < USDG (0x5fc5...).
  function _spyV4PoolKey() internal pure returns (V4PoolKey memory) {
    return V4PoolKey({
      currency0: SPY_ADDRESS,
      currency1: USDG_ADDRESS,
      fee: SPY_V4_POOL_FEE,
      tickSpacing: SPY_V4_POOL_TICK_SPACING,
      hooks: address(0)
    });
  }

  /// @dev Encodes a real Universal Router V4_SWAP buying exactly amountOut SPY with at most amountInMax USDG:
  ///      SWAP_EXACT_OUT_SINGLE (oneForZero), SETTLE_ALL USDG from the caller via Permit2, TAKE_ALL SPY to the caller
  function _urV4ExactOutCalldata(uint256 amountOut, uint256 amountInMax) internal view returns (bytes memory) {
    bytes memory actions = abi.encodePacked(V4_SWAP_EXACT_OUT_SINGLE, V4_SETTLE_ALL, V4_TAKE_ALL);
    bytes[] memory params = new bytes[](3);
    params[0] = abi.encode(
      V4ExactOutputSingleParams({
        poolKey: _spyV4PoolKey(),
        zeroForOne: false,
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut: uint128(amountOut),
        // forge-lint: disable-next-line(unsafe-typecast)
        amountInMaximum: uint128(amountInMax),
        minHopPriceX36: 0,
        hookData: ""
      })
    );
    params[1] = abi.encode(USDG_ADDRESS, amountInMax);
    params[2] = abi.encode(SPY_ADDRESS, amountOut);

    bytes[] memory inputs = new bytes[](1);
    inputs[0] = abi.encode(actions, params);
    return abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(UR_V4_SWAP), inputs, block.timestamp));
  }

  /// @dev Asserts the vault holds no USDG allowance to the router, to Permit2, or inside Permit2 for the router
  function _assertNoStandingAllowance(address routerAddress) internal view {
    assertEq(usdg.allowance(address(ufVault), routerAddress), 0, "No USDG allowance to the router");
    assertEq(usdg.allowance(address(ufVault), PERMIT2_ADDRESS), 0, "No USDG allowance to Permit2");
    (uint160 amount, uint48 expiration,) =
      IPermit2(PERMIT2_ADDRESS).allowance(address(ufVault), USDG_ADDRESS, routerAddress);
    assertEq(amount, 0, "No Permit2 allowance for the router");
    assertLe(expiration, block.timestamp, "No live Permit2 expiration for the router");
  }

  /// @dev Asserts the post-fill end state shared by every successful fill
  function _assertFilledCleanly(IERC20 collateral, uint256 usdxBefore) internal view {
    assertEq(mortgageNFT.ownerOf(1), borrower, "Borrower should have received the mortgage nft");
    assertGe(usdx.balanceOf(address(ufVault)), usdxBefore, "Vault USDX must not decrease across a fill");
    assertEq(usdg.balanceOf(address(ufVault)), 0, "Vault should hold no USDG after the fill");
    assertEq(collateral.balanceOf(address(ufVault)), 0, "Vault should hold no collateral after the fill");
    assertEq(ufVault.totalAssets(), usdx.balanceOf(address(ufVault)), "Total assets should be the USDX balance");
    assertEq(keeper.balance, GAS_FEE, "Keeper should have received the gas fee");
  }

  // ---------------------------------------------------------------------------------------------
  // SwapRouter02 (ERC20 mode)
  // ---------------------------------------------------------------------------------------------

  function test_fork_fillOrder_endToEnd() public {
    if (!forkEnabled) {
      vm.skip(true);
    }

    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT, block.timestamp + 10 minutes);
    uint256 maxUsdgIn = _computeMaxUsdgIn(COLLATERAL_AMOUNT, purchaseAmount);
    uint256 usdxBefore = usdx.balanceOf(address(ufVault));

    vm.expectEmit(true, true, false, false);
    emit IUniswapFulfillmentVaultEvents.OrderFilled(index, NVDA_ADDRESS, COLLATERAL_AMOUNT, 0, 0);
    vm.startPrank(keeper);
    ufVault.fillOrder(index, new uint256[](0), SWAP_ROUTER02_ADDRESS, _swapCalldata(COLLATERAL_AMOUNT, maxUsdgIn));
    vm.stopPrank();

    _assertFilledCleanly(nvda, usdxBefore);
    _assertNoStandingAllowance(SWAP_ROUTER02_ADDRESS);
  }

  function test_fork_fillOrder_boundConstrainsRealSwap() public {
    if (!forkEnabled) {
      vm.skip(true);
    }

    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT, block.timestamp + 10 minutes);

    // Re-anchor the route to an oracle reporting half the real price: the vault's bound (and scoped
    // approval) lands well below what the live pool charges, so the real swap cannot complete
    MockPriceOracle lowOracle = new MockPriceOracle(18);
    lowOracle.setPrice(nvdaChainlinkOracle.price() / 2);
    vm.startPrank(admin);
    ufVault.setCollateralRoute(
      NVDA_ADDRESS,
      CollateralRoute({
        priceOracle: address(lowOracle), maxPremiumBps: ROUTE_PREMIUM_BPS, maxFillCost: ROUTE_MAX_FILL_COST
      })
    );
    vm.stopPrank();

    uint256 lowMaxUsdgIn = _computeMaxUsdgIn(COLLATERAL_AMOUNT, purchaseAmount);

    // The live pool demands roughly twice the approved input; the transfer inside the swap callback
    // exceeds the scoped approval and the whole fill unwinds
    vm.startPrank(keeper);
    vm.expectRevert();
    ufVault.fillOrder(index, new uint256[](0), SWAP_ROUTER02_ADDRESS, _swapCalldata(COLLATERAL_AMOUNT, lowMaxUsdgIn));
    vm.stopPrank();

    // The order is untouched and remains fillable
    assertEq(orderPool.orders(index).mortgageParams.collateral, NVDA_ADDRESS, "Order should remain open");
  }

  function test_fork_fillOrder_staleFeedFailsClosed() public {
    if (!forkEnabled) {
      vm.skip(true);
    }

    // A long-lived order so the order outlives the feed's maxAge
    vm.startPrank(admin);
    orderPool.setMaximumOrderDuration(30 days);
    vm.stopPrank();
    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT, block.timestamp + 8 days);
    uint256 maxUsdgIn = _computeMaxUsdgIn(COLLATERAL_AMOUNT, purchaseAmount);

    // Past maxAge the real feed reads as stale and the adapter's revert propagates through the vault
    (,,, uint256 updatedAt,) = nvdaChainlinkOracle.aggregator().latestRoundData();
    uint256 warpTo = block.timestamp + FEED_MAX_AGE + 1 hours;
    vm.warp(warpTo);
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.StalePrice.selector, warpTo - updatedAt, FEED_MAX_AGE));
    ufVault.fillOrder(index, new uint256[](0), SWAP_ROUTER02_ADDRESS, _swapCalldata(COLLATERAL_AMOUNT, maxUsdgIn));
    vm.stopPrank();
  }

  // ---------------------------------------------------------------------------------------------
  // Universal Router (Permit2 mode)
  // ---------------------------------------------------------------------------------------------

  function test_fork_fillOrder_universalRouterV3_revertsInErc20Mode() public {
    if (!forkEnabled) {
      vm.skip(true);
    }
    assertGt(UNIVERSAL_ROUTER_ADDRESS.code.length, 0, "Universal Router should be deployed");

    // A plain token approval to the Universal Router, as the vault granted before per-router approval modes
    vm.startPrank(admin);
    ufVault.setRouterApproval(UNIVERSAL_ROUTER_ADDRESS, RouterApproval.ERC20);
    vm.stopPrank();

    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT, block.timestamp + 10 minutes);
    uint256 maxUsdgIn = _computeMaxUsdgIn(COLLATERAL_AMOUNT, purchaseAmount);

    // The router pays through Permit2, where the vault holds no allowance: Permit2 rejects the pull
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSignature("AllowanceExpired(uint256)", 0));
    ufVault.fillOrder(
      index, new uint256[](0), UNIVERSAL_ROUTER_ADDRESS, _urV3ExactOutCalldata(COLLATERAL_AMOUNT, maxUsdgIn)
    );
    vm.stopPrank();

    assertEq(orderPool.orders(index).mortgageParams.collateral, NVDA_ADDRESS, "Order should remain open");
  }

  function test_fork_fillOrder_universalRouterV3_permit2() public {
    if (!forkEnabled) {
      vm.skip(true);
    }
    assertTrue(ufVault.routerApproval(UNIVERSAL_ROUTER_ADDRESS) == RouterApproval.Permit2);

    (uint256 index, uint256 purchaseAmount) = _createOrder(COLLATERAL_AMOUNT, block.timestamp + 10 minutes);
    uint256 maxUsdgIn = _computeMaxUsdgIn(COLLATERAL_AMOUNT, purchaseAmount);
    uint256 usdxBefore = usdx.balanceOf(address(ufVault));

    vm.expectEmit(true, true, false, false);
    emit IUniswapFulfillmentVaultEvents.OrderFilled(index, NVDA_ADDRESS, COLLATERAL_AMOUNT, 0, 0);
    vm.startPrank(keeper);
    ufVault.fillOrder(
      index, new uint256[](0), UNIVERSAL_ROUTER_ADDRESS, _urV3ExactOutCalldata(COLLATERAL_AMOUNT, maxUsdgIn)
    );
    vm.stopPrank();

    _assertFilledCleanly(nvda, usdxBefore);
    _assertNoStandingAllowance(UNIVERSAL_ROUTER_ADDRESS);
  }

  function test_fork_fillOrder_universalRouterV4_permit2() public {
    if (!forkEnabled) {
      vm.skip(true);
    }

    // The encoded key is the live pool: id matches, no hooks, in-range liquidity
    V4PoolKey memory key = _spyV4PoolKey();
    assertEq(keccak256(abi.encode(key)), SPY_V4_POOL_ID, "PoolKey should hash to the discovered pool id");
    assertEq(key.hooks, address(0), "The v4 route must not pass through hooks");
    (uint160 sqrtPriceX96,,,) = IStateView(STATE_VIEW_ADDRESS).getSlot0(SPY_V4_POOL_ID);
    assertGt(sqrtPriceX96, 0, "The v4 pool should be initialized");
    assertGt(IStateView(STATE_VIEW_ADDRESS).getLiquidity(SPY_V4_POOL_ID), 0, "The v4 pool should have liquidity");

    (uint256 index, uint256 purchaseAmount) =
      _createOrderFor(SPY_ADDRESS, address(spySubConsol), SPY_COLLATERAL_AMOUNT, block.timestamp + 10 minutes);
    uint256 maxUsdgIn = _computeMaxUsdgInFor(SPY_ADDRESS, SPY_COLLATERAL_AMOUNT, purchaseAmount);
    uint256 usdxBefore = usdx.balanceOf(address(ufVault));
    uint256 poolManagerUsdgBefore = usdg.balanceOf(POOL_MANAGER_ADDRESS);

    vm.expectEmit(true, true, false, false);
    emit IUniswapFulfillmentVaultEvents.OrderFilled(index, SPY_ADDRESS, SPY_COLLATERAL_AMOUNT, 0, 0);
    vm.startPrank(keeper);
    ufVault.fillOrder(
      index, new uint256[](0), UNIVERSAL_ROUTER_ADDRESS, _urV4ExactOutCalldata(SPY_COLLATERAL_AMOUNT, maxUsdgIn)
    );
    vm.stopPrank();

    // The USDG went to the v4 singleton, not a v3 pool
    assertGt(usdg.balanceOf(POOL_MANAGER_ADDRESS), poolManagerUsdgBefore, "USDG should settle into the PoolManager");
    _assertFilledCleanly(spy, usdxBefore);
    _assertNoStandingAllowance(UNIVERSAL_ROUTER_ADDRESS);
  }

  function test_fork_fillOrder_universalRouterV4_revertsInErc20Mode() public {
    if (!forkEnabled) {
      vm.skip(true);
    }
    vm.startPrank(admin);
    ufVault.setRouterApproval(UNIVERSAL_ROUTER_ADDRESS, RouterApproval.ERC20);
    vm.stopPrank();

    (uint256 index, uint256 purchaseAmount) =
      _createOrderFor(SPY_ADDRESS, address(spySubConsol), SPY_COLLATERAL_AMOUNT, block.timestamp + 10 minutes);
    uint256 maxUsdgIn = _computeMaxUsdgInFor(SPY_ADDRESS, SPY_COLLATERAL_AMOUNT, purchaseAmount);

    // SETTLE_ALL pays through Permit2 as well, so a plain approval cannot settle the v4 swap either
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSignature("AllowanceExpired(uint256)", 0));
    ufVault.fillOrder(
      index, new uint256[](0), UNIVERSAL_ROUTER_ADDRESS, _urV4ExactOutCalldata(SPY_COLLATERAL_AMOUNT, maxUsdgIn)
    );
    vm.stopPrank();
  }

  function test_fork_permit2_currentTimestampExpiration() public {
    if (!forkEnabled) {
      vm.skip(true);
    }

    // The real Permit2 honors an allowance expiring at block.timestamp for pulls in the same block and
    // rejects it after, which is the scope the vault grants a Permit2-mode router
    IPermit2 permit2 = IPermit2(PERMIT2_ADDRESS);
    _dealUsdg(address(ufVault), 2e6);
    vm.startPrank(address(ufVault));
    usdg.approve(PERMIT2_ADDRESS, 2e6);
    // forge-lint: disable-next-line(unsafe-typecast)
    permit2.approve(USDG_ADDRESS, rando, 2e6, uint48(block.timestamp));
    vm.stopPrank();

    vm.startPrank(rando);
    permit2.transferFrom(address(ufVault), rando, 1e6, USDG_ADDRESS);
    vm.stopPrank();
    assertEq(usdg.balanceOf(rando), 1e6, "A same-block pull should succeed");

    uint256 grantedAt = block.timestamp;
    vm.warp(grantedAt + 1);
    vm.startPrank(rando);
    vm.expectRevert(abi.encodeWithSignature("AllowanceExpired(uint256)", grantedAt));
    permit2.transferFrom(address(ufVault), rando, 1e6, USDG_ADDRESS);
    vm.stopPrank();
  }
}
