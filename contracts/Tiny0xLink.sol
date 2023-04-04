// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Tiny0xLink is
    ERC721,
    ERC721Enumerable,
    ERC721URIStorage,
    ERC721Burnable,
    Ownable
{
    using Counters for Counters.Counter;

    uint256 private constant DECIMALS = 18;
    uint256 private constant MAX_PRICE = 1 * 10 ** DECIMALS; // $1

    Counters.Counter private _tokenIdCounter;
    address private _feesReceiver;
    IERC20 private _stableCoin;

    constructor() ERC721("Tiny0xLink", "T0XLink") {}

    function setFeesReceiver(address feesReceiver) public onlyOwner {
        _feesReceiver = feesReceiver;
    }

    function setstableCoin(address stableCoinAddress) public onlyOwner {
        _stableCoin = IERC20(stableCoinAddress);
    }

    function safeMint(address to, string memory uri) public onlyOwner {
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function safeMintWithPrice(
        address to,
        string memory uri,
        uint256 price
    ) public onlyOwner {
        safeMint(to, uri);
        require(
            price <= MAX_PRICE,
            "Tiny0x Link NFT Price cannot exceed MAX_PRICE"
        );
        if (price > 0) {
            _stableCoin.transferFrom(msg.sender, _feesReceiver, price);
        }
    }

    // The following functions are overrides required by Solidity.

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function _burn(
        uint256 tokenId
    ) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
