# AIJudge — Commit-Reveal Bounty Lifecycle

This document explains how a bounty moves through its lifecycle in the
updated `AIJudge.sol` contract, and why each stage prevents participants
from copying each other's answers.

## The problem being solved

In the original contract, `submitAnswer(bountyId, answer)` wrote the
plaintext answer straight into contract storage. Anyone watching the
mempool or reading chain state could see every existing submission and
submit an improved copy before the deadline. The fix is a **commit-reveal**
scheme: the chain only ever sees a hash during submission, and plaintext
only appears after nobody can react to it.

## Lifecycle stages

### 1. Bounty creation

`createBounty(title, rubric, commitDeadline, revealDeadline)` — payable.

The owner funds the reward and sets **two** deadlines instead of one:

- `commitDeadline` — the last moment a new commitment can be submitted.
- `revealDeadline` — the last moment a reveal can happen. Must be strictly
  after `commitDeadline`.

Splitting the single deadline into two windows is what makes hiding
possible: nobody can reveal while the commit window is still open, so
there's no point at which a plaintext answer is visible next to still-open
submissions.

### 2. Commit phase — `submitCommitment(bountyId, commitment)`

Open from bounty creation until `commitDeadline`. A participant computes:

```
commitment = keccak256(abi.encode(answer, salt, msg.sender, bountyId))
```

off-chain (the `salt` is a random `bytes32` they generate and keep secret)
and submits only that hash. The contract:

- Rejects a second commitment from the same address for the same bounty.
- Rejects an empty (`bytes32(0)`) commitment.
- Rejects commitments once `MAX_SUBMISSIONS` is reached or the commit
  deadline has passed.

At this point the chain stores an address and a hash — nothing about the
content of the answer is recoverable from it.

### 3. Reveal phase — `revealAnswer(bountyId, answer, salt)`

Open from `commitDeadline` until `revealDeadline`. The participant sends
back their plaintext `answer` and the `salt` they used. The contract
recomputes `keccak256(abi.encode(answer, salt, msg.sender, bountyId))` and
requires it to equal the commitment they submitted earlier. If it matches,
`revealed` is set to `true` and the plaintext answer is now stored and
public.

Because reveals can only start once the commit window is fully closed,
nobody can read a competitor's answer and still get a commitment in — the
commit door is already shut.

If a participant never reveals (loses their salt, changes their mind, or
was never serious), their commitment simply stays a hash forever. It is
never eligible for judging or for winning.

### 4. Judging — `judgeAll(bountyId, llmInput)`

Owner-only, callable only once `block.timestamp >= revealDeadline` and only
if at least one submission was revealed. This calls the Ritual LLM
inference precompile with `llmInput` (built off-chain by the owner/frontend
from `getRevealedSubmissions`, which returns only the revealed
submitter/answer pairs) and stores the model's structured review.

### 5. Finalization — `finalizeWinner(bountyId, winnerIndex)`

Owner-only, callable once `judged == true`. `winnerIndex` must point at a
submission where `revealed == true` — an un-revealed commitment can never
be picked as a winner or receive the reward, even if the owner tries. The
reward is transferred to that submitter and the bounty is marked
`finalized`.

## State machine summary

```
createBounty
     │
     ▼
[commit phase]  submitCommitment × N   (until commitDeadline)
     │
     ▼
[reveal phase]  revealAnswer × N       (commitDeadline → revealDeadline)
     │
     ▼
judgeAll   (only after revealDeadline, needs ≥1 revealed answer)
     │
     ▼
finalizeWinner   (winner must be revealed)
```

## What's public vs. hidden, and when

| Data | Commit phase | Reveal phase | After judging |
|---|---|---|---|
| Commitment hash | public | public | public |
| Plaintext answer | **hidden** | public (once revealed) | public |
| Salt | private to submitter | public (once revealed) | public |
| AI review | n/a | n/a | public |
