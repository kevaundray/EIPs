# Post-quantum meta: completeness audits

Companion to [Post-Quantum Meta](./eip-post-quantum-meta.md). The audits
here exist to falsify that document's plan: each one is a view a reviewer
can scan for a missing handler. They add nothing to the schedule; the
meta's migration plan is authoritative.

The meta's transition is audited from four independent directions. The same
mechanism may therefore appear in more than one table. The duplication is
intentional: each view catches a different class of omission.

1. **Cryptographic-property audit.** Every property of BLS that is load-bearing
   somewhere in the protocol must have a replacement. The property table in
   the meta's Motivation
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

## Coverage by service

This table is the service-indexed completeness view described above. It does
not alter the authoritative schedule. Lifecycle services already map
directly onto Migration requirements entries, so this second view focuses
on cross-cutting duty
services. Data availability is shown only to make its deliberate exclusion
visible; it also has an entry in the meta's inventory, in the out-of-scope
segment.

| Service | Signed today | Replaced by | Phase |
| - | - | - | - |
| Block production | proposal signature, RANDAO reveal | verification EIP; [EIP-8321](./eip-8321.md) hash chain | 2a |
| Finality | attestations and their aggregates | vote aggregation and verification EIPs; aggregator selection per open decision 6 | 2a |
| Payload timeliness ([EIP-7732](./eip-7732.md)) | payload attestations, proposer preferences, builder bids | vote aggregation, gossip authentication, and builder key EIPs | 2a |
| Censorship resistance ([EIP-7805](./eip-7805.md)) | inclusion lists | gossip authentication EIP | 2a |
| Light clients | sync committee messages and the `SyncAggregate` | verification EIP for the signing; light client EIP, or removal under [EIP-8390](./eip-8390.md) (open decision 11) | 2a |
| Accountability | slashing evidence | evidence EIP; pre-switch window per open decision 10 | 2a, closed by 2c |
| Data availability | KZG blob commitments, pairings rather than signatures | out of scope, separate track | none |

## Validator lifecycle audit

The table below is a completeness checklist, not a second schedule. A
"MUST define" cell marks a rule the transition needs before the relevant
fork can be considered specified.

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

The final specification should replace every `MUST define` above with
either a rule in the meta or a named constituent EIP.

## Fork-boundary audit

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
- **Deposit contract candidates, early deposits.** Every candidate must
  record an early post-quantum deposit rather than ignore it; no current
  draft does.

## Rationale

### Why the cutover is atomic

The pubkey registry draft specifies a single switch
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
BLS deposit signature verification that Phase 2b left unused. The
migration plan is the authoritative schedule. Two paths the drafts record
and this
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



### Open decisions

The unresolved choices are listed here once in full. The index shows what
each decision controls and the earliest phase it blocks; the couplings
between decisions follow the numbered entries.

| # | Decision | Controls | Earliest gate |
| - | - | - | - |
| 1 | Registration threshold | safe/lively Phase 2a cutover and Phase 2c force-exit bound | Phase 2a |
| 2 | Deposit contract candidate | post-quantum entry mechanism and Phase 1 encoding | Phase 1 |
| 3 | Existing-contract cutover | treatment of BLS-form deposits after legacy entry closes | Phase 2b |
| 4 | `Validator.pubkey` representation | validator naming and compatibility | Phase 1 |
| 5 | Tooling readiness | whether operators can safely register and use stateful PQ keys | Phase 1 |
| 6 | Attestation aggregator selection | proof producer and any extra readiness credential | Phase 1 |
| 7 | Retired `0x00` balances | final disposition before `BLSToExecutionChange` removal | Phase 1 |
| 8 | Distributed validators | whether DVT operators can migrate | Phase 1 |
| 9 | Historical verification | checkpoint distribution and pre-switch verification policy | Phase 2c |
| 10 | Unswitched validators | status, way back, exit, and pre-switch evidence | Phase 2a |
| 11 | Sync committee | PQ light-client design versus committee removal | Phase 1 / 2a |
| 12 | Key replacement | recovery from state loss, exhaustion, or compromise | Phase 2a |
| 13 | Execution accounts | PQ-safe authorization of withdrawal-address actions | Phase 2a |

1. **Registration threshold.** What fraction of active stake must hold both a
   registered key and an active registered RANDAO commitment before Phase 2 ships, and
   how much unswitched stake Phase 2c may force-exit. Two bounds from decision
   10 constrain it: if unswitched validators stay active and leak, the
   switched fraction must exceed two thirds of active balance for finality; if
   post-fork registration stays open, the unswitched fraction plus any
   attacker stake must stay below one third until Phase 2c, and rejoining
   must be churn-limited.
2. **Deposit contract candidate.** Combined contract or post-quantum-only
   contract; reuse of the existing contract was rejected for lack of a
   signature field. Criteria: tooling burden across two live contracts
   during Phase 1, where BLS acceptance ends, and how each records
   dormant post-quantum deposits.
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
   assumes the first. Under either model the encoding is fixed in
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
6. **Attestation aggregator selection.** Deterministic selection or the
   hash-tree VRF, per the options table in the Aggregator selection
   entry; the opt-in role was rejected as making finality depend on
   altruistic provers. Only the hash-tree option adds a Phase 1
   credential, so the decision gates the Phase 1 fork. If the hash-tree
   option is chosen, its registration operation is added to Phase 1, its
   commitment to the Phase 1 deposit contract and to the definition of
   switched, since after the fold a validator without it could no longer
   BLS-sign the registration, and its registration signature moves to
   the post-quantum key at Phase 2c, as that draft specifies. Under
   either option committee members aggregate, chosen deterministically
   or by the private draw, and the vote-aggregation EIP integrates only
   the proof.
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

Couplings between decisions: the deposit candidate (2) fixes the
`Validator.pubkey` encoding (4) and the calldata that tooling (5) must
produce; the threshold (1) and unswitched status (10) are decided together;
the sync committee (11) selects three Phase 2a items and the Phase 1
placement of assigned draft 8384; key replacement (12) is an operation the
verification EIP would carry; and the execution-account mechanism (13) is a
Phase 2a entry condition.

## Security Considerations

One consideration is shared by every transitional mechanism: an attacker
that already holds a cryptographically relevant quantum computer during
the transition can forge any BLS signature the protocol still accepts.
Each phase closes a set of those paths: the duty cutover closes the duty
signatures and BLS builder bids; legacy entry closure stops BLS-form
deposits creating validators; retirement closes the remaining
registration paths, `BLSToExecutionChange`, and pre-switch slashing
evidence. The paths that change validator-set membership are the reason
for the safety bound in open decision 1, and the funds-side risks, the
`0x00` reveal race and unmigrated withdrawal accounts, are accepted
residuals recorded in the relevant entries.