// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GeneralManager} from "@core/GeneralManager.sol";
import {IGeneralManager} from "@core/interfaces/IGeneralManager/IGeneralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ForfeitedAssetsPool} from "@core/ForfeitedAssetsPool.sol";
import {IConsol} from "@core/interfaces/IConsol/IConsol.sol";
import {ISubConsol} from "@core/interfaces/ISubConsol/ISubConsol.sol";
import {IUSDX} from "@core/interfaces/IUSDX/IUSDX.sol";
import {USDX} from "@core/USDX.sol";
import {Consol} from "@core/Consol.sol";
import {SubConsol} from "@core/SubConsol.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {OriginationPoolScheduler} from "@core/OriginationPoolScheduler.sol";
import {IOriginationPoolScheduler} from "@core/interfaces/IOriginationPoolScheduler/IOriginationPoolScheduler.sol";
import {IWNT} from "../src/interfaces/IWNT.sol";
import {Roles} from "@core/libraries/Roles.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
// import {CreationRequest, BaseRequest} from "@core/types/orders/OrderRequests.sol";
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
// import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IConversionQueue} from "@core/interfaces/IConversionQueue/IConversionQueue.sol";
import {ConversionQueue} from "@core/ConversionQueue.sol";
import {IPyth} from "@pythnetwork/IPyth.sol";
import {MockPyth} from "@pythnetwork/MockPyth.sol";

contract BaseTest is Test {
  using OPoolConfigIdLibrary for OPoolConfigId;

  // Actors
  address public admin = makeAddr("admin");
  address public lender = makeAddr("lender");
  address public borrower = makeAddr("borrower");
  address public fulfiller = makeAddr("fulfiller");
  address public rando = makeAddr("rando");

  // Tokens
  IERC20 public usdt;
  IERC20 public usdh;
  IUSDX public usdx;
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
    // Make usdh
    usdh = new MockERC20("USD+", "USDH", 6);
    vm.label(address(usdh), "USDH");
    // Make usdx
    usdx = new USDX("USDX", "USDX", 18, admin);
    // Add usdt and usdh to usdx
    vm.startPrank(admin);
    IAccessControl(address(usdx)).grantRole(Roles.SUPPORTED_TOKEN_ROLE, admin);
    USDX(address(usdx)).addSupportedToken(address(usdt), 1e12, 1);
    USDX(address(usdx)).addSupportedToken(address(usdh), 1e12, 1);
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

  function setUpCore() public {
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
  }

  function test_constructor() public view {}
}
