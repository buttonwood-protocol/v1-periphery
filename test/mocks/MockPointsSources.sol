// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {MortgagePosition} from "@core/types/MortgagePosition.sol";

contract MockMortgageNFT is ERC721 {
  constructor() ERC721("Mock Mortgage", "MMORT") {}

  function mint(address to, uint256 tokenId) external {
    _mint(to, tokenId);
  }

  function burn(uint256 tokenId) external {
    _burn(tokenId);
  }
}

contract MockLoanManager {
  address public immutable nft;
  mapping(uint256 => MortgagePosition) internal positions;

  constructor() {
    nft = address(new MockMortgageNFT());
  }

  function setPosition(uint256 tokenId, uint32 dateOriginated, uint256 amountBorrowed) external {
    positions[tokenId].tokenId = tokenId;
    positions[tokenId].dateOriginated = dateOriginated;
    positions[tokenId].amountBorrowed = amountBorrowed;
  }

  function createLoan(address owner, uint256 tokenId, uint32 dateOriginated, uint256 amountBorrowed) external {
    MockMortgageNFT(nft).mint(owner, tokenId);
    positions[tokenId].tokenId = tokenId;
    positions[tokenId].dateOriginated = dateOriginated;
    positions[tokenId].amountBorrowed = amountBorrowed;
  }

  function getMortgagePosition(uint256 tokenId) external view returns (MortgagePosition memory) {
    return positions[tokenId];
  }
}

contract MockTotalAssetsVault {
  uint256 public totalAssets;

  function setTotalAssets(uint256 _totalAssets) external {
    totalAssets = _totalAssets;
  }
}
