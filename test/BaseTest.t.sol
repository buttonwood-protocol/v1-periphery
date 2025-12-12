// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// forge-lint: disable-next-line(unused-import)
import {Test, console} from "forge-std/Test.sol";
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
import {MockERC20} from "./mocks/MockERC20.sol";
import {RolloverVault} from "../src/RolloverVault.sol";

contract BaseTest is Test {
  using OPoolConfigIdLibrary for OPoolConfigId;

  // Actors
  address public admin = makeAddr("admin");
  address public lender = makeAddr("lender");
  address public borrower = makeAddr("borrower");
  address public fulfiller = makeAddr("fulfiller");
  address public rando = makeAddr("rando");
  address public user = makeAddr("user");
  address public keeper = makeAddr("keeper");

  // Mainnet Addresses
  address public USDT0_ADDRESS = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
  address public USDH0_ADDRESS = 0x111111a1a0667d36bD57c0A9f569b98057111111;
  address public UBTC_ADDRESS = 0x9FDBdA0A5e284c32744D2f17Ee5c74B284993463;

  // Tokens
  IERC20 public usdt;
  IERC20 public usdh;
  IUSDX public usdx;
  ForfeitedAssetsPool public forfeitedAssetsPool;
  IConsol public consol;
  IWNT public whype;
  IERC20 public ubtc;
  ISubConsol public whypeSubConsol;
  ISubConsol public ubtcSubConsol;
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
  IPriceOracle public ubtcPriceOracle;
  IInterestRateOracle public interestRateOracle;
  ILoanManager public loanManager;
  IMortgageNFT public mortgageNFT;
  INFTMetadataGenerator public nftMetadataGenerator;
  IOrderPool public orderPool;
  IConversionQueue public whypeConversionQueue;
  IConversionQueue public ubtcConversionQueue;
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
  // RolloverVault Args
  string ROLLLOVER_VAULT_NAME = "Test Rollover Vault";
  string ROLLLOVER_VAULT_SYMBOL = "tRV";
  uint8 ROLLLOVER_VAULT_DECIMALS = 24; // Make this 6 + usdx decimals
  uint8 ROLLLOVER_VAULT_DECIMALS_OFFSET = 6;
  RolloverVault public rolloverVault;
  uint256 public PRIME_AMOUNT = 1e18; // The initial amount of depositableAsset to prime the liquidityVault with (in depositableAsset decimals)

  function _deployWHype() internal {
    // Deploy the WHYPE to the 0x555... address
    deployCodeTo("test/artifacts/WHYPE9.json", WHYPE_ADDRESS);
    whype = IWNT(WHYPE_ADDRESS);
    vm.label(address(whype), "WHYPE");
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
    usdt = new MockERC20("USDT", "USDT", 18);
    vm.label(address(usdt), "USDT");
    // Make usdh
    usdh = new MockERC20("USDH", "USDH", 18);
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
    ubtc = new MockERC20("UBTC", "UBTC", 8);
    vm.label(address(ubtc), "UBTC");
  }

  function _createSubConsols() internal {
    // whype first
    whypeSubConsol = new SubConsol("WHYPE SubConsol", "WHYPE-SUBCONSOL", address(admin), address(whype));
    // ubtc second
    ubtcSubConsol = new SubConsol("UBTC SubConsol", "UBTC-SUBCONSOL", address(admin), address(ubtc));
  }

  function _createConsol() internal {
    consol = new Consol("Consol", "CONSOL", 8, address(admin), address(forfeitedAssetsPool));
    // Add inputs into consol
    vm.startPrank(admin);
    IAccessControl(address(consol)).grantRole(Roles.SUPPORTED_TOKEN_ROLE, admin);
    consol.addSupportedToken(address(usdx));
    consol.addSupportedToken(address(whypeSubConsol));
    consol.addSupportedToken(address(ubtcSubConsol));
    vm.stopPrank();
  }

  function _createLoanManager() internal {
    nftMetadataGenerator = new MockNFTMetadataGenerator();
    loanManager = new LoanManager(
      MORTGAGE_NFT_NAME, MORTGAGE_NFT_SYMBOL, address(nftMetadataGenerator), address(consol), address(generalManager)
    );
    mortgageNFT = IMortgageNFT(loanManager.nft());

    // Set the loan manager in the general manager
    vm.startPrank(admin);
    generalManager.setLoanManager(address(loanManager));
    vm.stopPrank();

    // Grant ACCOUNTING_ROLE to the loan manager for the subconsols
    vm.startPrank(admin);
    IAccessControl(address(whypeSubConsol)).grantRole(Roles.ACCOUNTING_ROLE, address(loanManager));
    IAccessControl(address(ubtcSubConsol)).grantRole(Roles.ACCOUNTING_ROLE, address(loanManager));
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
    // Create the UBTC conversion queue
    ubtcConversionQueue = new ConversionQueue(
      address(ubtc),
      IERC20Metadata(address(ubtc)).decimals(),
      address(ubtcSubConsol),
      address(consol),
      address(generalManager),
      admin
    );

    // Have the admin grant the consol's withdraw role to the conversion queue contract
    vm.startPrank(admin);
    IAccessControl(address(consol)).grantRole(Roles.WITHDRAW_ROLE, address(whypeConversionQueue));
    IAccessControl(address(consol)).grantRole(Roles.WITHDRAW_ROLE, address(ubtcConversionQueue));
    vm.stopPrank();

    // Have the admin grant the SubConsol's withdraw role to the conversion queue contract
    vm.startPrank(admin);
    IAccessControl(address(whypeSubConsol)).grantRole(Roles.ACCOUNTING_ROLE, address(whypeConversionQueue));
    IAccessControl(address(ubtcSubConsol)).grantRole(Roles.ACCOUNTING_ROLE, address(ubtcConversionQueue));
    vm.stopPrank();

    // Have GeneralManager grant the CONVERSION_ROLE to the conversion queue
    vm.startPrank(admin);
    IAccessControl(address(generalManager)).grantRole(Roles.CONVERSION_ROLE, address(whypeConversionQueue));
    IAccessControl(address(generalManager)).grantRole(Roles.CONVERSION_ROLE, address(ubtcConversionQueue));
    vm.stopPrank();
  }

  function _setupOracles() internal {
    interestRateOracle = new MockInterestRateOracle();
    whypePriceOracle = new MockPriceOracle(18);
    ubtcPriceOracle = new MockPriceOracle(8);

    // Set the oracles in the GM
    vm.startPrank(admin);
    generalManager.setInterestRateOracle(address(interestRateOracle));
    generalManager.setPriceOracle(address(whype), address(whypePriceOracle));
    generalManager.setPriceOracle(address(ubtc), address(ubtcPriceOracle));
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

    // UBTC limits
    generalManager.setMinimumCap(address(ubtc), 1e18); // Minimum cap of $1
    generalManager.setMaximumCap(address(ubtc), 10_000e18); // Maximum cap of $10k
    vm.stopPrank();
  }

  function setUpCore() public {
    // Skip 55 years into the future
    skip((31557600) * 55);

    // Deploy the WHYPE and other collaterals (ubtc)
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

  function primeRolloverVault() public {
    // Mint 0.5 PRIME_AMOUNT of usdt0 and usdh to the admin
    vm.startPrank(admin);
    uint256 usdtAmount = usdx.convertUnderlying(address(usdt), PRIME_AMOUNT / 2);
    uint256 usdhAmount = usdx.convertUnderlying(address(usdh), PRIME_AMOUNT / 2);
    deal(address(usdt), admin, usdtAmount);
    deal(address(usdh), admin, usdhAmount);
    vm.stopPrank();

    // Admin primes the rolloverVault with PRIME_AMOUNT of usdx
    vm.startPrank(admin);
    usdt.approve(address(usdx), usdtAmount);
    usdh.approve(address(usdx), usdhAmount);
    usdx.deposit(address(usdt), usdtAmount);
    usdx.deposit(address(usdh), usdhAmount);
    usdx.approve(address(rolloverVault), PRIME_AMOUNT);
    rolloverVault.deposit(address(usdx), PRIME_AMOUNT);
    vm.stopPrank();

    // Transfer the rolloverVault balance to the rolloverVault itself
    vm.startPrank(admin);
    rolloverVault.transfer(address(rolloverVault), rolloverVault.balanceOf(admin));
    vm.stopPrank();
  }

  function setUpRolloverVault() public {
    // Deploy the rolloverVault
    RolloverVault rolloverVaultImplementation = new RolloverVault();
    bytes memory initializerData = abi.encodeWithSelector(
      RolloverVault.initialize.selector,
      ROLLLOVER_VAULT_NAME,
      ROLLLOVER_VAULT_SYMBOL,
      ROLLLOVER_VAULT_DECIMALS,
      ROLLLOVER_VAULT_DECIMALS_OFFSET,
      address(generalManager),
      address(admin)
    );
    ERC1967Proxy proxy = new ERC1967Proxy(address(rolloverVaultImplementation), initializerData);
    rolloverVault = RolloverVault(payable(address(proxy)));

    // Prime the rolloverVault
    primeRolloverVault();

    // Grant the keeper the KEEPER_ROLE
    vm.startPrank(admin);
    rolloverVault.grantRole(rolloverVault.KEEPER_ROLE(), keeper);
    vm.stopPrank();
  }

  function test_constructor() public view virtual {}
}
