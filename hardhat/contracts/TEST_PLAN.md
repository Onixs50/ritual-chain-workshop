# Test Plan — Commit-Reveal AIJudge

Tests live in `contracts/AIJudge.t.sol` as Foundry-style Solidity tests
(run with `npx hardhat test solidity`), since all the logic under test is
pure on-chain state-machine behavior with no off-chain orchestration
needed. `forge-std`'s `vm.warp` and `vm.prank` are used to move through
time and impersonate different submitters.

## Covered cases

**Bounty creation**
- Reward is required (`msg.value > 0`).
- `revealDeadline` must be strictly after `commitDeadline`.
- Deadlines and initial state are stored correctly.

**Commit phase**
- A commitment is stored as a hash only — `getSubmission` returns an empty
  `answer` and `revealed == false` right after committing.
- The same address cannot commit twice to the same bounty.
- Commitments are rejected once `commitDeadline` has passed.
- An empty (`bytes32(0)`) commitment is rejected.

**Reveal phase**
- A reveal with the correct `answer` + `salt` succeeds and flips
  `revealed` to `true`.
- A reveal with a **different answer** than what was committed reverts
  with `commitment mismatch` — this is the core anti-copying guarantee:
  you cannot commit to one thing and reveal another.
- A reveal with the **correct answer but wrong salt** reverts the same
  way — salt can't be guessed or reused across submitters.
- Revealing before `commitDeadline` reverts (`reveal phase not started`).
- Revealing after `revealDeadline` reverts (`reveal phase closed`).
- Revealing without ever having committed reverts (`no commitment
  found`).
- Revealing twice for the same commitment reverts (`already revealed`).
- **A submission that is never revealed stays invisible**: after the
  reveal window closes, `getRevealedSubmissions` excludes it entirely and
  `getSubmission` still returns an empty `answer`.

**Judging gate**
- `judgeAll` reverts if called before `revealDeadline`, even if every
  submitter already revealed — judging cannot start while the reveal
  window is technically still open.
- `judgeAll` reverts if zero submissions were revealed (all commitments
  abandoned).
- `judgeAll` reverts for a non-owner caller.

**Finalization gate**
- `finalizeWinner` reverts before judging has happened.
- `finalizeWinner` would reject a `winnerIndex` pointing at an
  un-revealed submission (enforced by `require(submissions[winnerIndex].
  revealed)`) — a hidden/abandoned commitment can never collect the
  reward.

**Hash helper**
- `computeCommitment` (the pure on-chain helper meant for off-chain
  tooling/tests to use) produces the exact same hash as manually calling
  `keccak256(abi.encode(...))`, so a frontend can trust it as the source
  of truth for building commitments.

## Known gap — full judge → finalize happy path

`judgeAll` calls the Ritual `LLM_INFERENCE_PRECOMPILE` at a fixed address
(`0x0802`), which only exists on Ritual Chain (or a devnet with the
precompile registered) — it is not available on Hardhat's local simulated
EVM. Because of that, the full `judgeAll` → `finalizeWinner` happy path
(and the "winner index points at an unrevealed submission" revert, which
requires `judged == true` to reach) is exercised as an **integration test
against Ritual Chain testnet**, not a local unit test. Locally, we instead
verify every *gate* around `judgeAll`/`finalizeWinner` (ownership, timing,
"must have revealed answers", "must not already be judged/finalized") so
the state machine itself is fully covered without needing the precompile.

## Running the tests

```bash
cd hardhat
npx hardhat test solidity
```
