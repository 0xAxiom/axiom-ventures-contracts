// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AxiomVenturesFund1Testnet
 * @notice Testnet version with configurable USDC address
 */
contract AxiomVenturesFund1Testnet is 
    Initializable,
    ERC721Upgradeable,
    ERC2981Upgradeable,
    UUPSUpgradeable,
    ReentrancyGuard 
{
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    uint256 public constant SLIP_PRICE = 1010e6;
    uint256 public constant MAX_SUPPLY = 200;
    uint256 public constant MAX_PER_WALLET = 20;
    uint96 public constant ROYALTY_BPS = 250;

    address public safe;
    bool public depositsOpen;
    bool public tradingEnabled;
    uint256 public totalMinted;
    mapping(address => uint256) public slipsMintedBy;

    event Deposited(address indexed depositor, uint256 count, uint256 firstSlipId);
    event TradingEnabled();

    error DepositsNotOpen();
    error SoldOut();
    error ExceedsMaxPerWallet();
    error InvalidCount();
    error TradingNotEnabled();
    error OnlySafe();

    modifier onlySafe() {
        if (msg.sender != safe) revert OnlySafe();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _safe,
        address _usdc
    ) external initializer {
        __ERC721_init("Axiom Ventures Fund 1 (Testnet)", "AVF1-TEST");
        __ERC2981_init();

        safe = _safe;
        usdc = IERC20(_usdc);
        depositsOpen = true;
        
        _setDefaultRoyalty(_safe, ROYALTY_BPS);
    }

    function deposit(uint256 count) external nonReentrant {
        if (!depositsOpen) revert DepositsNotOpen();
        if (count == 0) revert InvalidCount();
        if (totalMinted + count > MAX_SUPPLY) revert SoldOut();
        if (slipsMintedBy[msg.sender] + count > MAX_PER_WALLET) revert ExceedsMaxPerWallet();

        usdc.safeTransferFrom(msg.sender, safe, count * SLIP_PRICE);

        uint256 firstSlipId = totalMinted;

        for (uint256 i = 0; i < count;) {
            _mint(msg.sender, totalMinted);
            totalMinted++;
            unchecked { ++i; }
        }
        
        slipsMintedBy[msg.sender] += count;

        emit Deposited(msg.sender, count, firstSlipId);
        
        if (totalMinted == MAX_SUPPLY && !tradingEnabled) {
            tradingEnabled = true;
            emit TradingEnabled();
        }
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && !tradingEnabled && from != safe) {
            revert TradingNotEnabled();
        }
        return super._update(to, tokenId, auth);
    }

    function enableTrading() external onlySafe {
        tradingEnabled = true;
        emit TradingEnabled();
    }

    function setDepositsOpen(bool _open) external onlySafe {
        depositsOpen = _open;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, ERC2981Upgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string(abi.encodePacked("https://axiomventures.xyz/api/nft/", _toString(tokenId)));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _authorizeUpgrade(address) internal override onlySafe {}
}
