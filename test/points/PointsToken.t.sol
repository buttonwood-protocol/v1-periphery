// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PointsToken} from "../../src/points/PointsToken.sol";
import {IPointsToken, IPointsTokenErrors} from "../../src/interfaces/IPointsToken/IPointsToken.sol";

contract PointsTokenV2 is PointsToken {
  function newFunction() external pure returns (bool) {
    return true;
  }
}

contract PointsTokenHandler is Test {
  PointsToken internal token;
  address internal minter;
  address internal burner;
  address[] internal actors;
  uint256 public ghostMinted;
  uint256 public ghostBurned;
  uint256 public ghostMovesSucceeded;

  constructor(PointsToken _token, address _minter, address _burner, address[] memory _actors) {
    token = _token;
    minter = _minter;
    burner = _burner;
    actors = _actors;
  }

  function actorCount() external view returns (uint256) {
    return actors.length;
  }

  function actorAt(uint256 i) external view returns (address) {
    return actors[i];
  }

  function mint(uint256 actorSeed, uint256 amount) external {
    amount = bound(amount, 0, 1e30);
    vm.prank(minter);
    token.mint(actors[actorSeed % actors.length], amount);
    ghostMinted += amount;
  }

  function burn(uint256 actorSeed, uint256 amount) external {
    address actor = actors[actorSeed % actors.length];
    amount = bound(amount, 0, token.balanceOf(actor));
    vm.prank(burner);
    token.burn(actor, amount);
    ghostBurned += amount;
  }

  function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
    address from = actors[fromSeed % actors.length];
    vm.prank(from);
    try token.transfer(actors[toSeed % actors.length], amount) {
      ghostMovesSucceeded++;
    } catch {}
  }

  function approveAndTransferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 amount) external {
    address from = actors[fromSeed % actors.length];
    address spender = actors[spenderSeed % actors.length];
    vm.prank(from);
    try token.approve(spender, amount) {
      ghostMovesSucceeded++;
    } catch {}
    vm.prank(spender);
    try token.transferFrom(from, spender, amount) {
      ghostMovesSucceeded++;
    } catch {}
  }
}

contract PointsTokenTest is Test {
  address internal admin = makeAddr("admin");
  address internal minter = makeAddr("minter");
  address internal burner = makeAddr("burner");
  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");

  PointsToken internal token;
  PointsTokenHandler internal handler;

  function setUp() public {
    PointsToken implementation = new PointsToken();
    bytes memory data = abi.encodeCall(PointsToken.initialize, ("Buttonwood Points", "BWP", 18, admin));
    token = PointsToken(address(new ERC1967Proxy(address(implementation), data)));
    vm.startPrank(admin);
    token.grantRole(token.MINTER_ROLE(), minter);
    token.grantRole(token.BURNER_ROLE(), burner);
    vm.stopPrank();

    address[] memory actors = new address[](3);
    actors[0] = alice;
    actors[1] = bob;
    actors[2] = admin;
    handler = new PointsTokenHandler(token, minter, burner, actors);
    targetContract(address(handler));
  }

  function test_initialize() public view {
    assertEq(token.name(), "Buttonwood Points");
    assertEq(token.symbol(), "BWP");
    assertEq(token.decimals(), 18);
    assertEq(token.totalSupply(), 0);
    assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    assertEq(token.MINTER_ROLE(), keccak256("MINTER_ROLE"));
    assertEq(token.BURNER_ROLE(), keccak256("BURNER_ROLE"));
  }

  function test_initialize_decimalsIsAParameter(uint8 decimals) public {
    PointsToken implementation = new PointsToken();
    bytes memory data = abi.encodeCall(PointsToken.initialize, ("P", "P", decimals, admin));
    PointsToken other = PointsToken(address(new ERC1967Proxy(address(implementation), data)));
    assertEq(other.decimals(), decimals);
  }

  function test_initialize_revertsTwice() public {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    token.initialize("X", "X", 6, rando());
  }

  function test_initialize_implementationDisabled() public {
    PointsToken implementation = new PointsToken();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    implementation.initialize("X", "X", 6, admin);
  }

  function test_supportsInterface() public view {
    assertTrue(token.supportsInterface(type(IPointsToken).interfaceId));
    assertTrue(token.supportsInterface(type(IERC20).interfaceId));
    assertTrue(token.supportsInterface(type(IERC20Metadata).interfaceId));
    assertTrue(token.supportsInterface(type(IAccessControl).interfaceId));
    assertTrue(token.supportsInterface(type(IERC165).interfaceId));
    assertFalse(token.supportsInterface(0xdeadbeef));
  }

  function test_mint(address to, uint256 amount) public {
    vm.assume(to != address(0));
    vm.expectEmit(true, true, false, true, address(token));
    emit IERC20.Transfer(address(0), to, amount);
    vm.prank(minter);
    token.mint(to, amount);
    assertEq(token.balanceOf(to), amount);
    assertEq(token.totalSupply(), amount);
  }

  function test_mint_revertsWithoutMinterRole(address caller) public {
    vm.assume(caller != minter);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, token.MINTER_ROLE())
    );
    vm.prank(caller);
    token.mint(alice, 1);
  }

  function test_mint_adminAndBurnerCannotMint() public {
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, token.MINTER_ROLE())
    );
    vm.prank(admin);
    token.mint(alice, 1);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, burner, token.MINTER_ROLE())
    );
    vm.prank(burner);
    token.mint(alice, 1);
  }

  function test_mint_revertsToZeroAddress() public {
    vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
    vm.prank(minter);
    token.mint(address(0), 1);
  }

  function test_burn(uint256 minted, uint256 burned) public {
    burned = bound(burned, 0, minted);
    vm.prank(minter);
    token.mint(alice, minted);
    vm.expectEmit(true, true, false, true, address(token));
    emit IERC20.Transfer(alice, address(0), burned);
    vm.prank(burner);
    token.burn(alice, burned);
    assertEq(token.balanceOf(alice), minted - burned);
    assertEq(token.totalSupply(), minted - burned);
  }

  function test_burn_needsNoAllowance() public {
    vm.prank(minter);
    token.mint(alice, 10);
    assertEq(token.allowance(alice, burner), 0);
    vm.prank(burner);
    token.burn(alice, 10);
    assertEq(token.balanceOf(alice), 0);
  }

  function test_burn_revertsAboveBalance(uint256 minted) public {
    minted = bound(minted, 0, type(uint256).max - 1);
    vm.prank(minter);
    token.mint(alice, minted);
    vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, minted, minted + 1));
    vm.prank(burner);
    token.burn(alice, minted + 1);
  }

  function test_burn_revertsWithoutBurnerRole(address caller) public {
    vm.assume(caller != burner);
    vm.prank(minter);
    token.mint(alice, 1);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, token.BURNER_ROLE())
    );
    vm.prank(caller);
    token.burn(alice, 1);
  }

  function test_burn_minterCannotBurn() public {
    vm.prank(minter);
    token.mint(alice, 1);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, minter, token.BURNER_ROLE())
    );
    vm.prank(minter);
    token.burn(alice, 1);
  }

  function test_transfer_alwaysReverts(address from, address to, uint256 balance, uint256 amount) public {
    vm.assume(from != address(0));
    vm.prank(minter);
    token.mint(from, balance);
    vm.expectRevert(IPointsTokenErrors.TransfersDisabled.selector);
    vm.prank(from);
    token.transfer(to, amount);
    assertEq(token.balanceOf(from), balance);
  }

  function test_transferFrom_alwaysReverts(address caller, address from, address to, uint256 amount) public {
    if (from != address(0)) {
      vm.prank(minter);
      token.mint(from, amount);
    }
    vm.expectRevert(IPointsTokenErrors.TransfersDisabled.selector);
    vm.prank(caller);
    token.transferFrom(from, to, amount);
  }

  function test_transfer_revertsEvenForTheAdminAndMinter() public {
    vm.prank(minter);
    token.mint(admin, 5);
    vm.expectRevert(IPointsTokenErrors.TransfersDisabled.selector);
    vm.prank(admin);
    token.transfer(alice, 5);
    vm.prank(minter);
    token.mint(minter, 5);
    vm.expectRevert(IPointsTokenErrors.TransfersDisabled.selector);
    vm.prank(minter);
    token.transfer(alice, 5);
  }

  function test_approve_alwaysReverts(address owner, address spender, uint256 amount) public {
    vm.expectRevert(IPointsTokenErrors.ApprovalsDisabled.selector);
    vm.prank(owner);
    token.approve(spender, amount);
    assertEq(token.allowance(owner, spender), 0);
  }

  function test_roleAdmin() public {
    assertEq(token.getRoleAdmin(token.MINTER_ROLE()), token.DEFAULT_ADMIN_ROLE());
    assertEq(token.getRoleAdmin(token.BURNER_ROLE()), token.DEFAULT_ADMIN_ROLE());
    bytes32 minterRole = token.MINTER_ROLE();
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, minter, token.DEFAULT_ADMIN_ROLE()
      )
    );
    vm.prank(minter);
    token.grantRole(minterRole, alice);
    vm.prank(admin);
    token.revokeRole(minterRole, minter);
    assertFalse(token.hasRole(minterRole, minter));
  }

  function test_upgrade_revertsForNonAdmin(address caller) public {
    vm.assume(caller != admin);
    PointsTokenV2 next = new PointsTokenV2();
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, token.DEFAULT_ADMIN_ROLE()
      )
    );
    vm.prank(caller);
    token.upgradeToAndCall(address(next), "");
  }

  function test_upgrade_minterAndBurnerCannotUpgrade() public {
    PointsTokenV2 next = new PointsTokenV2();
    bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, minter, adminRole));
    vm.prank(minter);
    token.upgradeToAndCall(address(next), "");
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, burner, adminRole));
    vm.prank(burner);
    token.upgradeToAndCall(address(next), "");
  }

  function test_upgrade_byAdminKeepsState() public {
    vm.prank(minter);
    token.mint(alice, 42);
    PointsTokenV2 next = new PointsTokenV2();
    vm.prank(admin);
    token.upgradeToAndCall(address(next), "");
    assertTrue(PointsTokenV2(address(token)).newFunction());
    assertEq(token.balanceOf(alice), 42);
    assertEq(token.decimals(), 18);
    assertEq(token.name(), "Buttonwood Points");
    assertTrue(token.hasRole(token.MINTER_ROLE(), minter));
    vm.expectRevert(IPointsTokenErrors.TransfersDisabled.selector);
    vm.prank(alice);
    token.transfer(bob, 1);
  }

  function test_storageLayout_erc7201() public view {
    bytes32 expected =
      keccak256(abi.encode(uint256(keccak256("buttonwood.storage.PointsToken")) - 1)) & ~bytes32(uint256(0xff));
    assertEq(expected, 0x610dc46ab039d4b6d6c0030441693d9675226bbe8c976e204412a1760dab4500);
    assertEq(uint256(vm.load(address(token), expected)) & 0xff, 18);
  }

  function testFuzz_mintBurnAccounting(uint128[4] memory mints, uint128[4] memory burns) public {
    address[2] memory holders = [alice, bob];
    uint256[2] memory expected;
    for (uint256 i = 0; i < 4; i++) {
      address holder = holders[i % 2];
      vm.prank(minter);
      token.mint(holder, mints[i]);
      expected[i % 2] += mints[i];
      uint256 burnAmount = bound(burns[i], 0, expected[i % 2]);
      vm.prank(burner);
      token.burn(holder, burnAmount);
      expected[i % 2] -= burnAmount;
    }
    assertEq(token.balanceOf(alice), expected[0]);
    assertEq(token.balanceOf(bob), expected[1]);
    assertEq(token.totalSupply(), expected[0] + expected[1]);
  }

  function invariant_noTransferPathSucceeds() public view {
    assertEq(handler.ghostMovesSucceeded(), 0);
  }

  function invariant_supplyMatchesMintsMinusBurns() public view {
    assertEq(token.totalSupply(), handler.ghostMinted() - handler.ghostBurned());
    uint256 sum;
    for (uint256 i = 0; i < handler.actorCount(); i++) {
      address actor = handler.actorAt(i);
      sum += token.balanceOf(actor);
      for (uint256 j = 0; j < handler.actorCount(); j++) {
        assertEq(token.allowance(actor, handler.actorAt(j)), 0);
      }
    }
    assertEq(sum, token.totalSupply());
  }

  function rando() internal returns (address) {
    return makeAddr("rando");
  }
}
