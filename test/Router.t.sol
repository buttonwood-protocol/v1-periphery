// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Router} from "../src/Router.sol";
import {GeneralManager} from "@core/GeneralManager.sol";
import {IGeneralManager} from "@core/interfaces/IGeneralManager/IGeneralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ForfeitedAssetsPool} from "@core/ForfeitedAssetsPool.sol";
import {IConsol} from "@core/interfaces/IConsol/IConsol.sol";
import {ISubConsol} from "@core/interfaces/ISubConsol/ISubConsol.sol";
import {USDX} from "@core/USDX.sol";
import {SharesMath} from "@core/libraries/SharesMath.sol";
import {Consol} from "@core/Consol.sol";
import {SubConsol} from "@core/SubConsol.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {OriginationPoolScheduler} from "@core/OriginationPoolScheduler.sol";
import {IOriginationPoolScheduler} from "@core/interfaces/IOriginationPoolScheduler/IOriginationPoolScheduler.sol";
import {IWNT} from "../src/interfaces/IWNT.sol";
import {Roles} from "@core/libraries/Roles.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CreationRequest, BaseRequest} from "@core/types/orders/OrderRequests.sol";
import {OriginationPoolConfig} from "@core/types/OriginationPoolConfig.sol";
import {OPoolConfigIdLibrary, OPoolConfigId} from "@core/types/OPoolConfigId.sol";
import {IOriginationPool} from "@core/interfaces/IOriginationPool/IOriginationPool.sol";
import {IInterestRateOracle} from "@core/interfaces/IInterestRateOracle.sol";
import {MockInterestRateOracle} from "./mocks/MockInterestRateOracle.sol";
import {IPriceOracle} from "@core/interfaces/IPriceOracle.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {ILoanManager} from "@core/interfaces/ILoanManager/ILoanManager.sol";
import {IMortgageNFT} from "@core/interfaces/IMortgageNFT/IMortgageNFT.sol";
import {LoanManager} from "@core/LoanManager.sol";
import {INFTMetadataGenerator} from "@core/interfaces/INFTMetadataGenerator.sol";
import {MockNFTMetadataGenerator} from "./mocks/MockNFTMetadataGenerator.sol";
import {IOrderPool} from "@core/interfaces/IOrderPool/IOrderPool.sol";
import {OrderPool} from "@core/OrderPool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IConversionQueue} from "@core/interfaces/IConversionQueue/IConversionQueue.sol";
import {ConversionQueue} from "@core/ConversionQueue.sol";
import {IPyth} from "@pythnetwork/IPyth.sol";
import {MockPyth} from "@pythnetwork/MockPyth.sol";

contract RouterTest is Test {
  using OPoolConfigIdLibrary for OPoolConfigId;

  // Actors
  address public admin = makeAddr("admin");
  address public lender = makeAddr("lender");
  address public borrower = makeAddr("borrower");
  address public fulfiller = makeAddr("fulfiller");
  address public rando = makeAddr("rando");

  // Router
  Router public router;
  // Tokens
  IERC20 public usdt;
  IERC20 public usdx;
  ForfeitedAssetsPool public forfeitedAssetsPool;
  IConsol public consol;
  IWNT public whype;
  IERC20 public wbtc;
  ISubConsol public whypeSubConsol;
  ISubConsol public wbtcSubConsol;
  // Arguments
  address public insuranceFund = makeAddr("insuranceFund");
  uint16 public penaltyRate = 50;
  uint16 public refinanceRate = 50;
  uint16 public conversionPremiumRate = 5000;
  uint16 public priceSpread = 100;
  // Components
  IGeneralManager public generalManager;
  IOriginationPoolScheduler public originationPoolScheduler;
  IOriginationPool public originationPool;
  IPriceOracle public whypePriceOracle;
  IPriceOracle public wbtcPriceOracle;
  IInterestRateOracle public interestRateOracle;
  ILoanManager public loanManager;
  IMortgageNFT public mortgageNFT;
  INFTMetadataGenerator public nftMetadataGenerator;
  IOrderPool public orderPool;
  IConversionQueue public whypeConversionQueue;
  IConversionQueue public wbtcConversionQueue;
  // Pyth
  IPyth public pyth;
  // OPool Config
  OriginationPoolConfig public originationPoolConfig;
  string public namePrefix = "Test Origination Pool";
  string public symbolPrefix = "TOP";
  uint32 public ogDepositPhaseDuration = 1 weeks;
  uint32 public ogDeployPhaseDuration = 1 weeks;
  uint256 public ogDefaultPoolLimit = 105_000e18; // $105k limit
  uint16 public ogPoolLimitGrowthRateBps = 100; // 1% growth per week
  uint16 public ogPoolMultiplierBps = 200; // 2% commission
  // Order Pool Args
  uint256 public opMaximumOrderDuration = 10 minutes; // Orders expire in 10 minutes

  // Constants
  address public constant WHYPE_ADDRESS = 0x5555555555555555555555555555555555555555;
  string public constant MORTGAGE_NFT_NAME = "Mortgage NFT";
  string public constant MORTGAGE_NFT_SYMBOL = "MNFT";

  function _deployWHype() internal {
    // Deploy the WHYPE to the 0x555... address
    deployCodeTo("test/artifacts/WHYPE9.json", WHYPE_ADDRESS);
    whype = IWNT(WHYPE_ADDRESS);
  }

  function _createGeneralManager() internal {
    GeneralManager generalManagerImplementation = new GeneralManager();
    bytes memory initializerData = abi.encodeCall(
      GeneralManager.initialize,
      (
        address(usdx),
        address(consol),
        penaltyRate,
        refinanceRate,
        conversionPremiumRate,
        priceSpread,
        insuranceFund,
        address(interestRateOracle)
      )
    );
    vm.startPrank(admin);
    ERC1967Proxy proxy = new ERC1967Proxy(address(generalManagerImplementation), initializerData);
    vm.label(address(proxy), "GeneralManagerProxy");
    vm.stopPrank();
    generalManager = GeneralManager(payable(address(proxy)));
  }

  function _createOriginationPoolConfig() internal {
    originationPoolConfig = OriginationPoolConfig({
      namePrefix: namePrefix,
      symbolPrefix: symbolPrefix,
      consol: address(consol),
      usdx: address(usdx),
      depositPhaseDuration: ogDepositPhaseDuration,
      deployPhaseDuration: ogDeployPhaseDuration,
      defaultPoolLimit: ogDefaultPoolLimit,
      poolLimitGrowthRateBps: ogPoolLimitGrowthRateBps,
      poolMultiplierBps: ogPoolMultiplierBps
    });
  }

  function _createOriginationPoolSchedulerAndPools() internal {
    OriginationPoolScheduler originationPoolSchedulerImplementation = new OriginationPoolScheduler();
    bytes memory initializerData =
      abi.encodeCall(OriginationPoolScheduler.initialize, (address(generalManager), address(admin)));
    vm.startPrank(admin);
    ERC1967Proxy proxy = new ERC1967Proxy(address(originationPoolSchedulerImplementation), initializerData);
    vm.label(address(proxy), "OriginationPoolSchedulerProxy");
    vm.stopPrank();
    originationPoolScheduler = OriginationPoolScheduler(payable(address(proxy)));

    // Create the origination pool config
    _createOriginationPoolConfig();

    // Add the origination pool config to the origination pool scheduler
    vm.startPrank(admin);
    originationPoolScheduler.addConfig(originationPoolConfig);
    vm.stopPrank();

    // Deploy the origination pool
    OPoolConfigId oPoolConfigId = OPoolConfigIdLibrary.toId(originationPoolConfig);
    originationPool = IOriginationPool(originationPoolScheduler.deployOriginationPool(oPoolConfigId));
    vm.stopPrank();
  }

  function _createForfeitedAssetsPool() internal {
    forfeitedAssetsPool = new ForfeitedAssetsPool("Forfeited Assets Pool", "FAP", admin);
  }

  function _createUSDX() internal {
    // Make usdt
    usdt = new MockERC20("Tether USD", "USDT", 6);
    vm.label(address(usdt), "USDT");
    // Make usdx
    usdx = new USDX("USDX", "USDX", 18, admin);
    // Add usdt to usdx
    vm.startPrank(admin);
    IAccessControl(address(usdx)).grantRole(Roles.SUPPORTED_TOKEN_ROLE, admin);
    USDX(address(usdx)).addSupportedToken(address(usdt), 1e12, 1);
    vm.stopPrank();
  }

  function _setupCollaterals() internal {
    wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
    vm.label(address(wbtc), "WBTC");
  }

  function _createSubConsols() internal {
    // whype first
    whypeSubConsol = new SubConsol("WHYPE SubConsol", "WHYPE-SUBCONSOL", address(admin), address(whype));
    // wbtc second
    wbtcSubConsol = new SubConsol("Bitcoin SubConsol", "BTC-SUBCONSOL", address(admin), address(wbtc));
  }

  function _createConsol() internal {
    consol = new Consol("Consol", "CONSOL", 8, address(admin), address(forfeitedAssetsPool));
    // Add inputs into consol
    vm.startPrank(admin);
    IAccessControl(address(consol)).grantRole(Roles.SUPPORTED_TOKEN_ROLE, admin);
    consol.addSupportedToken(address(usdx));
    consol.addSupportedToken(address(whypeSubConsol));
    consol.addSupportedToken(address(wbtcSubConsol));
    vm.stopPrank();
  }

  function _createLoanManager() internal {
    nftMetadataGenerator = new MockNFTMetadataGenerator();
    loanManager = new LoanManager(
      MORTGAGE_NFT_NAME, MORTGAGE_NFT_SYMBOL, address(nftMetadataGenerator), address(consol), address(generalManager)
    );

    // Set the loan manager in the general manager
    vm.startPrank(admin);
    generalManager.setLoanManager(address(loanManager));
    vm.stopPrank();
  }

  function _createOrderPool() internal {
    // Create the order pool
    orderPool = new OrderPool(address(whype), address(generalManager), admin);

    // Set the maximum order duration
    vm.startPrank(admin);
    orderPool.setMaximumOrderDuration(opMaximumOrderDuration);
    vm.stopPrank();

    // Set the order pool in the general manager
    vm.startPrank(admin);
    generalManager.setOrderPool(address(orderPool));
    vm.stopPrank();
  }

  function _createConversionQueues() internal {
    // Create the WHYPE conversion queue
    whypeConversionQueue = new ConversionQueue(
      address(whype),
      IERC20Metadata(address(whype)).decimals(),
      address(whypeSubConsol),
      address(consol),
      address(generalManager),
      admin
    );
    // Create the WBTC conversion queue
    wbtcConversionQueue = new ConversionQueue(
      address(wbtc),
      IERC20Metadata(address(wbtc)).decimals(),
      address(wbtcSubConsol),
      address(consol),
      address(generalManager),
      admin
    );

    // Have the admin grant the consol's withdraw role to the conversion queue contract
    vm.startPrank(admin);
    IAccessControl(address(consol)).grantRole(Roles.WITHDRAW_ROLE, address(whypeConversionQueue));
    IAccessControl(address(consol)).grantRole(Roles.WITHDRAW_ROLE, address(wbtcConversionQueue));
    vm.stopPrank();

    // Have the admin grant the SubConsol's withdraw role to the conversion queue contract
    vm.startPrank(admin);
    IAccessControl(address(whypeSubConsol)).grantRole(Roles.ACCOUNTING_ROLE, address(whypeConversionQueue));
    IAccessControl(address(wbtcSubConsol)).grantRole(Roles.ACCOUNTING_ROLE, address(wbtcConversionQueue));
    vm.stopPrank();

    // Have GeneralManager grant the CONVERSION_ROLE to the conversion queue
    vm.startPrank(admin);
    IAccessControl(address(generalManager)).grantRole(Roles.CONVERSION_ROLE, address(whypeConversionQueue));
    IAccessControl(address(generalManager)).grantRole(Roles.CONVERSION_ROLE, address(wbtcConversionQueue));
    vm.stopPrank();
  }

  function _setupOracles() internal {
    interestRateOracle = new MockInterestRateOracle();
    whypePriceOracle = new MockPriceOracle(18);
    wbtcPriceOracle = new MockPriceOracle(8);

    // Set the oracles in the GM
    vm.startPrank(admin);
    generalManager.setInterestRateOracle(address(interestRateOracle));
    generalManager.setPriceOracle(address(whype), address(whypePriceOracle));
    generalManager.setPriceOracle(address(wbtc), address(wbtcPriceOracle));
    vm.stopPrank();
  }

  function _updateSupportedTotalPeriods() internal {
    vm.startPrank(admin);
    generalManager.updateSupportedMortgagePeriodTerms(address(whype), 36, true);
    vm.stopPrank();
  }

  function _updateMinMaxBorrowCaps() internal {
    vm.startPrank(admin);
    // WHYPE limits
    generalManager.setMinimumCap(address(whype), 1e18); // Minimum cap of $1
    generalManager.setMaximumCap(address(whype), 10_000e18); // Maximum cap of $10k

    // WBTC limits
    generalManager.setMinimumCap(address(wbtc), 1e18); // Minimum cap of $1
    generalManager.setMaximumCap(address(wbtc), 10_000e18); // Maximum cap of $10k
    vm.stopPrank();
  }

  function setUp() public {
    // Skip 55 years into the future
    skip((31557600) * 55);

    // Deploy the WHYPE and other collaterals (wbtc)
    _deployWHype();
    _setupCollaterals();

    // Create Inputs into Consol
    _createForfeitedAssetsPool();
    _createUSDX();
    _createSubConsols();

    // Create Consol
    _createConsol();

    // Create the general manager
    _createGeneralManager();
    // Create the loan manager
    _createLoanManager();
    // Set up the origination pool scheduler and pools
    _createOriginationPoolSchedulerAndPools();
    // Create the order pool
    _createOrderPool();
    // Create the conversion queues
    _createConversionQueues();

    // Set up the oracles
    _setupOracles();

    // Update the supported total periods
    _updateSupportedTotalPeriods();

    // Update the min/max borrow caps
    _updateMinMaxBorrowCaps();

    // Set the origination pool scheduler in the general manager
    vm.startPrank(admin);
    generalManager.setOriginationPoolScheduler(address(originationPoolScheduler));
    vm.stopPrank();

    // Deploy the Pyth contract
    pyth = new MockPyth(120, 0); // 120 seconds valid time period, 0 update fee

    // Deploy the router
    router = new Router(address(whype), address(generalManager), address(pyth)); // Using btc as wrapped native token for testing

    // Run the approve functions on the router
    router.approveCollaterals();
    router.approveUsdTokens();
  }

  function test_constructor() public view {
    assertEq(address(router.generalManager()), address(generalManager), "General Manager address is incorrect");
    assertEq(address(router.wrappedNativeToken()), address(whype), "Wrapped native token address is incorrect");
    assertEq(address(router.usdx()), generalManager.usdx(), "USDX address is incorrect");
    assertEq(address(router.consol()), generalManager.consol(), "Consol address is incorrect");
    assertEq(
      address(router.originationPoolScheduler()),
      address(originationPoolScheduler),
      "Origination Pool Scheduler address is incorrect"
    );
    assertEq(
      IERC20(router.usdx()).allowance(address(router), address(router.consol())),
      type(uint256).max,
      "USDX allowance should be max"
    );
    assertEq(
      IERC20(router.consol()).allowance(address(router), address(router.generalManager())),
      type(uint256).max,
      "Consol allowance should be max"
    );
  }

  function test_approveCollaterals() public {
    // Making a new router just for this test
    router = new Router(address(whype), address(generalManager), address(pyth)); // Using btc as wrapped native token for testing
    // The WHYPE is already approved because it's the wrappedNativeToken in the constructor
    // So let's verify it's already approved
    assertEq(
      IERC20(address(whype)).allowance(address(router), address(generalManager)),
      type(uint256).max,
      "WHYPE should already be approved as wrappedNativeToken"
    );

    // Call approveCollaterals - this should approve collateral tokens from SubConsols
    router.approveCollaterals();

    // Verify that WBTC (as collateral from SubConsol) is still approved to max
    // This function iterates through consol supported tokens, finds SubConsols,
    // and approves their collateral tokens
    assertEq(
      wbtc.allowance(address(router), address(generalManager)),
      type(uint256).max,
      "WBTC collateral should remain approved to max after calling approveCollaterals"
    );
  }

  function test_approveUsdTokens() public {
    // Making a new router just for this test
    router = new Router(address(whype), address(generalManager), address(pyth)); // Using btc as wrapped native token for testing

    // Check initial state - router should not have approvals for USD tokens yet
    assertEq(usdt.allowance(address(router), address(usdx)), 0, "USDT should not be approved initially");

    // Call approveUsdTokens
    router.approveUsdTokens();

    // Verify that the router now has max approval for USD tokens to spend by USDX contract
    assertEq(
      usdt.allowance(address(router), address(usdx)),
      type(uint256).max,
      "USDT should be approved to max after calling approveUsdTokens"
    );
  }

  function test_requestMortgage_BNPLPaymentPlan() public {
    // Lender deposits $100k into the origination pool
    {
      vm.startPrank(lender);
      MockERC20(address(usdt)).mint(lender, 100e6); // 100 USDT
      MockERC20(address(usdt)).approve(address(usdx), 100e6);
      USDX(address(usdx)).deposit(address(usdt), 100e6); // This gives us USDX
      USDX(address(usdx)).approve(address(originationPool), 100e18);
      originationPool.deposit(100e18);
      vm.stopPrank();
    }

    // Skip ahead to the deploy phase of the origination pool
    vm.warp(originationPool.deployPhaseTimestamp());

    // Set the price of WHYPE to $50
    MockPriceOracle(address(whypePriceOracle)).setPrice(50e18);

    // Create a basic creation request for BNPL mortgage with a payment plan
    CreationRequest memory creationRequest;
    {
      uint256[] memory collateralAmounts = new uint256[](1);
      address[] memory originationPools = new address[](1);
      // Buying 100 WHYPE with 1 origination pool
      collateralAmounts[0] = 100e18;
      originationPools[0] = address(originationPool);

      creationRequest = CreationRequest({
        base: BaseRequest({
          collateralAmounts: collateralAmounts,
          totalPeriods: 36,
          originationPools: originationPools,
          isCompounding: false, // Buy-now-pay-later
          expiration: block.timestamp
        }),
        mortgageId: "Mortgage - 001",
        collateral: address(whype),
        subConsol: address(whypeSubConsol),
        conversionQueues: new address[](0), // No conversion queue
        hasPaymentPlan: true // Has a payment plan
      });
    }

    {
      // Calculate the amount of usdx to collect from the borrower
      (, uint256 requiredUsdxCollected,,) = router.calculateCollectedAmounts(creationRequest);
      // Mint the required usdt (NOT usdx) to the borrower and approve it to the router
      vm.startPrank(borrower);
      uint256 usdtAmount = router.convert(address(usdx), address(usdt), requiredUsdxCollected);
      MockERC20(address(usdt)).mint(borrower, usdtAmount);
      MockERC20(address(usdt)).approve(address(router), usdtAmount);
      vm.stopPrank();
    }

    // Borrower calls requestMortgage (using usdt NOT usdx)
    vm.startPrank(borrower);
    (uint256 collateralCollected, uint256 usdxCollected, uint256 paymentAmount, uint8 collateralDecimals) =
      router.requestMortgage{value: 0}(address(usdt), creationRequest, false, 2576e18); // Don't need to pay any fees yet
    vm.stopPrank();

    // Calculate expectedPaymentAmount
    uint256 expectedPaymentAmount = Math.mulDiv(50e18, 1e4 + 100, 1e4) * 100; // $50 * (101% with spread) * 100 WHYPE

    // Check the balances of the order pool
    assertEq(usdx.balanceOf(address(orderPool)), usdxCollected, "USDX balance of order pool should be 100");
    assertEq(whype.balanceOf(address(orderPool)), collateralCollected, "WHYPE balance of order pool should be 1");
    // Check that the payment amount is correct
    assertEq(paymentAmount, expectedPaymentAmount, "Payment amount should be equal to expectedPaymentAmount");
    // Check that the collateralDecimals is 18 (for WHYPE)
    assertEq(collateralDecimals, 18, "Collateral decimals should be 18");

    // Check the balances of the router
    assertEq(usdx.balanceOf(address(router)), 0, "USDX balance of router should be 0");
    assertEq(whype.balanceOf(address(router)), 0, "WHYPE balance of router should be 0");
  }

  function test_requestMortgage_CompoundingNoPaymentPlan() public {
    // Lender deposits $100k into the origination pool
    {
      vm.startPrank(lender);
      MockERC20(address(usdt)).mint(lender, 100e6); // 100 USDT
      MockERC20(address(usdt)).approve(address(usdx), 100e6);
      USDX(address(usdx)).deposit(address(usdt), 100e6); // This gives us USDX
      USDX(address(usdx)).approve(address(originationPool), 100e18);
      originationPool.deposit(100e18);
      vm.stopPrank();
    }

    // Skip ahead to the deploy phase of the origination pool
    vm.warp(originationPool.deployPhaseTimestamp());

    // Set the price of WHYPE to $50
    MockPriceOracle(address(whypePriceOracle)).setPrice(50e18);

    // Create a basic creation request for compounding mortgage with no payment plan
    CreationRequest memory creationRequest;
    {
      uint256[] memory collateralAmounts = new uint256[](1);
      address[] memory originationPools = new address[](1);
      address[] memory conversionQueues = new address[](1);
      // Buying 100 WHYPE with 1 origination pool
      collateralAmounts[0] = 100e18;
      originationPools[0] = address(originationPool);
      conversionQueues[0] = address(whypeConversionQueue);

      creationRequest = CreationRequest({
        base: BaseRequest({
          collateralAmounts: collateralAmounts,
          totalPeriods: 36,
          originationPools: originationPools,
          isCompounding: true, // Compounding
          expiration: block.timestamp
        }),
        mortgageId: "Mortgage - 002",
        collateral: address(whype),
        subConsol: address(whypeSubConsol),
        conversionQueues: conversionQueues, // One conversion queue
        hasPaymentPlan: false // Has a payment plan
      });
    }

    // Calculate the amount of collateral to collect from the borrower
    (uint256 requiredCollateralCollected,,,) = router.calculateCollectedAmounts(creationRequest);
    // Deel the required amount of HYPE to the user
    vm.deal(borrower, requiredCollateralCollected);
    whype.approve(address(router), requiredCollateralCollected);
    vm.stopPrank();

    // Borrower calls requestMortgage (using usdt NOT usdx)
    vm.startPrank(borrower);
    (uint256 collateralCollected, uint256 usdxCollected, uint256 paymentAmount, uint8 collateralDecimals) =
      router.requestMortgage{value: requiredCollateralCollected}(address(whype), creationRequest, true, 51e18); // Don't need to pay any fees yet
    vm.stopPrank();

    // Calculate expectedPaymentAmount
    uint256 expectedPaymentAmount = Math.mulDiv(Math.mulDiv(50e18, 1e4 + 100, 1e4), 1e4 - 200, 1e4) * 50; // $50 * (101% with spread) * (98% since 2% commission fee is coming from the borrower) * 50 WHYPE (because borrower is supplying the other half)

    // Check the balances of the order pool
    assertEq(usdx.balanceOf(address(orderPool)), usdxCollected, "USDX balance of order pool should be 100");
    assertEq(whype.balanceOf(address(orderPool)), collateralCollected, "WHYPE balance of order pool should be 1");
    // Check that the payment amount is correct
    assertEq(paymentAmount, expectedPaymentAmount, "Payment amount should be equal to expectedPaymentAmount");
    // Check that the collateralDecimals is 18 (for WHYPE)
    assertEq(collateralDecimals, 18, "Collateral decimals should be 18");

    // Check the balances of the router
    assertEq(usdx.balanceOf(address(router)), 0, "USDX balance of router should be 0");
    assertEq(whype.balanceOf(address(router)), 0, "WHYPE balance of router should be 0");
  }
}
