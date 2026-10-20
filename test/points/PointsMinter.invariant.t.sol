// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PointsBase} from "./PointsBase.t.sol";
import {PointsMinter} from "../../src/points/PointsMinter.sol";
import {PointsToken} from "../../src/points/PointsToken.sol";
import {WalletRecord, LendDay} from "../../src/interfaces/IPointsMinter/PointsMinterTypes.sol";
import {MockLoanManager, MockTotalAssetsVault} from "../mocks/MockPointsSources.sol";

contract PointsMinterHandler is Test {
  uint256 internal constant BPS = 10_000;

  PointsMinter internal minter;
  PointsToken internal token;
  MockLoanManager internal loanManager;
  MockTotalAssetsVault internal vault;
  address internal admin;
  address internal roller;
  uint256 internal signerPk;
  uint256 internal programStart;
  uint256 internal programEnd;

  address[] public actors;
  uint256 internal nextTokenId = 1;
  uint256[] internal creditedLoans;
  uint256[] public touchedDays;
  mapping(uint256 => bool) internal dayTouched;
  mapping(uint256 => uint256) public ghostDayTotal;
  mapping(address => uint256) public ghostBalance;
  uint256 public ghostDoubleCredits;
  uint256 public ghostMovesSucceeded;
  uint256 public ghostLastNumber;
  uint256 public ghostNumberGaps;
  uint256 public ghostLendCalls;
  uint256 public ghostBorrowCalls;

  constructor(
    PointsMinter _minter,
    PointsToken _token,
    MockLoanManager _loanManager,
    MockTotalAssetsVault _vault,
    address _admin,
    address _roller,
    uint256 _signerPk
  ) {
    minter = _minter;
    token = _token;
    loanManager = _loanManager;
    vault = _vault;
    admin = _admin;
    roller = _roller;
    signerPk = _signerPk;
    programStart = _minter.config().programStart;
    programEnd = _minter.config().programEnd;
    for (uint256 i = 0; i < 6; i++) {
      actors.push(address(uint160(0xA000 + i)));
    }
  }

  function actorCount() external view returns (uint256) {
    return actors.length;
  }

  function touchedDayCount() external view returns (uint256) {
    return touchedDays.length;
  }

  function warp(uint256 seconds_) external {
    seconds_ = bound(seconds_, 0, 2 days);
    if (block.timestamp + seconds_ > programEnd + 3 days) return;
    vm.warp(block.timestamp + seconds_);
  }

  function setAssets(uint256 assets) external {
    vault.setTotalAssets(bound(assets, 0, 1e27));
  }

  function register(uint256 actorSeed) external {
    address wallet = actors[actorSeed % actors.length];
    if (minter.isRegistered(wallet)) return;
    uint256 expiry = block.timestamp + 1 hours;
    bytes32 structHash = keccak256(abi.encode(minter.REGISTRATION_TYPEHASH(), wallet, expiry));
    bytes32 domain = keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("PointsMinter"),
        keccak256("1"),
        block.chainid,
        address(minter)
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    vm.prank(wallet);
    uint256 number = minter.register(expiry, abi.encodePacked(r, s, v));
    if (number != ghostLastNumber + 1) ghostNumberGaps++;
    ghostLastNumber = number;
  }

  function borrow(uint256 actorSeed, uint256 amount) external {
    if (block.timestamp < programStart || block.timestamp >= programEnd) return;
    address wallet = actors[actorSeed % actors.length];
    uint256 tokenId = nextTokenId++;
    loanManager.createLoan(wallet, tokenId, uint32(block.timestamp), bound(amount, 0, 12_000e18));
    uint256 multiplierBps = minter.multiplier(wallet);
    uint256 before = minter.earned(wallet).borrowPoints;
    try minter.creditBorrow(tokenId) returns (uint256 minted) {
      ghostBalance[wallet] += (minter.earned(wallet).borrowPoints - before) * multiplierBps / BPS;
      assertEq(minted, (minter.earned(wallet).borrowPoints - before) * multiplierBps / BPS);
      creditedLoans.push(tokenId);
      ghostBorrowCalls++;
    } catch {}
  }

  function recreditBorrow(uint256 seed) external {
    if (creditedLoans.length == 0) return;
    try minter.creditBorrow(creditedLoans[seed % creditedLoans.length]) {
      ghostDoubleCredits++;
    } catch {}
  }

  function lend(uint256 daySeed, uint256[3] memory actorSeeds, uint256[3] memory amounts) external {
    if (block.timestamp < programStart + 1 days) return;
    uint256 completed = (block.timestamp - programStart) / 1 days;
    uint256 dayCount = (programEnd - programStart + 1 days - 1) / 1 days;
    if (completed > dayCount) completed = dayCount;
    uint256 day = daySeed % completed;

    LendDay memory d = minter.lendDay(day);
    uint256 remaining = d.opened ? d.cap - d.total : vault.totalAssets() * 10_100 / 70_000;

    address[] memory users = new address[](3);
    uint256[] memory points = new uint256[](3);
    uint256[] memory multipliers = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      users[i] = actors[actorSeeds[i] % actors.length];
      points[i] = amounts[i] % 16 == 0 ? bound(amounts[i], 0, 1e27) : bound(amounts[i], 0, remaining / 3);
      multipliers[i] = minter.multiplier(users[i]);
    }
    vm.prank(roller);
    try minter.creditLend(day, users, points) {
      ghostLendCalls++;
      if (!dayTouched[day]) {
        dayTouched[day] = true;
        touchedDays.push(day);
      }
      for (uint256 i = 0; i < 3; i++) {
        if (minter.earned(users[i]).blocked) continue;
        ghostDayTotal[day] += points[i];
        ghostBalance[users[i]] += points[i] * multipliers[i] / BPS;
      }
    } catch {}
  }

  function setBlocked(uint256 actorSeed, bool blocked) external {
    vm.prank(admin);
    minter.setBlocked(actors[actorSeed % actors.length], blocked);
  }

  function setRevoked(uint256 actorSeed, bool revoked) external {
    vm.prank(admin);
    minter.setRevoked(actors[actorSeed % actors.length], revoked);
  }

  function tryMove(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
    address from = actors[fromSeed % actors.length];
    address to = actors[toSeed % actors.length];
    vm.startPrank(from);
    try token.transfer(to, amount) {
      ghostMovesSucceeded++;
    } catch {}
    try token.approve(to, amount) {
      ghostMovesSucceeded++;
    } catch {}
    vm.stopPrank();
    vm.prank(to);
    try token.transferFrom(from, to, amount) {
      ghostMovesSucceeded++;
    } catch {}
  }
}

contract PointsMinterInvariantTest is PointsBase {
  PointsMinterHandler internal handler;

  function setUp() public {
    setUpPoints(18);
    vault.setTotalAssets(7_000_000e18);
    vm.warp(PROGRAM_START);
    handler = new PointsMinterHandler(minter, token, loanManager, vault, admin, roller, signerPk);
    targetContract(address(handler));
  }

  function invariant_lendDayTotalsBoundedAndExact() public view {
    for (uint256 i = 0; i < handler.touchedDayCount(); i++) {
      uint256 day = handler.touchedDays(i);
      LendDay memory d = minter.lendDay(day);
      assertLe(d.total, d.cap);
      assertEq(d.total, handler.ghostDayTotal(day));
    }
  }

  function invariant_eachLoanCreditedOnce() public view {
    assertEq(handler.ghostDoubleCredits(), 0);
  }

  function invariant_noTransferPathSucceeds() public view {
    assertEq(handler.ghostMovesSucceeded(), 0);
  }

  function invariant_whitelistNumbersSequential() public view {
    assertEq(handler.ghostNumberGaps(), 0);
    assertEq(minter.registeredCount(), handler.ghostLastNumber());
  }

  function invariant_walletBounds() public view {
    uint256 supply;
    for (uint256 i = 0; i < handler.actorCount(); i++) {
      address wallet = handler.actors(i);
      WalletRecord memory r = minter.earned(wallet);
      uint256 m = minter.multiplier(wallet);
      assertLe(r.borrowPoints, 10_000 * POINT, "borrow clip");
      assertLe(r.genesisBorrowPoints, r.borrowPoints);
      assertLe(r.genesisDepositPoints, r.depositPoints);
      assertGe(m, 10_000);
      assertLe(m, 14_500, "multiplier ceiling");
      if (r.whitelistNumber == 0) {
        assertEq(m, 10_000);
        assertEq(token.balanceOf(wallet), r.depositPoints + r.borrowPoints, "unregistered mints at 1.0x");
      }
      assertEq(token.balanceOf(wallet), handler.ghostBalance(wallet), "mint used the multiplier before the credit");
      supply += token.balanceOf(wallet);
    }
    assertEq(token.totalSupply(), supply);
  }
}
