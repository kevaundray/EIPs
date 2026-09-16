# Task: length caps and BLS length enforcement

Target file: `EIPS/eip-9999.md` (branch `kw/pq-deposit-contract-naive`).

Make two changes. Both are contract-side rules. Do not add any consensus-side
block-validity rule for either one.

## Background

The EIP defines a new validator deposit contract. A deposit carries
`(scheme, pubkey, withdrawal_credentials, credential_metadata)`. Scheme `0`
(`BLS_CREDENTIAL_SCHEME`) is BLS: 48-byte pubkey, 96-byte signature metadata.
Each accepted deposit is emitted as one event, and execution clients copy the
event into an EIP-7685 request that is embedded in the Engine API payload and
in the beacon block itself.

Design principles already established in the doc. Keep all of them:

- The execution layer never classifies, filters, or discards decoded requests.
- Semantic invalidity never invalidates a block. Enforcement happens in the
  contract (revert, depositor refunded) or consensus ignores the request.
- Invariants enforced by the pinned contract bytecode are not re-checked in
  consensus. See the BLS retirement section for the pattern: "A valid
  execution payload cannot contain a new BLS request after retirement."

## Change 1: field length caps

Add two constants to the constants table:

| `MAX_PUBKEY_LENGTH` | `8192` | Maximum `pubkey` length in bytes |
| `MAX_CREDENTIAL_METADATA_LENGTH` | `8192` | Maximum `credential_metadata` length in bytes |

Contract rule (Deposit operation section): a deposit MUST revert if
`len(pubkey) > MAX_PUBKEY_LENGTH` or
`len(credential_metadata) > MAX_CREDENTIAL_METADATA_LENGTH`. The rule applies
in every mode and for every scheme.

Delete the clause "The contract MUST NOT apply a minimum or maximum length to
`pubkey` or `credential_metadata`." Delete the TODO comment about length
bounds in the Rationale.

Replace the Rationale section "No contract-side length limits" with a section
that justifies the cap. Use this argument, it is the load-bearing one:

- Ordinary log data is never propagated. Nodes derive receipts locally and
  commit them with the receipts root. This contract is different: request
  derivation copies its event bytes into the beacon block, so every consensus
  node receives them in gossip. LOG data at 8 gas per byte would otherwise be
  the cheapest propagated-byte channel in the protocol, cheaper than the
  EIP-7623 calldata floor (10 gas per zero-byte token, 40 per nonzero-byte
  token).
- Worst-case cost is about 8.4 gas per request byte: a batching contract
  composes credentials in memory, so there is no calldata cost and the LOG
  price dominates. Total request bytes per block are therefore gas-bound at
  roughly `gas_limit / 8.4` with or without a cap. The cap does not bound
  block bytes; gas does.
- What the cap bounds is the economics and the per-request size. Without a
  cap, one deposit with the 1 ETH minimum buys a multi-megabyte request. At
  8192 bytes per field, one deposit carries at most about 16.4 KB, so filling
  a 45M-gas block with request spam locks about 330 ETH forever (about 61 ETH
  per MB), and consensus clients get a hard per-request maximum for sizing.
- Every existing request type is already bounded: EIP-6110 requests are fixed
  at 192 bytes, EIP-7002 allows 16 per block, EIP-7251 allows 2 per block.
  This is the first variable-length request type; the cap restores the
  property.
- Scheme headroom: 8192 covers ML-DSA-87 (2592-byte key, 4627-byte signature),
  Falcon-1024, and SLH-DSA-128s (7856-byte signature) with little margin.
  SLH-DSA-192s and 256s (16224 and 29792 bytes) do not fit. State this
  trade-off in the rationale; 32768 is the alternative if hash-based headroom
  is wanted. Use 8192.

Rewrite the Security Considerations section "Variable request size" to match:
propagated-bytes argument, gas-bound total, cap-bound per-request size and
attacker ETH cost.

SSZ: keep `ProgressiveByteList`. Add one sentence that the caps are enforced
by the contract, not by the SSZ schema.

Reference implementation: add the two checks with a new error (for example
`InvalidLength`).

Test cases: exact-cap length accepted and emitted; cap plus one byte reverts;
cover both fields.

## Change 2: BLS length enforcement at the contract

Contract rule (Deposit operation section): in `DEPOSIT_MODE_BLS_ENABLED`, a
deposit with `scheme == BLS_CREDENTIAL_SCHEME` MUST revert unless
`len(pubkey) == BLS_PUBKEY_LENGTH` and
`len(credential_metadata) == BLS_CREDENTIAL_METADATA_LENGTH`. No rule change
is needed for the other modes: `DEPOSIT_MODE_BLS_RETIRED` already reverts
every scheme-0 deposit and `DEPOSIT_MODE_INHIBITED` reverts everything.

Why the contract and not consensus (put a short version in the Rationale,
extending "Explicit scheme identifier" or as a new subsection):

- A contract revert refunds the depositor. Consensus-side ignoring locks the
  ETH forever. Consensus-side block rejection turns a user mistake into a
  poison-pill transaction that every block builder must filter during
  transaction selection, which is a liveness hazard and reintroduces request
  classification in the execution layer.
- The contract cannot get this protection for future schemes because its
  bytecode is immutable. BLS is the one scheme with a live tooling ecosystem
  during the migration window, so it is where mistaken deposits will happen.
  State this asymmetry honestly.

Consensus handler: remove the two length early-returns from
`process_bls_credential_deposit` and state the invariant instead, matching the
retirement pattern: a valid execution payload cannot contain a scheme-0
request with other field lengths, because the pinned runtime code rejects such
a deposit in every mode. Delete the sentence "A BLS request with any other
field lengths makes no state change. Consensus ignores it instead of
reinterpreting it under another scheme."

Update the Deposit operation clauses so the carve-outs are exact: the contract
still does not validate field contents and does not restrict the scheme value,
except for the mode rules, the caps from Change 1, and the scheme-0 length
rule. No cryptography in the contract.

Reference implementation: add the check after the retirement check and before
the amount checks, with an error such as `InvalidBLSLength`.

Text sweeps required by Change 2:

- Security section "Scheme labeling": it currently says a BLS deposit with
  other field lengths is ignored. Now it reverts. Only unassigned schemes
  still lock ETH through mislabeling.
- Security section "Permanently locked deposits": scheme-0 deposits with wrong
  lengths no longer lock funds (they revert). Scheme-0 deposits with correct
  lengths but an invalid BLS signature still lock funds, and unassigned
  schemes still lock funds. Adjust the wording to keep those cases.
- Rationale "Explicit scheme identifier": the paragraph "Consensus requires
  the exact BLS lengths for the BLS scheme. A mislabeled or padded credential
  is ignored, not reinterpreted." is now wrong. The contract requires the
  exact lengths and the revert refunds the depositor.
- Test Cases, "Deposit schemes" table: add scheme-0 rows for `BLS_ENABLED`:
  lengths 48/96 accept, 47/96 revert, 48/95 revert. The sentence "The contract
  result does not depend on the `pubkey` or `credential_metadata` lengths" is
  now wrong; restrict it to nonzero schemes within the caps.
- Cross-layer test bullet "BLS requests with other field lengths do not change
  consensus state" is obsolete; replace with a contract-level rejection test.
  Keep "BLS requests with the exact BLS lengths append the expected existing
  `PendingDeposit`" but the qualifier "with the exact BLS lengths" can become
  just "BLS requests" once the contract guarantees the lengths.

Check-order note: the spec does not need to fix the order of revert checks. A
sensible reference order is mode, retirement, scheme-0 lengths, caps, amount.
For scheme 0 the caps are subsumed by the exact-length rule.

## Style constraints

- No em dashes anywhere.
- Present rejected design alternatives in present tense ("Consensus-side
  ignoring locks the ETH"), never as document history ("an earlier draft
  ignored these requests").
- Match the existing prose: short sentences, RFC 2119 keywords in the
  Specification section only.
- Do not change the event ABI or the event topic hash. Neither change touches
  the event signature.
- Do not touch unrelated sections.

## Acceptance checklist

- `grep` finds no "MUST NOT apply a minimum or maximum length".
- No remaining claim that wrong-length BLS deposits are ignored by consensus.
- `process_bls_credential_deposit` has no length guard; the invariant sentence
  is present.
- Constants table has `MAX_PUBKEY_LENGTH` and `MAX_CREDENTIAL_METADATA_LENGTH`
  set to 8192.
- Rationale covers: propagated-bytes argument, gas-bound total, cap-bound
  economics with the ETH figures, PQ scheme headroom trade-off.
- The length-bounds TODO comment is gone.
- Tests cover the cap boundary on both fields and scheme-0 length rejection.
