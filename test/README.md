# Ochre test suite

Run from the repository root:

```sh
forge build
forge test
```

The accepted `Ochre.t.sol` suite is retained. `OchreProperties.t.sol` adds constructor,
arithmetic, authorization and payment boundary cases. `OchreInvariant.t.sol` adds a
handler with eight funded actors, a separate admin, and independent inventory and
payment accounting. `support/OchreSetup.sol` shares deployment parameters and a small
sorted-pair Merkle tree. No production contract or build configuration is changed.

## Rules under test

- Rehearsal deployment uses Sepolia WETH at
  `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`, with 18 decimals, and sends every
  payment directly to `0x000000000000000000000000000000000000dEaD`.
  The admin and Adam are `0x7B8C742F2e1eEB3fB2C10d72967Fa6d4a22f0479`.
  Construction needs no coin code or external calls. The default root is
  `0x0a8005d6196642a338d7e5a99dc48ff300c5843bd0eb68fa9db611157af7fffb`.
- IDs are exactly 0 through 736. Zero belongs to Adam and One to admin at deployment.
  Each of seven caves has 21 rounds of five slots: four lines and one gathering.
  Round sales take slots in order 5, 4, 3, 2, 1. The sale quotas per round are
  1, 1, 2, 3, 4, 4, 4, except the final round sells all five. Cave sale totals are
  21, 21, 42, 63, 84, 84, 85: 400 sales and 335 seats overall.
- The schedule starts at 1791396553. Caves last 3600 seconds and rounds last 150
  seconds. Buying includes the round's opening second and excludes the cave's
  closing second. Old rounds remain independently available at the floor until close.
  All 21 round lengths must fit inside a cave.
- The first opening is 4e15 and the floor is 4e14 coin base units. Each round's
  curve interpolates between successive integer halvings over equally sized rational
  time segments, with a floor clamp. A later opening uses twice the predecessor's
  last above-floor sale, bounded below by half its opening and twice the floor.
  A quiet predecessor halves its opening. Floor purchases do not change the ladder.
  Prices and durations are constructor parameters, also tested with different values.
- Seats use single-hashed address leaves and sorted Merkle pairs. Each eligible
  wallet claims once, from the start, consuming free IDs in ascending order across
  all caves. Bad proofs, stolen proofs and duplicate claims fail without consuming
  inventory. Anyone can release unclaimed seats at `start + 8 * caveLength`;
  this permanently disables claims and enables unlimited floor-price leftover buys.
- Anyone can sweep a closed cave's unsold sale pieces to admin in ascending ID
  order. Sweeps cannot consume seats, sold pieces, transferred pieces or already
  swept pieces. A zero-size or exhausted sweep fails. Failed coin payments roll
  back issuance, counters, inventory cursors and token movement.
- Minting does not invoke receiver hooks. Ochre does not accept native-currency
  payments. Royalties always return admin and `salePrice / 100`.
- Labels in cave order are `zto-cave-test5`, `zto-cave-test4`, `zto-cave-test3`,
  `zto-cave-test2`, `zto-cave-test5`, `zto-cave-test4`, `zto-cave-test3`.
  Metadata uses `https://<label>.sites.imd.fun/` followed by `line-<slot>/<rr>.json`
  or `gathering/<rr>.json`; Zero and One use `zero.json` and `one.json`.
  Only admin may freeze each cave once. Cave 1 also determines `collection.json`.
  Labels may occupy all 32 bytes and otherwise must be right-padded ASCII.

## Added properties

| Check | Independent expectation |
| --- | --- |
| Halving knots, 1,000 fuzz runs | At each integral segment boundary, the opening is divided by the appropriate power of two. |
| Fractional curves and payment, 1,000 runs | Quotes stay bounded and decrease with time; actual buyer debit and dead-address credit equal the quote. |
| All cave/round boundaries, 1,000 runs | Before-open and at-close calls fail; exact opening allocates the gathering. |
| Royalty rounding, 1,000 runs | Multiplying the fee by 100 leaves a remainder in 0 through 99, including full-width inputs. |
| Largest rehearsal ladder | Buying at all 147 openings produces the exact geometric payment sum without overflow. |
| Integer edges | One-wei floor, odd openings, subsecond segments, full-width interpolation, and the latest representable release timestamp. |
| Invalid construction and payment | Zero addresses, malformed labels, overflowing schedules, insufficient balance and insufficient allowance fail atomically. |

The invariant campaign runs 256 sequences of 128 calls. Time advances monotonically;
the handler mixes buys, proof claims, transfers, sweeps, release, leftovers and
authorized/unauthorized freeze attempts. It deliberately exercises expected reverts,
including false-returning payments. Unexpected reverts fail the campaign through
inline `fail-on-revert` configuration. A deterministic handler test ensures each
transition is reachable without relying on random selection.

Inventory queues are generated from the assignment's quota table, without asking
Ochre which IDs are sale pieces. Ghost state tracks owners, balances, sold counts,
claimed wallets, consumed free IDs, cumulative charges, release and freeze flags.
After every call the invariant checks:

- `supply = 2 + purchases + claims + leftovers + swept`, at most 737;
- tracked NFT balances sum to supply, and sale/seat allocations stay within 400/335;
- every tracked buyer's coin debit equals its successful charges, all charges reach
  dead, and neither Ochre nor admin receives purchase funds;
- claims, release and freeze state match the independently tracked transitions.

Operation assertions additionally check allocation order, payment arguments, sale
counters, last line sale, rollback, and sweep event order. After **each sequence**,
the harness closes the week, sweeps all unsold sales, releases seats and purchases
all remaining free pieces. It verifies all 737 owners and every round's sold count,
then retries exhausted issuance. This checks completion remains possible after
arbitrary earlier operations, rather than checking only a fresh deployment.

## Offline scope

The payment stand-in is the accepted suite's `MockCoin`, installed only in the local
EVM at the configured address. It models balances, allowances, true/false return
values, reverts and optional callbacks. All dependencies are already vendored; the
suite needs no RPC, FFI, environment mutation, new package or deployment transaction.
Successful seat tests use known test roots; the supplied root is checked as a
deployment value because its complete wallet/proof set is not supplied.

The no-custody property covers protocol-generated payment flows. It does not claim
that unsolicited token transfers or forcibly supplied native currency are impossible.
Live Sepolia WETH behavior and deployment are not verified by these offline tests.
The existing suite retains receiver/reentry, interfaces, metadata, fixed deployment,
event, runtime-size and complete-allocation checks.
