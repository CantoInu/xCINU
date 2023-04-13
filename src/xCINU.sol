// SPDX-License-Identifier: The Unlicense
pragma solidity 0.8.19;

import "solmate/mixins/ERC4626.sol";
import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";

interface IWOOF {
    function getCInuBurnt(uint256 tokenId) external view returns (uint256);
}

interface ICINU {
    function burn(uint256 value) external;
}

contract xCINU is ERC4626, ERC721TokenReceiver {
    using SafeTransferLib for ERC20;

    IWOOF public immutable woof;

    // depositor[address] = nftId
    mapping(address => uint256) public nftDepositor; 

    // levels of cinu burn to calculate the deposit tax (under 100 ether or no NFT = 10% tax)
    uint256[4] private _burnLevels = [
        1000 ether * 420_000_000,   // 1 %
        500 ether * 420_000_000,    // 2 %
        250 ether * 420_000_000,    // 4 %
        125 ether * 420_000_000     // 6.66666 %
    ];

    constructor (address _cinu, address _woof) ERC4626(ERC20(_cinu), "xCANTO INU", "xCINU") {
        woof = IWOOF(_woof);
    }
    
    // do this
    function totalAssets() public view override returns (uint256) {}


    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        require(msg.sender == address(woof), "Not WOOF");

        // check if the token is already deposited
        require(nftDepositor[from] == 0, "WOOF already deposited");

        nftDepositor[from] = tokenId;

        return ERC721TokenReceiver.onERC721Received.selector;
    }


    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    // should handle burn logic
    function _beforeDeposit(uint256 assets, address receiver) internal returns (uint256) {
        // check if the user's burn stats
        uint256 tokenId = nftDepositor[receiver];
        uint256 cinuBurnt = woof.getCInuBurnt(tokenId);
        uint256 taxAmt;
        if (cinuBurnt > _burnLevels[0]) {
            taxAmt = (assets / 100);
        } else if (cinuBurnt > _burnLevels[1]) {
            taxAmt = (assets / 100);
        } else if (cinuBurnt < _burnLevels[2]) {
            taxAmt = (assets / 100);
        } else if (cinuBurnt < _burnLevels[3]) {
            taxAmt = (assets / 100);
        } else {
            taxAmt = (assets / 100);
        }

        ICINU(address(asset)).burn(taxAmt);

        return (assets - taxAmt);

    }

    // should perform claimComp and swap

    function afterDeposit(uint256 assets, uint256 shares) internal override {}

    function beforeWithdraw(uint256 assets, uint256 shares) internal override {}


}
