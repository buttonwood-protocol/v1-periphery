// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PointsToken} from "../../src/points/PointsToken.sol";
import {PointsMinter} from "../../src/points/PointsMinter.sol";
import {PointsMinterConfig} from "../../src/interfaces/IPointsMinter/PointsMinterTypes.sol";
import {MockLoanManager, MockTotalAssetsVault} from "../mocks/MockPointsSources.sol";

abstract contract PointsBase is Test {
  bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  uint64 internal constant PROGRAM_START = 1_800_000_000;
  uint64 internal constant PROGRAM_END = PROGRAM_START + 90 days;
  uint64 internal constant GENESIS_CLOSE = PROGRAM_START + 30 days;
  uint16 internal constant TOLERANCE_BPS = 100;
  uint256 internal constant POINT = 1e18;

  address internal admin = makeAddr("admin");
  address internal roller = makeAddr("roller");
  address internal rando = makeAddr("rando");
  uint256 internal signerPk = 0xA11CE;
  address internal signer = vm.addr(0xA11CE);

  PointsToken internal token;
  PointsMinter internal minter;
  MockLoanManager internal loanManager;
  MockTotalAssetsVault internal vault;

  function defaultConfig() internal view returns (PointsMinterConfig memory c) {
    c.loanManager = address(loanManager);
    c.rolloverVault = address(vault);
    c.attestationSigner = signer;
    c.programStart = PROGRAM_START;
    c.programEnd = PROGRAM_END;
    c.genesisCloseAt = GENESIS_CLOSE;
    c.lendToleranceBps = TOLERANCE_BPS;
    c.firstNBonusBps = 500;
    c.firstN = 500;
    c.borrowClip = 10_000;
    c.tierThresholds = [uint32(1_000), 5_000, 10_000];
    c.tierBps = [uint16(500), 1_000, 2_000];
  }

  function deployToken(uint8 decimals) internal returns (PointsToken) {
    PointsToken implementation = new PointsToken();
    bytes memory data = abi.encodeCall(PointsToken.initialize, ("Buttonwood Points", "BWP", decimals, admin));
    return PointsToken(address(new ERC1967Proxy(address(implementation), data)));
  }

  function deployMinter(address pointsToken, PointsMinterConfig memory c) internal returns (PointsMinter) {
    PointsMinter implementation = new PointsMinter();
    bytes memory data = abi.encodeCall(PointsMinter.initialize, (pointsToken, c, admin));
    return PointsMinter(address(new ERC1967Proxy(address(implementation), data)));
  }

  function setUpPoints(uint8 decimals) internal {
    vm.warp(PROGRAM_START - 1 days);
    loanManager = new MockLoanManager();
    vault = new MockTotalAssetsVault();
    token = deployToken(decimals);
    minter = deployMinter(address(token), defaultConfig());
    vm.startPrank(admin);
    token.grantRole(token.MINTER_ROLE(), address(minter));
    token.grantRole(token.BURNER_ROLE(), admin);
    minter.grantRole(minter.LEND_CREDITOR_ROLE(), roller);
    vm.stopPrank();
  }

  function domainSeparator(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
    return keccak256(
      abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("PointsMinter"), keccak256("1"), chainId, verifyingContract)
    );
  }

  function attest(uint256 pk, address wallet, uint256 expiry, uint256 chainId, address verifyingContract)
    internal
    view
    returns (bytes memory)
  {
    bytes32 structHash = keccak256(abi.encode(minter.REGISTRATION_TYPEHASH(), wallet, expiry));
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(chainId, verifyingContract), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return abi.encodePacked(r, s, v);
  }

  function attest(address wallet, uint256 expiry) internal view returns (bytes memory) {
    return attest(signerPk, wallet, expiry, block.chainid, address(minter));
  }

  function register(address wallet) internal returns (uint256) {
    bytes memory signature = attest(wallet, block.timestamp + 1 hours);
    vm.prank(wallet);
    return minter.register(block.timestamp + 1 hours, signature);
  }

  function creditLendOne(uint256 day, address wallet, uint256 points) internal {
    address[] memory users = new address[](1);
    uint256[] memory amounts = new uint256[](1);
    users[0] = wallet;
    amounts[0] = points;
    vm.prank(roller);
    minter.creditLend(day, users, amounts);
  }

  function dayEnd(uint256 day) internal pure returns (uint256) {
    return uint256(PROGRAM_START) + (day + 1) * 1 days;
  }
}
