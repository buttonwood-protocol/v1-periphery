// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseTest, console} from "./BaseTest.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USDX} from "@core/USDX.sol";
import {IUSDX} from "@core/interfaces/IUSDX/IUSDX.sol";
import {IFulfillmentVault} from "../src/interfaces/IFulfillmentVault/IFulfillmentVault.sol";
import {FulfillmentVault} from "../src/FulfillmentVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Roles} from "@core/libraries/Roles.sol";
import {IWNT} from "../src/interfaces/IWNT.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {ILiquidityVault} from "../src/interfaces/ILiquidityVault/ILiquidityVault.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HyperCore} from "@hyper-evm-lib/test/simulation/HyperCore.sol";
import {TokenRegistry} from "@hyper-evm-lib/src/registry/TokenRegistry.sol";
import {HLConversions} from "@hyper-evm-lib/src/common/HLConversions.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {Router} from "../src/Router.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {CreationRequest, BaseRequest} from "@core/types/orders/OrderRequests.sol";


contract FulfillmentVaultTest is BaseTest {
  HyperCore public hyperCore;

  using PrecompileLib for address;

  string NAME = "Test Fulfillment Vault";
  string SYMBOL = "tFT";
  uint8 DECIMALS = 26; // ToDo: Make this 8 + usdx decimals????
  uint8 DECIMALS_OFFSET = 8;

  // Hyper-EVM-Lib Values
  TokenRegistry public tokenRegistry;
  address public HYPER_CORE_ADDRESS = 0x9999999999999999999999999999999999999999;
  address TOKEN_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080C;
  address SPOT_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080b;
  address SPOT_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000808;
  address public TOKEN_REGISTRY_ADDRESS = 0x0b51d1A9098cf8a72C325003F44C194D41d7A85B;
  uint32 public HYPE_TOKEN_INDEX = uint32(HLConstants.hypeTokenIndex());
  uint32 public USDC_TOKEN_INDEX = 0;
  uint32 public USDT_TOKEN_INDEX = 268;
  uint32 public USDH_TOKEN_INDEX = 360;

  FulfillmentVault public fulfillmentVault;

  address public user = makeAddr("user");
  address public keeper = makeAddr("keeper");

  uint256 public PRIME_AMOUNT = 1e18; // The initial amount of depositableAsset to prime the liquidityVault with (in depositableAsset decimals)

  function mockTokenInfo(
    uint32 tokenIndex,
    address evmContract,
    string memory name,
    uint8 szDecimals,
    uint8 weiDecimals,
    int8 evmExtraWeiDecimals
  ) internal {
    PrecompileLib.TokenInfo memory info = PrecompileLib.TokenInfo({
      name: name,
      spots: new uint64[](0),
      deployerTradingFeeShare: 0,
      deployer: address(0),
      evmContract: evmContract,
      szDecimals: szDecimals,
      weiDecimals: weiDecimals,
      evmExtraWeiDecimals: evmExtraWeiDecimals
    });

    vm.mockCall(TOKEN_INFO_PRECOMPILE_ADDRESS, abi.encode(tokenIndex), abi.encode(info));
    if (tokenIndex != HYPE_TOKEN_INDEX && tokenIndex != USDC_TOKEN_INDEX) {
      tokenRegistry.setTokenInfo(tokenIndex);
    }
  }

  function mockSpotInfo(
    uint32 spotIndex,
    string memory name,
    uint64[2] memory tokens
  ) internal {
    PrecompileLib.SpotInfo memory info = PrecompileLib.SpotInfo({
      name: name,
      tokens: tokens
    });
    vm.mockCall(SPOT_INFO_PRECOMPILE_ADDRESS, abi.encode(spotIndex), abi.encode(info));
  }

  function mockSpotPx(uint32 spotIndex, uint64 px) internal {
    vm.mockCall(SPOT_PX_PRECOMPILE_ADDRESS, abi.encode(spotIndex), abi.encode(px));
  }

  function setupHyperCore() internal {
    hyperCore = new HyperCore();
    vm.etch(HYPER_CORE_ADDRESS, address(hyperCore).code);
    vm.label(HYPER_CORE_ADDRESS, "HyperCore");
    hyperCore = CoreSimulatorLib.init();
  }

  function setupTokenRegistry() internal {
    tokenRegistry = new TokenRegistry();
    vm.etch(TOKEN_REGISTRY_ADDRESS, address(tokenRegistry).code);
    vm.label(TOKEN_REGISTRY_ADDRESS, "TokenRegistry");
    tokenRegistry = TokenRegistry(TOKEN_REGISTRY_ADDRESS);
    mockTokenInfo(USDT_TOKEN_INDEX, address(usdt), "USDT", 2, 8, -2);
    mockTokenInfo(USDH_TOKEN_INDEX, address(usdh), "USDH", 2, 8, -2);
    mockTokenInfo(HYPE_TOKEN_INDEX, address(0), "HYPE", 2, 8, 0);
    mockTokenInfo(USDC_TOKEN_INDEX, address(0), "USDC", 8, 8, 0);
  }

  function setupSpotInfo() internal {
    uint64[2] memory tokens = [uint64(USDT_TOKEN_INDEX), uint64(USDC_TOKEN_INDEX)];
    mockSpotInfo(USDT_TOKEN_INDEX, "@166", tokens);
    tokens = [uint64(USDH_TOKEN_INDEX), uint64(USDC_TOKEN_INDEX)];
    mockSpotInfo(USDH_TOKEN_INDEX, "@230", tokens);
    tokens = [uint64(HYPE_TOKEN_INDEX), uint64(USDC_TOKEN_INDEX)];
    mockSpotInfo(HYPE_TOKEN_INDEX, "@107", tokens);
  }

  function primeFulfillmentVault() public {
    // Mint 0.5 PRIME_AMOUNT of usdt0 and usdh to the admin
    vm.startPrank(admin);
    uint256 usdtAmount = usdx.convertUnderlying(address(usdt), PRIME_AMOUNT / 2);
    uint256 usdhAmount = usdx.convertUnderlying(address(usdh), PRIME_AMOUNT / 2);
    deal(address(usdt), admin, usdtAmount);
    deal(address(usdh), admin, usdhAmount);
    vm.stopPrank();

    // Admin primes the fulfillmentVault with PRIME_AMOUNT of usdx
    vm.startPrank(admin);
    usdt.approve(address(usdx), usdtAmount);
    usdh.approve(address(usdx), usdhAmount);
    usdx.deposit(address(usdt), usdtAmount);
    usdx.deposit(address(usdh), usdhAmount);
    usdx.approve(address(fulfillmentVault), PRIME_AMOUNT);
    fulfillmentVault.deposit(address(usdx), PRIME_AMOUNT);
    vm.stopPrank();

    // Transfer the fulfillmentVault balance to the fulfillmentVault itself
    vm.startPrank(admin);
    fulfillmentVault.transfer(address(fulfillmentVault), fulfillmentVault.balanceOf(admin));
    vm.stopPrank();
  }

  function setUp() public {
    // Initialize the HyperCore simulator
    // vm.createSelectFork(vm.rpcUrl("hyperliquid"), 17133085);
    setupHyperCore();

    // Setup core
    setUpCore();

    // Setup the mock token registry
    setupTokenRegistry();

    // Setup the mock spot info
    setupSpotInfo();

    // Deploy the fulfillmentVault
    FulfillmentVault fulfillmentVaultImplementation = new FulfillmentVault();
    bytes memory initializerData = abi.encodeWithSelector(
      FulfillmentVault.initialize.selector,
      NAME,
      SYMBOL,
      DECIMALS,
      DECIMALS_OFFSET,
      address(whype),
      address(generalManager),
      address(admin)
    );
    ERC1967Proxy proxy = new ERC1967Proxy(address(fulfillmentVaultImplementation), initializerData);
    fulfillmentVault = FulfillmentVault(payable(address(proxy)));

    // Prime the fulfillmentVault
    primeFulfillmentVault();

    // Grant the keeper the KEEPER_ROLE
    vm.startPrank(admin);
    fulfillmentVault.grantRole(fulfillmentVault.KEEPER_ROLE(), keeper);
    vm.stopPrank();

    // Force the fulfillmentVault to be activated on hypercore
    CoreSimulatorLib.forceAccountActivation(address(fulfillmentVault));
    
    // Force activate the HYPE system address so bridging works
    CoreSimulatorLib.forceAccountActivation(0x2222222222222222222222222222222222222222);

    // Grant the fulfillmentVault the orderPool's FULFILLMENT_VAULT_ROLE
    vm.startPrank(admin);
    IAccessControl(address(orderPool)).grantRole(Roles.FULFILLMENT_ROLE, address(fulfillmentVault));
    vm.stopPrank();
  }

  function test_initialize() public {
    CoreSimulatorLib.forceSpotBalance(address(fulfillmentVault), USDT_TOKEN_INDEX, 0);
    assertEq(fulfillmentVault.name(), NAME);
    assertEq(fulfillmentVault.symbol(), SYMBOL);
    assertEq(fulfillmentVault.decimals(), DECIMALS);
    assertEq(fulfillmentVault.decimalsOffset(), DECIMALS_OFFSET);
    assertEq(fulfillmentVault.totalAssets(), PRIME_AMOUNT);
    assertEq(fulfillmentVault.totalSupply(), PRIME_AMOUNT * (10 ** DECIMALS_OFFSET));
    assertEq(fulfillmentVault.depositableAssets()[0], address(usdx));
    assertEq(fulfillmentVault.redeemableAssets()[0], address(usdx));
    assertEq(fulfillmentVault.wrappedNativeToken(), address(whype));
    assertEq(fulfillmentVault.generalManager(), address(generalManager));
    assertEq(fulfillmentVault.orderPool(), address(orderPool));
    assertEq(fulfillmentVault.usdx(), address(usdx));
    assertEq(fulfillmentVault.nonce(), 0);
    assertTrue(fulfillmentVault.hasRole(fulfillmentVault.DEFAULT_ADMIN_ROLE(), admin));
  }

  function test_supportedInterfaces_valid() public view {
    // Test all interfaces that FulfillmentVault implements
    assertTrue(fulfillmentVault.supportsInterface(type(ILiquidityVault).interfaceId), "Should support ILiquidityVault");
    assertTrue(
      fulfillmentVault.supportsInterface(type(IFulfillmentVault).interfaceId), "Should support IFulfillmentVault"
    );
    assertTrue(fulfillmentVault.supportsInterface(type(IERC165).interfaceId), "Should support IERC165");
    assertTrue(fulfillmentVault.supportsInterface(type(IAccessControl).interfaceId), "Should support IAccessControl");
    assertTrue(
      fulfillmentVault.supportsInterface(type(IERC1822Proxiable).interfaceId), "Should support IERC1822Proxiable"
    );
    assertTrue(fulfillmentVault.supportsInterface(type(IERC20).interfaceId), "Should support IERC20");
    assertTrue(fulfillmentVault.supportsInterface(type(IERC20Metadata).interfaceId), "Should support IERC20Metadata");
  }

  function test_supportedInterfaces_invalid(bytes4 interfaceId) public view {
    // Make sure it's not one of the valid interfaces
    vm.assume(
      interfaceId != type(ILiquidityVault).interfaceId && interfaceId != type(IFulfillmentVault).interfaceId
        && interfaceId != type(IERC165).interfaceId && interfaceId != type(IAccessControl).interfaceId
        && interfaceId != type(IERC1822Proxiable).interfaceId && interfaceId != type(IERC20).interfaceId
        && interfaceId != type(IERC20Metadata).interfaceId
    );
    assertFalse(fulfillmentVault.supportsInterface(interfaceId), "Should not support invalid interface");
  }

  function test_approveWhype(address caller) public {
    // Caller calls approveWhype()
    vm.startPrank(caller);
    fulfillmentVault.approveWhype();
    vm.stopPrank();

    // Validate that order pool has maximum allowance of whype from fulfillmentVault
    assertEq(whype.allowance(address(fulfillmentVault), address(orderPool)), type(uint256).max);
  }

  function test_wrapHype(address caller, uint256 hypeBalance) public {
    // Donate a balance of hype to the fulfillmentVault
    deal(address(fulfillmentVault), hypeBalance);

    // Validate that the fulfillmentVault has the hype balance and no whype balance before starting
    assertEq(address(fulfillmentVault).balance, hypeBalance, "FulfillmentVault should have the hype balance");
    assertEq(whype.balanceOf(address(fulfillmentVault)), 0, "FulfillmentVault should have no whype balance");

    // Caller calls wrapHype()
    vm.startPrank(caller);
    fulfillmentVault.wrapHype();
    vm.stopPrank();

    // Validate that the fulfillmentVault has no hype balance and has the entire hype balance in whype now
    assertEq(address(fulfillmentVault).balance, 0, "FulfillmentVault should have no hype balance");
    assertEq(whype.balanceOf(address(fulfillmentVault)), hypeBalance, "FulfillmentVault should have the same hype balance as before the wrap");
  }

  function test_bridgeHypeFromCoreToEvm_revertsWhenDoesNotHaveKeeperRole(address caller, uint256 hypeBalance) public {
    // Ensure the caller does not have the KEEPER_ROLE
    vm.assume(fulfillmentVault.hasRole(fulfillmentVault.KEEPER_ROLE(), caller) == false);

    // Attempt to call bridgeHypeFromCoreToEvm() without the KEEPER_ROLE
    vm.startPrank(caller);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, fulfillmentVault.KEEPER_ROLE()));
    fulfillmentVault.bridgeHypeFromCoreToEvm(hypeBalance);
    vm.stopPrank();
  }

  function test_bridgeHypeFromCoreToEvm_revertsWhenNotPaused(uint256 bridgeAmount) public {
    // Validate that the fulfillmentVault is not paused
    assertFalse(fulfillmentVault.paused(), "FulfillmentVault should not be paused");

    // Keeper attempts to call bridgeHypeFromCoreToEvm() when the fulfillmentVault is not paused
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector));
    fulfillmentVault.bridgeHypeFromCoreToEvm(bridgeAmount);
    vm.stopPrank();
  }

  function test_bridgeHypeFromCoreToEvm(uint256 hypeBalance, uint256 bridgeAmount) public {
    // Ensure hypeBalance doesn't overflow or underflow
    hypeBalance = uint256(bound(hypeBalance, 1e10, uint256(type(uint64).max)) * 1e10);

    // Make sure bridgeAmount is less than or equal to hypeBalance
    bridgeAmount = uint256(bound(bridgeAmount, 1e10, hypeBalance));

    // Set fulfillmentVault's hype balance on core
    uint64 hypeBalance64 = HLConversions.evmToWei(HYPE_TOKEN_INDEX, hypeBalance);
    hyperCore.forceSpotBalance(address(fulfillmentVault), HYPE_TOKEN_INDEX, hypeBalance64);

    // Set fulfillmentVault's USDC balance on core
    // uint64 usdcBalance64 = HLConversions.evmToWei(USDC_TOKEN_INDEX, 1e18);
    hyperCore.forceSpotBalance(address(fulfillmentVault), USDC_TOKEN_INDEX, 1e8);

    // Validate that the fulfillmentVault has the hype balance on core
    PrecompileLib.SpotBalance memory balance = PrecompileLib.spotBalance(address(fulfillmentVault), HYPE_TOKEN_INDEX);
    assertEq(balance.total, hypeBalance64, "FulfillmentVault should have the hype balance on core");

    // Keeper pauses the fulfillmentVault and calls bridgeHypeFromCoreToEvm() with bridgeAmount
    vm.startPrank(keeper);
    fulfillmentVault.setPaused(true);
    fulfillmentVault.bridgeHypeFromCoreToEvm(bridgeAmount);
    vm.stopPrank();

    // Move to the next block,
    // Performing all queued CoreWriter and bridging actions
    CoreSimulatorLib.nextBlock();

    // Validate that the fulfillmentVault has the bridgeAmount of hype on evm (rounded to within 1e10 precision)
    assertApproxEqAbs(address(fulfillmentVault).balance, bridgeAmount, 1e10, "FulfillmentVault should have the bridgeAmount of hype on evm");
  }

  function test_burnUsdx_revertsWhenDoesNotHaveKeeperRole(address caller, uint256 amount) public {
    // Ensure the caller does not have the KEEPER_ROLE
    vm.assume(fulfillmentVault.hasRole(fulfillmentVault.KEEPER_ROLE(), caller) == false);

    // Attempt to call burnUsdx() without the KEEPER_ROLE
    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, fulfillmentVault.KEEPER_ROLE()
      )
    );
    fulfillmentVault.burnUsdx(amount);
    vm.stopPrank();
  }

  function test_burnUsdx_revertsWhenNotPaused(uint256 amount) public {
    // Validate that the fulfillmentVault is not paused
    assertFalse(fulfillmentVault.paused(), "FulfillmentVault should not be paused");

    // Attempt to call burnUsdx() when the fulfillmentVault is not paused
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector));
    fulfillmentVault.burnUsdx(amount);
    vm.stopPrank();
  }

  function test_burnUsdx(uint128 mintAmount, uint128 burnAmount) public {
    // Ensure mintAmount is greater than $1
    mintAmount = uint128(bound(mintAmount, 1e18, type(uint128).max));

    // User deposits mintAmount of usdx into the fulfillmentVault
    vm.startPrank(user);
    {
      uint256 usdtAmount = usdx.convertUnderlying(address(usdt), mintAmount);
      deal(address(usdt), user, usdtAmount);
      usdt.approve(address(usdx), usdtAmount);
      usdx.deposit(address(usdt), usdtAmount);
      usdx.approve(address(fulfillmentVault), mintAmount);
      fulfillmentVault.deposit(address(usdx), mintAmount);
    }
    vm.stopPrank();

    // Record the user's balance in the fulfillmentVault
    uint256 fBalance = fulfillmentVault.balanceOf(user);

    // Keeper pauses the fulfillmentVault
    vm.startPrank(keeper);
    fulfillmentVault.setPaused(true);
    vm.stopPrank();

    // Keeper calls burnUsdx() with usdxAmount leq the minted usdx amount, but greater than $1
    burnAmount = uint128(bound(burnAmount, 1e18, mintAmount));
    vm.startPrank(keeper);
    fulfillmentVault.burnUsdx(burnAmount);
    vm.stopPrank();

    // Validate that the user's shares have not changed
    assertEq(fulfillmentVault.balanceOf(user), fBalance, "User should have the same balance in the fulfillmentVault");

    // Validate that the fulfillmentVault is now holding usdt (dust amount of usdh is omitted because it can get rounded down to 0)
    assertGt(usdt.balanceOf(address(fulfillmentVault)), 0, "FulfillmentVault should be holding usdt");
  }

  function test_withdrawUsdTokenFromUsdx_revertsWhenDoesNotHaveKeeperRole(address caller, address usdToken, uint256 amount) public {
    // Ensure the caller does not have the KEEPER_ROLE
    vm.assume(fulfillmentVault.hasRole(fulfillmentVault.KEEPER_ROLE(), caller) == false);

    // Attempt to call withdrawUsdTokenFromUsdx() without the KEEPER_ROLE
    vm.startPrank(caller);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, fulfillmentVault.KEEPER_ROLE()));
    fulfillmentVault.withdrawUsdTokenFromUsdx(usdToken, amount);
    vm.stopPrank();
  }

  function test_withdrawUsdTokenFromUsdx_revertsWhenNotPaused(address usdToken, uint256 amount) public {
    // Validate that the fulfillmentVault is not paused
    assertFalse(fulfillmentVault.paused(), "FulfillmentVault should not be paused");

    // Attempt to call withdrawUsdTokenFromUsdx() when the fulfillmentVault is not paused
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector));
    fulfillmentVault.withdrawUsdTokenFromUsdx(usdToken, amount);
    vm.stopPrank();
  }

  function test_withdrawUsdTokenFromUsdx(uint128 depositAmount, uint128 withdrawAmount) public {
    // Ensure depositAmount is greater than $1
    depositAmount = uint128(bound(depositAmount, 1e6, type(uint128).max));

    // User deposits depositAmount of usdt into the fulfillmentVault (after wrapping it to usdx)
    vm.startPrank(user);
    {
      deal(address(usdt), user, depositAmount);
      usdt.approve(address(usdx), depositAmount);
      usdx.deposit(address(usdt), depositAmount);
      uint256 usdxAmount = usdx.convertAmount(address(usdt), depositAmount);
      usdx.approve(address(fulfillmentVault), usdxAmount);
      fulfillmentVault.deposit(address(usdx), usdxAmount);
    }
    vm.stopPrank();

    // Record the user's balance in the fulfillmentVault
    uint256 fBalance = fulfillmentVault.balanceOf(user);

    // Keeper pauses the fulfillmentVault
    vm.startPrank(keeper);
    fulfillmentVault.setPaused(true);
    vm.stopPrank();

    // Keeper calls withdrawFromUsdx() with withdrawAmount leq the deposited usdt amount, but greater than $1
    withdrawAmount = uint128(bound(withdrawAmount, 1e6, depositAmount));
    vm.startPrank(keeper);
    fulfillmentVault.withdrawUsdTokenFromUsdx(address(usdt), withdrawAmount);
    vm.stopPrank();

    // Validate that the user's shares have not changed
    assertEq(fulfillmentVault.balanceOf(user), fBalance, "User should have the same balance in the fulfillmentVault");

    // Validate that the fulfillmentVault is now holding usdt (can compare exact amount since we're withdrawing, not burning)
    assertEq(usdt.balanceOf(address(fulfillmentVault)), withdrawAmount, "FulfillmentVault should be holding the withdrawn usdt amount");
  }

  function test_bridgeUsdTokenToCore_revertsWhenDoesNotHaveKeeperRole(address caller, address usdToken, uint256 amount)
    public
  {
    // Ensure the caller does not have the KEEPER_ROLE
    vm.assume(fulfillmentVault.hasRole(fulfillmentVault.KEEPER_ROLE(), caller) == false);

    // Attempt to call bridgeUsdTokenToCore() without the KEEPER_ROLE
    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, fulfillmentVault.KEEPER_ROLE()
      )
    );
    fulfillmentVault.bridgeUsdTokenToCore(usdToken, amount);
    vm.stopPrank();
  }

  function test_bridgeUsdTokenToCore_revertsWhenNotPaused(address usdToken, uint256 amount) public {
    // Validate that the fulfillmentVault is not paused
    assertFalse(fulfillmentVault.paused(), "FulfillmentVault should not be paused");

    // Attempt to call bridgeUsdTokenToCore() when the fulfillmentVault is not paused
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector));
    fulfillmentVault.bridgeUsdTokenToCore(usdToken, amount);
    vm.stopPrank();
  }

  function test_bridgeUsdTokenToCore(uint128 usdxAmount) public {
    // Ensure usdxAmount is greater than $1 and leq to $100m
    usdxAmount = uint128(bound(usdxAmount, 1e18, 100e6 * 1e18));

    // User deposits usdt into the fulfillmentVault via usdx
    vm.startPrank(user);
    {
      uint256 usdtAmount = usdx.convertUnderlying(address(usdt), usdxAmount);
      deal(address(usdt), user, usdtAmount);
      usdt.approve(address(usdx), usdtAmount);
      usdx.deposit(address(usdt), usdtAmount);
      usdx.approve(address(fulfillmentVault), usdxAmount);
      fulfillmentVault.deposit(address(usdx), usdxAmount);
    }
    vm.stopPrank();

    // Keeper pauses the fulfillmentVault
    vm.startPrank(keeper);
    fulfillmentVault.setPaused(true);
    vm.stopPrank();

    // Keeper burns usdxAmount of usdx from the fulfillmentVault
    vm.startPrank(keeper);
    fulfillmentVault.burnUsdx(usdxAmount);
    vm.stopPrank();

    // Collect the usdt balance of the fulfillmentVault (won't equal $5 because some of the burnt usdx will be converted to usdh)
    uint256 usdtBalance = usdt.balanceOf(address(fulfillmentVault));

    // Keeper calls bridgeUsdTokenToCore() with token and amount
    vm.startPrank(keeper);
    fulfillmentVault.bridgeUsdTokenToCore(address(usdt), usdtBalance);
    vm.stopPrank();

    // Move to the next block,
    // Performing all queued CoreWriter and bridging actions
    CoreSimulatorLib.nextBlock();

    // Validate that the usdt balance of the fulfillmentVault has been bridged to core
    PrecompileLib.SpotBalance memory balance = PrecompileLib.spotBalance(address(fulfillmentVault), USDT_TOKEN_INDEX);

    PrecompileLib.TokenInfo memory tokenInfo = PrecompileLib.tokenInfo(USDT_TOKEN_INDEX);
    assertGt(balance.total, 0, "FulfillmentVault should have a balance of usdt on core");
    // Converting the 8-decimal sz on core to the 6-decimal precision of usdt on evm
    assertEq(
      uint256(balance.total) * (1e6) / (1e8),
      usdtBalance,
      "FulfillmentVault should have the same balance of usdt on core as it did before the bridge"
    );
  }

  function test_tradeOnCore_revertsWhenDoesNotHaveKeeperRole(address caller, uint32 asset, bool isBuy, uint32 limitPx, uint64 sz) public {
    // Ensure the caller does not have the KEEPER_ROLE
    vm.assume(fulfillmentVault.hasRole(fulfillmentVault.KEEPER_ROLE(), caller) == false);

    // Attempt to call tradeOnCore() without the KEEPER_ROLE
    vm.startPrank(caller);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, fulfillmentVault.KEEPER_ROLE()));
    fulfillmentVault.tradeOnCore(asset, isBuy, limitPx, sz);
    vm.stopPrank();
  }

  function test_tradeOnCore_revertsWhenNotPaused(uint32 asset, bool isBuy, uint32 limitPx, uint64 sz) public {
    // Validate that the fulfillmentVault is not paused
    assertFalse(fulfillmentVault.paused(), "FulfillmentVault should not be paused");

    // Keeper attempts to call tradeOnCore() when the fulfillmentVault is not paused
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector));
    fulfillmentVault.tradeOnCore(asset, isBuy, limitPx, sz);
    vm.stopPrank();
  }

  function test_tradeOnCore_sellUsdt(uint32 limitPx, uint64 sz, uint64 coreSpotBalance) public {
    // Ensure that coreSpotBalance is geq sz and both are geq 1e8 ( and also don't overflow)
    coreSpotBalance = uint64(bound(coreSpotBalance, 1e8, type(uint64).max/1e10));
    limitPx = 1e6;
    sz = uint64(bound(sz, 1e2, coreSpotBalance / 1e6));

    // Mock the spot px for USDT to be 1:1 with USDC
    mockSpotPx(USDT_TOKEN_INDEX, 1e6);

    // We assign a spot balance of coreSpotBalance to the fulfillmentVault on core
    hyperCore.forceSpotBalance(address(fulfillmentVault), USDT_TOKEN_INDEX, coreSpotBalance);

    // Validate that the fulfillmentVault has the coreSpotBalance on core
    PrecompileLib.SpotBalance memory balance = PrecompileLib.spotBalance(address(fulfillmentVault), USDT_TOKEN_INDEX);
    assertEq(balance.total, coreSpotBalance, "FulfillmentVault should have the coreSpotBalance on core");

    // Keeper pauses the fulfillmentVault
    vm.startPrank(keeper);
    fulfillmentVault.setPaused(true);
    vm.stopPrank();

    // Keeper calls tradeOnCore() with USDT_TOKEN_INDEX, false, limitPx, and sz
    vm.startPrank(keeper);
    fulfillmentVault.tradeOnCore(USDT_TOKEN_INDEX, false, limitPx, sz);
    vm.stopPrank();

    // Move to the next block,
    // Performing all queued CoreWriter and bridging actions
    CoreSimulatorLib.nextBlock();

    // Validate that the fulfillmentVault has a balance of usdc on core
    balance = PrecompileLib.spotBalance(address(fulfillmentVault), USDC_TOKEN_INDEX);
    assertEq(balance.total, uint256(sz) * 1e6, "FulfillmentVault should have a balance of usdc on core");
  }

  function test_fillOrder_revertsWhenDoesNotHaveKeeperRole(address caller, uint256 index, uint256[] memory hintPrevIds) public {
    // Ensure the caller does not have the KEEPER_ROLE
    vm.assume(fulfillmentVault.hasRole(fulfillmentVault.KEEPER_ROLE(), caller) == false);

    // Attempt to call fillOrder() without the KEEPER_ROLE
    vm.startPrank(caller);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, fulfillmentVault.KEEPER_ROLE()));
    fulfillmentVault.fillOrder(index, hintPrevIds);
    vm.stopPrank();
  }

  function test_fillOrder_revertsWhenNotPaused(uint256 index, uint256[] memory hintPrevIds) public {
    // Validate that the fulfillmentVault is not paused
    assertFalse(fulfillmentVault.paused(), "FulfillmentVault should not be paused");

    // Attempt to call fillOrder() when the fulfillmentVault is not paused
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector));
    fulfillmentVault.fillOrder(index, hintPrevIds);
    vm.stopPrank();
  }

  function test_fillOrder_completeFlow() public {
    // Deploying a new router
    Router router = new Router(address(whype), address(generalManager), address(pyth)); // Using btc as wrapped native token for testing
    // Run the approve functions on the router
    router.approveCollaterals();
    router.approveUsdTokens();

    // Lender uses router to deposit $100k of usdt into the origination pool
    {
      deal(address(usdt), lender, 100_000e6);
      vm.startPrank(lender);
      usdt.approve(address(router), 100_000e6);
      router.originationPoolDeposit(originationPoolScheduler.configIdAt(0), address(usdt), 100_000e6);
      vm.stopPrank();
    }

    // Confirm the origination pool has the $100k of usdt
    {
      assertEq(IUSDX(usdx).balanceOf(address(originationPool)), 100_000e18, "Origination pool should have the $100k of usdx");
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
          expiration: block.timestamp + 10 minutes // Add 5 minutes to account for the blocks moving
        }),
        mortgageId: "Mortgage - 001",
        collateral: address(whype),
        subConsol: address(whypeSubConsol),
        conversionQueues: new address[](0), // No conversion queue
        hasPaymentPlan: true // Has a payment plan
      });
    }

    // Borrower uses router to request a mortgage
    {
      // Calculate the amount of usdx to collect from the borrower
      (, uint256 requiredUsdxCollected,,) = router.calculateCollectedAmounts(creationRequest);
      // Mint the required usdt (NOT usdx) to the borrower and approve it to the router
      vm.startPrank(borrower);
      uint256 usdtAmount = router.convert(address(usdx), address(usdt), requiredUsdxCollected);
      deal(address(usdt), borrower, usdtAmount);
      usdt.approve(address(router), usdtAmount);
      router.requestMortgage{value: 0}(address(usdt), creationRequest, false, 2576e18);
      vm.stopPrank();
    }

    // User deposits 5k of usdx into the fulfillmentVault
    {
      vm.startPrank(user);
      uint256 usdtAmount = usdx.convertUnderlying(address(usdt), 5_000e18);
      deal(address(usdt), user, usdtAmount);
      usdt.approve(address(usdx), usdtAmount);
      usdx.deposit(address(usdt), usdtAmount);
      usdx.approve(address(fulfillmentVault), 5_000e18);
      fulfillmentVault.deposit(address(usdx), 5_000e18);
      vm.stopPrank();
    }

    // Keeper pauses the fulfillmentVault
    {
      vm.startPrank(keeper);
      fulfillmentVault.setPaused(true);
      vm.stopPrank();
    }

    // Keeper unwraps the usdx into usdt
    uint256 usdtAmount = usdx.convertUnderlying(address(usdt), 5_000e18);
    {
      vm.startPrank(keeper);
      fulfillmentVault.withdrawUsdTokenFromUsdx(address(usdt), usdtAmount);
      vm.stopPrank();
    }

    // Start recording vm logs to reduce the noise in the parser
    vm.recordLogs();

    // Keeper bridges usdt to core
    {
      vm.startPrank(keeper);
      fulfillmentVault.bridgeUsdTokenToCore(address(usdt), usdtAmount);
      vm.stopPrank();
    }

    // Move to the next block,
    // Performing all queued CoreWriter and bridging actions
    CoreSimulatorLib.nextBlock();

    // Mock the spot px for USDT to be 1:1 with USDC
    mockSpotPx(USDT_TOKEN_INDEX, 1e6);

    // Keeper trades usdt for usdc on core ($5050 usdt to usdc)
    {
      vm.startPrank(keeper);
      fulfillmentVault.tradeOnCore(USDT_TOKEN_INDEX, false, 1e6, 5000e2);
      vm.stopPrank();
    }

    // Move to the next block,
    // Performing all queued CoreWriter and bridging actions
    CoreSimulatorLib.nextBlock();

    // Validate that the fulfillmentVault has usdc on core
    {
      PrecompileLib.SpotBalance memory spotBalance = PrecompileLib.spotBalance(address(fulfillmentVault), USDC_TOKEN_INDEX);
      assertEq(spotBalance.total, 5_000e8, "FulfillmentVault should have 5_000 usdc on core");
    }

    // Mock the spot px for HYPE to be 50 USDC
    mockSpotPx(HYPE_TOKEN_INDEX, 50e6);

    // Keeper trades usdc to hype on core (buys hype with usdc)
    {
      vm.startPrank(keeper);
      fulfillmentVault.tradeOnCore(HYPE_TOKEN_INDEX, true, 50e6, 100e2);
      vm.stopPrank();
    }

    // Move to the next block,
    // Performing all queued CoreWriter and bridging actions
    CoreSimulatorLib.nextBlock();

    // Validate that the fulfillmentVault has hype on core
    {
      PrecompileLib.SpotBalance memory spotBalance = PrecompileLib.spotBalance(address(fulfillmentVault), HYPE_TOKEN_INDEX);
      assertEq(spotBalance.total, 100e8, "FulfillmentVault should have 100 hype on core");
    }

    // Keeper transfers hype to evm
    {
      vm.startPrank(keeper);
      fulfillmentVault.bridgeHypeFromCoreToEvm(100e18);
      vm.stopPrank();
    }

    // Move to the next block,
    // Performing all queued CoreWriter and bridging actions
    CoreSimulatorLib.nextBlock();
    
    // Keeper wraps the hype into whype
    {
      vm.startPrank(keeper);
      fulfillmentVault.wrapHype();
      vm.stopPrank();
    }

    // Keeper approves fulfillment vault's whype to the origination pool
    {
      vm.startPrank(keeper);
      fulfillmentVault.approveWhype();
      vm.stopPrank();
    }

    // Keeper fills the order from the order pool
    {
      uint256 index = 0;
      uint256[] memory hintPrevIds = new uint256[](0); // No hintPrevIds because no conversion queues
      vm.startPrank(keeper);
      fulfillmentVault.fillOrder(index, hintPrevIds);
      vm.stopPrank();
    }

    // Validate that the borrower has received the mortgage nft
    assertEq(mortgageNFT.ownerOf(1), borrower, "Borrower should have received the mortgage nft");
    assertEq(loanManager.getMortgagePosition(1).tokenId, 1, "Corresponding mortgage position should exist");

    // Validate that the fulfillmentVault now has ~5_050 usdx (started with 5k)
    assertApproxEqAbs(usdx.balanceOf(address(fulfillmentVault)), 5_050e18, 1000e18, "FulfillmentVault should have ~5_050 usdx");
  }
}
