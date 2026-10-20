// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PointsBase} from "./PointsBase.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {PointsMinter} from "../../src/points/PointsMinter.sol";
import {PointsToken} from "../../src/points/PointsToken.sol";
import {
  IPointsMinter,
  IPointsMinterErrors,
  IPointsMinterEvents
} from "../../src/interfaces/IPointsMinter/IPointsMinter.sol";
import {PointsMinterConfig, WalletRecord, LendDay} from "../../src/interfaces/IPointsMinter/PointsMinterTypes.sol";

contract PointsMinterV2 is PointsMinter {
  function newFunction() external pure returns (bool) {
    return true;
  }
}

contract PointsMinterTest is PointsBase {
  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  uint256 internal nextTokenId = 1;

  function setUp() public {
    setUpPoints(18);
    vault.setTotalAssets(7_000_000e18);
  }

  function newLoan(address owner, uint256 amountBorrowed) internal returns (uint256 tokenId) {
    tokenId = nextTokenId++;
    loanManager.createLoan(owner, tokenId, uint32(block.timestamp), amountBorrowed);
  }

  function setGenesis(address wallet, uint256 depositWhole, uint256 borrowWhole) internal {
    vm.warp(dayEnd(0));
    if (depositWhole != 0) creditLendOne(0, wallet, depositWhole * POINT);
    if (borrowWhole != 0) minter.creditBorrow(newLoan(wallet, borrowWhole * 1e18));
  }

  // ---------------------------------------------------------------- initialize

  function test_initialize() public view {
    assertEq(minter.pointsToken(), address(token));
    assertEq(minter.pointUnit(), 1e18);
    assertEq(minter.registeredCount(), 0);
    assertTrue(minter.hasRole(minter.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(minter.hasRole(minter.LEND_CREDITOR_ROLE(), roller));
    assertEq(minter.LEND_CREDITOR_ROLE(), keccak256("LEND_CREDITOR_ROLE"));
    assertEq(minter.REGISTRATION_TYPEHASH(), keccak256("Registration(address wallet,uint256 expiry)"));
    PointsMinterConfig memory c = minter.config();
    assertEq(c.loanManager, address(loanManager));
    assertEq(c.rolloverVault, address(vault));
    assertEq(c.attestationSigner, signer);
    assertEq(c.programStart, PROGRAM_START);
    assertEq(c.programEnd, PROGRAM_END);
    assertEq(c.genesisCloseAt, GENESIS_CLOSE);
    assertEq(c.borrowClip, 10_000);
    assertEq(c.firstN, 500);
    assertFalse(minter.paused());
  }

  function test_initialize_revertsTwice() public {
    PointsMinterConfig memory c = defaultConfig();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    minter.initialize(address(token), c, admin);
  }

  function test_initialize_implementationDisabled() public {
    PointsMinter implementation = new PointsMinter();
    PointsMinterConfig memory c = defaultConfig();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    implementation.initialize(address(token), c, admin);
  }

  function test_initialize_pointUnitFollowsTokenDecimals(uint8 decimals) public {
    decimals = uint8(bound(decimals, 0, 30));
    PointsToken other = deployToken(decimals);
    PointsMinter otherMinter = deployMinter(address(other), defaultConfig());
    assertEq(otherMinter.pointUnit(), 10 ** decimals);
  }

  function test_supportsInterface() public view {
    assertTrue(minter.supportsInterface(type(IPointsMinter).interfaceId));
    assertTrue(minter.supportsInterface(type(IAccessControl).interfaceId));
    assertTrue(minter.supportsInterface(type(IERC165).interfaceId));
    assertFalse(minter.supportsInterface(0xdeadbeef));
  }

  function test_storageLayout_erc7201() public view {
    bytes32 slot =
      keccak256(abi.encode(uint256(keccak256("buttonwood.storage.PointsMinter")) - 1)) & ~bytes32(uint256(0xff));
    assertEq(slot, 0x4de64b8f9574cc39251469a79c0f10af4bc675a4d84ab1d0e0e2059d2850ce00);
    assertEq(address(uint160(uint256(vm.load(address(minter), slot)))), address(token));
    assertEq(uint256(vm.load(address(minter), bytes32(uint256(slot) + 1))), 1e18);
    assertEq(address(uint160(uint256(vm.load(address(minter), bytes32(uint256(slot) + 2))))), address(loanManager));
  }

  // ---------------------------------------------------------------- register

  function test_register() public {
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(alice, expiry);
    vm.expectEmit(true, false, false, true, address(minter));
    emit IPointsMinterEvents.Registered(alice, 1);
    vm.prank(alice);
    assertEq(minter.register(expiry, signature), 1);
    WalletRecord memory r = minter.earned(alice);
    assertEq(r.whitelistNumber, 1);
    assertEq(r.registeredAt, block.timestamp);
    assertTrue(minter.isRegistered(alice));
    assertEq(minter.registeredCount(), 1);
  }

  function test_register_numbersAreSequential(uint8 count) public {
    count = uint8(bound(count, 1, 60));
    for (uint256 i = 1; i <= count; i++) {
      address wallet = address(uint160(0x1000 + i));
      assertEq(register(wallet), i);
      assertEq(minter.earned(wallet).whitelistNumber, i);
    }
    assertEq(minter.registeredCount(), count);
  }

  function test_register_revertsOnReplay() public {
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(alice, expiry);
    vm.prank(alice);
    minter.register(expiry, signature);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.AlreadyRegistered.selector, alice));
    vm.prank(alice);
    minter.register(expiry, signature);
    assertEq(minter.registeredCount(), 1);
  }

  function test_register_revertsForAnotherWalletsAttestation() public {
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(alice, expiry);
    vm.prank(bob);
    vm.expectPartialRevert(IPointsMinterErrors.InvalidAttestation.selector);
    minter.register(expiry, signature);
  }

  function test_register_revertsWhenExpired(uint256 delay) public {
    delay = bound(delay, 1, 365 days);
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(alice, expiry);
    vm.warp(expiry + delay);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.AttestationExpired.selector, expiry));
    vm.prank(alice);
    minter.register(expiry, signature);
  }

  function test_register_acceptsAtExpiry() public {
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(alice, expiry);
    vm.warp(expiry);
    vm.prank(alice);
    assertEq(minter.register(expiry, signature), 1);
  }

  function test_register_revertsWhenExpiryAltered() public {
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(alice, expiry);
    vm.expectPartialRevert(IPointsMinterErrors.InvalidAttestation.selector);
    vm.prank(alice);
    minter.register(expiry + 1, signature);
  }

  function test_register_revertsForWrongSigner(uint256 pk) public {
    pk = bound(pk, 1, 1e70);
    vm.assume(pk != signerPk);
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(pk, alice, expiry, block.chainid, address(minter));
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.InvalidAttestation.selector, vm.addr(pk)));
    vm.prank(alice);
    minter.register(expiry, signature);
  }

  function test_register_revertsForOtherChainDomain(uint64 chainId) public {
    vm.assume(chainId != block.chainid);
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(signerPk, alice, expiry, chainId, address(minter));
    vm.expectPartialRevert(IPointsMinterErrors.InvalidAttestation.selector);
    vm.prank(alice);
    minter.register(expiry, signature);
  }

  function test_register_revertsAfterChainIdChanges() public {
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(alice, expiry);
    vm.chainId(block.chainid + 1);
    vm.expectPartialRevert(IPointsMinterErrors.InvalidAttestation.selector);
    vm.prank(alice);
    minter.register(expiry, signature);
  }

  function test_register_revertsForOtherVerifyingContract() public {
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(signerPk, alice, expiry, block.chainid, address(token));
    vm.expectPartialRevert(IPointsMinterErrors.InvalidAttestation.selector);
    vm.prank(alice);
    minter.register(expiry, signature);
  }

  function test_register_revertsForMalformedSignature() public {
    vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 3));
    vm.prank(alice);
    minter.register(block.timestamp + 1, hex"010203");
  }

  function test_register_revertsWhenPaused() public {
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(alice, expiry);
    vm.prank(admin);
    minter.setPaused(true);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vm.prank(alice);
    minter.register(expiry, signature);
  }

  function test_register_rotatedSignerInvalidatesOldAttestations() public {
    uint256 expiry = block.timestamp + 1 hours;
    bytes memory signature = attest(alice, expiry);
    PointsMinterConfig memory c = defaultConfig();
    c.attestationSigner = makeAddr("newSigner");
    vm.prank(admin);
    minter.setConfig(c);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.InvalidAttestation.selector, signer));
    vm.prank(alice);
    minter.register(expiry, signature);
  }

  // ---------------------------------------------------------------- creditBorrow

  function test_creditBorrow_unregisteredMintsAtBase(address caller) public {
    vm.warp(PROGRAM_START + 1 hours);
    uint256 tokenId = newLoan(alice, 2_000e18);
    vm.expectEmit(true, true, false, true, address(minter));
    emit IPointsMinterEvents.BorrowCredited(tokenId, alice, 2_000e18, 2_000 * POINT, 2_000 * POINT, 10_000);
    vm.prank(caller);
    assertEq(minter.creditBorrow(tokenId), 2_000 * POINT);
    assertEq(token.balanceOf(alice), 2_000 * POINT);
    assertEq(minter.earned(alice).borrowPoints, 2_000 * POINT);
    assertEq(minter.earned(alice).genesisBorrowPoints, 2_000 * POINT);
    assertTrue(minter.isLoanCredited(tokenId));
  }

  function test_creditBorrow_revertsTwice() public {
    vm.warp(PROGRAM_START);
    uint256 tokenId = newLoan(alice, 100e18);
    minter.creditBorrow(tokenId);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LoanAlreadyCredited.selector, tokenId));
    minter.creditBorrow(tokenId);
    assertEq(token.balanceOf(alice), 100 * POINT);
  }

  function test_creditBorrow_revertsBeforeProgram(uint32 originated) public {
    originated = uint32(bound(originated, 1, PROGRAM_START - 1));
    vm.warp(PROGRAM_START + 1 days);
    loanManager.createLoan(alice, 7, originated, 100e18);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LoanOutsideProgram.selector, 7, originated));
    minter.creditBorrow(7);
  }

  function test_creditBorrow_revertsAtOrAfterProgramEnd(uint32 originated) public {
    originated = uint32(bound(originated, PROGRAM_END, type(uint32).max));
    vm.warp(originated);
    loanManager.createLoan(alice, 7, originated, 100e18);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LoanOutsideProgram.selector, 7, originated));
    minter.creditBorrow(7);
  }

  function test_creditBorrow_lastSecondOfProgramIsCredited() public {
    vm.warp(PROGRAM_END + 5 days);
    loanManager.createLoan(alice, 7, uint32(PROGRAM_END - 1), 100e18);
    assertEq(minter.creditBorrow(7), 100 * POINT);
  }

  function test_creditBorrow_revertsForUnknownLoan(uint256 tokenId) public {
    vm.warp(PROGRAM_START + 1 days);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LoanOutsideProgram.selector, tokenId, 0));
    minter.creditBorrow(tokenId);
  }

  function test_creditBorrow_revertsWhenNftBurned() public {
    vm.warp(PROGRAM_START + 1 days);
    loanManager.setPosition(9, uint32(block.timestamp), 100e18);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 9));
    minter.creditBorrow(9);
    assertFalse(minter.isLoanCredited(9));
  }

  function test_creditBorrow_creditsTheCurrentNftOwner() public {
    vm.warp(PROGRAM_START);
    uint256 tokenId = newLoan(alice, 100e18);
    MockNFTLike nft = MockNFTLike(loanManager.nft());
    vm.prank(alice);
    nft.transferFrom(alice, bob, tokenId);
    minter.creditBorrow(tokenId);
    assertEq(token.balanceOf(bob), 100 * POINT);
    assertEq(token.balanceOf(alice), 0);
  }

  function test_creditBorrow_clipsPerWallet() public {
    vm.warp(PROGRAM_START);
    assertEq(minter.creditBorrow(newLoan(alice, 6_000e18)), 6_000 * POINT);
    uint256 second = newLoan(alice, 6_000e18);
    vm.expectEmit(true, true, false, true, address(minter));
    emit IPointsMinterEvents.BorrowCredited(second, alice, 6_000e18, 4_000 * POINT, 4_000 * POINT, 10_000);
    minter.creditBorrow(second);
    uint256 third = newLoan(alice, 1e18);
    assertEq(minter.creditBorrow(third), 0);
    assertTrue(minter.isLoanCredited(third));
    assertEq(minter.earned(alice).borrowPoints, 10_000 * POINT);
    assertEq(token.balanceOf(alice), 10_000 * POINT);
    assertEq(minter.creditBorrow(newLoan(bob, 500e18)), 500 * POINT);
  }

  function testFuzz_creditBorrow_neverExceedsClip(uint96[6] memory amounts) public {
    vm.warp(PROGRAM_START);
    uint256 sum;
    for (uint256 i = 0; i < amounts.length; i++) {
      minter.creditBorrow(newLoan(alice, amounts[i]));
      sum += amounts[i];
      assertLe(minter.earned(alice).borrowPoints, 10_000 * POINT);
    }
    uint256 expected = sum > 10_000e18 ? 10_000 * POINT : sum;
    assertEq(minter.earned(alice).borrowPoints, expected);
    assertEq(token.balanceOf(alice), expected);
  }

  function test_creditBorrow_clipLoweredBelowRecordCreditsZero() public {
    vm.warp(PROGRAM_START);
    minter.creditBorrow(newLoan(alice, 5_000e18));
    PointsMinterConfig memory c = defaultConfig();
    c.borrowClip = 1_000;
    vm.prank(admin);
    minter.setConfig(c);
    assertEq(minter.creditBorrow(newLoan(alice, 1_000e18)), 0);
    assertEq(minter.earned(alice).borrowPoints, 5_000 * POINT);
  }

  function test_creditBorrow_revertsForBlockedWalletAndCanRetryAfterUnblock() public {
    vm.warp(PROGRAM_START);
    uint256 tokenId = newLoan(alice, 100e18);
    vm.prank(admin);
    minter.setBlocked(alice, true);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.WalletBlocked.selector, alice));
    minter.creditBorrow(tokenId);
    assertFalse(minter.isLoanCredited(tokenId));
    vm.prank(admin);
    minter.setBlocked(alice, false);
    assertEq(minter.creditBorrow(tokenId), 100 * POINT);
  }

  function test_creditBorrow_appliesFirstNBonusWhenRegistered() public {
    register(alice);
    vm.warp(PROGRAM_START);
    assertEq(minter.creditBorrow(newLoan(alice, 1_000e18)), 1_050 * POINT);
    assertEq(minter.earned(alice).borrowPoints, 1_000 * POINT);
  }

  function test_creditBorrow_originatedAfterGenesisDoesNotCountTowardTiers(uint256 creditDelay) public {
    creditDelay = bound(creditDelay, 0, 60 days);
    vm.warp(GENESIS_CLOSE);
    uint256 tokenId = newLoan(alice, 2_000e18);
    vm.warp(block.timestamp + creditDelay);
    minter.creditBorrow(tokenId);
    WalletRecord memory r = minter.earned(alice);
    assertEq(r.borrowPoints, 2_000 * POINT);
    assertEq(r.genesisBorrowPoints, 0);
  }

  function test_creditBorrow_originatedBeforeGenesisCountsWhenCreditedAfter(uint256 creditDelay) public {
    creditDelay = bound(creditDelay, 1, 60 days);
    register(alice);
    vm.warp(GENESIS_CLOSE - 1);
    uint256 tokenId = newLoan(alice, 5_000e18);
    vm.warp(GENESIS_CLOSE + creditDelay);
    // the multiplier is still the one at mint time: tier 0 plus the first-N bonus
    assertEq(minter.creditBorrow(tokenId), 5_250 * POINT);
    WalletRecord memory r = minter.earned(alice);
    assertEq(r.genesisBorrowPoints, 5_000 * POINT);
    (, uint256 borrowTier) = minter.tierOf(alice);
    assertEq(borrowTier, 2);
    assertEq(minter.multiplier(alice), 11_500);
  }

  function test_creditBorrow_revertsWhenPaused() public {
    vm.warp(PROGRAM_START);
    uint256 tokenId = newLoan(alice, 1e18);
    vm.prank(admin);
    minter.setPaused(true);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    minter.creditBorrow(tokenId);
  }

  // ---------------------------------------------------------------- creditLend

  function test_creditLend() public {
    vm.warp(dayEnd(0));
    address[] memory users = new address[](2);
    uint256[] memory points = new uint256[](2);
    (users[0], users[1]) = (alice, bob);
    (points[0], points[1]) = (300 * POINT, 700 * POINT);
    uint256 cap = 7_000_000e18 * 10_100 / (7 * 10_000);
    vm.expectEmit(true, false, false, true, address(minter));
    emit IPointsMinterEvents.LendDayOpened(0, 7_000_000e18, cap);
    vm.expectEmit(true, true, false, true, address(minter));
    emit IPointsMinterEvents.LendCredited(0, alice, 300 * POINT, 300 * POINT, 10_000);
    vm.prank(roller);
    minter.creditLend(0, users, points);
    assertEq(token.balanceOf(alice), 300 * POINT);
    assertEq(token.balanceOf(bob), 700 * POINT);
    assertEq(minter.earned(bob).depositPoints, 700 * POINT);
    assertEq(minter.earned(bob).genesisDepositPoints, 700 * POINT);
    LendDay memory d = minter.lendDay(0);
    assertTrue(d.opened);
    assertEq(d.cap, cap);
    assertEq(d.total, 1_000 * POINT);
    assertTrue(minter.isLendCredited(0, alice));
    assertFalse(minter.isLendCredited(1, alice));
  }

  function test_creditLend_capIsAssetsOverSevenPlusTolerance() public {
    vault.setTotalAssets(70_000e18);
    vm.warp(dayEnd(0));
    uint256 cap = 10_100 * POINT;
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LendCapExceeded.selector, 0, cap + 1, cap));
    creditLendOne(0, alice, cap + 1);
    creditLendOne(0, alice, cap);
    assertEq(minter.lendDay(0).total, cap);
  }

  function testFuzz_creditLend_neverExceedsCap(uint128 assets, uint128[4] memory chunks) public {
    vault.setTotalAssets(assets);
    vm.warp(dayEnd(3));
    uint256 cap = uint256(assets) * 10_100 / 70_000;
    uint256 total;
    for (uint256 i = 0; i < chunks.length; i++) {
      address wallet = address(uint160(0x2000 + i));
      if (total + chunks[i] > cap) {
        vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LendCapExceeded.selector, 3, total + chunks[i], cap));
        creditLendOne(3, wallet, chunks[i]);
      } else {
        creditLendOne(3, wallet, chunks[i]);
        total += chunks[i];
      }
      assertLe(minter.lendDay(3).total, cap);
      assertEq(minter.lendDay(3).total, total);
    }
  }

  function test_creditLend_multipleChunksShareOneCap() public {
    vault.setTotalAssets(7_000e18);
    vm.warp(dayEnd(0));
    creditLendOne(0, alice, 600 * POINT);
    vm.expectRevert(
      abi.encodeWithSelector(IPointsMinterErrors.LendCapExceeded.selector, 0, 1_011 * POINT, 1_010 * POINT)
    );
    creditLendOne(0, bob, 411 * POINT);
    creditLendOne(0, bob, 410 * POINT);
    assertEq(minter.lendDay(0).total, 1_010 * POINT);
  }

  function test_creditLend_capIsSnapshottedOnFirstCall() public {
    vault.setTotalAssets(7_000e18);
    vm.warp(dayEnd(0));
    creditLendOne(0, alice, 1);
    vault.setTotalAssets(7_000_000e18);
    vm.expectPartialRevert(IPointsMinterErrors.LendCapExceeded.selector);
    creditLendOne(0, bob, 1_010 * POINT);
    assertEq(minter.lendDay(0).cap, 1_010 * POINT);
    // a different day snapshots afresh
    vm.warp(dayEnd(1));
    creditLendOne(1, bob, 1_010 * POINT);
  }

  function test_creditLend_revertsForSameUserTwiceInADay() public {
    vm.warp(dayEnd(0));
    creditLendOne(0, alice, 1 * POINT);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LendAlreadyCredited.selector, 0, alice));
    creditLendOne(0, alice, 1 * POINT);
  }

  function test_creditLend_revertsForDuplicateUserInOneBatch() public {
    vm.warp(dayEnd(0));
    address[] memory users = new address[](2);
    uint256[] memory points = new uint256[](2);
    (users[0], users[1]) = (alice, alice);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LendAlreadyCredited.selector, 0, alice));
    vm.prank(roller);
    minter.creditLend(0, users, points);
    assertFalse(minter.isLendCredited(0, alice));
  }

  function test_creditLend_revertsBeforeDayEnds(uint256 day) public {
    day = bound(day, 0, 88);
    vm.warp(dayEnd(day) - 1);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.DayNotCreditable.selector, day));
    creditLendOne(day, alice, 1);
  }

  function test_creditLend_revertsBeyondProgram(uint256 day) public {
    day = bound(day, 90, type(uint256).max);
    vm.warp(PROGRAM_END + 365 days);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.DayNotCreditable.selector, day));
    creditLendOne(day, alice, 1);
  }

  function test_creditLend_lastDayCreditableAfterProgramEnd() public {
    vm.warp(PROGRAM_END + 1 days);
    creditLendOne(89, alice, 1 * POINT);
    assertEq(token.balanceOf(alice), 1 * POINT);
  }

  function test_creditLend_partialLastDayCounts() public {
    PointsMinterConfig memory c = defaultConfig();
    c.programEnd = PROGRAM_START + 2 days + 1 hours;
    c.genesisCloseAt = c.programEnd;
    vm.prank(admin);
    minter.setConfig(c);
    vm.warp(dayEnd(2));
    creditLendOne(2, alice, 1);
    vm.warp(dayEnd(3));
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.DayNotCreditable.selector, 3));
    creditLendOne(3, alice, 1);
  }

  function test_creditLend_revertsWithoutRole(address caller) public {
    vm.assume(caller != roller);
    vm.warp(dayEnd(0));
    address[] memory users = new address[](0);
    uint256[] memory points = new uint256[](0);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, minter.LEND_CREDITOR_ROLE()
      )
    );
    vm.prank(caller);
    minter.creditLend(0, users, points);
  }

  function test_creditLend_revertsOnLengthMismatch() public {
    vm.warp(dayEnd(0));
    vm.expectRevert(IPointsMinterErrors.LengthMismatch.selector);
    vm.prank(roller);
    minter.creditLend(0, new address[](2), new uint256[](1));
  }

  function test_creditLend_skipsBlockedWallet() public {
    vm.prank(admin);
    minter.setBlocked(alice, true);
    vm.warp(dayEnd(0));
    address[] memory users = new address[](2);
    uint256[] memory points = new uint256[](2);
    (users[0], users[1]) = (alice, bob);
    (points[0], points[1]) = (5 * POINT, 7 * POINT);
    vm.expectEmit(true, true, false, true, address(minter));
    emit IPointsMinterEvents.LendSkipped(0, alice, 5 * POINT);
    vm.prank(roller);
    minter.creditLend(0, users, points);
    assertEq(token.balanceOf(alice), 0);
    assertEq(minter.earned(alice).depositPoints, 0);
    assertTrue(minter.isLendCredited(0, alice));
    assertEq(minter.lendDay(0).total, 7 * POINT);
  }

  function test_creditLend_dayStartingAtOrAfterGenesisDoesNotCountTowardTiers(uint256 day) public {
    // day 30 starts exactly at genesis close
    day = bound(day, 30, 89);
    vm.warp(dayEnd(89));
    creditLendOne(day, alice, 2_000 * POINT);
    assertEq(minter.earned(alice).depositPoints, 2_000 * POINT);
    assertEq(minter.earned(alice).genesisDepositPoints, 0);
    (uint256 depositTier,) = minter.tierOf(alice);
    assertEq(depositTier, 0);
  }

  function test_creditLend_lastGenesisDayCreditedAfterCloseRaisesTier(uint256 creditDelay) public {
    creditDelay = bound(creditDelay, 0, 60 days);
    register(alice);
    // day 29 is the last day starting before genesis close; it ends exactly at the close
    assertEq(dayEnd(29), GENESIS_CLOSE);
    vm.warp(GENESIS_CLOSE + creditDelay);
    vm.expectEmit(true, true, false, true, address(minter));
    emit IPointsMinterEvents.LendCredited(29, alice, 1_000 * POINT, 1_050 * POINT, 10_500);
    creditLendOne(29, alice, 1_000 * POINT);
    assertEq(minter.earned(alice).genesisDepositPoints, 1_000 * POINT);
    (uint256 depositTier,) = minter.tierOf(alice);
    assertEq(depositTier, 1);
    assertEq(minter.multiplier(alice), 11_000);
    // a later, post-genesis day pays the new tier but does not add to it
    vm.warp(dayEnd(30));
    creditLendOne(30, alice, 100 * POINT);
    assertEq(token.balanceOf(alice), 1_050 * POINT + 110 * POINT);
    assertEq(minter.earned(alice).genesisDepositPoints, 1_000 * POINT);
  }

  function test_creditLend_zeroAssetsAllowsOnlyZero() public {
    vault.setTotalAssets(0);
    vm.warp(dayEnd(0));
    creditLendOne(0, alice, 0);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LendCapExceeded.selector, 0, 1, 0));
    creditLendOne(0, bob, 1);
  }

  function test_creditLend_revertsWhenPaused() public {
    vm.warp(dayEnd(0));
    vm.prank(admin);
    minter.setPaused(true);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    creditLendOne(0, alice, 1);
  }

  function test_creditLend_pointUnitScalesCap() public {
    PointsToken six = deployToken(6);
    PointsMinter sixMinter = deployMinter(address(six), defaultConfig());
    vm.startPrank(admin);
    six.grantRole(six.MINTER_ROLE(), address(sixMinter));
    sixMinter.grantRole(sixMinter.LEND_CREDITOR_ROLE(), roller);
    vm.stopPrank();
    vault.setTotalAssets(7_000e18);
    vm.warp(dayEnd(0));
    address[] memory users = new address[](1);
    uint256[] memory points = new uint256[](1);
    users[0] = alice;
    points[0] = 1_010e6;
    vm.prank(roller);
    sixMinter.creditLend(0, users, points);
    assertEq(sixMinter.lendDay(0).cap, 1_010e6);
    assertEq(six.balanceOf(alice), 1_010e6);
  }

  // ---------------------------------------------------------------- multiplier and tiers

  function test_multiplier_unregisteredIsOne() public {
    setGenesis(alice, 10_000, 10_000);
    assertEq(minter.multiplier(alice), 10_000);
    assertFalse(minter.isRegistered(alice));
  }

  function test_multiplier_firstNBonus() public {
    assertEq(register(alice), 1);
    assertEq(minter.multiplier(alice), 10_500);
  }

  function test_multiplier_noBonusAfterFirstN() public {
    PointsMinterConfig memory c = defaultConfig();
    c.firstN = 1;
    vm.prank(admin);
    minter.setConfig(c);
    register(alice);
    register(bob);
    assertEq(minter.multiplier(alice), 10_500);
    assertEq(minter.multiplier(bob), 10_000);
  }

  function test_multiplier_maxIsOnePointFourFive() public {
    register(alice);
    setGenesis(alice, 10_000, 10_000);
    (uint256 depositTier, uint256 borrowTier) = minter.tierOf(alice);
    assertEq(depositTier, 3);
    assertEq(borrowTier, 3);
    assertEq(minter.multiplier(alice), 14_500);
  }

  function test_tier_thresholds() public {
    register(alice);
    vm.warp(dayEnd(0));
    creditLendOne(0, alice, 1_000 * POINT - 1);
    (uint256 depositTier,) = minter.tierOf(alice);
    assertEq(depositTier, 0);
    vm.warp(dayEnd(1));
    creditLendOne(1, alice, 1);
    (depositTier,) = minter.tierOf(alice);
    assertEq(depositTier, 1);
    assertEq(minter.multiplier(alice), 11_000);
    vm.warp(dayEnd(2));
    creditLendOne(2, alice, 4_000 * POINT);
    (depositTier,) = minter.tierOf(alice);
    assertEq(depositTier, 2);
    assertEq(minter.multiplier(alice), 11_500);
    vm.warp(dayEnd(3));
    creditLendOne(3, alice, 5_000 * POINT);
    (depositTier,) = minter.tierOf(alice);
    assertEq(depositTier, 3);
    assertEq(minter.multiplier(alice), 12_500);
  }

  function testFuzz_multiplier_bounded(uint64 depositWhole, uint64 borrowWhole, bool registered) public {
    if (registered) register(alice);
    vault.setTotalAssets(type(uint128).max);
    setGenesis(alice, depositWhole, borrowWhole);
    uint256 m = minter.multiplier(alice);
    assertGe(m, 10_000);
    assertLe(m, 14_500);
    if (!registered) assertEq(m, 10_000);
  }

  function test_multiplier_revokedKeepsNumberAndDropsBoosters() public {
    register(alice);
    setGenesis(alice, 5_000, 0);
    assertEq(minter.multiplier(alice), 11_500);
    vm.expectEmit(true, false, false, true, address(minter));
    emit IPointsMinterEvents.RevokedSet(alice, true);
    vm.prank(admin);
    minter.setRevoked(alice, true);
    assertEq(minter.multiplier(alice), 10_000);
    assertTrue(minter.isRegistered(alice));
    assertEq(minter.earned(alice).whitelistNumber, 1);
    vm.warp(dayEnd(1));
    creditLendOne(1, alice, 100 * POINT);
    assertEq(token.balanceOf(alice), 5_000 * POINT * 105 / 100 + 100 * POINT);
    vm.prank(admin);
    minter.setRevoked(alice, false);
    assertEq(minter.multiplier(alice), 11_500);
  }

  function test_multiplier_blockedIsOne() public {
    register(alice);
    vm.prank(admin);
    minter.setBlocked(alice, true);
    assertEq(minter.multiplier(alice), 10_000);
  }

  function test_multiplier_notRetroactive() public {
    // Earn while unregistered: 1.0x, and enough genesis points for deposit tier 3
    vm.warp(dayEnd(0));
    creditLendOne(0, alice, 10_000 * POINT);
    assertEq(token.balanceOf(alice), 10_000 * POINT);
    // Registration does not touch past mints
    register(alice);
    assertEq(token.balanceOf(alice), 10_000 * POINT);
    assertEq(minter.multiplier(alice), 12_500);
    // Only the next mint is boosted
    vm.warp(dayEnd(1));
    creditLendOne(1, alice, 100 * POINT);
    assertEq(token.balanceOf(alice), 10_000 * POINT + 125 * POINT);
  }

  function test_multiplier_tierCrossedByACreditAppliesFromTheNextMint() public {
    register(alice);
    vm.warp(dayEnd(0));
    vm.expectEmit(true, true, false, true, address(minter));
    emit IPointsMinterEvents.LendCredited(0, alice, 1_000 * POINT, 1_050 * POINT, 10_500);
    creditLendOne(0, alice, 1_000 * POINT);
    assertEq(minter.multiplier(alice), 11_000);
    vm.warp(dayEnd(1));
    creditLendOne(1, alice, 100 * POINT);
    assertEq(token.balanceOf(alice), 1_050 * POINT + 110 * POINT);
  }

  // ---------------------------------------------------------------- admin

  function test_setConfig() public {
    PointsMinterConfig memory c = defaultConfig();
    c.lendToleranceBps = 50;
    vm.expectEmit(false, false, false, true, address(minter));
    emit IPointsMinterEvents.ConfigSet(c);
    vm.prank(admin);
    minter.setConfig(c);
    assertEq(minter.config().lendToleranceBps, 50);
  }

  function test_setConfig_revertsWithoutAdmin(address caller) public {
    vm.assume(caller != admin);
    PointsMinterConfig memory c = defaultConfig();
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, minter.DEFAULT_ADMIN_ROLE()
      )
    );
    vm.prank(caller);
    minter.setConfig(c);
  }

  function expectInvalid(PointsMinterConfig memory c) internal {
    vm.expectRevert(IPointsMinterErrors.InvalidConfig.selector);
    vm.prank(admin);
    minter.setConfig(c);
  }

  function test_setConfig_rejectsInvalid() public {
    PointsMinterConfig memory c = defaultConfig();
    c.loanManager = address(0);
    expectInvalid(c);
    c = defaultConfig();
    c.rolloverVault = address(0);
    expectInvalid(c);
    c = defaultConfig();
    c.programStart = 0;
    expectInvalid(c);
    c = defaultConfig();
    c.programEnd = c.programStart;
    expectInvalid(c);
    c = defaultConfig();
    c.genesisCloseAt = c.programStart - 1;
    expectInvalid(c);
    c = defaultConfig();
    c.genesisCloseAt = c.programEnd + 1;
    expectInvalid(c);
    c = defaultConfig();
    c.lendToleranceBps = 1_001;
    expectInvalid(c);
    c = defaultConfig();
    c.tierThresholds = [uint32(0), 5_000, 10_000];
    expectInvalid(c);
    c = defaultConfig();
    c.tierThresholds = [uint32(5_000), 5_000, 10_000];
    expectInvalid(c);
    c = defaultConfig();
    c.tierThresholds = [uint32(1_000), 10_000, 10_000];
    expectInvalid(c);
    c = defaultConfig();
    c.tierBps = [uint16(1_000), 500, 2_000];
    expectInvalid(c);
    c = defaultConfig();
    c.tierBps = [uint16(500), 2_001, 2_000];
    expectInvalid(c);
    c = defaultConfig();
    c.tierBps = [uint16(500), 1_000, 2_001];
    expectInvalid(c);
    c = defaultConfig();
    c.firstNBonusBps = 501;
    expectInvalid(c);
  }

  function testFuzz_setConfig_multiplierCeilingHolds(uint16[3] memory tierBps, uint16 bonus) public {
    PointsMinterConfig memory c = defaultConfig();
    c.tierBps = tierBps;
    c.firstNBonusBps = bonus;
    bool valid =
      tierBps[0] <= tierBps[1] && tierBps[1] <= tierBps[2] && 10_000 + 2 * uint256(tierBps[2]) + bonus <= 14_500;
    if (!valid) {
      expectInvalid(c);
      return;
    }
    vm.prank(admin);
    minter.setConfig(c);
    register(alice);
    setGenesis(alice, 10_000, 10_000);
    assertLe(minter.multiplier(alice), 14_500);
  }

  function test_setConfig_programStartLockedOnceReached() public {
    PointsMinterConfig memory c = defaultConfig();
    c.programStart = PROGRAM_START - 1 hours;
    vm.prank(admin);
    minter.setConfig(c);
    vm.warp(c.programStart);
    c.programStart = PROGRAM_START;
    expectInvalid(c);
    c.programStart = PROGRAM_START - 1 hours;
    c.programEnd = PROGRAM_END + 30 days;
    vm.prank(admin);
    minter.setConfig(c);
    assertEq(minter.config().programEnd, PROGRAM_END + 30 days);
  }

  function test_setRevokedAndSetBlocked_revertWithoutAdmin(address caller) public {
    vm.assume(caller != admin);
    bytes memory err = abi.encodeWithSelector(
      IAccessControl.AccessControlUnauthorizedAccount.selector, caller, minter.DEFAULT_ADMIN_ROLE()
    );
    vm.expectRevert(err);
    vm.prank(caller);
    minter.setRevoked(alice, true);
    vm.expectRevert(err);
    vm.prank(caller);
    minter.setBlocked(alice, true);
    vm.expectRevert(err);
    vm.prank(caller);
    minter.setPaused(true);
  }

  function test_setBlocked_emits() public {
    vm.expectEmit(true, false, false, true, address(minter));
    emit IPointsMinterEvents.BlockedSet(alice, true);
    vm.prank(admin);
    minter.setBlocked(alice, true);
    assertTrue(minter.earned(alice).blocked);
  }

  function test_setPaused_unpauseRestoresCredits() public {
    vm.startPrank(admin);
    minter.setPaused(true);
    minter.setPaused(false);
    vm.stopPrank();
    vm.warp(dayEnd(0));
    creditLendOne(0, alice, 1);
    assertEq(token.balanceOf(alice), 1);
  }

  function test_roleSeparation_creditorHasNoAdminPowers() public {
    bytes32 adminRole = minter.DEFAULT_ADMIN_ROLE();
    bytes memory err =
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, roller, adminRole);
    PointsMinterConfig memory c = defaultConfig();
    PointsMinterV2 next = new PointsMinterV2();
    bytes32 burnerRole = token.BURNER_ROLE();
    bytes32 minterRole = token.MINTER_ROLE();
    vm.startPrank(roller);
    vm.expectRevert(err);
    minter.setConfig(c);
    vm.expectRevert(err);
    minter.setPaused(true);
    vm.expectRevert(err);
    minter.setBlocked(alice, true);
    vm.expectRevert(err);
    minter.upgradeToAndCall(address(next), "");
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, roller, burnerRole)
    );
    token.burn(alice, 0);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, roller, minterRole)
    );
    token.mint(roller, 1);
    vm.stopPrank();
  }

  function test_roleSeparation_creditorCannotRegisterWithoutAttestation() public {
    bytes memory signature = attest(alice, block.timestamp + 1);
    vm.expectPartialRevert(IPointsMinterErrors.InvalidAttestation.selector);
    vm.prank(roller);
    minter.register(block.timestamp + 1, signature);
  }

  function test_roleSeparation_minterContractCannotBurn() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(minter), token.BURNER_ROLE()
      )
    );
    vm.prank(address(minter));
    token.burn(alice, 0);
  }

  function test_adminCanBurnMintedPoints() public {
    vm.warp(dayEnd(0));
    creditLendOne(0, alice, 10 * POINT);
    vm.prank(admin);
    token.burn(alice, 10 * POINT);
    assertEq(token.balanceOf(alice), 0);
    assertEq(minter.earned(alice).depositPoints, 10 * POINT);
  }

  function test_upgrade_revertsForNonAdmin(address caller) public {
    vm.assume(caller != admin);
    PointsMinterV2 next = new PointsMinterV2();
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, caller, minter.DEFAULT_ADMIN_ROLE()
      )
    );
    vm.prank(caller);
    minter.upgradeToAndCall(address(next), "");
  }

  function test_upgrade_byAdminKeepsState() public {
    register(alice);
    vm.warp(dayEnd(0));
    creditLendOne(0, alice, 10 * POINT);
    PointsMinterV2 next = new PointsMinterV2();
    vm.prank(admin);
    minter.upgradeToAndCall(address(next), "");
    assertTrue(PointsMinterV2(address(minter)).newFunction());
    assertEq(minter.earned(alice).whitelistNumber, 1);
    assertEq(minter.earned(alice).depositPoints, 10 * POINT);
    assertTrue(minter.isLendCredited(0, alice));
    assertEq(minter.registeredCount(), 1);
    assertEq(minter.config().programStart, PROGRAM_START);
    // the EIP-712 domain survives the upgrade
    bytes memory signature = attest(bob, block.timestamp + 1);
    vm.prank(bob);
    minter.register(block.timestamp + 1, signature);
    assertEq(minter.earned(bob).whitelistNumber, 2);
  }

  function test_lendNeverReferencesPools_onlyVaultAssets() public {
    // The day cap reads totalAssets() and nothing else; changing anything other than total assets changes nothing.
    vault.setTotalAssets(7e18);
    vm.warp(dayEnd(0));
    vm.expectCall(address(vault), abi.encodeWithSignature("totalAssets()"), 1);
    creditLendOne(0, alice, 1e18);
    assertEq(minter.lendDay(0).cap, 1.01e18);
  }
}

interface MockNFTLike {
  function transferFrom(address from, address to, uint256 tokenId) external;
}
