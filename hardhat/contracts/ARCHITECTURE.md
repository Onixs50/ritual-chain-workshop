# Architecture Note

## Required track: commit-reveal design decisions

**Hashing scheme.** The spec describes
`keccak256(answer, salt, msg.sender, bountyId)`. This implementation uses
`keccak256(abi.encode(answer, salt, msg.sender, bountyId))` rather than
`abi.encodePacked`. With `encodePacked`, a dynamic type (`string answer`)
sitting next to fixed-size types can in principle produce ambiguous byte
layouts across different inputs; `abi.encode` pads and length-prefixes
each argument, which removes that class of collision entirely. The
tradeoff is a few extra bytes of calldata for the reveal call — cheap
compared to the correctness guarantee. `computeCommitment(...)` is exposed
as a `pure` function precisely so the frontend and tests never have to
reimplement the hashing by hand and risk drifting from the contract.

**Two deadlines instead of one.** A single deadline can't express
"submissions are closed" and "reveals are closed" separately — hiding
requires that reveals cannot start until commitments are fully closed.
`commitDeadline` / `revealDeadline` make that ordering explicit and
enforceable (`revealDeadline > commitDeadline` is checked at creation).

**One commitment per address.** `commitmentIndex` is a
`mapping(address => uint256)` (1-indexed, `0` = none) inside the `Bounty`
struct, giving O(1) "have you already committed" and "which submission is
yours" lookups instead of scanning the array, while still keeping
`MAX_SUBMISSIONS` as a hard cap on array growth.

**Un-revealed submissions are structurally unable to win.**
`finalizeWinner` requires `submissions[winnerIndex].revealed == true`.
Combined with `judgeAll` requiring `revealedCount > 0`, there is no code
path where a hidden commitment receives the reward or influences the AI
review — the guarantee lives in the contract, not in frontend discipline.

## Advanced track: Ritual-native hidden submissions

This section is a design note (not implemented in this submission) for
how the same guarantee could be achieved without a manual reveal step, by
keeping answers encrypted end-to-end and only decrypting inside Ritual's
TEE-backed execution.

### Where plaintext exists

| Location | Plaintext present? |
|---|---|
| Submitter's browser (before encrypting) | yes |
| On-chain calldata / storage | **no** — only ciphertext + a reference |
| Ritual off-chain secrets store | yes, but access-controlled to the executing node's enclave |
| Inside the TEE during the `judgeAll` batch call | yes, transiently, for the duration of inference |
| AI review output written back on-chain | yes (the review itself is meant to be public) |

### On-chain vs. off-chain

- **On-chain:** a commitment-style record per submission —
  `submitter`, a `secretsName`/reference handle (not the ciphertext
  itself if it's large), and a content hash of the ciphertext for
  integrity. This mirrors `ConvoHistory` in the existing contract, which
  already carries a `storageType` / `path` / `secretsName` triple for
  precompile-managed off-chain content.
- **Off-chain, but Ritual-managed:** the actual ciphertext, stored via
  Ritual's secrets/private-input mechanism (e.g. through the DKMS
  precompile at `0x081B`) so that only Ritual's node-side TEE can decrypt
  it — not the submitter's own frontend server, not a public IPFS blob,
  and not the bounty owner.
- **Never stored anywhere in plaintext** except transiently inside the
  enclave during inference.

### How the LLM receives submissions for batch judging

Instead of the owner assembling `llmInput` from plaintext strings
(`getRevealedSubmissions` in the required track), `judgeAll` would pass
the **list of secret references**, not content:

```solidity
function judgeAll(uint256 bountyId, bytes32[] calldata secretRefs, bytes calldata promptTemplate) external onlyOwner(bountyId) { ... }
```

The LLM inference precompile resolves each `secretRefs[i]` inside the TEE
(via the DKMS precompile), decrypts it there, assembles all submissions
into a single batch prompt using `promptTemplate` (so it's genuinely one
LLM call judging every submission together, not one call per answer —
matching the "batch judging" requirement), and returns only the
structured review. Plaintext answers never leave the enclave and never
touch contract storage or an event log.

### Why this is stronger than the manual commit-reveal

The required track's guarantee depends on humans behaving correctly (not
revealing early through a side channel, not leaking their salt). The
Ritual-native version removes the reveal step entirely — there's no
window where a submitter *could* leak plaintext even if they wanted to,
because they never held authority over when it becomes visible; decryption
is gated by the TEE's own access policy and only triggers as a side effect
of the batch judging call.

### What this design gives up

- Harder to audit: you can't inspect a plaintext submission on a block
  explorer to sanity-check the AI's judgment; you have to trust the
  TEE attestation.
- Depends on Ritual's TEE / DKMS infrastructure being available and
  correctly attested, versus the required track which only needs
  `keccak256`, which works identically on any EVM chain.

## Reflection: what should be public, hidden, and human-vs-AI?

Commitment hashes, deadlines, the rubric, and the final AI review should
all be public — they let anyone audit that the process ran fairly without
exposing any participant's ideas. The actual answer content should stay
hidden until the submission window is unambiguously closed for everyone,
because the entire point of hiding it is to stop later submitters from
free-riding on earlier ones; once no more submissions can arrive, there's
no more harm in revealing. Salts and any raw off-chain secrets should
never be public before their matching reveal, and in the TEE-based design,
plaintext should ideally never be public at all outside the enclave.
Scoring against the rubric — reading dozens of answers consistently and
without fatigue or favoritism — is a good fit for AI judging, since it's
mechanical and benefits from consistency more than nuance. Deciding who
gets to be the bounty owner, what the rubric actually rewards, and
resolving edge cases the AI flags as ambiguous or borderline should stay
with a human, because those are value judgments about what "good" means
in context, not something a rubric can fully capture in advance.
