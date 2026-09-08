---
title: Hash-Tree Aggregator Selection
description: Replace the attestation selection proof with a Merkle commitment opened once per epoch
author: Kevaundray Wedderburn (@kevaundray)
discussions-to: 
status: Draft
type: Standards Track
category: Core
created: 2026-08-20
requires: 7549, 7916
---

## Abstract

At each slot, signatures are aggregated. Validators run a _lottery_ to check whether
they are eligible to be an aggregator for that slot, and if so they then decide
to aggregate or not. Formally, the validators are running a Verifiable Random Function(VRF).

This lottery/vrf relies on BLS signatures being unique per message. This means that validators
cannot keep grinding/computing signatures until they are chosen as validators. Post-quantum
hash-based schemes are rarely unique per message, which means that if we cannot swap BLS for
a PQ scheme for this purpose.

This EIP preserves self-selection by replacing the signature with a Merkle leaf.
Each validator registers the root of a Merkle tree of depth `D`, and
opens the leaf at index `i` for its `i`-th epoch when it claims to be an aggregator.

Uniqueness comes from the Merkle binding and the collision resistance of the hash
function used in the tree.

## Motivation

Aggregator secrecy is what stops an attacker knowing, an epoch in advance,
which 16 attesters of a committee's ~512 members must be DoSd to suppress its
aggregates.

Attestation aggregates carry consensus votes, so suppression keeps
attestations off chain and lowers participation. We note that the sync committee
also has aggregators and are being treated differently because attestations have
a materially larger consequence for consensus than sync committee votes. Moreover,
since sync committee aggregators can be chosen per slot vs attestation aggregators
being chosen per epoch, this solution is harder to implement for sync committee
aggregators.

In short, the property is worth preserving if it can be done at acceptable cost.
Note: Aggregators today _can_ be identified by a sufficiently motivated actor, aggregator
secrecy makes it harder for a curious actor to immediately know this by looking at
the chain.

A merkle tree committed ahead of time achieves the same properties we want:

- **Binding** comes from collision resistance. For a fixed root and leaf index,
only one value verifies, so a validator cannot retry into a win.
- **Hiding** comes from the leaves being hashed before insertion and otherwise
unopened. Also opening one leaf reveals nothing about any other.
- **Verifiability** costs `AGGREGATOR_COMMITMENT_TREE_DEPTH + 1` hashes. ie its
a merkle tree opening.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in
[RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and
[RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

### New constants

| Name | Value |
| - | - |
| `DOMAIN_AGGREGATOR_COMMITMENT_REGISTRATION` | `DomainType('0x13000000')` |

### New presets

| Name | Value | Notes |
| - | - | - |
| `AGGREGATOR_COMMITMENT_TREE_DEPTH` | `uint64(24)` | one leaf per epoch, sized to outlast a validator |
| `AGGREGATOR_COMMITMENT_REGISTRATION_DELAY` | `Epoch(3)` | at least `MIN_SEED_LOOKAHEAD + 2`, as `COMMITMENT_REGISTRATION_DELAY` in [EIP-8321](./eip-8321.md) |
| `MAX_AGGREGATOR_COMMITMENT_REGISTRATIONS` | `uint64(128)` | per block |

### New containers

```python
class AggregatorCommitment(Container):
    root: Bytes32
    activation_epoch: Epoch  # FAR_FUTURE_EPOCH until registered


class AggregatorCommitmentRegistration(Container):
    validator_index: ValidatorIndex
    root: Bytes32


class SignedAggregatorCommitmentRegistration(Container):
    message: AggregatorCommitmentRegistration
    signature: BLSSignature


class AggregatorSelectionOpening(Container):
    value: Bytes32
    branch: Vector[Bytes32, AGGREGATOR_COMMITMENT_TREE_DEPTH]
```

The registration containers mirror EIP-8321's, with `commitment` named `root`
since it is a Merkle root.

### Modified `AggregateAndProof`

```python
class AggregateAndProof(Container):
    aggregator_index: ValidatorIndex
    aggregate: Attestation
    selection_proof: BLSSignature  # transitional; the G2 point at infinity once the aggregator has an active commitment
    selection_opening: AggregatorSelectionOpening  # [New in this EIP] zero until the aggregator has an active commitment
```

`selection_proof` is retained transitionally: unregistered validators keep
self-selecting with it exactly as today until their commitment activates.

### Modified `BeaconState`

```python
class AggregatorCommitments(ProgressiveList[AggregatorCommitment]):
    pass


class BeaconState(Container):
    ...
    aggregator_commitments: AggregatorCommitments  # [New in this EIP]
```

One entry per registry member, indexed by validator index, written once at
registration and never updated. `ProgressiveList` is defined in
[EIP-7916](./eip-7916.md).

### Modified `BeaconBlockBody`

```python
class BeaconBlockBody(Container):
    ...
    aggregator_commitment_registrations: List[
        SignedAggregatorCommitmentRegistration, MAX_AGGREGATOR_COMMITMENT_REGISTRATIONS
    ]  # [New in this EIP]
```

### New `get_aggregator_leaf_index`

```python
def get_aggregator_leaf_index(commitment: AggregatorCommitment, epoch: Epoch) -> uint64:
    """
    Return the leaf index to open for ``epoch``. Requires ``epoch >= commitment.activation_epoch``.
    """
    return uint64(epoch - commitment.activation_epoch)
```

### Modified `is_aggregator`

```python
def is_aggregator(state: BeaconState,
                  slot: Slot,
                  index: CommitteeIndex,
                  aggregator_index: ValidatorIndex,
                  selection_proof: BLSSignature,
                  opening: AggregatorSelectionOpening) -> bool:
    committee = get_beacon_committee(state, slot, index)
    modulo = max(uint64(1), uint64(len(committee)) // TARGET_AGGREGATORS_PER_COMMITTEE)
    epoch = compute_epoch_at_slot(slot)
    commitment = state.aggregator_commitments[aggregator_index]
    if epoch < commitment.activation_epoch:
        # Transitional: no commitment active at ``epoch``, use the legacy selection proof
        return bytes_to_uint64(hash(selection_proof)[0:8]) % modulo == 0
    leaf_index = get_aggregator_leaf_index(commitment, epoch)
    if leaf_index >= uint64(2**AGGREGATOR_COMMITMENT_TREE_DEPTH):
        return False
    seed = get_seed(state, epoch, DOMAIN_SELECTION_PROOF)
    if bytes_to_uint64(hash(opening.value + seed)[0:8]) % modulo != 0:
        return False
    # The tree commits to the hash of each value, not the value itself
    return is_valid_merkle_branch(
        hash(opening.value),
        opening.branch,
        AGGREGATOR_COMMITMENT_TREE_DEPTH,
        leaf_index,
        commitment.root,
    )
```

The draw is checked before the branch, since it is one hash and rejects most
arbitrary values. An entry is written once, at inclusion, so any state from the
including block on holds it; `state` otherwise has the same requirements as
today.

### New `process_aggregator_commitment_registration`

```python
def process_aggregator_commitment_registration(
    state: BeaconState, signed_registration: SignedAggregatorCommitmentRegistration
) -> None:
    registration = signed_registration.message
    index = registration.validator_index
    assert index < len(state.validators)
    # One-time: valid only while the validator is unregistered
    assert state.aggregator_commitments[index].activation_epoch == FAR_FUTURE_EPOCH
    validator = state.validators[index]
    domain = compute_domain(
        DOMAIN_AGGREGATOR_COMMITMENT_REGISTRATION,
        genesis_validators_root=state.genesis_validators_root,
    )
    signing_root = compute_signing_root(registration, domain)
    assert bls.Verify(validator.pubkey, signing_root, signed_registration.signature)
    state.aggregator_commitments[index] = AggregatorCommitment(
        root=registration.root,
        activation_epoch=Epoch(get_current_epoch(state) + AGGREGATOR_COMMITMENT_REGISTRATION_DELAY),
    )
```

Called from `process_operations` after the existing operations:

```python
    for_ops(body.aggregator_commitment_registrations, process_aggregator_commitment_registration)
```

- The signing domain uses the genesis fork version, as in EIP-8321, so a
  registration stays valid across forks until it is included.
- Any validator in the registry may register once, including one still in the
  activation queue.
- The entry is written at inclusion with a future `activation_epoch`, and
  `is_aggregator` takes the legacy path until then. No pending queue is needed;
  EIP-8321 has one because its entry has nowhere to hold the activation epoch.

### Fork transition

`upgrade_to_*` initialises the new field, and `add_validator_to_registry` gains
one line:

```python
    aggregator_commitments=[
        AggregatorCommitment(activation_epoch=FAR_FUTURE_EPOCH) for _ in range(len(pre.validators))
    ],
```

```python
    set_or_append_list(state.aggregator_commitments, index, AggregatorCommitment(activation_epoch=FAR_FUTURE_EPOCH))  # [New in this EIP]
```

### Modified `beacon_aggregate_and_proof` gossip validation

The selection checks become, in order:

- `[REJECT]` if the aggregator has no commitment active at the attestation's
  epoch, `selection_opening` is zero; otherwise `selection_proof` is the G2
  point at infinity.
- `[REJECT]` `is_aggregator(state, aggregate.data.slot, index,
  aggregate_and_proof.aggregator_index, aggregate_and_proof.selection_proof,
  aggregate_and_proof.selection_opening)`, where `index` is the committee index
  already derived from `aggregate.committee_bits` per
  [EIP-7549](./eip-7549.md).
- `[REJECT]` if the aggregator has no commitment active at the attestation's
  epoch, `selection_proof` is a valid signature of `aggregate.data.slot` by the
  validator, as today.

### New `aggregator_commitment_registration` gossip topic

A new global gossip topic `aggregator_commitment_registration` carries
`SignedAggregatorCommitmentRegistration` messages, validated as EIP-8321's
`randao_commitment_registration` topic, in order:

- **[REJECT]** `validator_index` is unknown.
- **[IGNORE]** a registration for `validator_index` has already been seen.
- **[REJECT]** the validator is already registered in the node's view of the head
  state.
- **[REJECT]** the signature is invalid.

### Modified `get_aggregate_and_proof`

```python
def get_aggregate_and_proof(state: BeaconState,
                            aggregator_index: ValidatorIndex,
                            aggregate: Attestation,
                            privkey: int,
                            opening: AggregatorSelectionOpening) -> AggregateAndProof:
    commitment = state.aggregator_commitments[aggregator_index]
    if compute_epoch_at_slot(aggregate.data.slot) < commitment.activation_epoch:
        # Transitional: legacy selection proof
        selection_proof = get_slot_signature(state, aggregate.data.slot, privkey)
        opening = AggregatorSelectionOpening()
    else:
        selection_proof = BLSSignature(G2_POINT_AT_INFINITY)
    return AggregateAndProof(
        aggregator_index=aggregator_index,
        aggregate=aggregate,
        selection_proof=selection_proof,
        selection_opening=opening,
    )
```

`opening` carries `v_i` and its branch for
`i = get_aggregator_leaf_index(commitment, compute_epoch_at_slot(aggregate.data.slot))`.
A validator decides whether to aggregate with the same `is_aggregator` call a
verifier makes.

### Leaf derivation

Leaf derivation is a validator-side concern and is not consensus enforced. A
validator SHOULD derive

```python
v_i = hash(s + uint_to_bytes(uint64(validator_index)) + uint_to_bytes(uint64(i)))
```

from a single 32 byte secret `s`, where `hash` is the SSZ hash function, so that
any leaf is recomputable from 32 bytes rather than storing
`2**AGGREGATOR_COMMITMENT_TREE_DEPTH` values. The tree is built over `hash(v_i)`,
and the opening for index `i` carries `v_i`.

The validator index term means a secret shared across a fleet still yields a
distinct tree per validator. Without it, validators sharing `s` would register
identical roots, and one validator's opening would reveal the status of every
validator in the fleet for the rest of the epoch.

A validator MUST NOT derive leaves in a way that relates them to one another, for
example as a hash chain, since opening one leaf would then expose others.

The secret `s` is key material, as EIP-8321 says of the chain secret. Anyone
holding it can compute every future draw, and nothing on chain reveals the
compromise.

### Sunset of the legacy path

The legacy branch of `is_aggregator` and the gossip rules that verify
`selection_proof` are transitional and SHOULD be removed in a later fork after
registration has saturated, naturally the fork that retires BLS validator keys,
as for EIP-8321's BLS reveal. At that point:

- `get_slot_signature` and the `selection_proof` field of `AggregateAndProof`
  are removed; `DOMAIN_SELECTION_PROOF` remains as the seed domain of the draw.
- Initial commitments move into validator onboarding, as EIP-8321 anticipates
  for its RANDAO commitment, after which the registration operation is no
  longer needed and can be deprecated.

## Rationale

### Why a tree and not a hash chain

EIP-8321 replaces the RANDAO reveal with a hash chain, which is
cheaper: 32 bytes per reveal and one hash to verify. That works because every
RANDAO reveal is published in a block and `process_randao` writes it back into
state, so consecutive reveals are always one hash apart.

Selection reveals have neither property. They live only in gossip, blocks carry
`Attestation` rather than `AggregateAndProof`, and roughly 31 draws in 32 lose and
are never published. A chain therefore has no on-chain anchor, and verification
costs the distance from the last recorded link, which grows for the life of the
commitment and is attacker-influenceable. A Merkle root never moves, so
verification is a fixed `AGGREGATOR_COMMITMENT_TREE_DEPTH + 1` hashes for everyone.

### Why leaves are hashed before insertion

`is_valid_merkle_branch` hashes the leaf together with `branch[0]`, so `branch[0]`
is the sibling leaf in the clear. If leaves were the raw values, opening index `i`
would reveal `v_{i ^ 1}`, which for even `i` is the value for the following epoch.
The seed for that epoch is already public by then, so the validator's next draw
would be computable by anyone, one epoch ahead, which is the exact horizon the
Motivation is concerned with. Committing to `hash(v_i)` costs one extra hash per
verification and closes this.

### Why the seed is mixed into the draw

A verifier sees only the opened leaf and its branch. Nothing proves the leaf came
from a PRF, so a validator could pick leaves that satisfy the threshold and commit
a tree of guaranteed wins. Mixing `get_seed` into the predicate removes the
benefit: the seed for a future epoch is not known at registration, so any leaf is
a fair draw however it was chosen.

### Why registrations are delayed

For the reason derived in EIP-8321: the seed for epoch `e` is fixed at the end
of `e - 2`, so a delay shorter than `MIN_SEED_LOOKAHEAD + 2` would let a
registrant see the seed its first leaves are drawn against and grind the tree
against it.

### Why registration is one-time

Registration is one-time and replay-safe for the reasons in EIP-8321: the tree
is sized to outlast the validator, a lost secret is recovered by exiting and
re-entering, and a registration is valid only while the entry is unset, which the
first inclusion falsifies. Writing the entry at inclusion, with its activation
epoch inside it, means there is no pending window and no need for EIP-8321's
one-pending rule.

### Indexing by epoch

A validator has exactly one attestation duty per epoch, so one leaf per epoch is
exact, and the index is a public function of the duty, so a validator cannot shop
for a favourable leaf. Indexing from the commitment's `activation_epoch` rather
than an absolute epoch keeps the tree sized to the validator's service life rather
than to chain age, and lets leaf 0 be the first usable index.

### Tree depth

Registration is one-time and running past the last leaf disables aggregation
until the validator exits and re-enters, so the tree must outlast the validator.
Depth 24 gives about 204 years at one leaf per epoch and 12 second slots, or 102
years at 6 second slots, for an 800 byte opening. Lifetime is exponential in
depth while opening size is linear, so the headroom is cheap: each extra level
costs 32 bytes per aggregate and doubles the lifetime. Keygen under the
recommended derivation is about `3 * 2**depth` hashes (leaf derivation, leaf
hash, internal nodes), on the order of ten seconds per validator at depth 24.

Because `AGGREGATOR_COMMITMENT_TREE_DEPTH` is the length of the SSZ `branch`
vector, changing it later changes the `AggregateAndProof` type and invalidates
every registered commitment.

Per duty, the draw needs only `v_i` and the seed, so a validator SHOULD evaluate
it first and build the branch only on a win. An opening needs the
`AGGREGATOR_COMMITMENT_TREE_DEPTH` sibling nodes, so a validator holding only
`s` would rebuild the whole tree for it; caching the top `depth - k` levels and
rebuilding only the `2**k` leaf subtree containing the duty leaf costs 256 KB per
validator and about 12,000 hashes per opening with `k = 12`.

## Backwards Compatibility

This is a consensus change requiring a hard fork. `AggregateAndProof` changes, so
the `beacon_aggregate_and_proof` topic requires a new fork digest.

Within the fork, the change is backwards compatible from the validator's
perspective: every entry is unregistered at the fork, and unregistered validators
continue to self-select with the BLS selection proof exactly as today. At
`MAX_AGGREGATOR_COMMITMENT_REGISTRATIONS = 128` per block, the full current
validator set (~1M) can register in under two days of full blocks, and there is
no deadline.

## Test Cases

State-transition and gossip test vectors to be provided in the consensus-specs
test suite.

## Security Considerations

### Grinding at registration

The registration delay means a registrant never knows the seed that any of its
leaves will be drawn against. EIP-8321's caveat applies unchanged: an attacker
that already holds a CRQC during the transition could predict every remaining
legacy BLS RANDAO reveal, and so future seeds, and grind a registration against
them.

### RANDAO bias

The current selection proof is a signature over the slot alone, so RANDAO has no
influence over who aggregates. Mixing `get_seed` into the draw introduces one:
the tail proposers of epoch `e - 2` each get the usual one bit of influence over
the epoch `e` aggregator set, and a proposer holding leaves for many validators
can choose the mix that maximises its own wins. This is the same one-bit-per-proposer
bias RANDAO already carries for committee and proposer selection, and aggregation
carries no reward, so there is no prize to grind for.

### Forged registrations

Only unregistered validators are exposed: whoever can produce a signature for one
can register a root whose leaves the validator does not hold, which permanently
disables its aggregation, though not its attestation, until it exits and
re-enters. Under BLS this requires the signing key, whose compromise is already
total. Once BLS is broken, a CRQC holder could do this to every still-unregistered
validator, which is why the registration signature moves to the post-quantum key,
and initial commitments to deposit time, at the fork that retires BLS keys. The
same applies to EIP-8321's registration.

### Distributed validators

This is the principal cost of this design. Threshold BLS is linear, so partial
signatures interpolate to the group signature without any operator holding the
key. A shared seed `s` has no such structure: any operator holding it can compute
every future leaf.

Secrecy within a cluster does not require a threshold PRF, only threshold-shared
precomputed randomness. Operators can hold Shamir shares of each `v_i`, about
512 MB per operator at depth 24, and reveal only the share for the duty epoch. The
cost moves to tree construction: every `hash(v_i)` must be computed without
revealing `v_i` to any one party, which means either a dealer trusted at cluster
setup or a one-time multi-party computation over the `2**depth` leaf hashes; the
internal nodes follow in the clear from the hashed leaves, which operators then
persist alongside their shares, since a bottom-level sibling cannot be recomputed
from a share. Both are heavier than a BLS distributed key generation, and clusters
unwilling to pay it must share `s` and accept that any single operator can predict
their draws.

### Bandwidth and state

An opening is 800 bytes at depth 24. At roughly 1024 aggregates per slot that is
about 800 KB per slot of additional gossip during the transition, and about
700 KB once the 96 byte `selection_proof` is removed, a two to three times growth
of the aggregate message today. Once the attestation signature itself is
post-quantum, at a few kilobytes per signature, the opening is a minor share of
the message. The state grows by 40 bytes per validator, about 40 MB at 1M
validators.

Verification is cheaper than today: 25 hashes instead of a pairing, with the
draw hash common to both.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
