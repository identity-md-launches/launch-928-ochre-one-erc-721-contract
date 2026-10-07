// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ochre} from "../src/Ochre.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MockCoin {
    error InsufficientBalance();
    error InsufficientAllowance();
    error CoinReverted();

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public returnsFalse;
    bool public throws;
    Ochre public callback;
    uint256 public callbackCave;
    uint256 public callbackRound;
    bool public reenter;
    bool public reenterLeftover;
    uint256 public nestedId;
    uint256 public observedSold;
    uint256 public observedSupply;
    address public lastFrom;
    address public lastTo;
    uint256 public lastAmount;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function fail(bool falseResult, bool revertResult) external {
        returnsFalse = falseResult;
        throws = revertResult;
    }

    function arm(Ochre target, uint256 c, uint256 r, bool leftover) external {
        callback = target;
        callbackCave = c;
        callbackRound = r;
        reenter = true;
        reenterLeftover = leftover;
        balanceOf[address(this)] = 1 ether;
        allowance[address(this)][address(target)] = 1 ether;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (throws) revert CoinReverted();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        if (allowance[from][msg.sender] < amount) revert InsufficientAllowance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        lastFrom = from;
        lastTo = to;
        lastAmount = amount;
        if (reenter) {
            reenter = false;
            observedSupply = callback.totalSupply();
            if (reenterLeftover) {
                nestedId = callback.buyLeftover();
            } else {
                observedSold = callback.roundSold(callbackCave, callbackRound);
                nestedId = callback.buy(callbackCave, callbackRound);
            }
        }
        return !returnsFalse;
    }
}

contract NoReturnCoin {
    fallback() external {}
}

contract NoReceiver {
    // Intentionally no ERC721 receiver implementation.
    function buy(Ochre target, uint256 c, uint256 r) external returns (uint256) {
        MockCoin(target.coin()).approve(address(target), 1 ether);
        return target.buy(c, r);
    }
}

contract OchreTest is Test {
    address internal constant COIN = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant ADMIN = address(bytes20(hex"7B8C742F2e1eEB3fB2C10d72967Fa6d4a22f0479"));
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant ROOT = 0x0a8005d6196642a338d7e5a99dc48ff300c5843bd0eb68fa9db611157af7fffb;
    uint256 internal constant START = 1791396553;
    uint256 internal constant FIRST = 0.004 ether;
    uint256 internal constant FLOOR = 0.0004 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    Ochre internal ochre;
    MockCoin internal coin;

    event Bought(uint256 indexed id, address indexed buyer, uint256 price);
    event Claimed(uint256 indexed id, address indexed wallet);
    event Swept(uint256 indexed id);
    event Frozen(uint256 indexed cave, string base);
    event UnclaimedReleased();

    function setUp() public {
        ochre = _deploy(ROOT, 3600, 150, FIRST, FLOOR);
        MockCoin template = new MockCoin();
        vm.etch(COIN, address(template).code);
        coin = MockCoin(COIN);
        _fund(ALICE, ochre);
        _fund(BOB, ochre);
    }

    function _deploy(bytes32 root, uint256 caveLen, uint256 roundLen, uint256 first, uint256 floor)
        internal
        returns (Ochre)
    {
        return new Ochre(
            COIN,
            ADMIN,
            ADMIN,
            root,
            START,
            caveLen,
            roundLen,
            first,
            floor,
            bytes32("zto-cave-test5"),
            bytes32("zto-cave-test4"),
            bytes32("zto-cave-test3"),
            bytes32("zto-cave-test2"),
            bytes32("zto-cave-test5"),
            bytes32("zto-cave-test4"),
            bytes32("zto-cave-test3")
        );
    }

    function _fund(address who, Ochre target) internal {
        coin.mint(who, 100 ether);
        vm.prank(who);
        coin.approve(address(target), 100 ether);
    }

    function _buy(uint256 c, uint256 r) internal returns (uint256) {
        vm.prank(ALICE);
        return ochre.buy(c, r);
    }

    function _singleSeat() internal returns (Ochre target) {
        target = _deploy(keccak256(abi.encodePacked(ALICE)), 3600, 150, FIRST, FLOOR);
        _fund(ALICE, target);
    }

    function testConstructorWithoutCoinCodeAndFixedDeployment() public {
        vm.etch(COIN, hex"");
        vm.chainId(11155111);
        vm.prank(address(0xFAC));
        Ochre target = _deploy(ROOT, 3600, 150, FIRST, FLOOR);
        assertEq(target.name(), "Ochre");
        assertEq(target.symbol(), "OCHRE");
        assertEq(target.coin(), COIN);
        assertEq(target.coinDecimals(), 18);
        assertEq(target.dead(), DEAD);
        assertEq(target.admin(), ADMIN);
        assertEq(target.adam(), ADMIN);
        assertEq(target.seatRoot(), ROOT);
        assertEq(target.startTime(), START);
        assertEq(target.caveLength(), 3600);
        assertEq(target.roundLength(), 150);
        assertEq(target.firstPrice(), FIRST);
        assertEq(target.floorPrice(), FLOOR);
        assertEq(target.labels(1), bytes32("zto-cave-test5"));
        assertEq(target.labels(7), bytes32("zto-cave-test3"));
        assertEq(target.ownerOf(0), ADMIN);
        assertEq(target.ownerOf(736), ADMIN);
        assertEq(target.balanceOf(ADMIN), 2);
        assertEq(target.totalSupply(), 2);
        assertLt(address(target).code.length, 9000);
        assertEq(address(target).balance, 0);
    }

    function testRuntimePassesProtectedOpcodeScanAndSizeLimit() public view {
        bytes memory code = address(ochre).code;
        assertGt(code.length, 0);
        assertLt(code.length, 9000);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }

    function testInvalidConfiguration() public {
        vm.expectRevert(Ochre.InvalidConfig.selector);
        _deploy(ROOT, 3149, 150, FIRST, FLOOR);
        vm.expectRevert(Ochre.InvalidConfig.selector);
        _deploy(ROOT, 3600, 0, FIRST, FLOOR);
        vm.expectRevert(Ochre.InvalidConfig.selector);
        _deploy(ROOT, 3600, 150, FIRST, 0);
        vm.expectRevert(Ochre.InvalidConfig.selector);
        _deploy(ROOT, 3600, 150, FLOOR, FLOOR);
        vm.expectRevert(Ochre.InvalidConfig.selector);
        _deploy(bytes32(0), 3600, 150, FIRST, FLOOR);
        vm.expectRevert(Ochre.InvalidConfig.selector);
        _deploy(ROOT, type(uint256).max, 150, FIRST, FLOOR);
        vm.expectRevert(Ochre.InvalidConfig.selector);
        _deploy(ROOT, 3600, 150, type(uint256).max, type(uint256).max);
    }

    function testEveryPieceAndSaleCount() public view {
        uint256[7] memory expected = [uint256(21), 21, 42, 63, 84, 84, 85];
        uint256 allSales;
        uint256 allFree;
        for (uint256 c = 1; c <= 7; ++c) {
            uint256 sales;
            for (uint256 r = 1; r <= 21; ++r) {
                for (uint256 s = 1; s <= 5; ++s) {
                    uint256 id = (c - 1) * 105 + (r - 1) * 5 + s;
                    (uint256 pc, uint256 pr, uint256 ps) = ochre.piece(id);
                    assertEq(pc, c);
                    assertEq(pr, r);
                    assertEq(ps, s);
                    if (ochre.isSalePiece(id)) ++sales;
                    else ++allFree;
                }
            }
            assertEq(sales, expected[c - 1]);
            allSales += sales;
        }
        assertEq(allSales, 400);
        assertEq(allFree, 335);
        assertFalse(ochre.isSalePiece(0));
        assertFalse(ochre.isSalePiece(736));
        assertEq(ochre.saleCount(7, 21), 5);
    }

    function testWindowsAndInvalidIndices() public {
        for (uint256 c = 1; c <= 7; ++c) {
            assertEq(ochre.caveOpen(c), START + (c - 1) * 3600);
            assertEq(ochre.caveClose(c), START + c * 3600);
            for (uint256 r = 1; r <= 21; ++r) {
                assertEq(ochre.roundOpen(c, r), START + (c - 1) * 3600 + (r - 1) * 150);
            }
        }
        vm.expectRevert(Ochre.InvalidCave.selector);
        ochre.caveOpen(0);
        vm.expectRevert(Ochre.InvalidCave.selector);
        ochre.caveClose(8);
        vm.expectRevert(Ochre.InvalidRound.selector);
        ochre.roundOpen(1, 0);
        vm.expectRevert(Ochre.InvalidRound.selector);
        ochre.openingPrice(1, 22);
        vm.expectRevert(Ochre.InvalidPiece.selector);
        ochre.piece(737);
    }

    function testBuyAndQuoteTimeBoundaries() public {
        vm.warp(START - 1);
        vm.expectRevert(Ochre.NotOpen.selector);
        _buy(1, 1);
        vm.expectRevert(Ochre.NotOpen.selector);
        ochre.priceNow(1, 1);
        vm.warp(START);
        assertEq(ochre.priceNow(1, 1), FIRST);
        vm.expectRevert(Ochre.NotOpen.selector);
        _buy(1, 2);
        assertEq(_buy(1, 1), 5);
        vm.expectRevert(Ochre.SoldOut.selector);
        _buy(1, 1);
        vm.warp(START + 3600 - 1);
        assertEq(ochre.priceNow(1, 2), FLOOR);
        vm.warp(START + 3600);
        vm.expectRevert(Ochre.NotOpen.selector);
        _buy(1, 2);
        vm.expectRevert(Ochre.NotOpen.selector);
        ochre.priceNow(1, 2);
        assertEq(_buy(2, 1), 110);
    }

    function testHalvingSegmentEndsAndInterior() public {
        Ochre target = _deploy(ROOT, 3600, 160, FIRST, FLOOR);
        uint256[9] memory secondsAfter = [uint256(0), 20, 40, 60, 80, 120, 140, 160, 3500];
        uint256[9] memory expected = [uint256(4e15), 3e15, 2e15, 15e14, 1e15, 5e14, FLOOR, FLOOR, FLOOR];
        for (uint256 i; i < secondsAfter.length; ++i) {
            vm.warp(START + secondsAfter[i]);
            assertEq(target.priceNow(1, 1), expected[i]);
        }
    }

    function testRehearsalFractionalSegments() public {
        vm.warp(START + 30);
        assertEq(ochre.priceNow(1, 1), 24e14);
        vm.warp(START + 75);
        assertEq(ochre.priceNow(1, 1), 1e15);
        vm.warp(START + 112);
        assertEq(ochre.priceNow(1, 1), 506666666666667);
        vm.warp(START + 149);
        assertEq(ochre.priceNow(1, 1), FLOOR);
    }

    function testFuzzHalvingPriceIsBoundedAndMonotone(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 3598);
        vm.warp(START + elapsed);
        uint256 beforePrice = ochre.priceNow(1, 1);
        vm.warp(START + elapsed + 1);
        uint256 afterPrice = ochre.priceNow(1, 1);
        assertGe(beforePrice, afterPrice);
        assertGe(afterPrice, FLOOR);
        assertLe(beforePrice, FIRST);
        if (elapsed >= 150) assertEq(afterPrice, FLOOR);
    }

    function testLadderDoublesLastLineSaleAndHalvesQuietRounds() public {
        vm.warp(START + 30);
        uint256 paid = ochre.priceNow(1, 1);
        _buy(1, 1);
        assertEq(ochre.lastLineSale(1, 1), paid);
        assertEq(ochre.openingPrice(1, 2), paid * 2);
        assertEq(ochre.openingPrice(1, 3), paid);
        assertEq(ochre.openingPrice(1, 4), paid / 2);
        assertEq(ochre.openingPrice(1, 5), 2 * FLOOR);
        assertEq(ochre.openingPrice(7, 21), 2 * FLOOR);
        vm.warp(START + 150);
        _buy(1, 2);
        assertEq(ochre.openingPrice(1, 3), paid * 4);
    }

    function testLadderFloorBuysIgnoredAndStoredOpeningStable() public {
        vm.warp(ochre.caveOpen(3));
        assertEq(ochre.openingPrice(3, 1), 2 * FLOOR);
        _buy(3, 1);
        assertEq(ochre.openingPrice(3, 2), 4 * FLOOR);
        vm.warp(ochre.roundOpen(3, 2));
        _buy(3, 2);
        uint256 stored = ochre.openingPrice(3, 2);
        assertEq(ochre.priceNow(3, 1), FLOOR);
        _buy(3, 1);
        assertEq(ochre.lastLineSale(3, 1), 2 * FLOOR);
        assertEq(ochre.openingPrice(3, 2), stored);
        vm.warp(ochre.roundOpen(3, 3));
        _buy(3, 2);
        assertEq(ochre.lastLineSale(3, 2), 4 * FLOOR);
        assertEq(ochre.openingPrice(3, 3), 8 * FLOOR);
    }

    function testLastLineSaleReplacesEarlierSaleAndHalfOpeningMinimum() public {
        // Grow the ladder so that the floor and half-opening bounds differ.
        vm.warp(ochre.caveOpen(3));
        for (uint256 r = 1; r <= 4; ++r) {
            vm.warp(ochre.roundOpen(3, r));
            _buy(3, r);
        }
        uint256 opening = ochre.openingPrice(3, 4);
        vm.warp(ochre.roundOpen(3, 4) + 140);
        uint256 latest = ochre.priceNow(3, 4);
        assertGt(latest, FLOOR);
        _buy(3, 4);
        assertEq(ochre.lastLineSale(3, 4), latest);
        assertLt(2 * latest, opening / 2);
        assertEq(ochre.openingPrice(3, 5), opening / 2);
    }

    function testLadderAcrossCavesAndUnboughtRoundNotSnapshot() public {
        vm.warp(ochre.roundOpen(1, 21));
        assertEq(ochre.openingPrice(2, 1), 2 * FLOOR);
        _buy(1, 21);
        assertEq(ochre.openingPrice(2, 1), 4 * FLOOR);
        assertEq(ochre.openingPrice(2, 2), 2 * FLOOR);
        vm.warp(ochre.caveOpen(2));
        _buy(2, 1);
        assertEq(ochre.openingPrice(2, 2), 8 * FLOOR);
    }

    function testQuietFirstBuyAtFloorDoesNotRaiseNextOpening() public {
        vm.warp(START + 150);
        _buy(1, 1);
        assertEq(ochre.lastLineSale(1, 1), 0);
        assertEq(ochre.openingPrice(1, 2), FIRST / 2);
        assertEq(ochre.openingPrice(1, 3), FIRST / 4);
    }

    function testEverySaleSlotBoughtInOrderAndAllSalesExhausted() public {
        uint256 count;
        for (uint256 c = 1; c <= 7; ++c) {
            // Every round is at the floor, so buying out the whole week is affordable.
            vm.warp(ochre.caveClose(c) - 1);
            for (uint256 r = 1; r <= 21; ++r) {
                uint256 amount = ochre.saleCount(c, r);
                for (uint256 j; j < amount; ++j) {
                    uint256 id = _buy(c, r);
                    assertEq(id, (c - 1) * 105 + r * 5 - j);
                    assertEq(ochre.ownerOf(id), ALICE);
                    ++count;
                }
                assertEq(ochre.roundSold(c, r), amount);
                vm.expectRevert(Ochre.SoldOut.selector);
                _buy(c, r);
            }
        }
        assertEq(count, 400);
        assertEq(ochre.totalSupply(), 402);
        assertEq(coin.balanceOf(DEAD), 400 * FLOOR);
        assertEq(coin.balanceOf(address(ochre)), 0);
    }

    function testBuyEventAndDirectBurnPayment() public {
        vm.warp(START);
        uint256 balance = coin.balanceOf(ALICE);
        vm.expectEmit(true, true, false, true, address(ochre));
        emit Bought(5, ALICE, FIRST);
        _buy(1, 1);
        assertEq(coin.lastFrom(), ALICE);
        assertEq(coin.lastTo(), DEAD);
        assertEq(coin.lastAmount(), FIRST);
        assertEq(coin.balanceOf(ALICE), balance - FIRST);
        assertEq(coin.balanceOf(DEAD), FIRST);
        assertEq(coin.balanceOf(address(ochre)), 0);
    }

    function testFalseAndRevertingCoinRollbackEntireBuy() public {
        vm.warp(ochre.caveOpen(3));
        coin.fail(true, false);
        vm.expectRevert(Ochre.PaymentFailed.selector);
        _buy(3, 1);
        assertEq(ochre.totalSupply(), 2);
        assertEq(ochre.roundSold(3, 1), 0);
        assertEq(ochre.lastLineSale(3, 1), 0);
        assertEq(ochre.openingPrice(3, 2), 2 * FLOOR);
        assertEq(coin.balanceOf(DEAD), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 215));
        ochre.ownerOf(215);
        coin.fail(false, true);
        vm.expectRevert(MockCoin.CoinReverted.selector);
        _buy(3, 1);
        coin.fail(false, false);
        assertEq(_buy(3, 1), 215);
    }

    function testMissingBoolOrMissingAllowanceRejectsBuy() public {
        vm.warp(START);
        vm.prank(ALICE);
        coin.approve(address(ochre), FIRST - 1);
        vm.expectRevert(MockCoin.InsufficientAllowance.selector);
        _buy(1, 1);
        NoReturnCoin badCoin = new NoReturnCoin();
        vm.etch(COIN, address(badCoin).code);
        vm.expectRevert();
        _buy(1, 1);
        assertEq(ochre.totalSupply(), 2);
    }

    function testCoinReentrySeesCompletedSaleAndCannotDuplicatePiece() public {
        vm.warp(ochre.caveOpen(3));
        coin.arm(ochre, 3, 1, false);
        uint256 id = _buy(3, 1);
        assertEq(id, 215);
        assertEq(coin.nestedId(), 214);
        assertEq(coin.observedSold(), 1);
        assertEq(coin.observedSupply(), 3);
        assertEq(ochre.ownerOf(id), ALICE);
        assertEq(ochre.ownerOf(214), COIN);
        assertEq(ochre.roundSold(3, 1), 2);
        assertEq(ochre.totalSupply(), 4);
        assertEq(coin.balanceOf(DEAD), 4 * FLOOR);
    }

    function testMintToContractWithoutReceiver() public {
        NoReceiver recipient = new NoReceiver();
        coin.mint(address(recipient), FIRST);
        vm.warp(START);
        assertEq(recipient.buy(ochre, 1, 1), 5);
        assertEq(ochre.ownerOf(5), address(recipient));
    }

    function testClaimProofStartAndDuplicate() public {
        Ochre target = _singleSeat();
        bytes32[] memory proof = new bytes32[](0);
        vm.warp(START - 1);
        vm.expectRevert(Ochre.TooEarly.selector);
        vm.prank(ALICE);
        target.claimSeat(proof);
        vm.warp(START);
        vm.expectRevert(Ochre.InvalidProof.selector);
        vm.prank(BOB);
        target.claimSeat(proof);
        vm.expectEmit(true, true, false, true, address(target));
        emit Claimed(1, ALICE);
        vm.prank(ALICE);
        assertEq(target.claimSeat(proof), 1);
        assertEq(target.ownerOf(1), ALICE);
        assertTrue(target.claimed(ALICE));
        assertEq(coin.balanceOf(DEAD), 0);
        vm.expectRevert(Ochre.AlreadyClaimed.selector);
        vm.prank(ALICE);
        target.claimSeat(proof);
    }

    function _merkleTree() internal pure returns (bytes32[] memory tree) {
        tree = new bytes32[](1024);
        for (uint256 i; i < 512; ++i) {
            tree[512 + i] = keccak256(abi.encodePacked(address(uint160(10000 + i))));
        }
        for (uint256 i = 511; i > 0; --i) {
            bytes32 a = tree[2 * i];
            bytes32 b = tree[2 * i + 1];
            tree[i] = a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
        }
    }

    function _proof(bytes32[] memory tree, uint256 leaf) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](9);
        uint256 index = 512 + leaf;
        for (uint256 depth; depth < 9; ++depth) {
            proof[depth] = tree[index ^ 1];
            index >>= 1;
        }
    }

    function testAll335SeatsInIdOrderAndMerkleExhaustion() public {
        bytes32[] memory tree = _merkleTree();
        Ochre target = _deploy(tree[1], 3600, 150, FIRST, FLOOR);
        vm.warp(START);
        uint256 count;
        uint256 firstSix;
        for (uint256 id = 1; id < 736; ++id) {
            if (target.isSalePiece(id)) continue;
            address who = address(uint160(10000 + count));
            bytes32[] memory proof = _proof(tree, count);
            vm.prank(who);
            assertEq(target.claimSeat(proof), id);
            assertEq(target.ownerOf(id), who);
            if (id <= 630) ++firstSix;
            ++count;
        }
        assertEq(firstSix, 315);
        assertEq(count, 335);
        bytes32[] memory extraProof = _proof(tree, 335);
        vm.expectRevert(Ochre.SoldOut.selector);
        vm.prank(address(10335));
        target.claimSeat(extraProof);
        assertFalse(target.claimed(address(10335)));
        assertEq(target.totalSupply(), 337);
        vm.warp(START + 8 * 3600);
        target.releaseUnclaimed();
        vm.expectRevert(Ochre.SoldOut.selector);
        target.buyLeftover();
    }

    function testReleaseTimingPermissionlessAndClaimStopsOnlyOnRelease() public {
        Ochre target = _singleSeat();
        vm.expectRevert(Ochre.NotReleased.selector);
        target.buyLeftover();
        vm.warp(START + 8 * 3600 - 1);
        vm.expectRevert(Ochre.TooEarly.selector);
        target.releaseUnclaimed();
        vm.warp(START + 8 * 3600);
        vm.prank(ALICE);
        assertEq(target.claimSeat(new bytes32[](0)), 1);
        vm.expectEmit(false, false, false, true, address(target));
        emit UnclaimedReleased();
        vm.prank(BOB);
        target.releaseUnclaimed();
        vm.expectRevert(Ochre.SeatsReleased.selector);
        vm.prank(ALICE);
        target.claimSeat(new bytes32[](0));
        vm.expectRevert(Ochre.AlreadyReleased.selector);
        target.releaseUnclaimed();
        vm.warp(START + 1000 days);
        vm.expectEmit(true, true, false, true, address(target));
        emit Bought(2, ALICE, FLOOR);
        vm.prank(ALICE);
        assertEq(target.buyLeftover(), 2);
        assertEq(coin.balanceOf(DEAD), FLOOR);
    }

    function testLeftoverFailureRollsBackCursorAndReentryUsesNextPiece() public {
        vm.warp(START + 8 * 3600);
        ochre.releaseUnclaimed();
        coin.fail(true, false);
        vm.expectRevert(Ochre.PaymentFailed.selector);
        vm.prank(ALICE);
        ochre.buyLeftover();
        assertEq(ochre.nextFree(), 1);
        assertEq(ochre.totalSupply(), 2);
        coin.fail(false, false);
        coin.arm(ochre, 0, 0, true);
        vm.prank(ALICE);
        assertEq(ochre.buyLeftover(), 1);
        assertEq(coin.nestedId(), 2);
        assertEq(ochre.ownerOf(1), ALICE);
        assertEq(ochre.ownerOf(2), COIN);
        assertEq(coin.balanceOf(DEAD), 2 * FLOOR);
    }

    function testSweepBoundariesPartialBatchesAndEvents() public {
        vm.warp(ochre.caveClose(3) - 1);
        assertEq(_buy(3, 1), 215);
        vm.expectRevert(Ochre.NotClosed.selector);
        ochre.sweep(3, 42);
        vm.warp(ochre.caveClose(3));
        vm.expectRevert(Ochre.InvalidQuantity.selector);
        ochre.sweep(3, 0);
        vm.expectEmit(true, false, false, true, address(ochre));
        emit Swept(214);
        vm.prank(BOB);
        assertEq(ochre.sweep(3, 1), 1);
        assertEq(ochre.ownerOf(214), ADMIN);
        assertEq(ochre.ownerOf(215), ALICE);
        // Transferring a sold piece cannot make it sweepable.
        vm.prank(ALICE);
        ochre.transferFrom(ALICE, BOB, 215);
        assertEq(ochre.sweep(3, 2), 2);
        assertEq(ochre.ownerOf(219), ADMIN);
        assertEq(ochre.ownerOf(220), ADMIN);
        assertEq(ochre.sweep(3, type(uint256).max), 38);
        assertEq(ochre.ownerOf(215), BOB);
        assertEq(ochre.roundSold(3, 1), 1);
        vm.expectRevert(Ochre.SoldOut.selector);
        ochre.sweep(3, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 211));
        ochre.ownerOf(211);
    }

    function testAll737EventuallyMintedExactlyOnce() public {
        Ochre target = _singleSeat();
        vm.warp(START);
        vm.prank(ALICE);
        target.claimSeat(new bytes32[](0));
        vm.prank(ALICE);
        target.buy(1, 1);
        vm.warp(START + 8 * 3600);
        uint256 swept;
        for (uint256 c = 1; c <= 7; ++c) {
            swept += target.sweep(c, 1000);
        }
        assertEq(swept, 399);
        target.releaseUnclaimed();
        uint256 leftovers;
        for (uint256 id = 2; id < 736; ++id) {
            if (target.isSalePiece(id)) continue;
            vm.prank(ALICE);
            assertEq(target.buyLeftover(), id);
            ++leftovers;
        }
        assertEq(leftovers, 334);
        assertEq(target.totalSupply(), 737);
        for (uint256 id; id < 737; ++id) {
            assertTrue(target.ownerOf(id) != address(0));
        }
        for (uint256 c = 1; c <= 7; ++c) {
            vm.expectRevert(Ochre.SoldOut.selector);
            target.sweep(c, 1000);
        }
        vm.expectRevert(Ochre.SoldOut.selector);
        target.buyLeftover();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 737));
        target.ownerOf(737);
        assertEq(coin.balanceOf(address(target)), 0);
        assertEq(coin.balanceOf(DEAD), FIRST + 334 * FLOOR);
    }

    function testURIsIncludingEndpointsRoundsSlotsAndFrozenCaves() public {
        assertEq(ochre.tokenURI(0), "https://zto-cave-test5.sites.imd.fun/zero.json");
        assertEq(ochre.tokenURI(736), "https://zto-cave-test3.sites.imd.fun/one.json");
        assertEq(ochre.contractURI(), "https://zto-cave-test5.sites.imd.fun/collection.json");
        vm.warp(START + 8 * 3600);
        ochre.releaseUnclaimed();
        vm.prank(ALICE);
        ochre.buyLeftover();
        for (uint256 c = 1; c <= 7; ++c) {
            ochre.sweep(c, 105);
        }
        assertEq(ochre.tokenURI(1), "https://zto-cave-test5.sites.imd.fun/line-1/01.json");
        assertEq(ochre.tokenURI(5), "https://zto-cave-test5.sites.imd.fun/gathering/01.json");
        assertEq(ochre.tokenURI(50), "https://zto-cave-test5.sites.imd.fun/gathering/10.json");
        assertEq(ochre.tokenURI(214), "https://zto-cave-test3.sites.imd.fun/line-4/01.json");
        assertEq(ochre.tokenURI(318), "https://zto-cave-test2.sites.imd.fun/line-3/01.json");
        assertEq(ochre.tokenURI(422), "https://zto-cave-test5.sites.imd.fun/line-2/01.json");
        assertEq(ochre.tokenURI(731), "https://zto-cave-test3.sites.imd.fun/line-1/21.json");
        vm.prank(ADMIN);
        ochre.freeze(7, "ipfs://seven/");
        assertEq(ochre.tokenURI(736), "ipfs://seven/one.json");
        assertEq(ochre.tokenURI(735), "ipfs://seven/gathering/21.json");
        assertEq(ochre.tokenURI(0), "https://zto-cave-test5.sites.imd.fun/zero.json");
        vm.prank(ADMIN);
        ochre.freeze(1, "ipfs://one/");
        assertEq(ochre.tokenURI(0), "ipfs://one/zero.json");
        assertEq(ochre.tokenURI(1), "ipfs://one/line-1/01.json");
        assertEq(ochre.contractURI(), "ipfs://one/collection.json");
    }

    function testFreezeOnlyAdminOnceAndValidBase() public {
        vm.expectRevert(Ochre.Unauthorized.selector);
        vm.prank(ALICE);
        ochre.freeze(1, "ipfs://cid/");
        vm.startPrank(ADMIN);
        vm.expectRevert(Ochre.InvalidCave.selector);
        ochre.freeze(8, "ipfs://cid/");
        vm.expectRevert(Ochre.InvalidBase.selector);
        ochre.freeze(1, "");
        vm.expectRevert(Ochre.InvalidBase.selector);
        ochre.freeze(1, "ipfs://cid");
        vm.expectEmit(true, false, false, true, address(ochre));
        emit Frozen(1, "ipfs://cid/");
        ochre.freeze(1, "ipfs://cid/");
        assertTrue(ochre.frozen(1));
        vm.expectRevert(Ochre.AlreadyFrozen.selector);
        ochre.freeze(1, "ipfs://different/");
        vm.stopPrank();
    }

    function testERC721TransfersApprovalsAndNoReceiverCallbacks() public {
        vm.warp(START);
        _buy(1, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, BOB, 5));
        vm.prank(BOB);
        ochre.transferFrom(ALICE, BOB, 5);
        vm.prank(ALICE);
        ochre.approve(BOB, 5);
        assertEq(ochre.getApproved(5), BOB);
        vm.prank(BOB);
        ochre.safeTransferFrom(ALICE, BOB, 5);
        assertEq(ochre.getApproved(5), address(0));
        assertEq(ochre.balanceOf(ALICE), 0);
        assertEq(ochre.balanceOf(BOB), 1);
        vm.prank(BOB);
        ochre.setApprovalForAll(ALICE, true);
        assertTrue(ochre.isApprovedForAll(BOB, ALICE));
        NoReceiver recipient = new NoReceiver();
        vm.expectRevert(Ochre.ContractRecipient.selector);
        vm.prank(ALICE);
        ochre.safeTransferFrom(BOB, address(recipient), 5, hex"1234");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        ochre.transferFrom(BOB, address(0), 5);
        vm.prank(ALICE);
        ochre.transferFrom(BOB, address(recipient), 5);
        assertEq(ochre.ownerOf(5), address(recipient));
        assertEq(ochre.totalSupply(), 3);
    }

    function testInterfacesRoyaltyAndNonexistentURI() public {
        assertTrue(ochre.supportsInterface(0x01ffc9a7));
        assertTrue(ochre.supportsInterface(0x80ac58cd));
        assertTrue(ochre.supportsInterface(0x5b5e139f));
        assertTrue(ochre.supportsInterface(0x2a55205a));
        assertFalse(ochre.supportsInterface(0xffffffff));
        assertFalse(ochre.supportsInterface(0x780e9d63));
        (address receiver, uint256 fee) = ochre.royaltyInfo(736, 123456);
        assertEq(receiver, ADMIN);
        assertEq(fee, 1234);
        (, fee) = ochre.royaltyInfo(0, type(uint256).max);
        assertEq(fee, type(uint256).max / 100);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        ochre.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 737));
        ochre.tokenURI(737);
    }
}
