// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ochre} from "src/Ochre.sol";
import {MockCoin} from "test/Ochre.t.sol";
import {OchreSetup} from "test/support/OchreSetup.sol";

contract OchreRejectingReceiver {
    error CallbackForbidden();

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert CallbackForbidden();
    }
}

contract OchrePropertiesTest is OchreSetup {
    function setUp() public {
        _installCoin();
        ochre = _deploy(_config());
        _fund(_actor(0), ochre, FUNDS);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzHalvingKnotsAcrossConstructorPrices(uint96 floorSeed, uint8 exponentSeed, uint32 secondsSeed)
        public
    {
        Config memory p = _config();
        p.floor = bound(floorSeed, 1, type(uint96).max);
        uint256 exponent = bound(exponentSeed, 1, 32);
        p.first = p.floor * (1 << exponent);
        uint256 segmentLength = bound(secondsSeed, 1, 1 days);
        p.roundLength = exponent * segmentLength;
        p.caveLength = 21 * p.roundLength;
        Ochre target = _deploy(p);
        // Exact knots are an algebraic consequence of the specified halving curve.
        for (uint256 k; k <= exponent; ++k) {
            vm.warp(START + k * segmentLength);
            assertEq(target.priceNow(1, 1), p.first / (1 << k), "halving knot");
        }
        vm.warp(START + p.caveLength - 1);
        assertEq(target.priceNow(1, 1), p.floor, "old round waits at floor");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFractionalCurveBoundsAndPayment(
        uint96 firstSeed,
        uint96 floorSeed,
        uint32 durationSeed,
        uint32 elapsedSeed
    ) public {
        Config memory p = _config();
        p.floor = bound(floorSeed, 1, type(uint96).max / 2);
        p.first = bound(firstSeed, 2 * p.floor, type(uint96).max);
        p.roundLength = bound(durationSeed, 1, 1 days);
        p.caveLength = 21 * p.roundLength;
        Ochre target = _deploy(p);
        _fund(_actor(1), target, FUNDS);
        uint256 elapsed = bound(elapsedSeed, 0, p.roundLength - 1);
        vm.warp(START + elapsed);
        uint256 price = target.priceNow(1, 1);
        assertGe(price, p.floor);
        assertLe(price, p.first);
        if (elapsed == 0) assertEq(price, p.first);
        uint256 balance = coin.balanceOf(_actor(1));
        vm.prank(_actor(1));
        assertEq(target.buy(1, 1), 5);
        assertEq(balance - coin.balanceOf(_actor(1)), price, "quote must match charge");
        assertEq(coin.balanceOf(DEAD), price);
        assertEq(coin.balanceOf(address(target)), 0);
        vm.warp(START + elapsed + 1);
        assertLe(target.priceNow(1, 1), price, "curve never rises");
        vm.warp(START + p.roundLength);
        assertEq(target.priceNow(1, 1), p.floor);
    }

    function testOneWeiFloorOddOpeningAndSubsecondSegments() public {
        Config memory p = _config();
        p.floor = 1;
        p.first = 7;
        p.roundLength = 6;
        p.caveLength = 126;
        Ochre target = _deploy(p);
        uint256[7] memory expected = [uint256(7), 6, 5, 3, 3, 2, 1];
        for (uint256 i; i < expected.length; ++i) {
            vm.warp(START + i);
            assertEq(target.priceNow(1, 1), expected[i]);
        }
        p.first = 1 << 200;
        p.roundLength = 1;
        p.caveLength = 21;
        target = _deploy(p);
        vm.warp(START);
        assertEq(target.priceNow(1, 1), 1 << 200);
        vm.warp(START + 1);
        assertEq(target.priceNow(1, 1), 1);
    }

    function testFullWidthInterpolationDoesNotOverflow() public {
        Config memory p = _config();
        p.first = type(uint256).max;
        p.floor = 1;
        p.roundLength = 1020;
        p.caveLength = 21 * 1020;
        Ochre target = _deploy(p);
        vm.warp(START + 1);
        // The first segment lasts four seconds; its first discount is 2^253.
        assertEq(target.priceNow(1, 1), type(uint256).max - (1 << 253));
        vm.warp(START + 4);
        assertEq(target.priceNow(1, 1), type(uint256).max / 2);
        vm.warp(START + 1020);
        assertEq(target.priceNow(1, 1), 1);
    }

    function testMaximumRehearsalLadderRemainsLiveThroughAll147Rounds() public {
        uint256 expected = FIRST;
        vm.startPrank(_actor(0));
        for (uint256 c = 1; c <= 7; ++c) {
            for (uint256 r = 1; r <= 21; ++r) {
                vm.warp(START + (c - 1) * 3600 + (r - 1) * 150);
                assertEq(ochre.openingPrice(c, r), expected);
                assertEq(ochre.priceNow(c, r), expected);
                ochre.buy(c, r);
                expected *= 2;
            }
        }
        vm.stopPrank();
        assertEq(coin.balanceOf(DEAD), expected - FIRST);
        assertEq(ochre.totalSupply(), 149);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzEveryCaveRoundBoundary(uint8 caveSeed, uint8 roundSeed) public {
        uint256 c = bound(caveSeed, 1, 7);
        uint256 r = bound(roundSeed, 1, 21);
        uint256 opens = START + (c - 1) * 3600 + (r - 1) * 150;
        vm.warp(opens - 1);
        vm.expectRevert(Ochre.NotOpen.selector);
        ochre.priceNow(c, r);
        vm.expectRevert(Ochre.NotOpen.selector);
        vm.prank(_actor(0));
        ochre.buy(c, r);
        vm.warp(opens);
        vm.prank(_actor(0));
        assertEq(ochre.buy(c, r), (c - 1) * 105 + r * 5);
        vm.warp(START + c * 3600);
        vm.expectRevert(Ochre.NotOpen.selector);
        ochre.priceNow(c, r);
        vm.expectRevert(Ochre.NotOpen.selector);
        vm.prank(_actor(0));
        ochre.buy(c, r);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzRoyaltyRoundingIdentity(uint256 id, uint256 amount) public view {
        (address recipient, uint256 fee) = ochre.royaltyInfo(id, amount);
        assertEq(recipient, ADMIN);
        assertLe(fee * 100, amount);
        assertLt(amount - fee * 100, 100);
    }

    function testConstructorRejectsZeroAddressesAndOverflowingSchedule() public {
        Config memory p = _config();
        p.coin = address(0);
        _invalid(p);
        p = _config();
        p.admin = address(0);
        _invalid(p);
        p = _config();
        p.adam = address(0);
        _invalid(p);
        p = _config();
        p.roundLength = type(uint256).max / 21 + 1;
        _invalid(p);
        p = _config();
        p.start = type(uint256).max - 8 * p.caveLength + 1;
        _invalid(p);
        --p.start;
        Ochre target = _deploy(p);
        vm.warp(type(uint256).max);
        target.releaseUnclaimed();
        assertTrue(target.unclaimedReleased());
    }

    function testLabelsRejectMalformedPaddingAndAcceptAll32Bytes() public {
        Config memory p = _config();
        for (uint256 i; i < 7; ++i) {
            bytes32 saved = p.labels[i];
            p.labels[i] = bytes32(0);
            _invalid(p);
            p.labels[i] = bytes32(hex"610062");
            _invalid(p);
            p.labels[i] = bytes32(hex"80");
            _invalid(p);
            p.labels[i] = saved;
        }
        p.labels[0] = bytes32("abcdefghijklmnopqrstuvwxyz123456");
        Ochre target = _deploy(p);
        assertEq(target.tokenURI(0), "https://abcdefghijklmnopqrstuvwxyz123456.sites.imd.fun/zero.json");
        assertEq(target.contractURI(), "https://abcdefghijklmnopqrstuvwxyz123456.sites.imd.fun/collection.json");
    }

    function testMerkleProofCannotBeReusedByAnotherWalletOrAltered() public {
        Config memory p = _config();
        p.root = _seatTree()[1];
        Ochre target = _deploy(p);
        vm.warp(START);
        bytes32[] memory proof = _seatProof(0);
        vm.expectRevert(Ochre.InvalidProof.selector);
        vm.prank(_actor(1));
        target.claimSeat(proof);
        proof[0] = bytes32(uint256(proof[0]) ^ 1);
        vm.expectRevert(Ochre.InvalidProof.selector);
        vm.prank(_actor(0));
        target.claimSeat(proof);
        assertFalse(target.claimed(_actor(0)));
        assertEq(target.nextFree(), 1);
        assertEq(target.totalSupply(), 2);
        proof = _seatProof(0);
        vm.prank(_actor(0));
        assertEq(target.claimSeat(proof), 1);
    }

    function testInsufficientBalanceAndLeftoverAllowancePreserveInventory() public {
        vm.warp(START);
        _fund(_actor(1), ochre, FIRST - 1);
        vm.prank(_actor(1));
        coin.approve(address(ochre), FIRST);
        vm.expectRevert(MockCoin.InsufficientBalance.selector);
        vm.prank(_actor(1));
        ochre.buy(1, 1);
        assertEq(ochre.roundSold(1, 1), 0);
        assertEq(ochre.totalSupply(), 2);
        assertEq(coin.allowance(_actor(1), address(ochre)), FIRST);
        assertEq(coin.balanceOf(DEAD), 0);
        vm.warp(START + 8 * 3600);
        ochre.releaseUnclaimed();
        vm.prank(_actor(0));
        coin.approve(address(ochre), FLOOR - 1);
        vm.expectRevert(MockCoin.InsufficientAllowance.selector);
        vm.prank(_actor(0));
        ochre.buyLeftover();
        assertEq(ochre.nextFree(), 1);
        assertEq(ochre.totalSupply(), 2);
        vm.prank(_actor(0));
        coin.approve(address(ochre), FLOOR);
        vm.prank(_actor(0));
        assertEq(ochre.buyLeftover(), 1);
        assertEq(coin.allowance(_actor(0), address(ochre)), 0);
    }

    function testNativeCurrencyIsRejectedByAllIssuancePaths() public {
        vm.deal(address(this), 4 wei);
        vm.warp(START);
        (bool success,) = address(ochre).call{value: 1}(abi.encodeCall(Ochre.buy, (1, 1)));
        assertFalse(success);
        (success,) = address(ochre).call{value: 1}(abi.encodeCall(Ochre.claimSeat, (new bytes32[](0))));
        assertFalse(success);
        (success,) = address(ochre).call{value: 1}("");
        assertFalse(success);
        vm.warp(START + 8 * 3600);
        ochre.releaseUnclaimed();
        (success,) = address(ochre).call{value: 1}(abi.encodeCall(Ochre.buyLeftover, ()));
        assertFalse(success);
        assertEq(address(ochre).balance, 0);
        assertEq(ochre.totalSupply(), 2);
    }

    function testEveryMintPathWorksWithAReceiverThatRejectsCallbacks() public {
        address recipient = address(new OchreRejectingReceiver());
        Config memory p = _config();
        p.admin = recipient;
        p.adam = recipient;
        p.root = keccak256(abi.encodePacked(recipient));
        Ochre target = _deploy(p);
        assertEq(target.ownerOf(0), recipient);
        assertEq(target.ownerOf(736), recipient);
        _fund(recipient, target, FUNDS);
        vm.warp(START);
        vm.prank(recipient);
        assertEq(target.claimSeat(new bytes32[](0)), 1);
        vm.prank(recipient);
        assertEq(target.buy(1, 1), 5);
        vm.warp(START + 8 * 3600);
        assertEq(target.sweep(1, type(uint256).max), 20);
        target.releaseUnclaimed();
        vm.prank(recipient);
        assertEq(target.buyLeftover(), 2);
        assertEq(target.balanceOf(recipient), 25);
        assertEq(target.ownerOf(10), recipient);
        assertEq(target.totalSupply(), 25);
        assertEq(coin.balanceOf(DEAD), FIRST + FLOOR);
    }

    function _invalid(Config memory p) private {
        vm.expectRevert(Ochre.InvalidConfig.selector);
        _deploy(p);
    }
}
