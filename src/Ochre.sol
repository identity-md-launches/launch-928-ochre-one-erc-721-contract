// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IOchreCoin {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice The 737 pieces of Ochre. Payments go directly from the buyer to dead.
contract Ochre is ERC721 {
    error InvalidConfig();
    error InvalidCave();
    error InvalidRound();
    error InvalidPiece();
    error NotOpen();
    error NotClosed();
    error SoldOut();
    error InvalidProof();
    error AlreadyClaimed();
    error SeatsReleased();
    error NotReleased();
    error TooEarly();
    error AlreadyReleased();
    error PaymentFailed();
    error Unauthorized();
    error AlreadyFrozen();
    error InvalidBase();
    error InvalidQuantity();
    error ContractRecipient();

    event Bought(uint256 indexed id, address indexed buyer, uint256 price);
    event Claimed(uint256 indexed id, address indexed wallet);
    event Swept(uint256 indexed id);
    event Frozen(uint256 indexed cave, string base);
    event UnclaimedReleased();

    address public constant dead = 0x000000000000000000000000000000000000dEaD;
    uint8 public constant coinDecimals = 18;
    uint256 public constant MAX_SUPPLY = 737;
    address public coin;
    address public admin;
    address public adam;
    bytes32 public seatRoot;
    uint256 public startTime;
    uint256 public caveLength;
    uint256 public roundLength;
    uint256 public firstPrice;
    uint256 public floorPrice;

    struct Round {
        uint256 opening;
        uint256 lastLineSale;
        uint256 sold;
    }

    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => bytes32) public labels;
    mapping(uint256 => string) public frozenBase;
    mapping(uint256 => bool) public frozen;
    mapping(uint256 => uint256) private _sweepCursor;
    mapping(address => bool) public claimed;
    uint256 public nextFree = 1;
    uint256 public totalSupply;
    bool public unclaimedReleased;

    /// @dev Sixteen static arguments; dead and coin decimals are fixed, not arguments.
    /// No external calls, including coin metadata or receiver callbacks.
    constructor(
        address coin_,
        address admin_,
        address adam_,
        bytes32 seatRoot_,
        uint256 startTime_,
        uint256 caveLength_,
        uint256 roundLength_,
        uint256 firstPrice_,
        uint256 floorPrice_,
        bytes32 label1,
        bytes32 label2,
        bytes32 label3,
        bytes32 label4,
        bytes32 label5,
        bytes32 label6,
        bytes32 label7
    ) ERC721("Ochre", "OCHRE") {
        if (
            coin_ == address(0) || admin_ == address(0) || adam_ == address(0) || seatRoot_ == bytes32(0)
                || roundLength_ == 0 || roundLength_ > type(uint256).max / 21 || caveLength_ < 21 * roundLength_
                || caveLength_ > (type(uint256).max - startTime_) / 8 || floorPrice_ == 0
                || floorPrice_ > type(uint256).max / 2 || firstPrice_ < 2 * floorPrice_
        ) revert InvalidConfig();
        coin = coin_;
        admin = admin_;
        adam = adam_;
        seatRoot = seatRoot_;
        startTime = startTime_;
        caveLength = caveLength_;
        roundLength = roundLength_;
        firstPrice = firstPrice_;
        floorPrice = floorPrice_;
        bytes32[7] memory configuredLabels = [label1, label2, label3, label4, label5, label6, label7];
        for (uint256 i; i < 7; ++i) {
            _checkLabel(configuredLabels[i]);
            labels[i + 1] = configuredLabels[i];
        }
        _rounds[0].opening = firstPrice_;
        _mintPiece(adam_, 0);
        _mintPiece(admin_, 736);
    }

    function caveOpen(uint256 c) public view returns (uint256) {
        _checkCave(c);
        return startTime + (c - 1) * caveLength;
    }

    function caveClose(uint256 c) public view returns (uint256) {
        return caveOpen(c) + caveLength;
    }

    function roundOpen(uint256 c, uint256 r) public view returns (uint256) {
        _key(c, r);
        return caveOpen(c) + (r - 1) * roundLength;
    }

    /// @notice Zero and One map to their metadata caves, with round and slot zero.
    function piece(uint256 id) public pure returns (uint256 c, uint256 r, uint256 slot) {
        if (id > 736) revert InvalidPiece();
        if (id == 0) return (1, 0, 0);
        if (id == 736) return (7, 0, 0);
        uint256 offset = id - 1;
        return (offset / 105 + 1, (offset % 105) / 5 + 1, offset % 5 + 1);
    }

    function saleCount(uint256 c, uint256 r) public pure returns (uint256) {
        _key(c, r);
        if (c == 7 && r == 21) return 5;
        if (c < 3) return 1;
        if (c < 5) return c - 1;
        return 4;
    }

    function isSalePiece(uint256 id) public pure returns (bool) {
        (uint256 c, uint256 r, uint256 slot) = piece(id);
        if (slot == 0) return false;
        return slot > 5 - saleCount(c, r);
    }

    function roundSold(uint256 c, uint256 r) external view returns (uint256) {
        return _rounds[_key(c, r)].sold;
    }

    function lastLineSale(uint256 c, uint256 r) external view returns (uint256) {
        return _rounds[_key(c, r)].lastLineSale;
    }

    function openingPrice(uint256 c, uint256 r) public view returns (uint256) {
        return _opening(_key(c, r));
    }

    function priceNow(uint256 c, uint256 r) public view returns (uint256) {
        uint256 opens = roundOpen(c, r);
        if (block.timestamp < opens || block.timestamp >= caveClose(c)) revert NotOpen();
        return _price(_opening(_key(c, r)), block.timestamp - opens);
    }

    function buy(uint256 c, uint256 r) external returns (uint256 id) {
        uint256 key = _key(c, r);
        uint256 opens = roundOpen(c, r);
        if (block.timestamp < opens || block.timestamp >= caveClose(c)) revert NotOpen();
        Round storage state = _rounds[key];
        if (state.sold == saleCount(c, r)) revert SoldOut();
        uint256 opening = _opening(key);
        uint256 price = _price(opening, block.timestamp - opens);
        state.opening = opening;
        if (price > floorPrice) state.lastLineSale = price;
        id = (c - 1) * 105 + r * 5 - state.sold;
        ++state.sold;
        _mintPiece(msg.sender, id);
        emit Bought(id, msg.sender, price);
        _pay(price);
    }

    function claimSeat(bytes32[] calldata proof) external returns (uint256 id) {
        if (block.timestamp < startTime) revert TooEarly();
        if (unclaimedReleased) revert SeatsReleased();
        if (claimed[msg.sender]) revert AlreadyClaimed();
        bytes32 hash = keccak256(abi.encodePacked(msg.sender));
        for (uint256 i; i < proof.length; ++i) {
            bytes32 sibling = proof[i];
            hash = hash < sibling ? keccak256(abi.encode(hash, sibling)) : keccak256(abi.encode(sibling, hash));
        }
        if (hash != seatRoot) revert InvalidProof();
        claimed[msg.sender] = true;
        id = _takeFree();
        _mintPiece(msg.sender, id);
        emit Claimed(id, msg.sender);
    }

    function releaseUnclaimed() external {
        if (block.timestamp < startTime + 8 * caveLength) revert TooEarly();
        if (unclaimedReleased) revert AlreadyReleased();
        unclaimedReleased = true;
        emit UnclaimedReleased();
    }

    function buyLeftover() external returns (uint256 id) {
        if (!unclaimedReleased) revert NotReleased();
        id = _takeFree();
        _mintPiece(msg.sender, id);
        emit Bought(id, msg.sender, floorPrice);
        _pay(floorPrice);
    }

    /// @notice Mint unsold sale pieces in ascending id order. Never touches seat pieces.
    function sweep(uint256 c, uint256 max) external returns (uint256 count) {
        if (block.timestamp < caveClose(c)) revert NotClosed();
        if (max == 0) revert InvalidQuantity();
        uint256 id = _sweepCursor[c];
        if (id == 0) id = (c - 1) * 105 + 1;
        uint256 end = c * 105;
        while (id <= end && count < max) {
            if (isSalePiece(id) && _ownerOf(id) == address(0)) {
                _mintPiece(admin, id);
                emit Swept(id);
                ++count;
            }
            ++id;
        }
        if (count == 0) revert SoldOut();
        _sweepCursor[c] = id;
    }

    function freeze(uint256 c, string calldata base) external {
        if (msg.sender != admin) revert Unauthorized();
        _checkCave(c);
        if (frozen[c]) revert AlreadyFrozen();
        bytes memory value = bytes(base);
        if (value.length == 0 || value[value.length - 1] != bytes1("/")) revert InvalidBase();
        frozen[c] = true;
        frozenBase[c] = base;
        emit Frozen(c, base);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        (uint256 c, uint256 r, uint256 slot) = piece(id);
        string memory base = _base(c);
        if (id == 0) return string.concat(base, "zero.json");
        if (id == 736) return string.concat(base, "one.json");
        string memory path =
            slot == 5 ? "gathering/" : string.concat("line-", string(abi.encodePacked(uint8(48 + slot))), "/");
        return string.concat(base, path, string(abi.encodePacked(uint8(48 + r / 10), uint8(48 + r % 10))), ".json");
    }

    function contractURI() external view returns (string memory) {
        return string.concat(_base(1), "collection.json");
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        return (admin, salePrice / 100);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId);
    }

    /// @dev The brief forbids receiver callbacks anywhere. Safe transfers accept only
    /// recipients without code; transferFrom remains available for contract custody.
    function safeTransferFrom(address from, address to, uint256 id, bytes memory) public override {
        if (to.code.length != 0) revert ContractRecipient();
        transferFrom(from, to, id);
    }

    function _opening(uint256 key) private view returns (uint256) {
        uint256 saved = _rounds[key].opening;
        if (saved != 0) return saved;
        uint256 quiet;
        while (key != 0) {
            --key;
            Round storage previous = _rounds[key];
            if (previous.opening != 0) {
                uint256 next = previous.opening / 2;
                if (previous.lastLineSale != 0) next = Math.max(next, 2 * previous.lastLineSale);
                return Math.max(2 * floorPrice, next >> quiet);
            }
            ++quiet;
        }
        // Round zero is always stored in the constructor.
        return firstPrice;
    }

    function _price(uint256 opening, uint256 elapsed) private view returns (uint256) {
        if (elapsed >= roundLength) return floorPrice;
        uint256 segments;
        uint256 end = opening;
        while (end > floorPrice) {
            end >>= 1;
            ++segments;
        }
        // Rational segment boundaries: no truncation of roundLength / segments.
        uint256 segment = Math.mulDiv(elapsed, segments, roundLength);
        uint256 remainder = mulmod(elapsed, segments, roundLength);
        uint256 high = opening >> segment;
        uint256 low = opening >> (segment + 1);
        return Math.max(floorPrice, high - Math.mulDiv(high - low, remainder, roundLength));
    }

    function _takeFree() private returns (uint256 id) {
        id = nextFree;
        while (id < 736 && isSalePiece(id)) ++id;
        if (id == 736) revert SoldOut();
        nextFree = id + 1;
    }

    function _pay(uint256 price) private {
        if (!IOchreCoin(coin).transferFrom(msg.sender, dead, price)) revert PaymentFailed();
    }

    function _mintPiece(address to, uint256 id) private {
        ++totalSupply;
        _mint(to, id);
    }

    function _base(uint256 c) private view returns (string memory) {
        if (frozen[c]) return frozenBase[c];
        bytes32 label = labels[c];
        uint256 length;
        while (length < 32 && label[length] != 0) ++length;
        bytes memory nameBytes = new bytes(length);
        for (uint256 i; i < length; ++i) {
            nameBytes[i] = label[i];
        }
        return string.concat("https://", string(nameBytes), ".sites.imd.fun/");
    }

    function _checkLabel(bytes32 label) private pure {
        if (label == bytes32(0)) revert InvalidConfig();
        bool padding;
        for (uint256 i; i < 32; ++i) {
            uint8 character = uint8(label[i]);
            if (character == 0) padding = true;
            else if (padding || character > 127) revert InvalidConfig();
        }
    }

    function _checkCave(uint256 c) private pure {
        if (c == 0 || c > 7) revert InvalidCave();
    }

    function _key(uint256 c, uint256 r) private pure returns (uint256) {
        _checkCave(c);
        if (r == 0 || r > 21) revert InvalidRound();
        return (c - 1) * 21 + r - 1;
    }
}
