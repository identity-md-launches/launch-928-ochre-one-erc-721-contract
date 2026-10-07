#!/usr/bin/env python3
"""Offline deployment-handoff checks. Run forge build first. Never broadcasts."""

import json
from pathlib import Path


def check():
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "launch.json").read_text())
    assert set(manifest) == {"kind", "contracts", "notes"}
    assert manifest["kind"] == "evm_contracts"
    assert len(manifest["contracts"]) == 1
    entry = manifest["contracts"][0]
    assert set(entry) == {"contract", "constructorArgs"}
    assert entry["contract"] == "Ochre"
    args = entry["constructorArgs"]
    assert len(args) == 16, "Manifest permits at most sixteen static arguments"
    artifact = json.loads((root / "out/Ochre.sol/Ochre.json").read_text())
    constructor = next(item for item in artifact["abi"] if item["type"] == "constructor")
    assert constructor["stateMutability"] == "nonpayable"
    assert [item["type"] for item in constructor["inputs"]] == (
        ["address"] * 3 + ["bytes32"] + ["uint256"] * 5 + ["bytes32"] * 7
    )
    assert args[:9] == [
        "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
        "0x7B8C742F2e1eEB3fB2C10d72967Fa6d4a22f0479",
        "0x7B8C742F2e1eEB3fB2C10d72967Fa6d4a22f0479",
        "0x0a8005d6196642a338d7e5a99dc48ff300c5843bd0eb68fa9db611157af7fffb",
        "1791396553", "3600", "150", "4000000000000000", "400000000000000",
    ]
    labels = [f"zto-cave-test{suffix}" for suffix in [5, 4, 3, 2, 5, 4, 3]]
    for value, label in zip(args[9:], labels):
        assert value == "0x" + label.encode("ascii").hex().ljust(64, "0")
        assert bytes.fromhex(value[2:]).rstrip(b"\0").decode("ascii") == label

    code = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    assert 0 < len(code) < 9000, f"Runtime is {len(code)} bytes"
    index = 0
    while index < len(code):
        opcode = code[index]
        assert opcode not in (0xF4, 0xF2, 0xFF), f"Forbidden opcode at byte {index}"
        index += 1 + (opcode - 0x5F if 0x60 <= opcode <= 0x7F else 0)
    assert not artifact["deployedBytecode"].get("linkReferences"), "Unlinked dependency"
    assert not artifact["bytecode"].get("linkReferences"), "Unlinked constructor dependency"
    print(f"Ochre: 16 static arguments, 7 verified labels, {len(code)} runtime bytes; launch checks pass.")


if __name__ == "__main__":
    check()
