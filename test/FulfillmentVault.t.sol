// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USDX} from "@core/USDX.sol";
import {IUSDX} from "@core/interfaces/IUSDX/IUSDX.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
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

contract FulfillmentVaultTest is BaseTest {

  string NAME = "Test Fulfillment Vault";
  string SYMBOL = "Test Fulfillment Vault";
  uint8 DECIMALS = 26; // ToDo: Make this 8 + usdx decimals????
  uint8 DECIMALS_OFFSET = 8;

  FulfillmentVault public fulfillmentVault;

  address public user = makeAddr("user");
  address public keeper = makeAddr("keeper");

  uint256 public PRIME_AMOUNT = 1e18; // The initial amount of depositableAsset to prime the liquidityVault with (in depositableAsset decimals)

  // function setupUsdx() public {
  //   vm.startPrank(admin);
  //   usdx = new USDX(USDX_NAME, USDX_SYMBOL, USDX_DECIMALS_OFFSET, admin);
  //   usdt0 = new MockERC20("USDT0", "USDT0", 6);
  //   vm.label(address(usdt0), "USDT0");
  //   usdh = new MockERC20("USDH", "USDH", 6);
  //   vm.label(address(usdh), "USDH");

  //   // Grant the admin the supported token role so it can add usdt0 and usdh to USDX
  //   USDX(address(usdx)).grantRole(Roles.SUPPORTED_TOKEN_ROLE, admin);
  //   usdx.addSupportedToken(address(usdt0), 1e12, 1);
  //   usdx.addSupportedToken(address(usdh), 1e12, 1);
  //   vm.stopPrank();
  // }

  function primeFulfillmentVault() public {
    // Mint 0.5 PRIME_AMOUNT of usdt0 and usdh to the admin
    vm.startPrank(admin);
    MockERC20(address(usdt)).mint(admin, PRIME_AMOUNT / 2);
    MockERC20(address(usdh)).mint(admin, PRIME_AMOUNT / 2);
    vm.stopPrank();

    // Admin primes the fulfillmentVault with PRIME_AMOUNT of usdx
    vm.startPrank(admin);
    usdt.approve(address(usdx), PRIME_AMOUNT / 2);
    usdh.approve(address(usdx), PRIME_AMOUNT / 2);
    usdx.deposit(address(usdt), PRIME_AMOUNT / 2);
    usdx.deposit(address(usdh), PRIME_AMOUNT / 2);
    usdx.approve(address(fulfillmentVault), PRIME_AMOUNT);
    fulfillmentVault.deposit(PRIME_AMOUNT);
    vm.stopPrank();

    // Transfer the fulfillmentVault balance to the fulfillmentVault itself
    vm.startPrank(admin);
    fulfillmentVault.transfer(address(fulfillmentVault), fulfillmentVault.balanceOf(admin));
    vm.stopPrank();
  }

  function setUp() public {
    // Setup core
    setUpCore();

    // Deploy the fulfillmentVault
    FulfillmentVault fulfillmentVaultImplementation = new FulfillmentVault();
    bytes memory initializerData = abi.encodeWithSelector(FulfillmentVault.initialize.selector, NAME, SYMBOL, DECIMALS, DECIMALS_OFFSET, address(usdx), address(whype), address(orderPool));
    vm.startPrank(admin);
    ERC1967Proxy proxy = new ERC1967Proxy(address(fulfillmentVaultImplementation), initializerData);
    vm.stopPrank();
    fulfillmentVault = FulfillmentVault(address(proxy));

    // Prime the fulfillmentVault
    primeFulfillmentVault();

    // Grant the keeper the KEEPER_ROLE
    vm.startPrank(admin);
    fulfillmentVault.grantRole(fulfillmentVault.KEEPER_ROLE(), keeper);
    vm.stopPrank();
  }

  function test_initialize() public view {
    assertEq(fulfillmentVault.name(), NAME);
    assertEq(fulfillmentVault.symbol(), SYMBOL);
    assertEq(fulfillmentVault.decimals(), DECIMALS);
    assertEq(fulfillmentVault.decimalsOffset(), DECIMALS_OFFSET);
    assertEq(fulfillmentVault.totalAssets(), PRIME_AMOUNT);
    assertEq(fulfillmentVault.totalSupply(), PRIME_AMOUNT * (10 ** DECIMALS_OFFSET));
    assertEq(fulfillmentVault.depositableAsset(), address(usdx));
    assertEq(fulfillmentVault.redeemableAsset(), address(usdx));
    assertEq(fulfillmentVault.wrappedNativeToken(), address(whype));
    assertEq(fulfillmentVault.orderPool(), address(orderPool));
    assertEq(fulfillmentVault.nonce(), 0);
    assertTrue(fulfillmentVault.hasRole(fulfillmentVault.DEFAULT_ADMIN_ROLE(), admin));
  }

  function test_supportedInterfaces_valid() public view {
    // Test all interfaces that FulfillmentVault implements
    assertTrue(fulfillmentVault.supportsInterface(type(ILiquidityVault).interfaceId), "Should support ILiquidityVault");
    assertTrue(fulfillmentVault.supportsInterface(type(IFulfillmentVault).interfaceId), "Should support IFulfillmentVault");
    assertTrue(fulfillmentVault.supportsInterface(type(IERC165).interfaceId), "Should support IERC165");
    assertTrue(fulfillmentVault.supportsInterface(type(IAccessControl).interfaceId), "Should support IAccessControl");
    assertTrue(fulfillmentVault.supportsInterface(type(IERC1822Proxiable).interfaceId), "Should support IERC1822Proxiable");
    assertTrue(fulfillmentVault.supportsInterface(type(IERC20).interfaceId), "Should support IERC20");
    assertTrue(fulfillmentVault.supportsInterface(type(IERC20Metadata).interfaceId), "Should support IERC20Metadata"); 
  }

  function test_supportedInterfaces_invalid(bytes4 interfaceId) public view {
    // Make sure it's not one of the valid interfaces
    vm.assume(interfaceId != type(ILiquidityVault).interfaceId && interfaceId != type(IFulfillmentVault).interfaceId && interfaceId != type(IERC165).interfaceId && interfaceId != type(IAccessControl).interfaceId && interfaceId != type(IERC1822Proxiable).interfaceId && interfaceId != type(IERC20).interfaceId && interfaceId != type(IERC20Metadata).interfaceId);
    assertFalse(fulfillmentVault.supportsInterface(interfaceId), "Should not support invalid interface");
  }

  function test_burnUsdx_revertsWhenDoesNotHaveKeeperRole(address caller, uint256 amount) public {
    // Ensure the caller does not have the KEEPER_ROLE
    vm.assume(fulfillmentVault.hasRole(fulfillmentVault.KEEPER_ROLE(), caller) == false);

    // Attempt to call burnUsdx() without the KEEPER_ROLE
    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, fulfillmentVault.KEEPER_ROLE())
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

  function test_burnUsdx(uint128 depositAmount, uint128 burnAmount) public {
    // Ensure depositAmount is greater than $1
    depositAmount = uint128(bound(depositAmount, 1e18, type(uint128).max));

    // User deposits depositAmount of usdx into the fulfillmentVault
    vm.startPrank(user);
    {
      uint256 usdtAmount = usdx.convertUnderlying(address(usdt), depositAmount);
      MockERC20(address(usdt)).mint(user, usdtAmount);
      usdt.approve(address(usdx), usdtAmount);
      usdx.deposit(address(usdt), usdtAmount);
      usdx.approve(address(fulfillmentVault), depositAmount);
      fulfillmentVault.deposit(depositAmount);
    }
    vm.stopPrank();

    // Record the user's balance in the fulfillmentVault
    uint256 fBalance = fulfillmentVault.balanceOf(user);

    // Keeper pauses the fulfillmentVault
    vm.startPrank(keeper);
    fulfillmentVault.setPaused(true);
    vm.stopPrank();

    // Keeper calls burnUsdx() with usdxAmount leq the deposited usdx amount, but greater than $1
    burnAmount = uint128(bound(burnAmount, 1e18, depositAmount));
    vm.startPrank(keeper);
    fulfillmentVault.burnUsdx(burnAmount);
    vm.stopPrank();

    // Validate that the user's shares have not changed
    assertEq(fulfillmentVault.balanceOf(user), fBalance, "User should have the same balance in the fulfillmentVault");

    // Validate that the fulfillmentVault is now holding usdt (dust amount of usdh is omitted because it can get rounded down to 0)
    assertGt(usdt.balanceOf(address(fulfillmentVault)), 0, "FulfillmentVault should be holding usdt");
  }
  
}
