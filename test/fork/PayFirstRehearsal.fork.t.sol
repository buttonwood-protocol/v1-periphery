// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// forge-lint: disable-next-line(unused-import)
import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IGeneralManager} from "@core/interfaces/IGeneralManager/IGeneralManager.sol";
import {IOrderPool} from "@core/interfaces/IOrderPool/IOrderPool.sol";
import {IOriginationPool} from "@core/interfaces/IOriginationPool/IOriginationPool.sol";
import {ILoanManager} from "@core/interfaces/ILoanManager/ILoanManager.sol";
import {IPriceOracle} from "@core/interfaces/IPriceOracle.sol";
import {IUSDX} from "@core/interfaces/IUSDX/IUSDX.sol";
import {ChainlinkPriceOracle} from "@core/ChainlinkPriceOracle.sol";
import {AggregatorV3Interface} from "@core/external/AggregatorV3Interface.sol";
import {MortgagePosition} from "@core/types/MortgagePosition.sol";
import {PurchaseOrder} from "@core/types/orders/PurchaseOrder.sol";
import {CreationRequest, BaseRequest} from "@core/types/orders/OrderRequests.sol";
import {Roles} from "@core/libraries/Roles.sol";
import {Constants} from "@core/libraries/Constants.sol";
import {PayFirstUpgrade} from "../../lib/cash/script/ops/PayFirstUpgrade.s.sol";
import {PayFirstVaultUpgradeScript} from "../../script/PayFirstVaultUpgrade.s.sol";
import {
  IUniswapFulfillmentVaultEvents
} from "../../src/interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVaultEvents.sol";
import {
  IUniswapFulfillmentVaultErrors
} from "../../src/interfaces/IUniswapFulfillmentVault/IUniswapFulfillmentVaultErrors.sol";
import {RouterApproval} from "../../src/interfaces/IUniswapFulfillmentVault/RouterApproval.sol";
import {UniswapFulfillmentVault} from "../../src/UniswapFulfillmentVault.sol";
import {Router} from "../../src/Router.sol";

/// @dev Minimal Universal Router surface for encoding the keeper's swap calldata
interface IUniversalRouterLike {
  function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev This repo compiles the general manager with other optimizer settings than the core repo, which
///      puts its bytecode over the size limit the core script enforces. The core repo's own fork rehearsal
///      runs the same steps with the bytecode that fits.
contract PayFirstUpgradeAtPeripherySettings is PayFirstUpgrade {
  function maxRuntimeSize() public pure override returns (uint256) {
    return type(uint256).max;
  }
}

/**
 * @title PayFirstRehearsalForkTest
 * @notice Rehearses the whole pay-first rollout against the live Robinhood Chain (4663) stack, in the order
 *         the scripts are run: core deploy, vault upgrade, core pause and cutover, vault approvals, both
 *         verifications, then a real order filled by the live vault while it holds no USDX, through the live
 *         Universal Router 2.1.2 and the NVDA/USDG v3 pool. Ends by rolling both back.
 * @dev Network-gated: the default suite skips it. Run with
 *      `RUN_FORK_TESTS=true forge test --match-path test/fork/PayFirstRehearsal.fork.t.sol -vv`.
 *      Forks the latest block unless PAY_FIRST_FORK_BLOCK is set; the public endpoint keeps little history.
 *      The origination pool only opens for deployment later, so the test warps to its deploy phase and
 *      re-stamps the collateral's Chainlink round, leaving the price itself untouched.
 */
contract PayFirstRehearsalForkTest is Test {
  string internal constant FORK_URL = "https://rpc.mainnet.chain.robinhood.com";
  bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  // Live 4663 addresses that the address books do not carry
  address internal constant ADMIN = 0xd7e86Bd77784217324b4E94AEDc68E5C8227EC2B;
  address internal constant GENESIS_POOL = 0x2c331A3c4A38E4EF36d4Ff49Ec977D22E5385e4d;
  address internal constant UNIVERSAL_ROUTER_212 = 0x204FAca1764B154221e35c0d20aBb3c525710498;
  address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
  address internal constant NVDA_USDG_V3_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
  uint24 internal constant NVDA_POOL_FEE = 500;
  uint8 internal constant UR_V3_SWAP_EXACT_OUT = 0x01;
  uint256 internal constant NVDA_INDEX = 6;

  address internal lender = makeAddr("lender");
  address internal borrower = makeAddr("borrower");

  bool internal forkEnabled;
  string internal coreBook;
  string internal peripheryBook;
  IGeneralManager internal generalManager;
  IOrderPool internal previousPool;
  UniswapFulfillmentVault internal vault;
  Router internal router;
  IUSDX internal usdx;
  IERC20 internal usdg;
  IERC20 internal nvda;
  address internal nvdaSubConsol;

  function setUp() public {
    forkEnabled = vm.envOr("RUN_FORK_TESTS", false);
    if (!forkEnabled) {
      return;
    }
    uint256 forkBlock = vm.envOr("PAY_FIRST_FORK_BLOCK", uint256(0));
    if (forkBlock == 0) {
      vm.createSelectFork(FORK_URL);
    } else {
      vm.createSelectFork(FORK_URL, forkBlock);
    }

    coreBook = vm.readFile(string.concat(vm.projectRoot(), "/lib/cash/addresses/addresses-4663.json"));
    peripheryBook = vm.readFile(string.concat(vm.projectRoot(), "/addresses/addresses-4663.json"));
    generalManager = IGeneralManager(vm.parseJsonAddress(coreBook, ".generalManagerAddress"));
    previousPool = IOrderPool(vm.parseJsonAddress(coreBook, ".orderPoolAddress"));
    usdx = IUSDX(vm.parseJsonAddress(coreBook, ".usdxAddress"));
    usdg = IERC20(vm.parseJsonAddressArray(coreBook, ".usdAddresses")[0]);
    nvda = IERC20(vm.parseJsonAddressArray(coreBook, ".collateralAddresses")[NVDA_INDEX]);
    nvdaSubConsol = vm.parseJsonAddressArray(coreBook, ".subConsolAddresses")[NVDA_INDEX];
    vault = UniswapFulfillmentVault(payable(vm.parseJsonAddress(peripheryBook, ".fulfillmentVaultAddress")));
    router = Router(payable(vm.parseJsonAddress(peripheryBook, ".routerAddress")));
  }

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------

  function _implementationOf(address proxy) internal view returns (address) {
    return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
  }

  /// @dev A core script instance as one `forge script` invocation would build it
  function _coreScript(address implementation, address pool, address previousImplementation)
    internal
    returns (PayFirstUpgrade script)
  {
    address[] memory fulfillers = new address[](2);
    fulfillers[0] = address(vault);
    fulfillers[1] = ADMIN;
    script = new PayFirstUpgradeAtPeripherySettings();
    script.setAddressBookJson(coreBook);
    script.setAdmin(ADMIN);
    script.setFulfillers(fulfillers);
    script.setDeployment(implementation, pool, previousImplementation, false);
    script.setUp();
  }

  /// @dev A vault script instance as one `forge script` invocation would build it
  function _vaultScript(address implementation, address previousImplementation)
    internal
    returns (PayFirstVaultUpgradeScript script)
  {
    script = new PayFirstVaultUpgradeScript();
    script.setAddressBookJsons(coreBook, peripheryBook);
    script.setAdmin(ADMIN);
    script.setDeployment(implementation, previousImplementation);
    script.setUp();
  }

  /// @dev USDG cannot be minted, so borrow it from the deep NVDA/USDG v3 pool's balance
  function _dealUsdg(address to, uint256 amount) internal {
    vm.prank(NVDA_USDG_V3_POOL);
    usdg.transfer(to, amount);
  }

  /// @dev Funds the genesis pool while it still takes deposits, then moves into its deploy phase and
  ///      re-stamps the NVDA round at the new timestamp with its price unchanged
  function _openBorrowing() internal {
    uint256 usdgAmount = usdx.convertUnderlying(address(usdg), 1_000e18);
    _dealUsdg(lender, usdgAmount);
    vm.startPrank(lender);
    usdg.approve(address(usdx), usdgAmount);
    usdx.deposit(address(usdg), usdgAmount);
    IERC20(address(usdx)).approve(GENESIS_POOL, 1_000e18);
    IOriginationPool(GENESIS_POOL).deposit(1_000e18);
    vm.stopPrank();

    AggregatorV3Interface aggregator = ChainlinkPriceOracle(generalManager.priceOracles(address(nvda))).aggregator();
    (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) = aggregator.latestRoundData();
    vm.warp(IOriginationPool(GENESIS_POOL).deployPhaseTimestamp());
    vm.mockCall(
      address(aggregator),
      abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
      abi.encode(roundId, answer, startedAt, block.timestamp, answeredInRound)
    );
  }

  /// @dev A borrower requests an NVDA BNPL mortgage worth about $60 through the live router, paying in USDG
  function _requestThroughRouter(IOrderPool pool) internal returns (uint256 index) {
    (uint256 costOfOne,) = IPriceOracle(generalManager.priceOracles(address(nvda))).cost(1e18);
    uint256[] memory collateralAmounts = new uint256[](1);
    collateralAmounts[0] = 60e18 * 1e18 / costOfOne;
    address[] memory originationPools = new address[](1);
    originationPools[0] = GENESIS_POOL;
    CreationRequest memory creationRequest = CreationRequest({
      base: BaseRequest({
        collateralAmounts: collateralAmounts,
        totalPeriods: 36,
        originationPools: originationPools,
        isCompounding: false,
        expiration: block.timestamp + 1 minutes
      }),
      mortgageId: "Pay-first rehearsal",
      collateral: address(nvda),
      subConsol: nvdaSubConsol,
      conversionQueues: new address[](0),
      hasPaymentPlan: true
    });

    (, uint256 requiredUsdxCollected,,) = router.calculateCollectedAmounts(creationRequest);
    uint256 usdgAmount = router.convert(address(usdx), address(usdg), requiredUsdxCollected);
    uint256 gasFee = pool.gasFee();
    _dealUsdg(borrower, usdgAmount);
    vm.deal(borrower, gasFee);
    index = pool.orderCount();
    vm.startPrank(borrower);
    usdg.approve(address(router), usdgAmount);
    router.requestMortgage{value: gasFee}(address(usdg), creationRequest, false, type(uint256).max);
    vm.stopPrank();
  }

  /// @dev A real Universal Router V3_SWAP_EXACT_OUT for USDG -> NVDA paid by the vault through Permit2.
  ///      Exact-output paths are reversed: tokenOut, fee, tokenIn.
  function _urV3ExactOutCalldata(uint256 amountOut, uint256 amountInMax) internal view returns (bytes memory) {
    bytes[] memory inputs = new bytes[](1);
    inputs[0] = abi.encode(
      address(vault),
      amountOut,
      amountInMax,
      abi.encodePacked(address(nvda), NVDA_POOL_FEE, address(usdg)),
      true,
      new uint256[](0)
    );
    return
      abi.encodeCall(IUniversalRouterLike.execute, (abi.encodePacked(UR_V3_SWAP_EXACT_OUT), inputs, block.timestamp));
  }

  // ---------------------------------------------------------------------------------------------
  // Rehearsal
  // ---------------------------------------------------------------------------------------------

  address internal coreImplementationBefore;
  address internal vaultImplementationBefore;
  address internal coreImplementation;
  address internal vaultImplementation;
  IOrderPool internal newPool;

  function _core() internal returns (PayFirstUpgrade) {
    return _coreScript(coreImplementation, address(newPool), coreImplementationBefore);
  }

  function _vault() internal returns (PayFirstVaultUpgradeScript) {
    return _vaultScript(vaultImplementation, vaultImplementationBefore);
  }

  /// @dev Steps 0-4: the live starting point, then both rollouts in the order the scripts are run
  function _rollOut() internal {
    coreImplementationBefore = _implementationOf(address(generalManager));
    vaultImplementationBefore = _implementationOf(address(vault));
    assertEq(generalManager.orderPool(), address(previousPool), "live order pool matches the address book");
    assertEq(previousPool.orderCount(), 0, "no order was ever placed");
    assertEq(IERC20(address(usdx)).balanceOf(address(vault)), 0, "the live vault holds no USDX");
    assertEq(vault.totalSupply(), 0, "the live vault has no depositors");
    assertTrue(vault.routerApproval(UNIVERSAL_ROUTER_212) == RouterApproval.Permit2, "Universal Router is allowlisted");
    assertTrue(vault.hasRole(vault.KEEPER_ROLE(), ADMIN), "the admin can act as keeper");

    // 1. Core: deploy the implementation and the new order pool. Nothing live changes.
    PayFirstUpgrade coreDeployed = _coreScript(address(0), address(0), address(0));
    coreDeployed.run();
    coreImplementation = coreDeployed.newImplementation();
    newPool = coreDeployed.newOrderPool();
    assertEq(_implementationOf(address(generalManager)), coreImplementationBefore, "core untouched by the deploy run");
    assertEq(generalManager.orderPool(), address(previousPool), "order pool untouched by the deploy run");

    // 2. Periphery: upgrade the vault. fillOrder is unchanged and the callback path is not reachable yet.
    PayFirstVaultUpgradeScript vaultDeployed = _vaultScript(address(0), address(0));
    vaultDeployed.run();
    vaultImplementation = vaultDeployed.newImplementation();
    assertEq(_implementationOf(address(vault)), vaultImplementation, "vault upgraded");
    assertEq(
      vaultDeployed.previousImplementation(), vaultImplementationBefore, "previous vault implementation recorded"
    );

    // 3. Core: pause, cut over, verify
    _core().pause();
    _core().cutover();
    _core().verify();
    assertEq(generalManager.orderPool(), address(newPool), "order pool");
    assertEq(vault.orderPool(), address(newPool), "the vault follows the general manager's order pool");

    // 4. Periphery: approve the collaterals and USDX to the new order pool, verify
    assertEq(nvda.allowance(address(vault), address(newPool)), 0, "no allowance to the new pool yet");
    _vault().approveAssets();
    _vault().verify();
    assertEq(nvda.allowance(address(vault), address(newPool)), type(uint256).max, "NVDA approved to the new pool");
  }

  /// @dev Step 5: a borrower's real order, filled by the vault while it holds no USDX
  function _fillFromEmptyVault() internal returns (uint256 vaultUsdx) {
    _openBorrowing();
    uint256 index = _requestThroughRouter(newPool);
    PurchaseOrder memory order = newPool.orders(index);
    uint256 purchaseAmount = order.orderAmounts.purchaseAmount;
    uint256 collateralAmount = order.mortgageParams.collateralAmount;
    uint256 maxUsdgIn = (purchaseAmount - Constants.FULFILLMENT_HOLDBACK_PER_POOL) / 1e12;
    bytes memory swapCalldata = _urV3ExactOutCalldata(collateralAmount, maxUsdgIn);
    assertEq(IERC20(address(usdx)).balanceOf(address(vault)), 0, "the vault still holds no USDX");
    assertEq(nvda.balanceOf(address(vault)), 0, "the vault holds no collateral");

    // The inventory path cannot fill it: there is nothing to withdraw
    vm.startPrank(ADMIN);
    vm.expectRevert();
    vault.fillOrder(index, new uint256[](0), UNIVERSAL_ROUTER_212, swapCalldata);
    vm.stopPrank();

    uint256 poolUsdgBefore = usdg.balanceOf(NVDA_USDG_V3_POOL);
    uint256 keeperBalanceBefore = ADMIN.balance;
    vm.startPrank(ADMIN);
    vm.expectEmit(true, true, false, false, address(vault));
    emit IUniswapFulfillmentVaultEvents.OrderFilled(index, address(nvda), collateralAmount, 0, 0);
    vault.fillOrderWithCallback(index, new uint256[](0), UNIVERSAL_ROUTER_212, swapCalldata);
    vm.stopPrank();

    uint256 usdgSpent = usdg.balanceOf(NVDA_USDG_V3_POOL) - poolUsdgBefore;
    vaultUsdx = IERC20(address(usdx)).balanceOf(address(vault));
    _assertFilled(order, usdgSpent, maxUsdgIn, vaultUsdx);
    assertEq(ADMIN.balance - keeperBalanceBefore, newPool.gasFee(), "the keeper collected the order gas fee");
    console.log("Zero-USDX fill of order %s", index);
    console.log("  purchase amount (USDX wei): %s", purchaseAmount);
    console.log("  USDG spent on the swap: %s", usdgSpent);
    console.log("  vault USDX after the fill (wei): %s", vaultUsdx);

    // A replayed callback has nothing to match
    vm.startPrank(address(generalManager));
    vm.expectRevert(IUniswapFulfillmentVaultErrors.UnexpectedFillCallback.selector);
    vault.orderFulfillmentCallback(order.mortgageParams.tokenId, address(nvda), collateralAmount, purchaseAmount, "");
    vm.stopPrank();
  }

  function _assertFilled(PurchaseOrder memory order, uint256 usdgSpent, uint256 maxUsdgIn, uint256 vaultUsdx)
    internal
    view
  {
    uint256 tokenId = order.mortgageParams.tokenId;
    MortgagePosition memory position = ILoanManager(generalManager.loanManager()).getMortgagePosition(tokenId);
    assertEq(position.collateralAmount, order.mortgageParams.collateralAmount, "mortgage collateral amount");
    assertEq(IERC721(generalManager.mortgageNFT()).ownerOf(tokenId), borrower, "borrower owns the mortgage");
    assertLe(usdgSpent, maxUsdgIn, "the swap stayed within the advance");
    assertApproxEqAbs(
      vaultUsdx, order.orderAmounts.purchaseAmount - usdgSpent * 1e12, 2, "the vault keeps exactly the fill margin"
    );
    assertGt(vaultUsdx, 0, "the vault ended with more USDX than it started with");
    assertEq(usdg.balanceOf(address(vault)), 0, "the vault holds no USDG");
    assertEq(nvda.balanceOf(address(vault)), 0, "the vault holds no collateral");
    assertEq(usdg.allowance(address(vault), PERMIT2), 0, "no USDG allowance to Permit2 is left");
    assertEq(IERC20(address(usdx)).balanceOf(address(generalManager)), 0, "the general manager holds no USDX");
    assertEq(nvda.balanceOf(address(generalManager)), 0, "the general manager holds no collateral");
  }

  /// @dev Step 6: the core back to the previous order pool, the vault back to its previous implementation
  function _rollBack(uint256 vaultUsdx) internal {
    _core().pause();
    _core().rollback();
    _vault().rollback();
    assertEq(generalManager.orderPool(), address(previousPool), "back on the previous order pool");
    assertEq(_implementationOf(address(vault)), vaultImplementationBefore, "vault back on its previous implementation");
    assertEq(vault.orderPool(), address(previousPool), "the vault follows the general manager back");
    assertEq(IERC20(address(usdx)).balanceOf(address(vault)), vaultUsdx, "the vault kept its USDX through the rollback");
    assertTrue(
      IAccessControl(address(previousPool)).hasRole(Roles.FULFILLMENT_ROLE, address(vault)),
      "the vault can still fulfill on the previous pool"
    );
    console.log("Rolled back to order pool %s", address(previousPool));
  }

  function test_fork_rehearsal() public {
    if (!forkEnabled) {
      vm.skip(true);
    }
    console.log("Fork block: %s", block.number);
    _rollOut();
    uint256 vaultUsdx = _fillFromEmptyVault();
    _rollBack(vaultUsdx);
  }
}
