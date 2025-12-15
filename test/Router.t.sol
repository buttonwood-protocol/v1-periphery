// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTest} from "./BaseTest.t.sol";
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

contract RouterTest is BaseTest {
  using OPoolConfigIdLibrary for OPoolConfigId;

  // Router
  Router public router;

  // ToDo: RolloverVault Address
  // ToDo: RolloverVault Address
  // ToDo: RolloverVault Address
  // ToDo: RolloverVault Address
  // ToDo: RolloverVault Address
  // ToDo: RolloverVault Address
  address public rolloverVaultAddress;

  function setUp() public {
    // Setting up the core contracts
    setUpCore();

    // Deploy the router
    router = new Router(address(whype), address(generalManager), rolloverVaultAddress, address(pyth));

    // Run the approve functions on the router
    router.approveCollaterals();
    router.approveUsdTokens();
  }

  function test_constructor() public view override {
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
    router = new Router(address(whype), address(generalManager), address(rolloverVault), address(pyth));
    // The WHYPE is already approved because it's the wrappedNativeToken in the constructor
    // So let's verify it's already approved
    assertEq(
      IERC20(address(whype)).allowance(address(router), address(generalManager)),
      type(uint256).max,
      "WHYPE should already be approved as wrappedNativeToken"
    );

    // Call approveCollaterals - this should approve collateral tokens from SubConsols
    router.approveCollaterals();

    // Verify that UBTC (as collateral from SubConsol) is still approved to max
    // This function iterates through consol supported tokens, finds SubConsols,
    // and approves their collateral tokens
    assertEq(
      ubtc.allowance(address(router), address(generalManager)),
      type(uint256).max,
      "UBTC collateral should remain approved to max after calling approveCollaterals"
    );
  }

  function test_approveUsdTokens() public {
    // Making a new router just for this test
    router = new Router(address(whype), address(generalManager), address(rolloverVault), address(pyth));

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

    // Deal 0.01e18 of native tokens to the borrower
    deal(address(borrower), 0.01e18);

    // Borrower calls requestMortgage (using usdt NOT usdx)
    vm.startPrank(borrower);
    (uint256 collateralCollected, uint256 usdxCollected, uint256 paymentAmount, uint8 collateralDecimals) =
      router.requestMortgage{value: 0.01e18}(address(usdt), creationRequest, false, 2576e18); // Don't need to pay any fees yet
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
    // Deel the required amount of HYPE to the user (plus 0.01e18 for the gas fee)
    vm.deal(borrower, requiredCollateralCollected + 0.01e18);
    vm.stopPrank();

    // Borrower calls requestMortgage (using usdt NOT usdx)
    vm.startPrank(borrower);
    (uint256 collateralCollected, uint256 usdxCollected, uint256 paymentAmount, uint8 collateralDecimals) =
      router.requestMortgage{value: requiredCollateralCollected + 0.01e18}(address(whype), creationRequest, true, 51e18); // Don't need to pay any fees yet
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
