// SPDX-License-Identifier: The Unlicense
pragma solidity 0.8.19;

import "solmate/mixins/ERC4626.sol";
import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {Comptroller, CToken} from "clm/Comptroller.sol";
import {WETH} from "clm/WETH.sol";

interface IWOOF {
    function getCInuBurnt(uint256 tokenId) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256 balance);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;
}

interface ICINU {
    function burn(uint256 value) external;
}

interface IRouter {

    function swapExactTokensForTokensSimple(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract xCINU is ERC4626, ERC721TokenReceiver, Owned(msg.sender) {
    using SafeTransferLib for ERC20;

    IWOOF       public immutable woof;
    Comptroller public constant comptroller = Comptroller(0x5E23dC409Fc2F832f83CEc191E245A191a4bCc5C);
    WETH        public constant weth = WETH(payable(0x826551890Dc65655a0Aceca109aB11AbDbD7a07B));
    CToken      public constant cCanto_NOTE = CToken(0x3C96dCfd875253A37acB3D2B102b6f328349b16B); 

    IRouter      public constant veloRouter = IRouter(0x8e2e2f70B4bD86F82539187A634FB832398cc771);

    // depositor[address] = nftId
    mapping(address => uint256) public nftDepositor; 

    // levels of cinu burn to calculate the deposit tax (under 125 canto or no NFT = 10% tax)
    uint256[4] private _burnLevels = [
        1000 ether * 420_000_000,   // 1 %
        500 ether * 420_000_000,    // 2 %
        250 ether * 420_000_000,    // 4 %
        125 ether * 420_000_000     // 6.66666 %
    ];

    constructor (address _cinu, address _woof) ERC4626(ERC20(_cinu), "xCANTO INU", "xCINU") {
        woof = IWOOF(_woof);
        asset.approve(address(veloRouter), type(uint256).max);
    }
    
    // do this
    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }


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
        if(nftDepositor[receiver] == 0 && woof.balanceOf(msg.sender) != 0) {
            uint idIdx0 = woof.tokenOfOwnerByIndex(msg.sender, 0);
            woof.transferFrom(msg.sender, address(this), idIdx0);
            nftDepositor[receiver] = idIdx0;
        }
        
        // Handle the tax deduction logic
        uint256 tax = calculateTax(assets, receiver);
        uint256 assetsAfterTax = assets - tax;
        
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assetsAfterTax)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);
        ICINU(address(asset)).burn(tax);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assetsAfterTax, shares);

        afterDeposit(assetsAfterTax, shares);
    }


    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        if(nftDepositor[receiver] == 0 && woof.balanceOf(msg.sender) != 0) {
            uint idIdx0 = woof.tokenOfOwnerByIndex(msg.sender, 0);
            woof.transferFrom(msg.sender, address(this), idIdx0);
            nftDepositor[receiver] = idIdx0;
        }
        
        uint256 assetsPreTax = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        uint256 tax = calculateTax(assetsPreTax, receiver);
        assets = assetsPreTax - tax;

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assetsPreTax);
        ICINU(address(asset)).burn(tax);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);

    }

    function calculateTax(uint256 amt, address receiver) public view returns (uint256 taxAmt) {
        // check if the user's burn stats
        uint256 tokenId = nftDepositor[receiver];
        uint256 cinuBurnt = woof.getCInuBurnt(tokenId);
        if (cinuBurnt > _burnLevels[0]) {
            taxAmt = (amt / 100);
        } else if (cinuBurnt > _burnLevels[1]) {
            taxAmt = (amt / 100);
        } else if (cinuBurnt < _burnLevels[2]) {
            taxAmt = (amt / 100);
        } else if (cinuBurnt < _burnLevels[3]) {
            taxAmt = (amt / 100);
        } else {
            taxAmt = (amt / 100);
        }
    }

    // should perform claimComp and swap
    function _performCompClaim() internal {
        CToken[] memory token = new CToken[](1);
        token[0] = cCanto_NOTE;
        address[] memory addr = new address[](1);
        addr[0] = address(this);
        comptroller.claimComp(addr, token, false, true);
    }

    function _swapCantoForCinu() internal {
        veloRouter.swapExactTokensForTokensSimple(
            weth.balanceOf(address(this)),
            10,
            address(weth),
            address(asset),
            false,
            address(this),
            (block.timestamp + 1)
        );

    }

    function afterDeposit(uint256 assets, uint256 shares) internal override {
        
        // claim WCANTO and check balance
        _performCompClaim();

        // swap WCANTO for CINU
        _swapCantoForCinu();
    }

    function beforeWithdraw(uint256 assets, uint256 shares) internal override {
        if(nftDepositor[msg.sender] != 0) {
            woof.safeTransferFrom(address(this), msg.sender, nftDepositor[msg.sender]);
        }

        // claim WCANTO and check balance
        _performCompClaim();

        // swap WCANTO for CINU
        _swapCantoForCinu();
    }

    // owner only functions to rescue lost assets
    function retrieveCToken(address cToken) public onlyOwner {
        CToken token = CToken(cToken);
        uint256 bal = token.balanceOf(address(this));
        token.transfer(msg.sender, bal);
    }

    function rescueWETH() public onlyOwner {
        uint256 bal = weth.balanceOf(address(this));
        weth.transfer(msg.sender, bal);
    }

    function extraApproval() public onlyOwner {
        asset.approve(address(veloRouter), type(uint256).max);
    }


}
