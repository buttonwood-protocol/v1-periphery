// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {LiquidityVault} from "../src/LiquidityVault.sol";
import {ILiquidityVault, ILiquidityVaultErrors} from "../src/interfaces/ILiquidityVault/ILiquidityVault.sol";
import {MockLiquidityVault} from "./mocks/MockLiquidityVault.sol";
import {MockLiquidityVault2} from "./mocks/MockLiquidityVault2.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract LiquidityVaultTest is Test {
  string NAME = "Test Liquidity Vault";
  string SYMBOL = "TLV";
  uint8 DECIMALS = 26; // ToDo: Make this 8 + depositableAsset decimals????
  uint8 DECIMALS_OFFSET = 8;
  IERC20 depositableAsset;
  IERC20 redeemableAsset;

  LiquidityVault public liquidityVault;

  address public admin = makeAddr("admin");
  address public user = makeAddr("user");
  address public keeper = makeAddr("keeper");

  uint256 public PRIME_AMOUNT = 1e18; // The initial amount of depositableAsset to prime the liquidityVault with (in depositableAsset decimals)

  function primeLiquidityVault() public {
    // Admin primes the liquidityVault with PRIME_AMOUNT of depositableAsset
    vm.startPrank(admin);
    MockERC20(address(depositableAsset)).mint(admin, PRIME_AMOUNT);
    depositableAsset.approve(address(liquidityVault), PRIME_AMOUNT);
    liquidityVault.deposit(address(depositableAsset), PRIME_AMOUNT);
    vm.stopPrank();

    // Transfer the liquidityVault balance to the liquidityVault itself
    vm.startPrank(admin);
    liquidityVault.transfer(address(liquidityVault), liquidityVault.balanceOf(admin));
    vm.stopPrank();
  }

  function setUp() public {
    // Set up the mock assets
    depositableAsset = new MockERC20("Depositable Asset", "DA", 18);
    vm.label(address(depositableAsset), "Depositable Asset");
    address[] memory depositableAssets = new address[](1);
    depositableAssets[0] = address(depositableAsset);
    redeemableAsset = new MockERC20("Redeemable Asset", "RA", 18);
    vm.label(address(redeemableAsset), "Redeemable Asset");
    address[] memory redeemableAssets = new address[](1);
    redeemableAssets[0] = address(redeemableAsset);

    MockLiquidityVault liquidityVaultImplementation = new MockLiquidityVault();
    bytes memory initializerData = abi.encodeWithSelector(
      LiquidityVault.initialize.selector,
      NAME,
      SYMBOL,
      DECIMALS,
      DECIMALS_OFFSET,
      depositableAssets,
      redeemableAssets,
      address(admin)
    );
    ERC1967Proxy proxy = new ERC1967Proxy(address(liquidityVaultImplementation), initializerData);
    liquidityVault = LiquidityVault(address(proxy));

    // Prime the liquidityVault
    primeLiquidityVault();

    // Grant the keeper the KEEPER_ROLE
    vm.startPrank(admin);
    liquidityVault.grantRole(liquidityVault.KEEPER_ROLE(), keeper);
    vm.stopPrank();
  }

  function test_initialize() public view {
    assertEq(liquidityVault.name(), NAME);
    assertEq(liquidityVault.symbol(), SYMBOL);
    assertEq(liquidityVault.decimals(), DECIMALS);
    assertEq(liquidityVault.decimalsOffset(), DECIMALS_OFFSET);
    assertEq(liquidityVault.totalAssets(), PRIME_AMOUNT);
    assertEq(liquidityVault.totalSupply(), PRIME_AMOUNT * (10 ** DECIMALS_OFFSET));
    assertEq(liquidityVault.depositableAssets()[0], address(depositableAsset));
    assertEq(liquidityVault.redeemableAssets()[0], address(redeemableAsset));
    assertTrue(liquidityVault.hasRole(liquidityVault.DEFAULT_ADMIN_ROLE(), admin));
  }

  function test_supportedInterfaces_valid() public view {
    // Test all interfaces that LiquidityVault implements
    assertTrue(liquidityVault.supportsInterface(type(ILiquidityVault).interfaceId), "Should support ILiquidityVault");
    assertTrue(liquidityVault.supportsInterface(type(IERC165).interfaceId), "Should support IERC165");
    assertTrue(liquidityVault.supportsInterface(type(IAccessControl).interfaceId), "Should support IAccessControl");
    assertTrue(
      liquidityVault.supportsInterface(type(IERC1822Proxiable).interfaceId), "Should support IERC1822Proxiable"
    );
    assertTrue(liquidityVault.supportsInterface(type(IERC20).interfaceId), "Should support IERC20");
    assertTrue(liquidityVault.supportsInterface(type(IERC20Metadata).interfaceId), "Should support IERC20Metadata");
  }

  function test_supportedInterfaces_invalid(bytes4 interfaceId) public view {
    // Make sure it's not one of the valid interfaces
    vm.assume(
      interfaceId != type(ILiquidityVault).interfaceId && interfaceId != type(IERC165).interfaceId
        && interfaceId != type(IAccessControl).interfaceId && interfaceId != type(IERC1822Proxiable).interfaceId
        && interfaceId != type(IERC20).interfaceId && interfaceId != type(IERC20Metadata).interfaceId
    );
    assertFalse(liquidityVault.supportsInterface(interfaceId), "Should not support invalid interface");
  }

  function test_upgradeTo_revertWhenNotAdmin(address caller) public {
    // Make sure caller is not admin
    vm.assume(caller != admin);

    // Make a new implementation
    MockLiquidityVault2 newImplementation = new MockLiquidityVault2();

    // Attempt to upgrade to the new implementation as a non-admin
    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, liquidityVault.DEFAULT_ADMIN_ROLE()
      )
    );
    liquidityVault.upgradeToAndCall(address(newImplementation), "");
    vm.stopPrank();
  }

  function test_upgradeTo_isAdmin(bytes32 salt) public {
    // Make a new implementation
    MockLiquidityVault2 newImplementation = new MockLiquidityVault2{salt: salt}();

    // Attempt to upgrade to the new implementation as a non-admin
    vm.startPrank(admin);
    liquidityVault.upgradeToAndCall(address(newImplementation), "");
    vm.stopPrank();

    // Validate that liquidityVault now has the new implementation functions
    assertTrue(
      MockLiquidityVault2(address(liquidityVault)).newFunction(),
      "liquidityVault should have the new implementation functions"
    );
  }

  function test_setPaused_revertWhenNotKeeper(address caller) public {
    // Make sure caller does not have the KEEPER_ROLE
    vm.assume(!liquidityVault.hasRole(liquidityVault.KEEPER_ROLE(), caller));

    // Attempt to set paused as a non-admin
    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, liquidityVault.KEEPER_ROLE()
      )
    );
    liquidityVault.setPaused(true);
    vm.stopPrank();
  }

  function test_setPaused_isKeeper(address caller) public {
    // Grant the caller the KEEPER_ROLE
    vm.startPrank(admin);
    liquidityVault.grantRole(liquidityVault.KEEPER_ROLE(), caller);
    vm.stopPrank();

    // Caller pauses the liquidityVault
    vm.startPrank(caller);
    liquidityVault.setPaused(true);
    vm.stopPrank();

    // Validate that the liquidityVault is paused
    assertTrue(liquidityVault.paused(), "liquidityVault should be paused");

    // Caller unpauses the liquidityVault
    vm.startPrank(caller);
    liquidityVault.setPaused(false);
    vm.stopPrank();

    // Validate that the liquidityVault is not paused
    assertFalse(liquidityVault.paused(), "liquidityVault should not be paused");
  }

  function test_setWhitelistEnforced_revertWhenNotAdmin(address caller, bool whitelistEnforced) public {
    // Ensure the caller does not have the DEFAULT_ADMIN_ROLE
    vm.assume(!liquidityVault.hasRole(liquidityVault.DEFAULT_ADMIN_ROLE(), caller));

    // Attempt to set whitelist enforced as a non-admin
    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, liquidityVault.DEFAULT_ADMIN_ROLE()
      )
    );
    liquidityVault.setWhitelistEnforced(whitelistEnforced);
    vm.stopPrank();
  }

  function test_setWhitelistEnforced_isAdmin(address caller, bool whitelistEnforced) public {
    // Ensure the caller has the DEFAULT_ADMIN_ROLE
    vm.startPrank(admin);
    liquidityVault.grantRole(liquidityVault.DEFAULT_ADMIN_ROLE(), caller);
    vm.stopPrank();

    // Set whitelist enforced
    vm.startPrank(caller);
    liquidityVault.setWhitelistEnforced(whitelistEnforced);
    vm.stopPrank();

    // Validate that the whitelist enforced is set
    assertEq(
      liquidityVault.whitelistEnforced(), whitelistEnforced, "Whitelist enforced should be set to the value passed in"
    );
  }

  function test_deposit_revertWhenPaused(uint256 amount) public {
    // Keeper pauses the liquidityVault
    vm.startPrank(keeper);
    liquidityVault.setPaused(true);
    vm.stopPrank();

    // User attempts to deposit when the liquidityVault is paused
    vm.startPrank(user);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
    liquidityVault.deposit(address(depositableAsset), amount);
    vm.stopPrank();
  }

  function test_deposit_revertWhenWhitelistEnforcedAndNotWhitelisted(address caller, uint256 depositAmount) public {
    // Ensure the caller does not have the WHITELIST_ROLE
    vm.assume(!liquidityVault.hasRole(liquidityVault.WHITELIST_ROLE(), caller));

    // Admin sets the whitelist enforced to true
    vm.startPrank(admin);
    liquidityVault.setWhitelistEnforced(true);
    vm.stopPrank();

    // Attempt to deposit when the liquidityVault is whitelist enforced and the caller is not whitelisted
    vm.startPrank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, liquidityVault.WHITELIST_ROLE()
      )
    );
    liquidityVault.deposit(address(depositableAsset), depositAmount);
    vm.stopPrank();
  }

  function test_deposit_whitelistEnforcedAndWhitelisted(uint128 depositAmount) public {
    // Ensure the user has the WHITELIST_ROLE
    vm.startPrank(admin);
    liquidityVault.grantRole(liquidityVault.WHITELIST_ROLE(), user);
    vm.stopPrank();

    // Admin sets the whitelist enforced to true
    vm.startPrank(admin);
    liquidityVault.setWhitelistEnforced(true);
    vm.stopPrank();

    // User deposits when the liquidityVault is whitelist enforced and the user is whitelisted
    vm.startPrank(user);
    MockERC20(address(depositableAsset)).mint(user, depositAmount);
    depositableAsset.approve(address(liquidityVault), depositAmount);
    liquidityVault.deposit(address(depositableAsset), depositAmount);
    vm.stopPrank();

    // Validate that the user has deposited the depositAmount of depositableAsset into the liquidityVault
    assertEq(
      liquidityVault.totalAssets(),
      PRIME_AMOUNT + depositAmount,
      "Total assets should have increased by the deposit amount"
    );
    assertEq(
      liquidityVault.balanceOf(user),
      depositAmount * (10 ** DECIMALS_OFFSET),
      "Balance of user should be equal to the deposit amount * decimalsOffset"
    );
    assertEq(
      depositableAsset.balanceOf(address(liquidityVault)),
      PRIME_AMOUNT + depositAmount,
      "Depositable asset balance of liquidityVault should be equal to the prime amount plus the deposit amount"
    );
    assertEq(depositableAsset.balanceOf(user), 0, "Depositable asset balance of user should be 0");
  }

  function test_deposit_revertWhenAssetNotDepositable(address inputAsset, uint128 depositAmount) public {
    // Ensure the input asset is not depositable
    vm.assume(inputAsset != address(depositableAsset));

    // Ensure the user has the WHITELIST_ROLE
    vm.startPrank(admin);
    liquidityVault.grantRole(liquidityVault.WHITELIST_ROLE(), user);
    vm.stopPrank();

    // Admin sets the whitelist enforced to true
    vm.startPrank(admin);
    liquidityVault.setWhitelistEnforced(true);
    vm.stopPrank();

    // User deposits when the liquidityVault is whitelist enforced and the user is whitelisted
    vm.startPrank(user);
    vm.expectRevert(abi.encodeWithSelector(ILiquidityVaultErrors.AssetNotDepositable.selector, inputAsset));
    liquidityVault.deposit(address(inputAsset), depositAmount);
    vm.stopPrank();
  }

  function test_deposit_firstDeposit(uint128 depositAmount) public {
    // Mint depositAmount of depositableAsset to the user
    MockERC20(address(depositableAsset)).mint(user, depositAmount);

    // User grants approval to the liquidityVault to spend the depositableAsset
    vm.startPrank(user);
    depositableAsset.approve(address(liquidityVault), depositAmount);
    vm.stopPrank();

    // User deposits the depositableAsset into the liquidityVault
    vm.startPrank(user);
    liquidityVault.deposit(address(depositableAsset), depositAmount);
    vm.stopPrank();

    // Validate that the user has deposited the depositAmount of depositableAsset into the liquidityVault
    assertEq(
      liquidityVault.totalAssets(),
      PRIME_AMOUNT + depositAmount,
      "Total assets should have increased by the deposit amount"
    );
    assertEq(
      liquidityVault.balanceOf(user),
      depositAmount * (10 ** DECIMALS_OFFSET),
      "Balance of user should be equal to the deposit amount * decimalsOffset"
    );
    assertEq(
      depositableAsset.balanceOf(address(liquidityVault)),
      PRIME_AMOUNT + depositAmount,
      "Depositable asset balance of liquidityVault should be equal to the prime amount plus the deposit amount"
    );
    assertEq(depositableAsset.balanceOf(user), 0, "Depositable asset balance of user should be 0");
  }

  function test_redeem_revertWhenPaused(uint256 amount) public {
    // Keeper pauses the liquidityVault
    vm.startPrank(keeper);
    liquidityVault.setPaused(true);
    vm.stopPrank();

    // User attempts to withdraw when the liquidityVault is paused
    vm.startPrank(user);
    vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
    liquidityVault.redeem(amount);
    vm.stopPrank();
  }

  function test_redeem_firstRedeem(uint128 depositAmount) public {
    // Mint depositAmount of depositableAsset to the user
    MockERC20(address(depositableAsset)).mint(user, depositAmount);

    // User grants approval to the liquidityVault to spend the depositableAsset
    vm.startPrank(user);
    depositableAsset.approve(address(liquidityVault), depositAmount);
    vm.stopPrank();

    // User deposits the depositableAsset into the liquidityVault
    vm.startPrank(user);
    liquidityVault.deposit(address(depositableAsset), depositAmount);
    vm.stopPrank();

    // LiquidityVault exchanges the depositableAsset for the redeemableAsset
    vm.startPrank(address(liquidityVault));
    uint256 totalDepositableBalance = depositableAsset.balanceOf(address(liquidityVault));
    MockERC20(address(depositableAsset)).burn(address(liquidityVault), totalDepositableBalance);
    MockERC20(address(redeemableAsset)).mint(address(liquidityVault), totalDepositableBalance);
    vm.stopPrank();

    // Confirm that the liquidityVault has 0 depositableAsset and depositAmount redeemableAsset
    assertEq(
      depositableAsset.balanceOf(address(liquidityVault)), 0, "Depositable asset balance of liquidityVault should be 0"
    );
    assertEq(
      redeemableAsset.balanceOf(address(liquidityVault)),
      PRIME_AMOUNT + depositAmount,
      "Redeemable asset balance of liquidityVault should be equal to the prime amount plus the deposit amount"
    );

    // User redeems their entire balance of the liquidityVault
    vm.startPrank(user);
    liquidityVault.redeem(liquidityVault.balanceOf(user));
    vm.stopPrank();

    // Validate that the user has redeemed their entire balance of the liquidityVault
    assertEq(liquidityVault.balanceOf(user), 0, "Balance of user should be 0");
    assertEq(depositableAsset.balanceOf(user), 0, "Depositable asset balance of user should be 0");
    assertEq(redeemableAsset.balanceOf(user), depositAmount, "Redeemable asset balance of user should be depositAmount");
  }

  function test_updateAsset_add(address asset, bool isRedeemable) public {
    // Update the assets
    MockLiquidityVault(address(liquidityVault)).updateAssets(asset, isRedeemable, true);

    if (isRedeemable) {
      assertEq(liquidityVault.redeemableAssets().length, 2, "Redeemable assets should have length 2");
      assertEq(liquidityVault.redeemableAssets()[0], address(redeemableAsset), "redeemableAssets[0] should be the redeemable asset");
      assertEq(liquidityVault.redeemableAssets()[1], asset, "redeemableAssets[1] should be the asset passed in");
    } else {
      assertEq(liquidityVault.depositableAssets().length, 2, "Depositable assets should have length 2");
      assertEq(liquidityVault.depositableAssets()[0], address(depositableAsset), "depositableAssets[0] should be the depositable asset");
      assertEq(liquidityVault.depositableAssets()[1], asset, "depositableAssets[1] should be the asset passed in");
    }
  }

  function test_updateAsset_remove(bool isRedeemable) public {
    // Update the assets
    address asset = isRedeemable ? address(redeemableAsset) : address(depositableAsset);
    MockLiquidityVault(address(liquidityVault)).updateAssets(asset, isRedeemable, false);

    if (isRedeemable) {
      assertEq(liquidityVault.redeemableAssets().length, 0, "Redeemable assets should have length 2");
    } else {
      assertEq(liquidityVault.depositableAssets().length, 0, "Depositable assets should have length 0");
    }
  }

  function test_updateAsset_removeMissingAsset(address asset, bool isRedeemable) public {
    // Make sure the asset is not the depositable asset or redeemable asset
    vm.assume(asset != address(depositableAsset) && asset != address(redeemableAsset));

    // Attempt to remove a missing asset
    vm.expectRevert();
    MockLiquidityVault(address(liquidityVault)).updateAssets(asset, isRedeemable, false);
  }
}
