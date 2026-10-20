// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PointsToken} from "../../src/points/PointsToken.sol";
import {PointsMinter} from "../../src/points/PointsMinter.sol";
import {IPointsMinterErrors} from "../../src/interfaces/IPointsMinter/IPointsMinterErrors.sol";
import {PointsMinterConfig} from "../../src/interfaces/IPointsMinter/PointsMinterTypes.sol";

/// Runs the minter against the real LoanManager and RolloverVault from the core test setup.
contract PointsMinterIntegrationTest is BaseTest {
  PointsToken internal points;
  PointsMinter internal minter;
  address internal pointsRoller = makeAddr("pointsRoller");

  function setUp() public {
    setUpCore();
    setUpRolloverVault();

    PointsToken tokenImplementation = new PointsToken();
    points = PointsToken(
      address(
        new ERC1967Proxy(
          address(tokenImplementation), abi.encodeCall(PointsToken.initialize, ("Buttonwood Points", "BWP", 18, admin))
        )
      )
    );

    PointsMinterConfig memory c;
    c.loanManager = address(loanManager);
    c.rolloverVault = address(rolloverVault);
    c.attestationSigner = makeAddr("attestationSigner");
    c.programStart = uint64(block.timestamp);
    c.programEnd = uint64(block.timestamp + 90 days);
    c.genesisCloseAt = uint64(block.timestamp + 30 days);
    c.lendToleranceBps = 100;
    c.firstNBonusBps = 500;
    c.firstN = 500;
    c.borrowClip = 10_000;
    c.tierThresholds = [uint32(1_000), 5_000, 10_000];
    c.tierBps = [uint16(500), 1_000, 2_000];
    PointsMinter minterImplementation = new PointsMinter();
    minter = PointsMinter(
      address(
        new ERC1967Proxy(
          address(minterImplementation), abi.encodeCall(PointsMinter.initialize, (address(points), c, admin))
        )
      )
    );

    vm.startPrank(admin);
    points.grantRole(points.MINTER_ROLE(), address(minter));
    minter.grantRole(minter.LEND_CREDITOR_ROLE(), pointsRoller);
    vm.stopPrank();
  }

  function test_creditLend_boundedByRealRolloverVault() public {
    vm.warp(block.timestamp + 1 days);
    uint256 assets = rolloverVault.totalAssets();
    assertGt(assets, 0);
    uint256 cap = assets * 10_100 / 70_000;
    address[] memory users = new address[](1);
    uint256[] memory amounts = new uint256[](1);
    users[0] = user;
    amounts[0] = cap + 1;
    vm.prank(pointsRoller);
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LendCapExceeded.selector, 0, cap + 1, cap));
    minter.creditLend(0, users, amounts);
    amounts[0] = cap;
    vm.prank(pointsRoller);
    minter.creditLend(0, users, amounts);
    assertEq(points.balanceOf(user), cap);
  }

  function test_creditBorrow_decodesRealLoanManagerPosition(uint256 tokenId) public {
    vm.expectRevert(abi.encodeWithSelector(IPointsMinterErrors.LoanOutsideProgram.selector, tokenId, 0));
    minter.creditBorrow(tokenId);
  }
}
