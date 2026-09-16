---
title: Post-Quantum Meta
description: List of EIPs for moving validator authentication from BLS to post-quantum signatures
author: Kevaundray Wedderburn (@kevaundray)
discussions-to:
status: Draft
type: Meta
created: 2026-08-26
requires: 6110, 7002, 7251, 7685, 7732, 8015, 8282, 8321
---

## Abstract

This Meta EIP bundles the changes that move every validator-facing signature on
the beacon chain off BLS and onto hash-based signatures, in two phases that
keep the chain finalizing throughout. It lists the EIPs that exist, marks the
ones that are still placeholders, states what each phase needs before it can
start, and records the decisions that are still open. Blob commitments and
data availability sampling rely on BLS12-381 pairings as well; they are a
separate track and out of scope for now. Execution-account authorization is
also an execution-layer track, but this EIP records the dependency because
[EIP-7002](./eip-7002.md) becomes the validator exit path.

## Motivation

A cryptographically relevant quantum computer breaks BLS12-381. Every way a
validator proves anything to the protocol today is a BLS signature, and the
signatures fall into two groups with different failure modes.

Signatures that guard stake, where a forgery moves funds or changes who is a
validator:

- deposits
- voluntary exits
- withdrawal credential changes
- builder registration and exit

Signatures that perform duties, where a forgery attacks liveness and
finality:

- attestations
- block proposals
- RANDAO reveals (unpredictable randomness)
- aggregator selection proofs (a verifiable random function)
- builder bids and payload envelopes
- payload attestations and proposer preferences under [EIP-7732](./eip-7732.md)
- sync committee messages and the on-chain sync aggregate
- slashing evidence, which re-verifies the signatures of the messages it cites
- authentication of every signed gossip message

Beneath both sits the network substrate: the transport layer's secp256k1 peer
identities and X25519 key agreement are not post-quantum either.

Consolidations and execution-triggered exits are authorized by the execution
address under [EIP-7251](./eip-7251.md) and [EIP-7002](./eip-7002.md). Their
request formats contain no signature, but their `msg.sender` authorization
inherits the security of the execution account. An externally owned account
usually uses secp256k1 and is not post-quantum.

Replacing the attestation signature is the well known part of the problem;
the rest are smaller mechanisms that lean on properties of BLS beyond
unforgeability. The table indexes the transition by those properties, since
each one explains the shape of its replacement. Like the Specification's
coverage table it adds nothing to the schedule, and every row ends in an EIP
or open decision below; a property with no such handler would be a gap.

| BLS property | Load-bearing at | Without it | Scheduled by |
| - | - | - | - |
| Signature aggregation: signatures add | attestations, the sync aggregate, [EIP-7732](./eip-7732.md) payload attestations | votes aggregate by succinct proof, putting a prover on the critical path | vote-aggregation EIP (Phase 2a), open decision 6 |
| Uniqueness: one valid signature per key and message, a VRF | RANDAO reveals, aggregator selection proofs | randomness and selection lotteries become grindable | [EIP-8321](./eip-8321.md), open decision 6, assigned draft 8384 |
| Public-key aggregation: pubkeys add | sync-committee light clients, which check one aggregate signature against a sum of held keys | constant-size updates end; a light client becomes a proof verifier with a standing prover dependency, which is why removing the committee under [EIP-8390](./eip-8390.md) is on the table | light-client EIP, open decision 11 |
| Proof of possession | the deposit signature's rogue-key defense | hash-based keys need no proof of possession; the deposit signature survives only to bind the key to withdrawal credentials | deposit candidates, open decision 2 |
| Statelessness: a key signs anything, forever | every duty, every signed gossip message, remote signers | one-time indices must be budgeted per message type, and restoring a key from backup can reuse an index and forfeit the key | gossip-authentication EIP, open decisions 5 and 12 |
| Threshold splitting | distributed validator clusters | no threshold scheme exists for stateful hash-based signatures | open decision 8 |
| Constant small size: 96-byte signatures, 48-byte keys | gossip and req/resp limits, `Validator.pubkey`, request-contract naming | signatures grow to kilobytes, and a post-quantum key does not fit the field that names validators | p2p-validation EIP, open decision 4 |
| Re-verifiable aggregates | slashing evidence, which re-verifies the signatures of the messages it cites | proof-aggregated votes leave no aggregate signature for evidence to cite | slashing-evidence EIP |

Liveness fixes the ordering: a validator cannot use a post-quantum key until it
has registered one, and the protocol cannot stop accepting BLS until enough
active validators hold the PQ material their duties need, which is more than
a key.

## Transition at a glance

The migration separates **preparation** from **use**. Validators register the
post-quantum material required for consensus while BLS remains the sole
authentication scheme for validator duties. Once enough active stake is ready,
a single hard fork switches every consensus duty to the post-quantum protocol.

There is no mixed BLS/post-quantum consensus. At any slot, validator duties are
authenticated by exactly one scheme.

| Stage | Validator duties | Validator entry | Purpose |
| - | - | - | - |
| Today | BLS | BLS | current protocol |
| Phase 1 | BLS | BLS, plus dormant post-quantum preparation | make the validator set post-quantum-ready |
| Phase 2a | post-quantum only | transitional | atomically switch consensus duties |
| Phase 2b | post-quantum only | post-quantum only | close legacy entry paths |
| Phase 2c | post-quantum only | post-quantum only | remove remaining BLS machinery |

**Atomic-duty invariant:** before the Phase 2a fork, BLS is the only accepted
authentication scheme for validator duties. From the Phase 2a fork onward, the
post-quantum scheme is the only accepted authentication scheme for validator
duties.

A validator is **post-quantum-ready** when all material required to perform its
post-quantum duties has been registered and is eligible to become active at the
cutover. At minimum this is a registered post-quantum signing key and an active
registered RANDAO commitment; if the chosen aggregator design adds another
credential, that credential is part of readiness as well. Readiness does not
give the validator a second consensus identity and does not enable
post-quantum duties before the cutover.

Conceptually:

```text
                         Phase 1
                    prepare under BLS
                           |
             +-------------+-------------+
             |                           |
       register PQ key             register RANDAO
             |                       material
             +-------------+-------------+
                           |
                     PQ-ready stake
                           |
                           | readiness threshold
                           v
                 +-------------------+
                 | Phase 2a cutover  |
                 +-------------------+
                           |
                 all duties become PQ
                           |
                           v
                     Phase 2b
                close legacy entry
                           |
                           v
                     Phase 2c
                    retire BLS
```

The transition therefore has two different shapes. **Lifecycle mechanisms**
change gradually: post-quantum material can be registered before it is used,
legacy entry paths close after the duty cutover, and remaining BLS machinery is
retired last. **Duty mechanisms** change atomically: attestations, proposals,
RANDAO, aggregation, sync-committee duties if retained, payload attestations,
and validator-authenticated gossip all switch together at Phase 2a.

### Completeness methodology

This document audits the transition from four independent directions. The same
mechanism may therefore appear in more than one table. The duplication is
intentional: each view catches a different class of omission.

1. **Cryptographic-property audit.** Every property of BLS that is load-bearing
   somewhere in the protocol must have a replacement. The table in Motivation
   covers aggregation, uniqueness, public-key aggregation, proof of possession,
   stateless signing, threshold splitting, key/signature size, and
   re-verifiable aggregates.
2. **Protocol-service audit.** Every service whose security depends on validator
   authentication must have a migration path. The coverage-by-service table
   indexes block production, finality, payload timeliness, censorship
   resistance, light clients, accountability, and adjacent tracks.
3. **Validator-lifecycle audit.** Every relevant validator state must have
   defined behavior before, at, and after the cutover.
4. **Fork-boundary audit.** Objects and assignments created under pre-fork rules
   but consumed under post-fork rules must have explicit transition semantics.

A missing handler in any of these views is a migration gap, even if the other
views appear complete.

### Target post-quantum architecture

The migration is easier to reason about if the destination is specified
independently of how Ethereum reaches it. In the end state:

- each validator has one stable validator identity and one active
  post-quantum signing credential;
- validator duties are authenticated only by the post-quantum scheme;
- committee votes that require succinct on-chain representation are aggregated
  by the post-quantum proof mechanism rather than BLS signature addition;
- RANDAO uses the registered post-quantum randomness mechanism rather than BLS
  signature uniqueness;
- aggregator selection no longer depends on a BLS selection proof;
- new validators enter with their post-quantum credential and required RANDAO
  material already bound to their withdrawal credentials;
- validator exits are authorized through the execution-layer withdrawal
  credential path rather than `SignedVoluntaryExit`;
- post-quantum slashing evidence provides accountability for post-quantum
  proposals and votes;
- validator-authenticated gossip uses the post-quantum credential with an
  explicit one-time-index budget where the base scheme is stateful;
- light clients either verify the post-quantum replacement for sync-committee
  authentication or the sync committee is removed;
- historical pre-switch blocks remain linked by their roots, but the cutover
  state is the trust anchor for post-quantum security;
- BLS verification is not part of the state transition for new post-retirement
  blocks.

This target architecture deliberately excludes the migration machinery:
dormant credentials, BLS-authorized registration, partial registrations,
pre-fold pubkey lookups that exist only for compatibility, and other
transitional paths are not properties of the desired consensus protocol.

### Validator lifecycle audit

The table below is a completeness checklist, not a second schedule. `TBD`
means that the transition needs an explicit rule before the relevant fork can
be considered specified.

| Validator state at Phase 2a | PQ-ready | Phase 2a | Phase 2b | Phase 2c |
| - | - | - | - | - |
| active | yes | begins all duties under PQ | unchanged | unchanged |
| active | no | open decision 10: inactive/leaking and exit semantics | cannot enter through a new BLS deposit after cutover | force-exited if still unswitched |
| pending activation | yes | MUST define whether existing activation schedule is preserved and when PQ duties begin | unchanged once activated | unchanged |
| pending activation | no | MUST define whether it may complete registration before activation or must leave/re-deposit | no new BLS-form validator creation | force-exit/remove remaining unswitched path |
| exiting | yes | no new duties after its existing exit epoch; any duties before then use PQ | existing exit continues | unchanged |
| exiting | no | MUST define whether any remaining pre-exit duty is expected and how exit completion works | existing exit continues | BLS registration path closed |
| slashed | yes | existing slashing/withdrawability schedule survives; any required duty uses PQ | unchanged | unchanged |
| slashed | no | MUST define whether registration is permitted or the validator only proceeds toward withdrawal | unchanged | no BLS recovery path remains |
| exited, not withdrawable | either | no consensus duties; existing withdrawal schedule survives | unchanged | unchanged |
| withdrawable / awaiting sweep | either | no consensus duties; sweep follows withdrawal credentials | unchanged | unchanged |
| `0x00` credential | no | handled by the credential-retirement path rather than PQ activation | recovery path remains as specified | `0x00` machinery removed under decision 7 |
| newly deposited PQ validator | yes by construction | activation is permitted under PQ rules | normal entry path | normal entry path |

The final specification should replace every `MUST define` above with either a
rule in this Meta EIP or a named constituent EIP.

### Fork-boundary audit

Phase 2a is atomic for duties, but consensus state contains assignments,
messages, and queues produced before the fork. The cutover specification MUST
define at least the following boundary cases:

- an attestation whose duty is pre-fork but which is included or otherwise
  processed after the fork;
- pre-fork attester or proposer slashing evidence submitted after the fork;
- proposer and committee assignments computed before the fork for duties at or
  after the fork;
- the sync-committee period spanning the fork, if the sync committee is kept,
  including `current_sync_committee`, `next_sync_committee`, and cached light
  client state;
- fork-choice latest messages whose last vote was BLS-authenticated before the
  switch;
- a RANDAO commitment registered shortly enough before the fork that its
  activation delay extends past the fork;
- validators whose activation or exit epoch was determined before the fork but
  takes effect at or after it;
- deposits emitted before a lifecycle cutover but processed after it;
- execution requests emitted before a fork but consumed by the consensus layer
  after it;
- builder bids, proposer preferences, payload envelopes, payload attestations,
  inclusion lists, and other slot-bound messages whose production and
  consumption straddle the fork;
- historical and checkpoint sync across the boundary, including the exact state
  that becomes the post-quantum weak-subjectivity trust anchor.

For every boundary object, the governing rule should be derived from the
object's duty slot, epoch, or other consensus context rather than merely from
the wall-clock time at which a node receives it.


## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in
[RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and
[RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

The transition runs in two phases, the second in three steps. Each phase is one
or more forks and steps may share a fork; which forks is a later decision, and
this document is where that assignment will be recorded.
Each phase states what it needs to start, the protocol changes it carries, and
what existing and new validators do during it. Items marked **EIP TBD** are
placeholders: the mechanism is required, but no EIP specifies it yet; each
states what its EIP must specify. Items marked **draft** exist as unnumbered
drafts.

A validator is **switched** after Phase 2a when it satisfies the
post-quantum-readiness predicate defined above and the post-quantum duty rules
are live. Before Phase 2a, the same material makes the validator
**post-quantum-ready**, not switched. The **fold** is the Phase 2a replacement
of a switched validator's `Validator.pubkey` by its registered key. A
**partial registration** holds only one item or holds a RANDAO commitment that
is not active yet. The **post-fork registration path** lets an unswitched
validator register after the Phase 2a fork if open decision 10 keeps this
path. The path can use the existing operation or a new operation. The **reuse
candidate** keeps the existing deposit contract as the post-quantum deposit
path.

The mechanisms below fall into two tracks and a substrate. The **lifecycle
track** is how stake and keys enter and leave: deposits, exits, withdrawal
credentials, top-ups, builder registration, and the accounts that authorize
them. It moves gradually, one phase at a time: post-quantum material is
registered in Phase 1, BLS entry closes at Phase 2b, and unswitched stake is
force-exited at Phase 2c. The **duty track** is everything the consensus
layer verifies while it runs: attestations, proposals, RANDAO reveals,
aggregation, the sync committee, slashing, and their gossip forms. It flips
atomically at Phase 2a, co-designed against the post-quantum consensus
specification; Phase 1 only prepares what it needs, which is why the
lifecycle track carries duty material such as the RANDAO commitment. Within
the duty track, cost divides by signature shape: committee votes are
aggregated and need the proof system, while sole-signer messages need only
the base scheme and a one-time-index budget. The
**substrate** is the transport layer beneath both; it depends on nothing
else and goes first. The tracks meet in one predicate: Phase 1's lifecycle
work makes validators switched, and Phase 2a's entry condition consumes that
as a single threshold over active stake.

The matrix below is the authoritative schedule. The coverage table and the
phase sections restate its scheduling facts and, where they disagree with it,
the matrix is the text to correct first; entry conditions and placeholder
requirements live only in the phase sections.

**Lifecycle track**

| Mechanism | Phase 1: readiness | Phase 2a: switch | Phase 2b: deprecate old contracts | Phase 2c: retire |
| - | - | - | - | - |
| Validator key | [Pubkey registry](./eip-pubkey-registry.md); PQ deposits recorded dormant, signatures verified | PQ verification (EIP TBD); switched keys folded into `Validator.pubkey`, partial registrations retained, old pubkey lookup retained; activation gate lifts | BLS-form deposits stop creating validators | [Retire BLS keys](./eip-retire-bls-validator-keys.md); partial-registration state, BLS deposit signature verification, and remaining registration operations removed |
| Withdrawal credentials | BLS withdrawal credential retirement (assigned draft 8365); balance sunset (assigned draft 8367) if open decision 7 chooses it | none | none | `0x00` machinery removed |
| Voluntary exits | none | removed in favor of [EIP-7002](./eip-7002.md) (EIP TBD) | none | none |
| Builder keys | EIP TBD, new request types, recorded dormant | PQ keys and bids live; BLS bids end | BLS deposit predeploy deprecated | builders without a PQ key exited |
| System contracts | deposit contract (candidates) and builder request contracts deployed; [EIP-7002](./eip-7002.md) and [EIP-7251](./eip-7251.md) contracts unchanged | none | old deposit contract and BLS builder deposit predeploy deprecated | none |
| Execution-account authorization | EIP TBD, separate execution-layer track | PQ-safe withdrawal accounts required before BLS exits are the only validator exit path | none | none |

**Duty track**

| Mechanism | Phase 1: readiness | Phase 2a: switch | Phase 2b: deprecate old contracts | Phase 2c: retire |
| - | - | - | - | - |
| RANDAO | [EIP-8321](./eip-8321.md) operation, dormant; commitment in PQ deposits | chain live; registered chain required to switch | none | registration signature moves to the PQ key; operation deprecated once deposits carry commitments |
| Aggregation | deterministic sync-committee aggregators (assigned draft 8384); attestation: open decision 6 | attestation and payload-attestation aggregation (EIP TBD); sync aggregate PQ | none | hash-tree registration re-signed, if adopted |
| Gossip authentication | none | EIP TBD | none | none |
| Light client | none | EIP TBD if the sync committee is kept | none | none |
| Slashing | none | PQ evidence format (EIP TBD); pre-switch BLS evidence, open decision 10 | none | kept pre-switch evidence closed |
| P2P validation | none | EIP TBD | none | none |
| History | none | switch state becomes a weak subjectivity checkpoint | none | BLS history verification, open decision 9 |

**Substrate**

| Mechanism | Phase 1: readiness | Phase 2a: switch | Phase 2b: deprecate old contracts | Phase 2c: retire |
| - | - | - | - | - |
| Transport | EIP TBD | none | none | none |

### Coverage by service

The matrix schedules work by mechanism, since that is how the EIPs are cut;
this table indexes the same work by the service the consensus layer offers,
so that coverage can be audited service by service. It adds nothing to the
schedule. Lifecycle services are omitted: deposits, exits, credentials, and
builder registration map one to one onto lifecycle table rows, so that table
is already service-indexed, and only the duty track, whose mechanisms
cross-cut services, needs this second view. Data availability appears here
and in the inventory's out-of-scope segment: its KZG commitments rely on
BLS12-381 pairings but are not signatures, so the signature-centric lists
above cannot carry it, and it remains the separate track the Abstract
records.

| Service | Signed today | Replaced by | Phase |
| - | - | - | - |
| Block production | proposal signature, RANDAO reveal | verification EIP; [EIP-8321](./eip-8321.md) hash chain | 2a |
| Finality | attestations and their aggregates | vote aggregation and verification EIPs; aggregator selection per open decision 6 | 2a |
| Payload timeliness ([EIP-7732](./eip-7732.md)) | payload attestations, proposer preferences, builder bids | vote aggregation, gossip authentication, and builder key EIPs | 2a |
| Censorship resistance ([EIP-7805](./eip-7805.md)) | inclusion lists | gossip authentication EIP | 2a |
| Light clients | sync committee messages and the `SyncAggregate` | verification EIP for the signing; light client EIP, or removal under [EIP-8390](./eip-8390.md) (open decision 11) | 2a |
| Accountability | slashing evidence | evidence EIP; pre-switch window per open decision 10 | 2a, closed by 2c |
| Data availability | KZG blob commitments, pairings rather than signatures | out of scope, separate track | none |

### BLS usage inventory

One entry per thing the consensus layer authenticates, segmented the way
the matrix is: stake lifecycle, then duties, then the substrate, then the
cross-cutting concerns that exist only while the transition runs, and last
the adjacent tracks that are out of scope for this document but that a
reader will look for. Each
entry states what the mechanism is for, how it works today, and what it
relies on; its **Migration** field names the path through the phases and
what is still open; its **End state** field names the post-quantum form.
A reliance names the property from the Motivation table that makes the
usage hard to migrate; "nothing BLS-specific" marks the easy case, where
any post-quantum scheme substitutes and the only new cost is the
one-time-index budget of a stateful key.
Like the coverage table, this section adds nothing to the schedule.

**Stake lifecycle**

#### Validator deposits

- **Purpose:** This registers a new validator via the execution layer, with
  the deposited stake, their withdrawal credentials, and the validator's
  public key.

- **Mechanism:**
  - `DepositData` object is signed under the validator's BLS key
  - This is sent to the deposit contract with an `amount`
  - If surface level checks pass (like pubkey length), then a log is emitted from the contract
  - This log is then sent to the CL through [EIP-6110](./eip-6110.md) requests
  - The CL does additional checks like pubkey/signature validity. If those checks
  fail, then deposit is lost. If they pass, then the validator goes into the entry queue.

- **Relies on:** BLS signature for proof of possession against rogue-key attacks, binding
  the key to the depositor's withdrawal credentials, and DoS resistance for
  the validator ID.

Note: on the last point, imagine that no signature was needed to register a validator with a particular
public key on the CL. Then an attacker would do it as a DoS vector while attaching their withdrawal
credentials to the deposit.

<!-- TODO: 
We could have an endpoint that verifies deposits:

POST /eth/v1/.../verify_deposit

{
  pubkey,
  withdrawal_credentials,
  amount,
  signature
}
→ valid / invalid

-->

- **Migration:** To migrate deposits, we need to create a new deposit contract that accepts PQ credentials.

- **End state:** only post-quantum deposits create validators, carrying the
  key and the RANDAO commitment bound to withdrawal credentials. Under the
  two contract-deploying candidates the original contract serves only
  top-ups, resolved through the retained lookup; under the reuse candidate
  it is itself the post-quantum path, with its BLS-form deposits inert
  beyond top-ups.

#### Validator exits

- **Purpose:** let a validator leave the active set and reclaim its stake.

- **CL-triggered:**
  - the validator signs a `VoluntaryExit` message
  - the message is eventually included in a block
  - the validator enters the exit queue and is deactivated
  - once withdrawable, the sweep credits the withdrawal address through the
    execution payload's withdrawals list

Note: this is the only path for `0x00` validators, who have no execution
withdrawal address. The exit stops them from participating in the CL, but
the sweep cannot credit their stake to the EL until they rotate to `0x01`;
the balance stays parked in the beacon state.

- **EL-triggered:**
  - the withdrawal address makes a call to the [EIP-7002](./eip-7002.md)
    predeploy
  - at the end of the block the EL dequeues the request from the contract
    through a system call and carries it as an [EIP-7685](./eip-7685.md)
    execution request
  - the CL processes the request when given the EL block
  - the validator is then put into the exit queue and is deactivated
  - once withdrawable, the sweep credits the withdrawal address as above

- **Relies on:** nothing BLS-specific: any post-quantum scheme can sign the
  CL-triggered operation; the EL-triggered path leans on the execution
  account instead.

The [EIP-7002](./eip-7002.md) contract only accepts 48-byte public keys to
name the validator. We may want to make this forward compatible, even
though XMSS public keys can fit under 50 bytes; otherwise post-quantum
validators stay reachable only through the retained pre-fold lookup.

- **Migration:** the CL-triggered operation is removed at Phase 2a, leaving
  the EL-triggered path as the only way out; the credential-retirement
  draft first clears `0x00` validators, so every remaining validator holds
  execution credentials, and the deprecation EIP must account for `0x01`
  addresses that are immutable contracts unable to call the predeploy.
  Open: decision 10 supplies the exit path for unswitched validators;
  decision 13 must make the withdrawal address itself post-quantum safe.

- **End state:** only EL-triggered exits remain: exit authority is the
  withdrawal address through [EIP-7002](./eip-7002.md), and its safety is
  the execution account's, under the decision 13 track.

#### Withdrawal credential changes

- **Purpose:** let a `0x00` validator, whose withdrawal credential is still
  a BLS key, rotate to an execution address so its balance can be withdrawn.

- **Mechanism:**
  - a `0x00` credential stores `sha256(withdrawal_pubkey)` and not the pubkey,
    where the withdrawal key is a second BLS key, separate from the signing key.
  - the validator signs a `BLSToExecutionChange` with the withdrawal key,
    naming the validator and the new `0x01` address that withdrawals should be redirected to
  - once included in the beacon block, the validator credentials point to an
    execution layer address, and the funds become sweepable.

- **Relies on:** nothing BLS-specific; the hash hides the pubkey until
  first use.

- **Migration:** assigned draft 8365 exits `0x00` validators in Phase 1;
  `BLSToExecutionChange` stays open for balance recovery until Phase 2c
  removes it. Open: decision 7 rules the remaining balances.

- **End state:** gone, with the rest of the `0x00` machinery; every
  validator holds execution credentials, and leftover retired balances
  follow open decision 7's rule.

#### Builder deposits and exits

- **Purpose:** register a builder's slashable stake behind its bids, top it
  up, and exit it.

- **Mechanism:**
  - registration and top-ups call the [EIP-8282](./eip-8282.md) deposit
    predeploy. This is similar to the validator deposit and exit contract.
  - the main difference between the two contracts is not consequential for
    our purposes.
  - Similar to the deposit/exit contracts both use 7685 to send the information to
    the CL.

- **Relies on:** nothing BLS-specific; the deposit signature proves key
  possession, and the exit leans on the execution account instead.

- **Migration:** post-quantum registration is recorded dormant in Phase 1;
  the BLS deposit predeploy stops being read at Phase 2b and top-ups move
  to the post-quantum request type; unrotated builders are exited at Phase
  2c. Open: no decision; the builder-key EIP (TBD) specifies it.

- **End state:** post-quantum request types for registration, top-up,
  rotation, and exit; the BLS deposit predeploy is no longer read.

#### Validator naming

- **Purpose:** everything outside the state needs a stable name for a
  validator.

- **Mechanism:** the 48-byte `Validator.pubkey` doubles as that identifier;
  no signature is involved:
  - the [EIP-7002](./eip-7002.md) and [EIP-7251](./eip-7251.md) request
    contracts name validators by a pubkey they do not validate
  - top-up deposits match on it
  - contracts and light clients prove it at an index against the
    [EIP-4788](./eip-4788.md) root
  - beacon APIs accept it as a validator identifier

- **Relies on:** The identifier being 48 bytes or less.

- **Migration:** Phase 1 fixes the encoding; the Phase 2a fold replaces
  switched keys in `Validator.pubkey` and retains a lookup for the pre-fold
  pubkey; `pq_pubkeys` is removed at Phase 2c. Open: decision 4 picks the
  `Validator.pubkey` model.

- **End state:** `Validator.pubkey` holds the post-quantum encoding under
  the decision 4 model; the pre-fold BLS pubkey lookup remains for
  immutable staking contracts; `pq_pubkeys` is gone.

**Duties**

#### Attestations

- **Purpose:** Before DC, it is a vote for: head, source, and target.

- **Mechanism:**
  - each epoch, every active validator is shuffled into one committee at
    one slot; at that slot it signs its `AttestationData`
  - the single attestation is gossiped on its committee's subnet
  - selected aggregators sum the signatures over identical data into one
    aggregate per committee
  - the next slot's proposer merges aggregates across committees into up to
    `MAX_ATTESTATIONS_ELECTRA` on-chain `Attestation`s; a block carries
    votes about earlier slots, never about itself, since the proposer's
    signature seals the whole block
  - votes that miss the block, late arrivals or divergent data, ride a
    later block at reduced reward

- **Relies on:** signature aggregation, to fit tens of thousands of votes
  per slot into a handful of on-chain objects.

- **Migration:** signing moves to the post-quantum scheme at Phase 2a;
  aggregation becomes proof-based under the vote-aggregation EIP. Open:
  decision 6 picks the producer, in Phase 1.

- **End state:** signed under the post-quantum scheme; committee votes
  reach the block as succinct proofs; the producer is whatever open
  decision 6 chose.

#### Aggregator selection

- **Purpose:** someone must aggregate the votes from each committee

- **Mechanism:**
  - If a validator is chosen to attest at a slot, they will run a VRF to see if
    they should also be an aggregator for their committee.
  - This VRF is essentially `hash(bls_sign(epoch)) < THRESHOLD`.
    The BLS signature is proof they won. This is called a selection proof.
  - Threshold is set in such a way that the number of aggregators selected per committee
    is on average 16.
  - aggregators will listen on a particular subnet for votes to aggregate
  - aggregators publish their aggregate wrapped with the selection proof, and
    peers verify they won before forwarding.
  - The vote aggregate is included in a block by the proposer.

Note: the sync committee runs the same VRF under a different message.

- **Relies on:** uniqueness. We do not want for there to be many valid signatures for
    a particular message, because this means that they can grind the lottery.

- **Migration:** replaced ahead of the switch, in Phase 1: assigned draft
  8384 on the sync side, the attestation side per decision 6. Open:
  decision 6; only its hash-tree option registers a Phase 1 credential.

- **End state:** no selection proof exists. Aggregators are an opt-in role,
  a public prefix of the committee, or a hash-tree draw, per open
  decision 6.

#### Block proposals

- **Purpose:** enforce leader election: the shuffle names one proposer per
  slot, and the signature is what makes that exclusive.

- **Mechanism:**
  - a proposer is chosen per slot from the RANDAO-seeded shuffle
  - the block it builds packs the previous slot's attestation aggregates
  - it signs the block and propagates it to attesters

- **Relies on:** nothing BLS specific

- **Migration:** flips at Phase 2a with the verification EIP. Open:
  nothing.

- **End state:** one post-quantum signature per proposal, one one-time
  index spent.

#### RANDAO

- **Purpose:** randomness for the chain; it seeds proposer selection and
  committee shuffling.

- **Mechanism:**
  - the proposer signs the current epoch and uses the signature as random bytes to
    mix into randao(randomness accumulator)

- **Relies on:** uniqueness; since there is one valid signature per epoch
    a proposer cannot grind signatures in order to bias their randao contribution.

- **Migration:** the [EIP-8321](./eip-8321.md) chain is registered in
  Phase 1, dormant, and goes live at Phase 2a; an active commitment is half
  of the definition of switched. Open: nothing; the required change to
  EIP-8321's activation timing is in Reconciliation.

- **End state:** the proposer reveals the next preimage of its registered
  hash chain; commitments ride in deposits.

#### Sync committee and light clients

- **Purpose:** let a client track the consensus chain, without needing to follow all
               all 1 million validators.

- **Mechanism:**
  - every 27 hours, 512 validators are chosen as the sync committee.
  - each slot, members sign the head block root
  - a light client listens to those 512 committee members as a proxy
    for the whole consensus set

- **Relies on:** same as attestor aggregation, the VRF being used requires the signature
    scheme to be deterministic.

- **Migration:** if the committee is kept, the sync aggregate goes
  post-quantum at Phase 2a alongside a light-client EIP; if removed,
  [EIP-8390](./eip-8390.md) supersedes both and the Phase 1 placement of
  assigned draft 8384. Open: decision 11 comes first.

- **End state:** either light clients verify a succinct proof over the
  committee's keys, or there is no sync committee and public infrastructure
  publishes finality proofs.

#### Proposer preferences

- **Purpose:** For a proposer that is not building their own block, they will
               want to specify their preferences to the builders. This can be
               gas limit target, fee recipient etc. To do this, they will sign
               a preference message.

- **Mechanism:**
  - ahead of its slot, the proposer signs and gossips its preferences
  - gossip validation checks the sender is the slot's scheduled proposer.
    The actual message is never recorded on-chain.
  - builders read it and bid against it for the slot that the proposer is chosen

- **Relies on:** nothing BLS-specific. Since it is signed with the validator key
                 it draws from the proposer's one-time-index budget.

Note: a proposer should not try to update their preferences after sending it. It would
confused builders and would make XMSS more difficult.

- **Migration:** flips at Phase 2a with the gossip-authentication EIP,
  which budgets its one-time indices. Open: nothing.

- **End state:** post-quantum gossip-signed under the validator key,
  drawing from its one-time-index budget.

#### Builder bids and payload envelopes

- **Purpose:** under [EIP-7732](./eip-7732.md), the builder commits to a
  payload with a bid the proposer can include, then reveals the payload
  envelope.

- **Mechanism:**
  - the builder signs its bid under its registered key and gossips it; the
    topic forwards one bid per builder per parent context, and only bids
    that beat the best value seen, so the public auction is between
    builders, not a builder against itself
  - the proposer commits to a bid in its block, and the state transition
    verifies the bid signature
  - the builder then reveals the signed payload envelope within its
    deadline

Note: in protocol builders, should only be sending one bid per slot. This is enforced
on the networking layer, so there are no slashing penalties if they send more.

- **Relies on:** nothing BLS-specific

- **Migration:** BLS bids end at Phase 2a: from the fork only bids signed
  under a post-quantum builder key are valid, and a builder that has not
  rotated cannot bid until it does. Open: nothing; the builder-key EIP
  (TBD) specifies the signing.

- **End state:** signed under the registered post-quantum builder key,
  verified in the state transition.

#### Payload attestations

- **Purpose:** report whether the [EIP-7732](./eip-7732.md) builder
  revealed its payload on time, so the chain can distinguish a withholding
  builder from a censoring proposer.

- **Mechanism:**
  - a payload-timeliness committee (PTC) is chosen for each slot, an epoch in advance
  - members sign whether the payload appeared on time
  - the next block carries their votes as `PayloadAttestation` objects,
    participation bits plus one aggregate signature

- **Relies on:** nothing specific for BLS.

Note: If votes are not aggregated, then we add another 512 * XMSS signature to blocks.

- **Migration:** the committee votes flip at Phase 2a with the
  vote-aggregation EIP. Open: nothing.

- **End state:** proof-aggregated like beacon attestations.

#### Inclusion lists

- **Purpose:** force transactions into blocks against a censoring proposer.

- **Mechanism:**
  - a [EIP-7805](./eip-7805.md) committee of 16 validators is chosen per
    slot, computed an epoch ahead
  - each member signs and gossips its list; lists are never aggregated
  - fork choice enforces that the next payload satisfies the lists, so the
    signatures are verified at gossip and are not put on-chain

- **Relies on:** nothing BLS-specific: any post-quantum scheme substitutes.

- **Migration:** flips at Phase 2a with the gossip-authentication EIP.
  Open: nothing.

- **End state:** post-quantum gossip-signed, still never aggregated.

#### Slashing

- **Purpose:** make equivocation punishable: anyone can submit two
  conflicting signed messages as evidence.

- **Mechanism:**
  - `AttesterSlashing` cites two conflicting `IndexedAttestation`s;
    `ProposerSlashing` cites two signed headers for the same slot
  - the state re-verifies the cited signatures from chain data, slashes
    every validator that signed both sides, and rewards the including
    proposer

- **Relies on:** aggregates staying re-verifiable from chain data.

Note: we ideally want validator identities to remain stable across the pq fork.
For example, if slashing identifies a validator by it's public key, and this
changes between PQ forks, then this could cause issues. TODO: need to check

- **Migration:** the post-quantum evidence format arrives at Phase 2a;
  pre-switch BLS evidence closes no later than Phase 2c. Open: decision 10
  sets the pre-switch evidence window.

- **End state:** evidence cites post-quantum votes in the Phase 2a format;
  pre-switch BLS evidence is closed.

#### Gossip authentication

- **Purpose:** attribute a subset of gossip messages to a validator.
              There are messages in the protocol that should only be sent by
              validators, these `SignedMessages` are checked on the p2p layer
              to ensure that it originated from a validator.

- **Mechanism:**
  - Given a p2p object `Message` that should only originate from a validator.
    We make a `SignedMessage` wrapper that is signed by the validator.
  - Upon receiving a `SignedMessage`, the node should verify that it was signed
    by a validator before forwarding.

- **Relies on:** Nothing special about BLS.

Note: using a stateful signature scheme here is harder because these messages are not synced
with a slot.

- **Migration:** flips at Phase 2a with the gossip-authentication EIP,
  which sets the one-time-index budget per message type. Open: nothing.

- **End state:** every signed gossip message spends from its key's
  one-time-index budget under the gossip-authentication EIP's allocation.

**Substrate**

#### Transport

- **Purpose:** encrypt and authenticate peer connections.

- **Mechanism:** secp256k1 peer identities over a Noise handshake with
  X25519 key agreement; discovery records are signed by the identity key.

- **Relies on:** not BLS, this is the layer below it.

- **Migration:** Phase 1, before everything else: it depends on nothing
  and nothing depends on it. Open: nothing; the transport EIP (TBD)
  specifies it.

- **End state:** post-quantum or hybrid key agreement and a post-quantum
  peer identity type.

**Cross-cutting**

#### History and sync

- **What changes:** from the switch, pre-switch history verifies nothing
  against the assumed attacker: the switch state is a weak subjectivity
  checkpoint distributed out of band, syncing from genesis ends, and the
  weak subjectivity period computation must absorb the churn-free set
  changes at Phase 2a and Phase 2c.
- **What survives:** block roots chain by hash, which the attacker does not
  break, so backfill, history serving, and proofs of any pre-switch block
  against the checkpoint root work as before. What ends is authentication of
  history by its signatures, not its integrity against the checkpoint.
- **Open:** decision 9.

#### Distributed validators

- **Problem:** no threshold scheme exists for stateful hash-based keys, so a
  cluster cannot split a post-quantum key the way it splits a BLS key, and
  cannot register without a construction.
- **Stakes:** clusters hold a material share of stake, so this bears on
  whether the Phase 1 threshold is reachable at all.
- **Open:** decision 8.

#### Networking

- **Problem:** every size assumption in the gossip layer is calibrated to
  96-byte signatures and 48-byte keys. A hash-based signature is kilobytes,
  so every signed message grows by an order of magnitude, and an aggregate
  becomes a succinct proof in the hundreds of kilobytes
  ([EIP-8292](./eip-8292.md)'s envelope), so the aggregation topics grow by
  three.

- **Scale:** a committee subnet that carries tens of kilobytes of
  attestations per slot today carries megabytes at kilobyte signature
  sizes, and publishing one aggregate proof to a gossipsub mesh consumes a
  large fraction of a slot at the [EIP-7870](./eip-7870.md) attester
  uplink, so propagation latency, not proving time, can become the
  binding constraint on aggregation depth.

- **Levers:** batching attestations at source so co-located validators
  publish one message ([EIP-8243](./eip-8243.md)); shrinking the signer
  count through [EIP-7251](./eip-7251.md) consolidation; partitioning
  signers across subnets with per-subnet aggregation; gossip-protocol
  changes that announce large messages instead of pushing them to the full
  mesh; holding proof sizes to soft targets; and, last, raising the
  [EIP-7870](./eip-7870.md) baseline.

- **Open:** no numbered decision; the p2p-validation EIP owns the limits
  and the bandwidth and verification budgets, and the vote-aggregation EIP
  owns the message sizes they must accommodate.

**Out of scope**

#### Data availability

- **Purpose:** blob data availability sampling.

- **Mechanism:** KZG commitments over BLS12-381; pairings rather than
  signatures, but broken by the same attacker.

- **Migration:** out of scope for this document; a separate track, as the
  Abstract records. Nothing here gates it and it gates nothing here.

#### Execution accounts

- **Purpose:** the address a validator's `0x01`/`0x02` credential points at
  is where swept funds land, and it authorizes [EIP-7002](./eip-7002.md)
  exits and [EIP-7251](./eip-7251.md) consolidations through `msg.sender`;
  after the switch it is the only exit path.

- **Mechanism:** an externally owned account signs with secp256k1. Its
  public key is hidden behind the address hash until the account's first
  outgoing transaction reveals it, the same reveal-on-first-use structure
  as the `0x00` withdrawal credential. Contracts are exposed wherever
  their control path still depends on such a key.

- **Relies on:** secp256k1, not BLS; it sits beside this document's scope,
  but everything above routes funds authority into it.

- **Migration:** out of scope for this document; the separate
  execution-layer track (decision 13) must let an existing address
  permanently replace vulnerable authorization. This document records only
  the dependency: the track's deployment with notice is a Phase 2a entry
  condition, adoption cannot be enforced, and accounts that never migrate
  stay exposed, the residual Security Considerations records.

### Phase 1: post-quantum readiness under BLS

In this phase, BLS is still used as a default. There are six things that happen:

- `0x00` credential validators are exited and no new `0x00` credentials are registered
- Validators register the necessary PQ material they will need with their BLS credentials
- Aggregator selection loses its dependence on BLS signature uniqueness, and
the attestation aggregator decision is made
- The transport layer moves to post-quantum key agreement
- A separate execution-layer track defines post-quantum authorization for
  withdrawal addresses
- The post-quantum system contracts are deployed; what they record stays
dormant until Phase 2a

#### Protocol changes

**Post-quantum credentials**

- [Post-quantum pubkey registry](./eip-pubkey-registry.md): an existing
  validator registers a post-quantum public key through a BLS-signed beacon
  operation. The key is not used initially.
- [EIP-8321: Hash-Chain RANDAO](./eip-8321.md): RANDAO reveal relies on
  BLS signatures being unique per message, which hash-based signatures are not.
  EIP-8321 specifies a hashchain construction that replaces this. This document
  assumes the commitment is registered here but dormant, like the key, and
  that the chain goes live at Phase 2a; the change this requires to EIP-8321's
  activation timing is recorded in Reconciliation. Deposit-time registration of the
  commitment is deferred by EIP-8321 to a later fork and not specified; the
  deposit contract candidate that wins MUST specify it, including that a
  deposit-carried chain goes live with the validator's activation.

**Aggregator selection**

- **Deterministic sync committee aggregators (assigned draft 8384):** sync
  committee aggregators self-select with a BLS selection proof. This EIP selects them as a
  function of beacon state instead. The sync committee in particular will likely be overhauled
  with decoupled consensus or retired in some way. This is the easiest way to remove its
  selection-proof dependency; the sync committee's own signatures and the
  on-chain `SyncAggregate` remain BLS and move to the post-quantum scheme at
  Phase 2a with everything else. [EIP-8390](./eip-8390.md), removing the sync committee
  entirely, would supersede both. The assigned draft is needed only from Phase 2a and
  sits here by choice, since it needs no post-quantum material; open decision
  11 therefore gates this Phase 1 item as well.
- Attestation aggregator selection is a pending decision with three options.
  Only the hash-tree option adds a credential, so the decision MUST be made before finalizing phase 1.

| Option | Who aggregates | Phase 1 credential | Aggregator secrecy | Cost | EIP |
| - | - | - | - | - | - |
| Opt-in role | any node that chooses to, altruistically | none | none, there is no selection | relies on enough nodes opting in to prove; the proposer builds the block proof | EIP TBD; [EIP-8292](./eip-8292.md) describes one candidate |
| Deterministic | a fixed prefix of each committee | none | no | aggregator set is public an epoch ahead; selected members must prove | same construction as assigned draft 8384: [Deterministic attestation aggregators](./eip-deterministic-attestation-aggregators.md) (draft) |
| Hash-tree VRF | committee members that win a private draw | Merkle commitment, registered by operation | yes | 800 byte openings and a registration operation; drawn members must prove | [Hash-Tree Aggregator Selection](./eip-committed-attestation-aggregators.md) (draft) |

**`0x00` retirement**

- **BLS withdrawal credential retirement (assigned draft 8365):** exits every
  active validator still holding `0x00` credentials, stops processing deposits
  that would create them, and keeps `BLSToExecutionChange` open for rotation to
  `0x01`. It assumes it activates no later than the pubkey registry, so that
  the registry never has to consider `0x00` validators; if Phase 1 spans
  forks, the credential-retirement draft goes in the first.
- **Balance sunset for retired BLS validators (assigned draft 8367),** if
  open decision 7 chooses the scheduled reduction: it must start here to have
  finished by Phase 2c.

**Transport**

- **EIP TBD: Post-quantum transport.** Peer connections are authenticated by
  secp256k1 peer IDs over a Noise handshake with X25519 key agreement. The EIP
  MUST specify a post-quantum or hybrid key agreement for the libp2p handshake,
  the peer identity key type, and the discovery record changes that are needed.

**Execution-account authorization**

- **EIP TBD: Post-quantum execution-account authorization.** EIP-7002 and
  EIP-7251 authorize requests through `msg.sender`, so their safety depends on
  the execution account at the withdrawal address. This separate
  execution-layer track MUST define how an existing withdrawal address can
  permanently disable vulnerable authorization and install post-quantum
  authorization. It MUST cover externally owned accounts whose secp256k1
  public key is already public. Until this track is complete, the consensus
  transition does not protect the funds controlled by those accounts.

**System contracts**

The contracts the post-quantum chain reads are deployed here, ahead of the
switch, and the consensus layer records what they emit the same way it records
the registry operations: dormant until Phase 2a. A validator whose only key is
post-quantum MUST NOT become active before Phase 2a, since it could not
perform duties. Where the hold sits is the winning candidate's choice, under
two constraints: it MUST NOT block BLS deposits queued behind it, which
holding the deposit in `pending_deposits` would, since that queue is
processed in order; and the release at the switch MUST be churn-limited or
otherwise bounded, since [EIP-7251](./eip-7251.md) charges deposit churn
when the deposit is processed, so releasing every held validator at once
would be a second churn-free change to the active set. Recording a validator
needs a 48-byte `Validator.pubkey`, so the winning candidate also fixes the
prefixed post-quantum encoding of that field, which the retire-BLS draft says
is set by the upgrade that first registers such keys; the Phase 2a fold
reuses it. ETH deposited this way is locked until the switch, which has no
fixed date. Each candidate MUST record an early
post-quantum deposit rather than ignore it; that no current draft does so is
recorded in Reconciliation.

- **Deposit contract.** Three designs provide the post-quantum deposit path;
  the choice is open decision 2. Every candidate MUST carry the key and the
  RANDAO commitment and MUST bind the key to the depositor's withdrawal
  credentials, so that an observed deposit cannot be replayed with different
  credentials: the two contract-deploying candidates do so with a signature
  under the key, while the reuse candidate has no room for a signature and
  binds through a key identifier that commits to the withdrawal address.
  Today's deposit signature also serves as a proof of possession against
  rogue-key attacks, which hash-based keys do not need; the binding is the
  only reason a signature is still required. Recording these deposits in Phase 1 means the winning candidate
  MUST have clients verify post-quantum deposit signatures from Phase 1, ahead
  of any post-quantum duty. The existing contract is immutable and keeps accepting deposits under
  every candidate; what changes at Phase 2b is what the consensus layer does
  with them. Every candidate assumes deposits flow only through
  [EIP-6110](./eip-6110.md) requests, so [EIP-8015](./eip-8015.md), which
  removes the legacy Eth1 deposit path, must have landed. A variable-length
  post-quantum deposit does not fit the fixed EIP-6110 deposit request layout,
  so the two
  candidates that deploy a contract also need a new [EIP-7685](./eip-7685.md)
  request type and engine API support on the execution layer; the reuse
  candidate keeps the existing layout.
  - Post-quantum-ready deposit contract (draft, not yet published here): one
    new contract that accepts BLS and post-quantum deposits, with an
    irreversible BLS retirement mode that ends BLS acceptance at a published
    timestamp, set by the Phase 2b cutover rule. Its two conflicts with the
    requirements above are recorded in Reconciliation.
  - Post-quantum-only deposit contract (EIP TBD): a new contract that accepts
    only post-quantum deposits; BLS deposits continue through the existing
    contract.
  - [Post-quantum validator registration](./eip-post-quantum-validator-registration.md)
    (draft): no new contract. The post-quantum key and the RANDAO commitment
    ride in the existing contract's unvalidated pubkey and signature fields.
    Its two conflicts with this document's phasing are recorded in
    Reconciliation.
- **EIP TBD: Post-quantum builder keys.** Builders under
  [EIP-7732](./eip-7732.md) register through
  [EIP-8282: Builder Execution Requests](./eip-8282.md). Its deposit predeploy
  dispatches on a fixed calldata size carrying a 48-byte BLS key and a 96-byte
  BLS signature and reverts on anything else; its exit predeploy carries only
  the 48-byte key and is authorized by the sender address, with no signature.
  The EIP MUST therefore define new [EIP-7685](./eip-7685.md) request types
  and predeploys for the post-quantum builder key type covering registration,
  top-ups, rotation of an existing builder's key authorized by its execution
  address, and exit, since the BLS exit predeploy names builders by their
  48-byte BLS pubkey and cannot name a post-quantum one, with a lookup from a
  BLS-registered builder's pubkey to its record; and MUST specify how bids and
  payload envelopes are signed under it from Phase 2a. Keys registered here
  are dormant until Phase 2a.
- **Withdrawal and consolidation request contracts** under
  [EIP-7002](./eip-7002.md) and [EIP-7251](./eip-7251.md) are unchanged. They
  are authorized by the execution address and identify validators by a 48-byte
  pubkey they do not validate, which is the pre-fold BLS pubkey that staking
  contracts have hard-coded. The verification EIP's retained lookup (Phase 2a)
  resolves it; without that lookup an immutable staking contract could no
  longer exit, consolidate, or top up its validators. The retire-BLS draft
  identifies the choice between a retained mapping and a coordinated tooling
  change and takes no position; this document takes the mapping.

#### Validators

What each kind of validator does in this phase:

- Existing validators will register their PQ metadata. A validator with
  `0x00` credentials will rotate to `0x01` first. Rotation before the
  credential-retirement fork keeps the validator active. Rotation after the
  fork still recovers the full balance through the sweep. However, the
  validator exits on the retirement schedule and must re-enter. It cannot
  register a PQ key after its exit starts.
  Validators whose withdrawal address uses vulnerable authorization also use
  the execution-account migration path when it becomes available.
- New validators may deposit through the existing deposit contract and then
register their PQ metadata on the CL, a two-step process, or deposit through
the post-quantum contract and wait in the activation queue until Phase 2a.

#### Exiting phase 1

The active stake whose validators hold both a PQ key and an active RANDAO
commitment is readable from the beacon state. The threshold for scheduling the
Phase 2a fork is open decision 1; it cannot be 100% because new validators keep
joining via the BLS deposit contract. The fork epoch is chosen only once the
threshold holds, so the count is taken before scheduling, over
`get_total_active_balance` at the epoch of evaluation, and re-checked at the
fork epoch itself: stake whose credential-retirement exit is initiated cannot
register a key but remains active until its exit epoch, so it counts as
unswitched in the denominator rather than being dropped. The threshold is
Phase 2a's entry condition, where its safety role is stated.

### Phase 2: cutover

This is the phase where the chain starts to use PQ on the CL. The CL does not
attest with both BLS and PQ signature schemes at the same time; the Rationale
says why.

The phase starts only once a threshold of validators has switched to PQ
credentials, so the chain stays live when it switches to PQ only.

The phase splits into sub-phases. 2a and 2b can be one hard-fork, in which
case 2a's window of BLS deposits is empty; 2c cannot be the same fork as 2b,
since its entry condition is measured after 2b, and if open decision 10 keeps
a conversion window the 2b window for late BLS entrants would otherwise be
empty. Phase 1 may likewise span
several forks; the registry should ship as early as possible and need not wait
for transport. The three steps are:

- Use PQ on the CL, while still having the BLS deposits enabled. This means that
there is still a 2 step process for becoming a PQ validator, and until a validator
registers their PQ credentials, it cannot sign; what the state does with it is
open decision 10.
- Deprecate the old contracts: the existing deposit contract stops creating
validators and the BLS builder deposit predeploy stops being read, leaving the
post-quantum deposit path from Phase 1 as the only way in. Those in the entry
queue or just activated under BLS register, if open decision 10 keeps a
post-fork registration path, or exit and re-deposit. All new validators after this
point will have PQ credentials.
- Retire what BLS paths remain: force-exit validators that never switched,
close whatever BLS-signed registration path is still open, and remove the
`0x00` machinery.

### Phase 2a: switch

The fork at which every duty moves to post-quantum signing, and at which the
keys, commitments, and deposits recorded dormant in Phase 1 become live. BLS
deposits stay enabled, so a new validator may still deposit under BLS and then
register. Each item below either signs something, or is the mechanism that
replaces one that did.
Aside from the voluntary-exit removal, every item is on the duty track: one
co-designed flip against the post-quantum consensus specification (leanSpec),
which is why this phase carries most of the placeholders.

A validator that does not hold both an active RANDAO commitment and a
registered key at the fork
cannot sign. What the state does with it is open decision 10: either it stays
in the active set and leaks, which requires the switched fraction to exceed
two thirds of active balance for finality, or it is made inactive and rejoins
through the churn-limited activation queue, which is what the pubkey registry
and retire-BLS drafts describe and which keeps finality independent of
unswitched stake, but which the beacon state cannot represent without a new
status, a lookahead delay, and rules for its slashability and its exit
eligibility clock. Under the
second option it also needs an exit path, since EIP-7002 exits require an
active validator. Whether it can still register through the operations below
and return, or must exit and re-enter, is the same decision's second part.

BLS is still verified after the fork, all of it closed by Phase 2c: the
registration operations and, if open decision 10 keeps it, the conversion
operation, the signatures on BLS-form deposits,
`BLSToExecutionChange`, the EIP-8282 builder deposit signature until Phase 2b,
the hash-tree registration if adopted, and pre-switch slashing evidence if
open decision 10 keeps it. Each is a path a BLS forger can use during Phase 2,
and the ones that change membership are the reason for the safety bound in
open decision 1.

#### Entry condition

Registration saturation (open decision 1); under the opt-in aggregation
option, proving infrastructure sufficient for post-quantum attestation
aggregation; a post-quantum execution-account migration path deployed on the
execution layer, with notice enough for withdrawal-address owners to adopt it
before the switch, since adoption itself cannot be required; and the
credential-retirement draft active with its initial
backlog of `0x00` exits initiated. Its rule is standing, so later arrivals are
retired as they surface. If
open decision 10 keeps post-fork registration open until Phase 2c, the threshold
is also a safety bound: stake that is not switched at the fork remains
capturable by a BLS forger until then, so the unswitched fraction plus any
attacker stake MUST stay below one third until Phase 2c.

#### Protocol changes

- **EIP TBD: Post-quantum signature verification.** The signature scheme, the
  proof system, and the consensus rules over them are defined in the
  post-quantum consensus specification (leanSpec). This EIP is the
  beacon-chain integration. It MUST:
  - make every existing way of naming a validator, the request-contract
    pubkey, the top-up pubkey, [EIP-4788](./eip-4788.md) proofs, and API
    identifiers, resolve
    to the same index after the switch, and represent the post-quantum key in
    `Validator.pubkey` under the model chosen in open decision 4; this
    document assumes the fold of every switched validator's key under the
    encoding fixed in Phase 1 and a retained lookup for the pre-fold pubkey.
    The `pq_pubkeys` list remains active through Phase 2c and preserves every
    Phase 1 registration. Unswitched validators keep their BLS pubkey in
    `Validator.pubkey`, so registration verifies against that key as today;
  - keep registration available to unswitched validators until Phase 2c under
    the existing authorization rule, if open decision 10 keeps a way back,
    and continue to write keys to `pq_pubkeys`. The operation that completes
    both credentials MUST fold the key atomically. If both registrations occur
    in one block, the fold MUST occur only after both operations are valid.
    No intermediate state may replace the BLS pubkey before the validator has
    an active RANDAO commitment;
  - treat a validator as switched only with an active registered RANDAO commitment,
    activating each registered chain at the later of the fork and its
    EIP-8321 activation epoch;
  - apply open decision 10 (status) to unswitched validators and give them an
    exit path;
  - cover every remaining BLS-signed duty, including sync committee messages
    and the `SyncAggregate`, individual EIP-7732 payload-attestation messages,
    and proposer preferences;
  - apply open decision 10 (pre-switch evidence) to BLS slashing evidence;
  - carry the key-replacement operation, if open decision 12 provides one;
  - handle committee and proposer lookahead across the fork, since duties for
    the fork epoch and the one after it were computed before the unswitched
    validators' status changed;
  - if the sync committee is kept, define how the sync committee period that
    spans the fork is handled: members that are not switched, the
    `aggregate_pubkey` field, and light clients that already hold
    `next_sync_committee`;
  - specify the block-level vote layout together with the aggregation EIP
    below.
- **EIP TBD: Post-quantum slashing evidence.** `AttesterSlashing` carries two
  `IndexedAttestation`s with aggregate signatures. Once attestations are
  aggregated by proof there is no aggregate signature to cite, so the EIP MUST
  define the evidence format for conflicting post-quantum votes, whether the
  individual signatures or a proof of the two votes, and its size budget in
  the block. `ProposerSlashing` works unchanged but carries two post-quantum
  block signatures; the budget covers both. Evidence for messages signed
  before the switch is a separate problem: keeping BLS slashing evidence valid
  after the fork lets a BLS forger fabricate pre-fork double votes against
  validators that have already switched, and once the slashed fraction passes
  one third the correlation penalty takes their whole balance. Whether to
  accept such evidence at all, and for how long, is open decision 10
  (pre-switch evidence).
- **EIP TBD: Post-quantum light client protocol.** Needed only if the sync
  committee is kept. The Altair light client verifies one BLS aggregate over
  the participating subset of `SyncCommittee.pubkeys`, which a light client
  holding only those pubkeys can check cheaply; hash-based signatures give it
  nothing equivalent. The EIP MUST specify how a light client that holds only
  the committee's keys verifies that a supermajority subset signed the
  header, presumably by proof, and the update format that carries it. [EIP-8390](./eip-8390.md) removes the need by
  removing the sync committee.
- **EIP TBD: Post-quantum vote aggregation.** Hash-based signatures do not add,
  so votes are aggregated by a succinct proof rather than by summing
  signatures. The proof, its block layout, and the timing budget are
  defined in the post-quantum consensus specification (leanSpec); the EIP MUST
  integrate them and specify who produces each proof. For beacon attestations,
  the producer follows the attestation aggregator selection decision from
  Phase 1. A block today carries up to
  `MAX_ATTESTATIONS_ELECTRA = 8` attestations, each with its own aggregate
  signature; keeping that layout with one proof per attestation implies up to
  eight proofs per block to produce and verify, whereas one proof over all of a
  block's attestations changes who can prove and when. The layout decision
  sets the verification cost of every block. EIP-8292 describes one candidate
  with both layers: opt-in aggregators with proving hardware produce
  per-message proofs, up to eight per block, and the proposer folds them into
  one block proof, so the proposer needs proving capacity too. Under that
  option finality degrades if too few nodes opt in, so proving infrastructure
  becomes an entry condition. Under the other two options the selected
  committee members prove.

  EIP-7732 also places `PayloadAttestation` objects in the block. Each object
  contains participation bits and one aggregate BLS signature from the payload
  timeliness committee. The EIP MUST replace this aggregate with a
  post-quantum proof. It MUST define the proof producer, gossip object, block
  layout, size limit, and production deadline for these payload attestations.
  It MUST also define whether the proposer combines these proofs with the
  beacon-attestation block proof or carries a separate proof.
- **EIP TBD: Deprecate voluntary exits.** `SignedVoluntaryExit` is BLS-signed
  and is removed rather than migrated. The credential-retirement draft first
  initiates the exit of every `0x00` validator. Every validator that can still
  exit then holds execution credentials. EIP-7002 execution-triggered exits
  are authorized by the withdrawal address. They cover active validators whose
  withdrawal address can make the paid call to the predeploy. Whether an unswitched validator is
  active is open decision 10; if it is not, the verification EIP provides its
  exit path. The EIP MUST remove the operation and its gossip topic, and MUST
  account for validators whose `0x01` address is an immutable contract with
  no way to call the predeploy, which today can still exit through the signed
  operation. A `0x00` validator that surfaces from the activation queue later
  is retired by the credential-retirement draft's standing rule. Exit
  authority moves entirely to the withdrawal address.
- **EIP TBD: Post-quantum gossip authentication.** Validator identity on the
  network is proven by per-message BLS signatures. The EIP MUST specify, for
  each gossip-only signed message (aggregate and contribution wrappers,
  [EIP-7805](./eip-7805.md) inclusion lists, EIP-7732 proposer preferences),
  which validator key signs it and how a stateful signing key budgets one-time
  indices for messages that are not attestations.
- **Builder bids.** EIP-7732 verifies the bid signature in the state
  transition, so BLS bids end here, not in Phase 2c: from the fork only bids
  signed under a post-quantum builder key are valid, and a builder that has
  not rotated cannot bid until it does.
- **EIP TBD: Post-quantum p2p validation.** Every gossip topic's validation
  rules call BLS verification today, and message size limits assume 96-byte
  signatures. The EIP MUST specify the validation conditions for the block,
  attestation subnet, aggregate, sync committee, and sidecar topics under the
  post-quantum scheme, and the gossip and req/resp size limits for
  multi-kilobyte per-validator signatures and aggregate proofs, with the
  per-slot bandwidth and per-block verification-time budgets those limits
  imply against the [EIP-7870](./eip-7870.md) baseline.

#### Validators

What each kind of validator does from the switch:

- **Existing**: sign every duty with the registered key from the fork. Those
  that have not registered cannot sign; open decision 10 covers their status
  and their way back.
- **New**: deposit through the post-quantum contract, which activates
  directly from this fork; or, only if open decision 10 keeps post-fork
  registration open, deposit under BLS and then register.

### Phase 2b: deprecate the old contracts

BLS-form deposits stop creating validators, so the post-quantum deposit path
from Phase 1 is the only way in and the two-step lifecycle closes. Validators
that entered under BLS shortly before this step, in the entry queue or newly
active, register through the post-fork registration path if open decision 10
keeps it open, and otherwise exit and re-deposit. After this step every new validator
holds post-quantum credentials.

#### Protocol changes

- **BLS-form deposit cutover.** The existing contract is immutable and keeps
  emitting BLS-form deposits. The winning deposit candidate's EIP MUST specify
  a cutover epoch (open decision 3) after which a BLS-form deposit creates
  no new validator,
  that top-ups to existing validators keep applying, and the rule for a
  deposit emitted before that epoch and processed after it; the
  post-quantum-ready contract draft's conflict with the top-up rule is
  recorded in Reconciliation. A BLS-form deposit for a new pubkey after
  the cutover creates nothing and its ETH stays in the contract with no refund path, and
  since the existing contract cannot be stopped this is permanent under every
  candidate; the rule MUST say so and tooling MUST refuse to produce such a
  deposit. Under the post-quantum-ready contract candidate its own BLS
  retirement timestamp MUST align with this epoch; under the reuse candidate
  the existing contract remains the post-quantum path and only its BLS-form
  deposits are affected.
- **BLS builder deposit predeploy.** The EIP-8282 deposit predeploy stops
  being read by the consensus layer, and value sent to it afterwards is locked,
  so the builder-key EIP MUST state the cutover. It is also the top-up path
  for BLS-registered builders, so from this step top-ups go through the
  post-quantum request type. The BLS exit predeploy keeps being read for
  builders it can name, so a builder that never rotated can still exit.

#### Validators

What each kind of validator does in this step:

- **Existing**: nothing. Those in the entry queue or newly active under BLS
  register or re-deposit per open decision 10.
- **New**: deposit with a post-quantum key and execution credentials.

### Phase 2c: retire

#### Entry condition

The stake still held by validators that are not switched, whenever they
entered, is below an agreed bound, so that force-exiting it is acceptable
(open decision 1); a rule
for balances still held by retired `0x00` validators is in place (open
decision 7); and every Phase 2a and 2b item has landed, since each is a place
where retirement would otherwise strand a validator.

#### Protocol changes

- [Retire BLS validator keys](./eip-retire-bls-validator-keys.md): closes the
  BLS-authorized key registration path and force-exits every validator that is
  not switched, whether it lacks the key or the commitment and whenever it
  entered; its `has_pq_pubkey` predicate reads the prefix of
  `Validator.pubkey`, which identifies exactly the switched validators because
  Phase 2a folds only those. Its stated end state is that no BLS signature is
  verified anywhere in the state transition, so the sunsets below are assigned
  to this fork and this EIP MUST specify them or name the companion that does:
  - the BLS-signed registration operations of the pubkey registry and
    EIP-8321, and the post-fork registration path if it exists. EIP-8321
    specifies that at this fork its registration signature migrates to the
    post-quantum scheme and the operation is deprecated only once deposits
    carry the commitment; this document follows that, and the pubkey
    registry's operation ends the same way. EIP-8321's differing name for
    this fork is recorded in Reconciliation;
  - BLS signature verification on BLS-form deposits from the existing
    contract, while top-ups through the retained lookup continue;
  - whatever pre-switch slashing evidence open decision 10 kept;
  - builders without a post-quantum key, which are exited;
  - `pq_pubkeys`, after every remaining validator with a partial registration
    is exited. Until this point the list preserves the single-use property of
    Phase 1 registrations and supplies keys for the post-fork registration path;
  - the remaining `0x00` machinery: `BLSToExecutionChange`, its gossip topic,
    and the registry entries that open decision 7 leaves. The
    credential-retirement draft defers this
    to "the post-quantum fork"; this document places it here rather than at
    Phase 2a.

Removal applies to the state transition for new blocks. Under the attacker
this document assumes, every pre-switch signature is forgeable, including the
registrations that bound post-quantum keys to indices, so verifying pre-switch
history with BLS provides no assurance: the switch state is a weak
subjectivity checkpoint that MUST be distributed out of band, and the
churn-free set changes at Phase 2a and here MUST be reflected in how the weak
subjectivity period is computed (open decision 9). Syncing from genesis
therefore ends at the switch: every client sync path starts from the
distributed checkpoint, whose distribution becomes infrastructure the
protocol depends on.

#### Validators

What each kind of validator does at retirement:

- **Existing**: nothing, if registered. Unregistered validators are exited.
- **New**: unchanged from Phase 2b.

### Open decisions

1. **Registration threshold.** What fraction of active stake must hold both a
   registered key and an active registered RANDAO commitment before Phase 2 ships, and
   how much unswitched stake Phase 2c may force-exit. Two bounds from decision
   10 constrain it: if unswitched validators stay active and leak, the
   switched fraction must exceed two thirds of active balance for finality; if
   post-fork registration stays open, the unswitched fraction plus any
   attacker stake must stay below one third until Phase 2c, and rejoining
   must be churn-limited.
2. **Deposit contract candidate.** Combined contract, post-quantum-only
   contract, or reuse of the existing contract. Criteria: tooling burden across
   two live contracts during Phase 1, where BLS acceptance ends, how each
   records dormant post-quantum deposits, and, for the reuse candidate, whether
   Phase 2a may keep BLS deposits enabled as its draft forbids.
3. **Existing-contract cutover.** The cutover epoch after which BLS-form
   deposits no longer create validators and the rule for in-flight deposits,
   needed under every deposit contract candidate; and, under the combined
   contract candidate only, the alignment between that epoch and the
   contract's retirement timestamp.
4. **What `Validator.pubkey` holds.** Two coherent models exist and one must
   be chosen for everyone. The pubkey registry and retire-BLS drafts put the
   raw post-quantum key there at the cutover. The separate list remains until
   Phase 2c so that partial registrations survive the cutover.
   The validator-registration draft puts a commitment to the key bound to the
   withdrawal address there, keeps the key in the separate list, and relies
   on that binding to stop deposit front-running; under it the list cannot be
   retired unless the key is recoverable from each signature. This document
   assumes the first; adopting the reuse candidate means either the fold
   stores a commitment for everyone or that candidate gives up the address
   binding for a signature. Under either model the encoding is fixed in
   Phase 1 by the winning candidate. Either way the change breaks any
   contract or light client that proves `Validator.pubkey` at an index
   against the [EIP-4788](./eip-4788.md) root, which the registry's
   compatibility claim assumed unchanged; the retained lookup does not help
   them.
5. **Tooling readiness.** Clients, staking tools, and deposit interfaces need
   support for post-quantum deposits from the moment the Phase 1 contracts are
   deployed. Remote signers need to hold and advance stateful signing state,
   the keymanager API needs to import post-quantum keys, and the
   slashing-protection database and its interchange format need a one-time
   index high-water mark. Beacon API endpoints that accept a pubkey as a
   validator identifier need to accept the pre-fold BLS pubkey, using the same
   lookup as the request contracts. Validator registrations to relays
   (`SignedValidatorRegistrationV1`) are BLS-signed off-protocol messages that
   move with the key. Solo stakers also need standards that do not exist:
   a keystore whose signing state is mutable and whose restore from backup
   cannot reuse an index, a key derivation path, and a deposit tool that
   produces the winning contract's calldata; reusing a one-time index can
   forfeit the key's security, so the failure mode is key compromise rather
   than a penalty. Without these the Phase 1
   threshold is reachable only through remote signers. Each phase also needs
   test vectors and a devnet before its fork. This is a
   coordination requirement rather than an EIP.
6. **Attestation aggregator selection.** Which of the three options in the
   Phase 1 table. Only the hash-tree option adds a Phase 1 credential, so the
   decision gates the Phase 1 fork; the opt-in role also makes proving
   infrastructure a Phase 2 entry condition. If the hash-tree option is
   chosen, its registration operation is added to Phase 1, its commitment to
   the Phase 1 deposit contract and to the definition of switched, since after
   the fold a validator without it could no longer BLS-sign the registration,
   and its registration signature moves to the post-quantum key at Phase 2c,
   as that draft specifies. Under the opt-in
   option the Phase 2a aggregation EIP defines the role; under either other
   option committee members still aggregate, chosen deterministically or by
   the private draw, and the aggregation EIP integrates only the proof.
7. **Retired `0x00` balances.** What happens to balances still held by retired
   `0x00` validators when `BLSToExecutionChange` is removed in Phase 2c: a
   scheduled reduction to zero, which the balance-sunset draft specifies and
   which must start
   in Phase 1 to finish in time, a final sweep, or a permanent recovery path.
   Because the first option must ship with or right after the
   credential-retirement draft, this
   decision gates the Phase 1 fork.
8. **Distributed validators.** There is no threshold scheme for stateful
   hash-based signatures, so a cluster cannot split a post-quantum key the way
   it splits a BLS key. Operators running distributed validators need a
   construction, such as multi-party signing or one key per operator with a
   different consolidation model, or they cannot register. Since they hold a
   material share of stake, this bears on whether the Phase 1 threshold is
   reachable.
9. **Historical verification.** How the switch state is distributed as a
   weak subjectivity checkpoint, and whether clients keep BLS verification for
   pre-switch history at all, given that it verifies nothing against the
   assumed attacker. Either way, syncing from genesis no longer
   authenticates the chain, so checkpoint distribution stops being an
   optimization and becomes the sync path every client depends on.
10. **Unswitched validators.** What "not switched" means for a validator
    without both a registered key and an active commitment at the fork. Three
    parts must be decided together. Status: whether it stays active and leaks, or is
    removed from the active set under a new status with a lookahead delay, and
    either way how it exits. Way back: whether it may still register through
    a BLS-signed operation until Phase 2c, in which case rejoining
    MUST be churn-limited and the unswitched fraction is the safety bound in
    decision 1, or BLS-authorized registration closes at the switch and it
    exits and re-enters. Pre-switch evidence: whether BLS slashing evidence
    for pre-fork messages is closed at the fork, leaving late-reported
    pre-fork equivocations unpunished, or accepted for a stated window that
    ends no later than Phase 2c, exposing switched validators to forged
    evidence for that long; this also settles whether an unswitched validator
    remains slashable. Of the two status options, the new status is the
    larger client change in this document: the beacon state derives a
    validator's status from its epoch fields rather than storing one, so a
    new status touches every computation of the active set, and clients
    need the answer well before the Phase 2a fork.
11. **Sync committee.** Whether it is kept, with assigned draft 8384 and the
    light client placeholder, or removed under EIP-8390. That proposal's
    precondition is public infrastructure that publishes finality proofs.
    Three Phase 2a items depend on the answer: the light client placeholder,
    the verification EIP's sync-committee fork handling, and the sync
    aggregate in the vote-aggregation EIP. The Phase 1 placement of assigned
    draft 8384 depends on it as well.
12. **Key replacement.** Registration is single-use, so a validator has no
    way to replace a stateful key at any point, on exhaustion, lost signing
    state, or compromise, other than exiting and re-depositing while a
    compromised key can still sign. The post-fork registration path can
    complete missing material for an unswitched validator, but it cannot
    replace a registered key. Whether a post-quantum-signed rotation operation
    is provided, as builders have.
13. **Execution accounts.** Which execution-layer mechanism lets an existing
    withdrawal address permanently replace vulnerable authorization with
    post-quantum authorization. The mechanism must cover externally owned
    accounts with exposed secp256k1 public keys and contracts whose control
    path still depends on such keys.

Which fork each decision gates:

- **Phase 1:** 2, 4, 5, 6, 7, and 8. The deposit candidate (2) fixes the
  `Validator.pubkey` encoding (4) and the calldata that tooling (5) must
  produce; only the hash-tree option (6) adds a credential; the scheduled
  reduction (7) must start here; and distributed validators (8) cannot
  register without a construction. Decision 11 also gates the Phase 1
  placement of assigned draft 8384.
- **Phase 2a:** 1, 10, 11, 12, and 13. The threshold (1) and unswitched
  status (10) are decided together; the sync committee (11) selects three
  Phase 2a items; key replacement (12) is an operation the verification EIP
  would carry; and the execution-account mechanism (13) is an entry condition.
- **Phase 2b:** 3, under every deposit contract candidate.
- **Phase 2c:** 9, and the pre-switch evidence window from decision 10.

### Reconciliation

The drafts this document sequences predate it. Where a draft as written
conflicts with the schedule above, the conflict and the required change are
recorded here rather than inline, so the phase text describes only the target
state. An entry is resolved by amending the named draft, and is then removed.

- **EIP-8321, activation timing.** As written, EIP-8321 switches a
  validator's reveal to its hash chain a few epochs after registration; this
  document keeps every registered chain dormant until Phase 2a. The draft
  must adopt the dormant model while keeping its grinding bound: a chain
  registered fewer than `COMMITMENT_REGISTRATION_DELAY` epochs before the
  switch activates at inclusion plus the delay, not at the fork, and its
  owner is not switched until then.
- **EIP-8321, fork naming.** The draft calls the fork that deprecates its
  registration operation "the fork that reworks deposits"; this document
  assigns that work to Phase 2c, and the names must be reconciled.
- **Post-quantum-ready deposit contract draft.** As written it carries no
  RANDAO commitment, which every candidate must carry, and from its
  retirement block it stops deriving any request from the legacy contract,
  which would end top-ups; Phase 2b requires top-ups to keep applying. Both
  must change.
- **Post-quantum validator registration draft.** Its text ties activation to
  post-quantum verification and ends BLS onboarding in the same fork;
  recording early deposits dormant relaxes the first, and Phase 2a's
  continued BLS deposits conflict with the second.
- **Deposit contract candidates, early deposits.** Every candidate must
  record an early post-quantum deposit rather than ignore it; no current
  draft does.

## Rationale

### Structure

A meta EIP exists to sequence work, and every open question about this
transition is about timing: when registration is sufficient, when the cutover
happens, what happens at the instant the old contract stops creating
validators. Phases give those questions a home. The matrix keeps the mechanism
view, so a reader can follow one row across the transition or one column for a
single phase.
One schedule fact deliberately appears in several views. To keep them
consistent the matrix is authoritative for scheduling, and the coverage
table and phase prose restate it.
The tracks separate the two transition shapes: lifecycle mechanisms change
gradually across phases, duty mechanisms flip at once at the switch, and the
substrate precedes both. Grouping the matrix by track shows which shape each
mechanism follows.

### Why the cutover is atomic

The pubkey registry and validator-registration drafts specify a single switch
with no coexistence; EIP-8321 supports per-validator coexistence, and this
document keeps its chain dormant for uniformity rather than necessity. If the
same validator can authenticate a duty under either scheme, its security is
that of the weaker scheme.

Disjoint validator cohorts are different. A quantum attacker controls only the
BLS cohort, so safety remains possible while that cohort plus existing attacker
stake stays below one third. Such coexistence still needs two wire formats,
two aggregation paths, mixed committee rules, and separate accounting for
stateful signing indices. This document chooses one atomic duty-format cutover
to avoid that transitional protocol. The cost is that unswitched validators
stop participating at the fork. Phase 1 therefore has a saturation threshold,
and Phase 2c has a force-exit bound.

### Dependencies

Phase 2 needs Phase 1 because nothing can verify a post-quantum signature
until keys and RANDAO commitments are on-chain. Within Phase 2, 2b needs the
switch because BLS-form deposits can only stop once post-quantum deposits
create validators that can perform duties, and 2c needs everything, because it
removes paths rather than adding them and its bound is measured after 2b.
Transport is in Phase 1 by choice rather than dependency: it depends on
nothing else, so it goes first.

The execution-account track is the one entry condition that is not a
beacon-state fact. Phase 2a removes voluntary exits, so from the switch
[EIP-7002](./eip-7002.md) is a validator's only way out, and its safety is
the safety of the withdrawal address. The track must therefore be usable
before the switch. Usable means the mechanism is deployed and
withdrawal-address owners have had notice to adopt it; the protocol cannot
see whether an address has migrated, so adoption cannot be a condition, and
the accounts that never migrate are the residual risk recorded in Security
Considerations.

### Placeholders

A placeholder is listed when the mechanism is required for retirement to be
safe, whether or not anyone has written it down. Stating the requirement and
the interface it must satisfy lets the EIPs that exist be reviewed against a
complete picture rather than against the pieces that happen to be written.

### Alternatives

Where more than one EIP addresses the same mechanism, all are listed and the
open decision is recorded rather than made here, so that the choice is made
deliberately.

## Backwards Compatibility

Every phase is a hard fork. Beyond the fork itself, four things break or
change for parties outside the protocol:

- The fold replaces `Validator.pubkey`, so any contract or light client that
  proves a validator's pubkey at an index against the
  [EIP-4788](./eip-4788.md) root stops matching for switched validators. The
  retained lookup serves the request contracts, not these proofs (open
  decision 4).
- After the Phase 2b cutover a BLS-form deposit for a new pubkey creates
  nothing and its ETH is unrecoverable, permanently, since the existing
  contract cannot be stopped. The Specification requires tooling to refuse
  such a deposit.
- A post-quantum deposit made in Phase 1 is locked until the switch, which has
  no fixed date.
- `0x00` validators are exited by the credential-retirement draft unless they
  rotate first, and
  `BLSToExecutionChange` is removed at Phase 2c, subject to open decision 7.

## Security Considerations

See individual EIPs. One consideration is shared by every transitional
mechanism: an attacker that already holds a cryptographically relevant quantum
computer during the transition can forge any BLS signature the protocol still
accepts. Each transitional EIP records what that attacker can do with its
particular BLS path. The switch closes the duty signatures and BLS builder
bids; Phase 2b closes the EIP-8282 builder deposit signature and stops
BLS-form deposits creating validators; Phase 2c closes the remaining
registration path, `BLSToExecutionChange`, the hash-tree registration if
adopted, and whatever pre-switch slashing evidence remains, and removes the
BLS deposit signature verification that Phase 2b left unused. The matrix is
the authoritative schedule. Two paths the drafts record and this
document restates because they cross EIP boundaries: a forged single-use
registration binds an honest validator to a key or chain it does not hold,
which the pubkey registry and EIP-8321 leave unrecoverable short of exit, so
a BLS forger can silence any unregistered validator during Phase 1; and the
BLS-signed registration path during Phase 2 can be used to capture unswitched
stake, which the retire-BLS draft bounds by activation churn and which is why
open decision 10 is a safety question.

The transition does not make an execution account post-quantum. EIP-7002 and
EIP-7251 trust the `msg.sender` recorded by the execution layer. If that address
is an externally owned account, an exposed secp256k1 public key lets a quantum
attacker recover its private key. The attacker can request a withdrawal and
spend the funds after the sweep. The separate execution-account authorization
track must remove this risk for affected withdrawal addresses. The Phase 2a
entry condition requires only that the track's mechanism is deployed with
notice; the protocol cannot detect whether a withdrawal address has migrated,
so the funds of accounts that have not migrated by the switch stay exposed.
This transition accepts that residual rather than closing it.

A post-quantum deposit made in Phase 1 is locked until the switch, which has no
fixed date, and an unactivated validator cannot exit through EIP-7002. If
Phase 2 slips, that ETH is stuck for the duration. Deposit tooling should say
so before accepting such a deposit.

The `0x00` credential change path is the case with funds directly at stake.
The credential-retirement draft keeps `BLSToExecutionChange` open so that
retired validators can recover their balance. The BLS withdrawal key alone
authorizes that operation. Only a hash of the withdrawal pubkey is on chain, so
a quantum-capable attacker cannot rotate an idle `0x00` validator whose
withdrawal pubkey was never disclosed; the exposure is the moment the owner
broadcasts the change, which reveals the pubkey and lets the attacker derive
the key and race a competing change. Validators whose withdrawal pubkey is
already public, through credentials derived from the signing key, published
deposit data, or a change broadcast but never included, can be rotated at any
time. That is why `0x00` holders should rotate while BLS is still sound rather
than wait, and why Phase 2c needs a rule for the balances that remain (open
decision 7).

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
