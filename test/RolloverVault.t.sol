// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// forge-lint: disable-next-line(unused-import)
import {BaseTest, console} from "./BaseTest.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
  IRolloverVault,
  IRolloverVaultEvents,
  IRolloverVaultErrors
} from "../src/interfaces/IRolloverVault/IRolloverVault.sol";
import {RolloverVault} from "../src/RolloverVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {IOriginationPoolScheduler} from "@core/interfaces/IOriginationPoolScheduler/IOriginationPoolScheduler.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RolloverVaultTest is BaseTest {
  using Math for uint256;

  HyperCore public hyperCore;

  using PrecompileLib for address;

  string NAME = "Test Rollover Vault";
  string SYMBOL = "tRV";
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

  RolloverVault public rolloverVault;

  address public user = makeAddr("user");
  address public keeper = makeAddr("keeper");

  uint256 public PRIME_AMOUNT = 1e18; // The initial amount of depositableAsset to prime the liquidityVault with (in depositableAsset decimals)

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

  function setUp() public {
    // Setup core
    setUpCore();

    // Deploy the rolloverVault
    RolloverVault rolloverVaultImplementation = new RolloverVault();
    bytes memory initializerData = abi.encodeWithSelector(
      RolloverVault.initialize.selector,
      NAME,
      SYMBOL,
      DECIMALS,
      DECIMALS_OFFSET,
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

    // Force the rolloverVault to be activated on hypercore
    vm.mockCall(HLConstants.CORE_USER_EXISTS_PRECOMPILE_ADDRESS, abi.encode(address(rolloverVault)), abi.encode(true));
    CoreSimulatorLib.forceAccountActivation(address(rolloverVault));

    // Force activate the HYPE system address so bridging works
    vm.mockCall(
      HLConstants.CORE_USER_EXISTS_PRECOMPILE_ADDRESS, abi.encode(HLConstants.HYPE_SYSTEM_ADDRESS), abi.encode(true)
    );
    CoreSimulatorLib.forceAccountActivation(0x2222222222222222222222222222222222222222);
  }

  function test_initialize() public {
    CoreSimulatorLib.forceSpotBalance(address(rolloverVault), USDT_TOKEN_INDEX, 0);
    assertEq(rolloverVault.name(), NAME);
    assertEq(rolloverVault.symbol(), SYMBOL);
    assertEq(rolloverVault.decimals(), DECIMALS);
    assertEq(rolloverVault.decimalsOffset(), DECIMALS_OFFSET);
    assertEq(rolloverVault.totalAssets(), PRIME_AMOUNT);
    assertEq(rolloverVault.totalSupply(), PRIME_AMOUNT * (10 ** DECIMALS_OFFSET));
    assertEq(rolloverVault.depositableAssets()[0], address(usdx));
    assertEq(rolloverVault.redeemableAssets()[0], address(usdx));
    assertEq(rolloverVault.redeemableAssets()[1], address(consol));
    assertEq(rolloverVault.usdx(), address(usdx));
    assertEq(rolloverVault.consol(), address(consol));
    assertEq(rolloverVault.generalManager(), address(generalManager));
    assertEq(rolloverVault.originationPoolScheduler(), address(originationPoolScheduler));
    assertEq(rolloverVault.originationPools().length, 0);
    assertTrue(rolloverVault.hasRole(rolloverVault.DEFAULT_ADMIN_ROLE(), admin));
  }

  function test_supportedInterfaces_valid() public view {
    // Test all interfaces that RolloverVault implements
    assertTrue(rolloverVault.supportsInterface(type(ILiquidityVault).interfaceId), "Should support ILiquidityVault");
    assertTrue(rolloverVault.supportsInterface(type(IRolloverVault).interfaceId), "Should support IRolloverVault");
    assertTrue(rolloverVault.supportsInterface(type(IERC165).interfaceId), "Should support IERC165");
    assertTrue(rolloverVault.supportsInterface(type(IAccessControl).interfaceId), "Should support IAccessControl");
    assertTrue(rolloverVault.supportsInterface(type(IERC1822Proxiable).interfaceId), "Should support IERC1822Proxiable");
    assertTrue(rolloverVault.supportsInterface(type(IERC20).interfaceId), "Should support IERC20");
    assertTrue(rolloverVault.supportsInterface(type(IERC20Metadata).interfaceId), "Should support IERC20Metadata");
  }

  function test_supportedInterfaces_invalid(bytes4 interfaceId) public view {
    // Make sure it's not one of the valid interfaces
    vm.assume(
      interfaceId != type(ILiquidityVault).interfaceId && interfaceId != type(IRolloverVault).interfaceId
        && interfaceId != type(IERC165).interfaceId && interfaceId != type(IAccessControl).interfaceId
        && interfaceId != type(IERC1822Proxiable).interfaceId && interfaceId != type(IERC20).interfaceId
        && interfaceId != type(IERC20Metadata).interfaceId
    );
    assertFalse(rolloverVault.supportsInterface(interfaceId), "Should not support invalid interface");
  }

  function test_depositOriginationPool_revertsWhenDoesNotHaveKeeperRole(
    address caller,
    address originationPool,
    uint256 amount
  ) public {
    // Ensure the caller does not have the KEEPER_ROLE
    vm.assume(rolloverVault.hasRole(rolloverVault.KEEPER_ROLE(), caller) == false);

    // Attempt to call depositOriginationPool() without the KEEPER_ROLE
    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, rolloverVault.KEEPER_ROLE()
      )
    );
    rolloverVault.depositOriginationPool(originationPool, amount);
    vm.stopPrank();
  }

  function test_depositOriginationPool_revertsWhenNotPaused(address originationPool, uint256 amount) public {
    // Validate that the rolloverVault is not paused
    assertFalse(rolloverVault.paused(), "RolloverVault should not be paused");

    // Keeper attempts to call depositOriginationPool() when the rolloverVault is not paused
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector));
    rolloverVault.depositOriginationPool(originationPool, amount);
    vm.stopPrank();
  }

  function test_depositOriginationPool_revertsWhenOriginationPoolNotRegistered(address originationPool, uint256 amount)
    public
  {
    // Ensure the origination pool is not registered
    vm.assume(IOriginationPoolScheduler(originationPoolScheduler).isRegistered(originationPool) == false);

    // Keeper pauses the rolloverVault
    vm.startPrank(keeper);
    rolloverVault.setPaused(true);
    vm.stopPrank();

    // Keeper attempts to call depositOriginationPool() when the origination pool is not registered
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IRolloverVaultErrors.OriginationPoolNotRegistered.selector, originationPool));
    rolloverVault.depositOriginationPool(originationPool, amount);
    vm.stopPrank();
  }

  function test_depositOriginationPool_revertsWhenAmountIsZero(address originationPool) public {
    // Ensure the origination pool is registered
    {
      vm.startPrank(admin);
      IOriginationPoolScheduler(originationPoolScheduler).updateRegistration(originationPool, true);
      vm.stopPrank();
    }

    // Keeper pauses the rolloverVault
    vm.startPrank(keeper);
    rolloverVault.setPaused(true);
    vm.stopPrank();

    // Keeper attempts to call depositOriginationPool() when the amount is zero
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IRolloverVaultErrors.AmountIsZero.selector));
    rolloverVault.depositOriginationPool(originationPool, 0);
    vm.stopPrank();
  }

  function test_depositOriginationPool_completeFlow(uint256 depositAmount) public {
    // Ensure the depositAmount is at least $1 but less than the origination pool limit
    depositAmount = uint256(bound(depositAmount, 1e18, originationPool.poolLimit()));

    // User deposits depositAmount of usdx into the rolloverVault
    {
      vm.startPrank(user);
      uint256 usdtAmount = usdx.convertUnderlying(address(usdt), depositAmount);
      deal(address(usdt), user, usdtAmount);
      usdt.approve(address(usdx), usdtAmount);
      usdx.deposit(address(usdt), usdtAmount);
      usdx.approve(address(rolloverVault), depositAmount);
      rolloverVault.deposit(address(usdx), depositAmount);
      vm.stopPrank();
    }

    // Record the user's balance in the rolloverVault, as well as total assets in the rolloverVault
    uint256 userBalanceBefore = rolloverVault.balanceOf(user);
    uint256 totalAssetsBefore = rolloverVault.totalAssets();

    // Keeper pauses the rolloverVault
    vm.startPrank(keeper);
    rolloverVault.setPaused(true);
    vm.stopPrank();

    // Keeper deposits the entire usdx balance into the origination pool
    vm.startPrank(keeper);
    vm.expectEmit(true, true, true, true);
    emit IRolloverVaultEvents.OriginationPoolAdded(address(originationPool));
    vm.expectEmit(true, true, true, true);
    emit IRolloverVaultEvents.OriginationPoolDeposited(address(originationPool), depositAmount);
    rolloverVault.depositOriginationPool(address(originationPool), depositAmount);
    vm.stopPrank();

    // Verify the user's balance and the total assets in the rolloverVault have not changed
    assertEq(rolloverVault.balanceOf(user), userBalanceBefore, "User's balance should not have changed");
    assertEq(rolloverVault.totalAssets(), totalAssetsBefore, "Total assets should not have changed");

    // Verify the origination pool is tracked
    assertTrue(rolloverVault.isTracked(address(originationPool)), "Origination pool should be tracked");
    assertEq(rolloverVault.originationPools().length, 1, "Origination pool should be tracked");
    assertEq(rolloverVault.originationPools()[0], address(originationPool), "Origination pool should be the first one");

    // Verify that the rolloverVault has the origination pool's balance
    assertEq(
      originationPool.balanceOf(address(rolloverVault)),
      depositAmount,
      "RolloverVault should have the origination pool's balance"
    );
    assertEq(
      usdx.balanceOf(address(rolloverVault)),
      1e18,
      "RolloverVault should have no usdx balance (only has the prime amount of $1)"
    );
  }

  function test_redeemOriginationPool_revertsWhenDoesNotHaveKeeperRole(address caller, address originationPool) public {
    // Ensure the caller does not have the KEEPER_ROLE
    vm.assume(rolloverVault.hasRole(rolloverVault.KEEPER_ROLE(), caller) == false);

    // Attempt to call redeemOriginationPool() without the KEEPER_ROLE
    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, rolloverVault.KEEPER_ROLE()
      )
    );
    rolloverVault.redeemOriginationPool(originationPool);
    vm.stopPrank();
  }

  function test_redeemOriginationPool_revertsWhenNotPaused(address originationPool) public {
    // Validate that the rolloverVault is not paused
    assertFalse(rolloverVault.paused(), "RolloverVault should not be paused");

    // Keeper attempts to call redeemOriginationPool() when the rolloverVault is not paused
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector));
    rolloverVault.redeemOriginationPool(originationPool);
    vm.stopPrank();
  }

  function test_redeemOriginationPool_revertsWhenOriginationPoolNotTracked(address originationPool) public {
    // Ensure the origination pool is not tracked
    assertFalse(rolloverVault.isTracked(originationPool), "Origination pool should not be tracked");

    // Keeper pauses the rolloverVault
    vm.startPrank(keeper);
    rolloverVault.setPaused(true);
    vm.stopPrank();

    // Keeper attempts to call redeemOriginationPool() when the origination pool is not tracked
    vm.startPrank(keeper);
    vm.expectRevert(abi.encodeWithSelector(IRolloverVaultErrors.OriginationPoolNotTracked.selector, originationPool));
    rolloverVault.redeemOriginationPool(originationPool);
    vm.stopPrank();
  }

  function test_redeemOriginationPool_completeFlow(uint256 depositAmount) public {
    // Ensure the depositAmount is at least $1 but less than the origination pool limit
    depositAmount = uint256(bound(depositAmount, 1e18, originationPool.poolLimit()));

    // User deposits depositAmount of usdx into the rolloverVault
    {
      vm.startPrank(user);
      uint256 usdtAmount = usdx.convertUnderlying(address(usdt), depositAmount);
      deal(address(usdt), user, usdtAmount);
      usdt.approve(address(usdx), usdtAmount);
      usdx.deposit(address(usdt), usdtAmount);
      usdx.approve(address(rolloverVault), depositAmount);
      rolloverVault.deposit(address(usdx), depositAmount);
      vm.stopPrank();
    }

    // Check that redeemable assets are set correctly
    {
      assertEq(rolloverVault.redeemableAssets().length, 2, "RolloverVault should have 2 redeemable assets");
      assertEq(
        rolloverVault.redeemableAssets()[0],
        address(usdx),
        "RolloverVault should have usdx as the first redeemable asset"
      );
      assertEq(
        rolloverVault.redeemableAssets()[1],
        address(consol),
        "RolloverVault should have consol as the second redeemable asset"
      );
    }

    // Keeper pauses the rolloverVault and deposits the entire usdx balance into the origination pool
    {
      vm.startPrank(keeper);
      rolloverVault.setPaused(true);
      rolloverVault.depositOriginationPool(address(originationPool), depositAmount);
      vm.stopPrank();
    }

    // Check that redeemable assets have been updated correctly
    {
      assertEq(rolloverVault.redeemableAssets().length, 3, "RolloverVault should have 3 redeemable assets");
      assertEq(
        rolloverVault.redeemableAssets()[0],
        address(usdx),
        "RolloverVault should have usdx as the first redeemable asset"
      );
      assertEq(
        rolloverVault.redeemableAssets()[1],
        address(consol),
        "RolloverVault should have consol as the second redeemable asset"
      );
      assertEq(
        rolloverVault.redeemableAssets()[2],
        address(originationPool),
        "RolloverVault should have the origination pool as the third redeemable asset"
      );
    }

    // Skip time ahead to the origination pool's redemption period
    vm.warp(originationPool.redemptionPhaseTimestamp());

    // Keeper redeems the entire origination pool balance
    vm.startPrank(keeper);
    vm.expectEmit(true, true, true, true);
    emit IRolloverVaultEvents.OriginationPoolRedeemed(address(originationPool), depositAmount);
    rolloverVault.redeemOriginationPool(address(originationPool));
    vm.stopPrank();

    // Check that redeemable assets have been updated correctly
    {
      assertEq(rolloverVault.redeemableAssets().length, 2, "RolloverVault should have 2 redeemable assets");
      assertEq(
        rolloverVault.redeemableAssets()[0],
        address(usdx),
        "RolloverVault should have usdx as the first redeemable asset"
      );
      assertEq(
        rolloverVault.redeemableAssets()[1],
        address(consol),
        "RolloverVault should have consol as the second redeemable asset"
      );
    }

    // Validate that the origination pool has been removed
    assertFalse(rolloverVault.isTracked(address(originationPool)), "Origination pool should not be tracked");
    assertEq(rolloverVault.originationPools().length, 0, "Origination pool should not be tracked");
    assertEq(originationPool.balanceOf(address(rolloverVault)), 0, "Origination pool should have no balance");
  }

  function test_totalAssets_whileTrackingOriginationPool(uint256 depositAmount) public {
    // Ensure the depositAmount is at least $1 but less than the origination pool limit
    depositAmount = uint256(bound(depositAmount, 1e18, originationPool.poolLimit()));

    // User deposits depositAmount of usdx into the rolloverVault
    {
      vm.startPrank(user);
      uint256 usdtAmount = usdx.convertUnderlying(address(usdt), depositAmount);
      deal(address(usdt), user, usdtAmount);
      usdt.approve(address(usdx), usdtAmount);
      usdx.deposit(address(usdt), usdtAmount);
      usdx.approve(address(rolloverVault), depositAmount);
      rolloverVault.deposit(address(usdx), depositAmount);
      vm.stopPrank();
    }

    // Query total assets in the rolloverVault
    uint256 totalAssetsBefore = rolloverVault.totalAssets();

    // Keeper pauses the rolloverVault and deposits the entire usdx balance into the origination pool
    {
      vm.startPrank(keeper);
      rolloverVault.setPaused(true);
      rolloverVault.depositOriginationPool(address(originationPool), depositAmount);
      vm.stopPrank();
    }

    // Query total assets in the rolloverVault
    uint256 totalAssetsAfter = rolloverVault.totalAssets();

    // Validate that total assets have not changed
    assertEq(totalAssetsAfter, totalAssetsBefore, "Total assets should not have changed");
  }

  function test_withdraw_whileTrackingOriginationPool(uint256 depositAmount) public {
    // Ensure the depositAmount is at least $1 but less than the origination pool limit
    depositAmount = uint256(bound(depositAmount, 1e18, originationPool.poolLimit()));

    // Validate that the user has 0 usdx balance to start with
    assertEq(usdx.balanceOf(user), 0, "User should have 0 usdx balance to start with");

    // User deposits depositAmount of usdx into the rolloverVault
    {
      vm.startPrank(user);
      uint256 usdtAmount = usdx.convertUnderlying(address(usdt), depositAmount);
      deal(address(usdt), user, usdtAmount);
      usdt.approve(address(usdx), usdtAmount);
      usdx.deposit(address(usdt), usdtAmount);
      usdx.approve(address(rolloverVault), usdx.balanceOf(user));
      rolloverVault.deposit(address(usdx), usdx.balanceOf(user));
      vm.stopPrank();
    }

    // Validate that the user has 0 usdx balance
    assertEq(usdx.balanceOf(user), 0, "User should have 0 usdx balance");

    // Keeper pauses the rolloverVault and deposits the entire usdx balance into the origination pool
    {
      vm.startPrank(keeper);
      rolloverVault.setPaused(true);
      rolloverVault.depositOriginationPool(address(originationPool), depositAmount);
      vm.stopPrank();
    }

    // Keeper unpauses the rolloverVault
    {
      vm.startPrank(keeper);
      rolloverVault.setPaused(false);
      vm.stopPrank();
    }

    // Calculate expected redemption amounts
    uint256 expectedUsdxRedemption =
      Math.mulDiv(rolloverVault.balanceOf(user), usdx.balanceOf(address(rolloverVault)), rolloverVault.totalSupply());
    uint256 expectedOgpRedemption = Math.mulDiv(
      rolloverVault.balanceOf(user), originationPool.balanceOf(address(rolloverVault)), rolloverVault.totalSupply()
    );

    // Expected total assets amount
    uint256 expectedTotalAssets =
      Math.mulDiv(rolloverVault.balanceOf(user), rolloverVault.totalAssets(), rolloverVault.totalSupply());

    // User withdraws their entire balance of the rolloverVault
    {
      vm.startPrank(user);
      rolloverVault.redeem(rolloverVault.balanceOf(user));
      vm.stopPrank();
    }

    // Validate that the user has the expected redemption amounts
    assertApproxEqAbs(
      usdx.balanceOf(user),
      expectedUsdxRedemption,
      1,
      "User should get expectedUsdxRedemption usdx out of the rolloverVault"
    );
    assertApproxEqAbs(
      originationPool.balanceOf(user),
      expectedOgpRedemption,
      1,
      "User should get expectedOgpRedemption origination pool out of the rolloverVault"
    );

    // Skip ahead to the origination pool's redemption period
    vm.warp(originationPool.redemptionPhaseTimestamp());

    // User redeems the entire origination pool balance
    {
      vm.startPrank(user);
      originationPool.redeem(originationPool.balanceOf(user));
      vm.stopPrank();
    }

    // Validate that the user has the expected redemption amounts
    assertEq(originationPool.balanceOf(user), 0, "User should have 0 origination pool balance");
    assertApproxEqAbs(usdx.balanceOf(user), expectedTotalAssets, 1, "User should have expectedTotalAssets of usdx");
  }
}
