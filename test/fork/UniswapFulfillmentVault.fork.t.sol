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

/**
 * @title UniswapFulfillmentVaultForkTest
 * @notice End-to-end fill against live Robinhood Chain (4663) state: real USDG, real NVDA, the real
 *         Chainlink NVDA feed through the ChainlinkPriceOracle adapter, and the real SwapRouter02.
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
  address constant SWAP_ROUTER02_ADDRESS = 0xCaf681a66D020601342297493863E78C959E5cb2;
  address constant NVDA_USDG_V3_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // 0.05% fee tier
  uint24 constant NVDA_POOL_FEE = 500;
  address constant UNIVERSAL_ROUTER_ADDRESS = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
  address constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

  // Universal Router command bytes (universal-router Commands.sol, identical across tags 2.0.0-2.2.0)
  uint8 constant UR_V3_SWAP_EXACT_OUT = 0x01;

  uint256 constant FEED_MAX_AGE = 7 days;
  uint16 constant ROUTE_PREMIUM_BPS = 50;
  uint256 constant ROUTE_MAX_FILL_COST = 1_000_000e18;
  uint256 constant COLLATERAL_AMOUNT = 0.05e18; // ~ $10 of NVDA: negligible pool impact
  uint256 constant USER_DEPOSIT = 1_000e18;
  uint256 constant GAS_FEE = 0.01e18;

  IERC20 public usdg = IERC20(USDG_ADDRESS);
  IERC20 public nvda = IERC20(NVDA_ADDRESS);
  SubConsol public nvdaSubConsol;
  ChainlinkPriceOracle public nvdaChainlinkOracle;
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

    // Real NVDA as a collateral, priced by the real Chainlink feed through the consol adapter
    assertEq(IERC20Metadata(NVDA_ADDRESS).decimals(), 18, "NVDA should have 18 decimals");
    nvdaChainlinkOracle = new ChainlinkPriceOracle(NVDA_FEED_ADDRESS, 18, FEED_MAX_AGE);
    nvdaSubConsol = new SubConsol("NVDA SubConsol", "NVDA-SUBCONSOL", admin, NVDA_ADDRESS);
    vm.startPrank(admin);
    consol.addSupportedToken(address(nvdaSubConsol));
    IAccessControl(address(nvdaSubConsol)).grantRole(Roles.ACCOUNTING_ROLE, address(loanManager));
    generalManager.setPriceOracle(NVDA_ADDRESS, address(nvdaChainlinkOracle));
    generalManager.updateSupportedMortgagePeriodTerms(NVDA_ADDRESS, 36, true);
    generalManager.setMinimumCap(NVDA_ADDRESS, 1e18);
    generalManager.setMaximumCap(NVDA_ADDRESS, 100_000e18);
    vm.stopPrank();

    // Vault with the real SwapRouter02 allowlisted
    UniswapFulfillmentVault implementation = new UniswapFulfillmentVault();
    address[] memory allowedRouters = new address[](2);
    allowedRouters[0] = SWAP_ROUTER02_ADDRESS;
    allowedRouters[1] = UNIVERSAL_ROUTER_ADDRESS;
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(implementation),
      abi.encodeCall(
        UniswapFulfillmentVault.initialize,
        ("Fork Uniswap Fulfillment Vault", "fUFV", 24, 6, address(generalManager), USDG_ADDRESS, allowedRouters, admin)
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
    vm.stopPrank();
    ufVault.approveAssetToOrderPool(NVDA_ADDRESS);

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

  /// @dev Creates a real BNPL purchase order for NVDA through the router, collecting USDG from the borrower
  function _createOrder(uint256 collateralAmount, uint256 expiration)
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
        collateral: NVDA_ADDRESS,
        subConsol: address(nvdaSubConsol),
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

  /// @dev Recomputes the vault's spend bound (anchor, premium, no-loss gate, floor to USDG units)
  function _computeMaxUsdgIn(uint256 collateralNeeded, uint256 purchaseAmount) internal view returns (uint256) {
    CollateralRoute memory route = ufVault.collateralRoute(NVDA_ADDRESS);
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

  function test_fork_fillOrder_universalRouterV3_plainApprovalReverts() public {
    if (!forkEnabled) {
      vm.skip(true);
    }
    assertGt(UNIVERSAL_ROUTER_ADDRESS.code.length, 0, "Universal Router should be deployed");

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

    // The mortgage originated against the real collateral
    assertEq(mortgageNFT.ownerOf(1), borrower, "Borrower should have received the mortgage nft");

    // No-loss: the vault's USDX never decreases across a fill (2-wei USDX share-rounding tolerance)
    assertGe(usdx.balanceOf(address(ufVault)) + 2, usdxBefore, "Vault USDX must not decrease across a fill");

    // Pure USDX at the end of the transaction
    assertEq(usdg.balanceOf(address(ufVault)), 0, "Vault should hold no USDG after the fill");
    assertEq(nvda.balanceOf(address(ufVault)), 0, "Vault should hold no NVDA after the fill");
    assertEq(ufVault.totalAssets(), usdx.balanceOf(address(ufVault)), "Total assets should be the USDX balance");

    // The keeper received the order gas fee
    assertEq(keeper.balance, GAS_FEE, "Keeper should have received the gas fee");
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
}
