// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ochre} from "src/Ochre.sol";
import {MockCoin} from "test/Ochre.t.sol";

/// @dev Reuses the accepted payment mock; no fork, environment changes or storage writes to Ochre.
abstract contract OchreSetup is Test {
    address internal constant COIN = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant ADMIN = address(bytes20(hex"7B8C742F2e1eEB3fB2C10d72967Fa6d4a22f0479"));
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant ROOT = 0x0a8005d6196642a338d7e5a99dc48ff300c5843bd0eb68fa9db611157af7fffb;
    uint256 internal constant START = 1791396553;
    uint256 internal constant FIRST = 4e15;
    uint256 internal constant FLOOR = 4e14;
    uint256 internal constant FUNDS = 1 << 220;

    struct Config {
        address coin;
        address admin;
        address adam;
        bytes32 root;
        uint256 start;
        uint256 caveLength;
        uint256 roundLength;
        uint256 first;
        uint256 floor;
        bytes32[7] labels;
    }

    Ochre internal ochre;
    MockCoin internal coin;

    function _config() internal pure returns (Config memory p) {
        p = Config({
            coin: COIN,
            admin: ADMIN,
            adam: ADMIN,
            root: ROOT,
            start: START,
            caveLength: 3600,
            roundLength: 150,
            first: FIRST,
            floor: FLOOR,
            labels: [
                bytes32("zto-cave-test5"),
                bytes32("zto-cave-test4"),
                bytes32("zto-cave-test3"),
                bytes32("zto-cave-test2"),
                bytes32("zto-cave-test5"),
                bytes32("zto-cave-test4"),
                bytes32("zto-cave-test3")
            ]
        });
    }

    function _deploy(Config memory p) internal returns (Ochre) {
        return new Ochre(
            p.coin,
            p.admin,
            p.adam,
            p.root,
            p.start,
            p.caveLength,
            p.roundLength,
            p.first,
            p.floor,
            p.labels[0],
            p.labels[1],
            p.labels[2],
            p.labels[3],
            p.labels[4],
            p.labels[5],
            p.labels[6]
        );
    }

    function _installCoin() internal {
        MockCoin implementation = new MockCoin();
        vm.etch(COIN, address(implementation).code);
        coin = MockCoin(COIN);
    }

    function _actor(uint256 index) internal pure returns (address) {
        return address(uint160(0x1000 + index));
    }

    function _fund(address who, Ochre target, uint256 amount) internal {
        coin.mint(who, amount);
        vm.prank(who);
        coin.approve(address(target), amount);
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _seatTree() internal pure returns (bytes32[16] memory tree) {
        for (uint256 i; i < 8; ++i) {
            tree[8 + i] = keccak256(abi.encodePacked(_actor(i)));
        }
        for (uint256 i = 7; i > 0; --i) {
            tree[i] = _pair(tree[2 * i], tree[2 * i + 1]);
        }
    }

    function _seatProof(uint256 index) internal pure returns (bytes32[] memory proof) {
        bytes32[16] memory tree = _seatTree();
        proof = new bytes32[](3);
        uint256 node = 8 + index;
        for (uint256 i; i < 3; ++i) {
            proof[i] = tree[node ^ 1];
            node /= 2;
        }
    }

    // The allocation oracle comes from the assignment's table, not Ochre's sale helpers.
    function _quota(uint256 c, uint256 r) internal pure returns (uint256) {
        uint256[7] memory quotas = [uint256(1), 1, 2, 3, 4, 4, 4];
        return c == 7 && r == 21 ? 5 : quotas[c - 1];
    }
}
