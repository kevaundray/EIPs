# Review: eip-withdrawal-authorised-val-creds.md

Overall: the core idea is sound and the EL side is tight. The CL side has one design gap that is blocking for the stated delegated-staking motivation, a few "funds locked forever" footguns that are avoidable, and the epoch-processing logic is prose-only where it most needs pseudocode. The file also will not pass `eipw` in its current shape.

Verified: the event hash at line 222 is exactly `keccak256("ValidatorDepositEvent(bytes20,uint8,uint8,bytes32,uint64)")`, the domain string at line 166 is the 32-byte ASCII `ETHEREUM_VALIDATOR_CREDENTIAL_V1`, and the SSZ container and packed request layouts both come to 62 bytes.

## Design issues (most important first)

### 1. Unregistered funding has no exit, so the operator can grief the withdrawal authority for the full principal

`PendingValidatorFunding` is only ever consumed by a registration (line 850) or locked (lines 569, 923, 965). For delegated staking this means W must trust the operator with the entire deposit until registration lands. The operator can simply never register, or, for 1 ETH they keep, create the validator via the legacy contract with their own withdrawal credentials (the "Legacy BLS preemption" bullet at line 1136). That is strictly worse than today, where W at least gets its chosen withdrawal credentials whenever it controls the deposit data.

Open Question 2 defers this. The Security Considerations should state it as a trust assumption now. Suggested fix: add a `cancel` primitive, an EL request from `source_address = W` for `(T, C)` that converts `F` into a pending withdrawal to W. That one addition removes most of the "locked forever" cases below.

### 2. Creation mode to an already-registered `C` with the same `(T, W)` is locked forever

Line 571 forbids converting creation to top-up unconditionally. Walk-through:

1. W funds `(T, W, C)` with 10 ETH.
2. The operator registers. `R` is created and `F` is consumed.
3. W sends another creation-mode deposit of 22 ETH before noticing.

A fresh `F(T, W, C)` appears. Rule 6 (line 745) means it can never register. Nothing was redirected, so Goal 7 is not at stake.

Suggested fix: if `make_withdrawal_credentials(T, W)` equals the withdrawal credentials of the registered or created validator for `C`, credit the deposit as a top-up. The spec already does this exact comparison at line 921, so the rule is consistent.

### 3. `T` in the pending key creates a similar footgun

`(0x01, W, C)` and `(0x02, W, C)` are separate fundings (line 649). Only one can register; the other is locked. Either key by `(W, C)` with a rule for conflicting `T`, or call this out explicitly in Security Considerations.

### 4. Epoch processing is underspecified

"Shared Pending Deposit Processing" (lines 929-942) and "Unified Deposit Application" (lines 854-927) describe the hardest part of the spec in prose only. Unspecified:

* how `deposit_balance_to_consume` carries over when two lists share it,
* whether a churn-limit `break` on the legacy list skips the credential list (strict FIFO) or still scans it (smaller deposits jump ahead),
* how `next_deposit_index` is shared against `MAX_PENDING_DEPOSITS_PER_EPOCH`, and
* the exited-validator and withdrawn-validator branches for credential-path top-ups.

Both readings of the `break` question are defensible. Only one is deterministic once written down. A single merged `process_pending_deposits` loop in pyspec style would settle all of it.

### 5. `apply_validated_validator_deposit` cannot be called as written for plain top-ups

The helper takes `credential_type`, `public_key`, and `withdrawal_credentials` (line 859), but `PendingCredentialDeposit` carries only `C`. Line 884 says to fetch these from `RegisteredPendingCredential`, yet for the common case at line 919 (`V` exists, `R` consumed) there is no `R`.

Suggested fix: have the helper take `C` directly, or specify pending credential deposit application as its own function. Also state the invariant that makes this safe: at application time `V` or `R` always exists, because `V` is never removed from `state.validators` and `R` is only consumed when `V` exists.

### 6. "Zero-balance pending entries SHOULD be removed" (line 1030) is a consensus-split risk

`SHOULD` inside the state transition is non-deterministic. As written no zero-balance entry can arise (every deposit is at least 1 ETH, and restores are at least 1 ETH), so delete the sentence or make it a `MUST` with a precise trigger.

### 7. Restore-on-mismatch (line 923) must merge, not append

If W already re-funded `(T, W, C)`, appending creates two `F` records with the same key. That breaks the implicit uniqueness `get_pending_validator_funding` relies on. Use the same get-or-create plus checked-add path as creation mode.

### 8. `process_operations` placement

Electra processes block body operations before execution requests. Lines 1034-1056 require registrations (a body operation) to run after `validator_deposits` (an execution request). Say explicitly where `validator_registrations` sits in the `for_ops` sequence.

### 9. No gossip specification

Without a topic and validation rules, operators can only reach proposers out of band. At minimum:

* ignore if `F` is absent or `C` is already reserved,
* reject if the proof is invalid, and
* accept one registration per `C` per epoch.

Gossip validation of a 64 KiB post-quantum proof is the DoS surface here, not block inclusion.

## Smaller correctness and clarity points

* Registration rule 7 (line 746) is redundant. `F.amount` is a sum of deposits that each pass the 1 ETH revert at line 980.
* "Minimum Deposit" (lines 976-984) is an EL revert rule filed under the CL specification. Move it to Deposit Operation.
* Top-up semantics: after a mismatch consumes `R`, a later top-up PCD credits the legacy-preempted validator with the operator's withdrawal credentials (line 919). "Cannot modify WC" (line 1140) is true, but the sharper statement belongs in Security Considerations: a top-up funds whatever withdrawal credentials `C` ends up with.
* Asymmetry worth a Rationale sentence: a legacy deposit to an existing pubkey is always a top-up regardless of its withdrawal credentials, while a credential-path deposit with mismatched withdrawal credentials is locked.
* Line 898 with `0x01`: a 100 ETH `F` yields a 32 ETH effective balance and 68 ETH swept to W. Say so.
* Backwards Compatibility (line 1146): "EIP-6110 processing MAY continue" should be MUST. Nothing in this EIP removes it.
* Event at line 354: a Solidity-style signature with non-ABI packed data will confuse ABI decoders. Say so, or use a non-ABI topic. Line 383 ("another topic count or data length makes the block invalid") is unreachable given fixed runtime code. Simpler: every log from the address must be a valid deposit event.
* `get_pending_validator_funding` and `get_registered_pending_credential` (lines 525-540) are linear scans over lists that only shrink on registration, and abandoned `F` records accumulate forever. Up to `MAX_VALIDATOR_DEPOSIT_REQUESTS_PER_PAYLOAD` lookups run per block. Note that clients need an index, like the commitment cache at line 712.
* `DOMAIN_VALIDATOR_REGISTRATION = 0x15000000` (line 407) does not collide with `0x0B` to `0x0F` (EIP-7732, EIP-7805, EIP-8025, EIP-8205, EIP-8321) or the sibling drafts at `0x12` to `0x14`, but reconcile against consensus-specs before opening a PR.
* `requires` should also list 6110 (pending deposits, `ExecutionRequests`) and 7251 (`0x02`, `MAX_EFFECTIVE_BALANCE_ELECTRA`, `get_max_effective_balance`).
* Abstract (lines 30-35): `W` is used as "withdrawal credentials" and then as "the execution account". The rest of the document treats `W` as an address. "created the pending validator" should be "funded".
* Security Considerations: the bullet list at lines 1134-1142 sits under the H3 "Execution Request Processing Bound" but is unrelated to it.
* Line 938 ("cannot give each list a separate allowance") reads as a statement of fact. The intent is MUST NOT.
* Line 1012 math verified: each BLS `ValidatorRegistration` serializes to 174 bytes plus a 4-byte list offset, and 178 × 128 = 22,784.

## Format (will fail `eipw` as-is)

1. The preamble must be `---`-delimited YAML front matter at the top of the file. Remove the `# EIP:` H1 and the `## Preamble` section.
2. `author` and `discussions-to` cannot be TBD. `discussions-to` needs an ethereum-magicians thread.
3. Only the nine canonical H2 sections are allowed, in fixed order (`config/eipw.toml:119-130`): Abstract, Motivation, Specification, Rationale, Backwards Compatibility, Test Cases, Reference Implementation, Security Considerations, Copyright. Goals, Non-Goals, Terminology, both `*-Layer Specification` headings, every H2 from "Same Credential Commitment..." through "Request Ordering", Future Work, and Open Questions must become H3s under Specification, or fold into Motivation and Rationale. The current order is also wrong: Test Cases, then Security Considerations, then Backwards Compatibility, then Rationale.
4. The doi.org links at line 1010 fail `markdown-rel-links` (`config/eipw.toml:132`). Cite FIPS 204 and FIPS 205 by name without links.
5. The Copyright line must be exactly `Copyright and related rights waived via [CC0](../LICENSE.md).` (`config/eipw.toml:938`).
6. The first mention of each EIP must be a relative link, for example `[EIP-7685](./eip-7685.md)`.

## Nits

* Filename uses "authorised"; the title uses "Authorized".

## Suggested order of work

1. Add a cancel path for unregistered funding (item 1).
2. Allow same-withdrawal-credentials creation deposits to top up (item 2).
3. Write the merged pending-deposit loop as pseudocode (item 4).
4. Fix the helper signature and state the `V` or `R` invariant (item 5).
5. Drop the `SHOULD` at line 1030 (item 6).
6. Restructure headings and the preamble so `eipw` passes.

---

# Re-review (second pass, 2026-08-23)

## What changed

Two additions relative to the first-pass version, nothing else:

1. Line 1135: a new **Operator liveness** bullet in Security Considerations. W transfers the full principal before registration; if the operator withholds the proof the stake stays locked; no timeout, cancellation, or recovery.
2. Line 1173: a Future Work paragraph stating that cancellation and recovery of `PendingValidatorFunding` are intentionally deferred, and that a future EIP can convert the funding into a pending withdrawal to W.

Both additions are accurate. Together they satisfy the minimum ask from item 1 of the first pass (state the trust assumption).

## The eight "concrete fixes worth doing now" were not applied

| # | Fix claimed | Status | Evidence in current file |
|---|---|---|---|
| 1 | Creation becomes top-up when `(T, W)` matches the registered or active withdrawal credentials | Not applied | Line 571 still forbids it unconditionally; line 1060 repeats "never becomes a top-up" |
| 2 | `apply_validated_validator_deposit` resolves active top-ups directly from `C` | Not applied | Lines 859-880 unchanged; helper still takes `credential_type`, `public_key`, `withdrawal_credentials` |
| 3 | Restored funding merges through the checked get-or-create path | Not applied | Line 923 unchanged; no merge rule |
| 4 | Remove the zero-balance `SHOULD` | Not applied | Line 1030 unchanged |
| 5 | One deterministic two-queue epoch-processing function | Not applied | Lines 929-942 still prose only |
| 6 | Place registrations precisely in `process_operations` | Not applied | Lines 1032-1056 unchanged |
| 7 | Gossip rules, `requires: 6110, 7251`, smaller wording fixes | Not applied | Line 15 still `requires: 7685, 7997`; no gossip section; line 1147 still says "MAY continue" |
| 8 | Canonical EIP formatting | Not applied | Line 1 is still `# EIP:`, line 3 is `## Preamble`; `eipw` stops on line 1 |

"Document conflicting `T` funding instead of merging it" was also not done. No text states that `(0x01, W, C)` and `(0x02, W, C)` are separate fundings of which only one can register.

Every first-pass item other than the trust-assumption wording remains open.

## Issues introduced or exposed by the additions

* **Future Work contradicts Open Questions.** Line 1173 says recovery is intentionally deferred. Line 1178 (Open Question 2) still asks whether pending stake should become recoverable. Keep one. If deferred, reword OQ2 to ask about the future EIP's shape, or delete it.
* **"Legacy BLS preemption" (line 1137) should name the actor.** A legacy initial deposit for `P` requires a BLS signature from `P`'s secret key, so only the operator can preempt. It is the same trust assumption as Operator liveness, not an external attacker. One clause makes that clear.

## On the two disagreements

* **Keep `T` in `(T, W, C)`.** Reasonable. The first pass offered documentation as the alternative to merging; the documentation still needs to be written.
* **Defer cancellation.** Documented now, which was the minimum ask. One consequence raises the priority of fix 1: a registration proof is valid forever and anyone can include it once gossiped. If it lands after W's first tranche, every later creation-mode tranche from the same `(T, W)` is locked under the current line 571. Without fix 1, incremental funding (Goal 5) is only safe if W sends the full amount before the operator signs. Fix 1 closes this with no architectural change.

## Nothing new elsewhere

Re-checked the unchanged sections. Confirmed the FIFO property that a top-up `PendingCredentialDeposit` cannot be processed before the registration's initial entry: top-ups require `R` to exist, and `R` is created in the same step as the initial entry. No new issues beyond the first-pass list.

---

# Third pass (2026-08-23, after the substantive revision)

## eipw status

`eipw --config config/eipw.toml` passes except for the three placeholder preamble fields (`eip`, `author`, `discussions-to`), which are expected until PR time. Section order, EIP links, external links, and the Copyright line are clean.

## What landed

All eight fixes plus the `T` documentation are in:

| # | Fix | Where |
|---|---|---|
| 1 | Creation becomes top-up on exact `(T, W)` match | `is_safe_creation_top_up` at 567-579; creation mode at 659-691 |
| 2 | Application resolves from `C` | `apply_pending_credential_deposit` at 979-1008 |
| 3 | Restore merges via checked get-or-create | 582-598, called at 993 |
| 4 | Zero-balance `SHOULD` removed | 1230-1240 |
| 5 | One deterministic two-queue loop | `process_pending_deposits` at 1042-1152 |
| 6 | Registrations placed in `process_operations` | 1255-1266 |
| 7 | Gossip, `requires: 6110, 7251`, wording | 922-941, line 11 |
| 8 | Canonical formatting | front matter, H2 order, CC0 link, doi links removed |

Smaller items also landed: minimum deposit moved to the EL (269), redundant registration rule 7 dropped, ABI-decoder note (360), `0x01` sweep note (1027), "MUST continue" (1331), legacy/new asymmetry rationale (1314), Open Question 2 removed so it no longer contradicts Future Work, "Legacy BLS preemption" names the operator (1392), abstract fixed (27-31), `T` conflict documented (748-750, 1396).

Checked and holding: shared count and churn accounting, `deposit_balance_to_consume` carryover, postponement, the Eth1 bridge gate, the Same-BLS example at 1280-1294. The assert at 999 cannot fire (an R-only state cannot recur once `V` exists). The FIFO invariant at 1010 survives the safe-creation path.

## New issue A (must fix): withdrawal-credential snapshots break when credentials change

Every `PendingCredentialDeposit` now stores `withdrawal_credentials` (448; set at 678, 723, 961). At application, any byte mismatch against the validator's current credentials is treated as a redirect (989, 1102-1106) and the amount is restored to `F` keyed by the snapshot (992-993).

A validator's credentials legitimately change:

* `switch_to_compounding_validator` rewrites `0x01||W` to `0x02||W` (EIP-7251, triggered by W's own self-consolidation request).
* `BLSToExecutionChange` rewrites `0x00||hash` to `0x01||addr`.

Reachable scenario: W tops up its validator, then switches it to compounding within the same finality window (routine for LSTs migrating to `0x02`). At application the bytes differ, the deposit is restored to `F(0x01, W, C)`, and since `C` is taken that record is locked forever.

Worse: a top-up to a `0x00` validator snapshots `0x00||hash`. `get_withdrawal_authority` (560-564) then returns `(0x00, 20 bytes of a hash)` as the restore key.

The same exact-byte comparison in `is_safe_creation_top_up` (578) sends a `T=0x01` creation deposit for a validator already at `0x02||W` into locked `F`.

Fix: compare authority, not bytes. Prefix transitions are monotone (`0x00 -> 0x01 -> 0x02`) and preserve the address, so:

```python
def is_redirected(snapshot, target):
    return snapshot[0] in (0x01, 0x02) and snapshot[12:] != target[12:]
```

Use it at 578, 989, and 1102. A `0x00` snapshot never triggers a restore, which removes the garbage-key case.

Alternative: store a zero sentinel for top-up-mode deposits (the caller already accepts the target). This gives up the property that a top-up made during the R-only window follows W on legacy preemption instead of crediting the operator's validator.

## New issue B (should fix): strict legacy priority starves credential deposits

Lines 1079-1084 pick the legacy head whenever it is finalized; 1278 states it in prose. Under a sustained legacy backlog (multi-day entry queues are routine under high demand) the legacy queue never empties, so credential deposits are never processed.

Fix: slot-ordered merge. Take whichever head has the smaller `slot`; ties go to legacy. Still deterministic, gives global FIFO, and the Same-BLS example still works because same-block entries tie and legacy wins.

## Smaller

* Gossip (930-939): say which state the `F` and `C` lookups run against (current head state). Note that an operator whose registration was `IGNORE`d must rebroadcast after the funding block is imported.
* Heading hierarchy: from 742 onward every section is an H3 sibling of `### Consensus Layer`, so that section nominally ends at "Top-up mode". Demote 742-1294 one level, or drop the two layer wrappers. `eipw` does not mind either way.
* 1238 still lists "zero-balance records" as something to manage, though none can exist now.
* 385 keeps the unreachable "another topic count" rule from the first pass. Harmless.

## Summary

Everything from the first two passes is addressed. The revision introduced one fund-locking bug (issue A, from treating withdrawal credentials as immutable bytes) and one liveness concern (issue B, legacy-first starvation). Both are local fixes and neither touches the architecture.

---

# Fourth pass (2026-08-23, verification of the 14 edits)

All 14 edits verified present and correct in the file (1433 lines). `eipw` reports only the three TBD preamble placeholders.

| Edit | Location | Status |
|---|---|---|
| 1 `is_redirected` | 567-573 | Verified |
| 2 `is_safe_creation_top_up` | 587 | Verified |
| 3 `apply_pending_credential_deposit` | 1000-1003 | Verified |
| 4 `process_pending_deposits` mismatch | 1122-1128 | Verified |
| 5 prose on prefix changes | 1028 | Verified |
| 6 Rationale subsection | 1337-1341 | Verified |
| 7 tests for prefix transitions | 1390-1391 | Verified |
| 8 slot-ordered merge | 1095-1106 | Verified; old priority comment removed |
| 9 prose at Request Ordering | 1299 | Verified |
| 10 ordering test | 1392 | Verified |
| 11 gossip head state and rebroadcast | 939, 952 | Verified |
| 12 heading demotion | 751-1301 | Verified |
| 13 zero-balance removed | State Growth | Verified |
| 14 line 385 | 385 | Verified |

Stale-wording touch-ups at 97, 700, 1026, 1291, 1386 are real and consistent.

## Residual nit

Line 1013, R-only branch of `apply_pending_credential_deposit`, still asserts exact equality:

```python
assert get_registered_withdrawal_credentials(registered) == deposit.withdrawal_credentials
```

With the loosened `is_safe_creation_top_up`, a creation request with `T=0x02` while `R` is `(0x01, W)` queues a deposit with snapshot `0x02||W`. It can only reach this branch while `R` exists and no validator does. Traced: unreachable, because the registration's own entry (exact `R` credentials) always precedes it, postponement requires a validator, and a churn break stops both queues. The assert is therefore safe but rests on the FIFO argument rather than the predicate.

Suggested tightening, which also gives the new validator the credentials `P` signed over:

```python
    registered_credentials = get_registered_withdrawal_credentials(registered)
    assert not is_redirected(deposit.withdrawal_credentials, registered_credentials)
    create_validator_for_credential_type(
        state,
        registered.credential_type,
        registered.public_key,
        registered_credentials,
        deposit.amount,
    )
```

Line 1335 (Rationale): "expected withdrawal credentials" should read "expected withdrawal address" for consistency.

Neither is blocking. All items from passes one through three are closed.

---

# Fifth pass (2026-08-23, verification of the two residual nits)

* Lines 1013-1020: R-only branch now binds `registered_credentials`, asserts via `is_redirected`, and passes `registered_credentials` to `create_validator_for_credential_type`. Verified.
* Line 1336: "expected withdrawal address and restores a redirect". Verified.
* No exact-equality comparisons on `withdrawal_credentials` remain in the file.
* `eipw`: only the three TBD preamble placeholders.

All review items from passes one through four are closed. Remaining work is outside review scope: preamble values (`eip`, `author`, `discussions-to`) and the TBD constants (request type, contract address/salt/init/runtime code, `MAX_VALIDATOR_DEPOSIT_REQUESTS_PER_PAYLOAD`).
