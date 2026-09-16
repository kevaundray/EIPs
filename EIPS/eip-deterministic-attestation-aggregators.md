---
title: Deterministic attestation aggregators
description: Select attestation aggregators as a function of beacon state
author: Kevaundray Wedderburn (@kevaundray)
discussions-to: 
status: Draft
type: Standards Track
category: Core
created: 2026-08-20
---

## Abstract

Attestation aggregators are currently self-selected. A validator signs its duty
slot under `DOMAIN_SELECTION_PROOF` and aggregates if the hash of that signature
falls below a threshold.

This EIP replaces that VRF-like lottery with `get_attestation_aggregators`, a pure
function of beacon state, and removes the selection proof from `AggregateAndProof`.

It is the attestation counterpart of [EIP-8384](./eip-8384.md), which does the
same for sync committee aggregators.

## Motivation

Secrecy of the aggregator set until publication is the main property the current
selection proof gives us. Two things push against keeping it.

- Post-quantum transition: self-selection relies on BLS signatures being *unique*,
so that a validator cannot retry into a win. Hash-based schemes using target-sum
encoding (leanSig) are not unique, since the signer grinds a randomizer to hit the
target sum. Many valid signatures exist per message, so a validator could grind
itself into the aggregator set.

- Attributable non-performance: a validator that lost the lottery is today
indistinguishable from one that won and stayed silent, so aggregation duty cannot
be monitored or penalised.

Deterministic selection needs no key material, so neither problem arises. The
alternative, keeping self-selection by giving each validator an on-chain
commitment, is specified separately as a competing design. Its main cost is that
no such scheme has a threshold construction, so distributed validator clusters
could not aggregate at all.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in
[RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and
[RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

### New `get_attestation_aggregators`

```python
def get_attestation_aggregators(state: BeaconState,
                                slot: Slot,
                                index: CommitteeIndex) -> Sequence[ValidatorIndex]:
    """
    Return the aggregator indices for committee ``index`` at ``slot``.
    """
    committee = get_beacon_committee(state, slot, index)
    # Clamped so that small committees select all of their members
    count = min(TARGET_AGGREGATORS_PER_COMMITTEE, uint64(len(committee)))
    return committee[:count]
```

- No seed and no new domain are needed. `get_beacon_committee` is already distinct
per `(slot, index)`, so a prefix of it rotates on its own.

- Similar to today, aggregating is based on honest validator behavior rather than
a consensus obligation, so there is no penalty for an aggregator that stays silent.

### Modified `is_aggregator`

```python
def is_aggregator(state: BeaconState,
                  slot: Slot,
                  index: CommitteeIndex,
                  validator_index: ValidatorIndex) -> bool:
    return validator_index in get_attestation_aggregators(state, slot, index)
```

### Modified `AggregateAndProof`

```python
class AggregateAndProof(Container):
    aggregator_index: ValidatorIndex
    aggregate: Attestation
```

### Modified `beacon_aggregate_and_proof` gossip validation

The condition that verified `selection_proof` as a signature over the slot is
removed, and we have:

- `[REJECT]` `is_aggregator(state, aggregate.data.slot, index,
  aggregate_and_proof.aggregator_index)`, where `index` is the committee index
  already derived from `aggregate.committee_bits`.

This subsumes the existing check that the aggregator is within the committee.

### Modified attestation subnet subscription

Today a validator subscribes to `beacon_attestation_{subnet_id}` only if it is an
aggregator, so the subscription signals the lottery outcome to its peers before
anything is published. With a public aggregator set that same signal would narrow
a host to `TARGET_AGGREGATORS_PER_COMMITTEE` named indices, so validators MUST now
subscribe to their committee's subnet regardless of aggregator status.

### Removed

- `DOMAIN_SELECTION_PROOF`
- `get_slot_signature`
- the `selection_proof` field of `AggregateAndProof`

`TARGET_AGGREGATORS_PER_COMMITTEE` is retained, with its meaning changed from an
expected count to an exact count.

## Rationale

### Precedence

[EIP-7805](./eip-7805.md) selects a 16 member inclusion list committee as a pure
function of state, publicly computable one epoch ahead, for a duty that is
fork-choice enforced. This proposal uses the same construction, a prefix of the
beacon committee for that slot.

### Prefix of a shuffling

`get_beacon_committee` is already a `compute_committee` slice of a shuffling, so
its first `TARGET_AGGREGATORS_PER_COMMITTEE` members are a sample without
replacement, and they rotate every slot and every epoch for free. This is why the
attestation side needs no seed, where the sync side does: a sync subcommittee is
fixed for a whole period, so nothing else in its derivation varies per slot.

### One draw per epoch

A validator has exactly one attestation duty per epoch, since `compute_committee`
partitions the active set across the slots and committees of the epoch. So the
selection is decided once per epoch, at that validator's single duty slot.

### Reduced cost

Removing the selection proof removes one BLS verification and 96 bytes per message
during gossip validation. At mainnet scale that is roughly 1024 aggregates per
slot, so about 1000 fewer pairings and 100 KB less gossip per slot.

## Backwards Compatibility

This is a consensus change requiring a hard fork.

`AggregateAndProof` changes, so the `beacon_aggregate_and_proof` topic is not
wire-compatible across the fork boundary and requires a new fork digest.

Committee membership, duties, rewards, penalties, and the on-chain `Attestation`
are unchanged.

## Security Considerations

### Loss of aggregator secrecy

Every other duty is already public in advance: attestation committees one to two
epochs ahead, includers one epoch ahead, proposers one epoch, and sync committee
membership about 27 hours. Aggregation is the exception, since selection proofs
are unpredictable until published.

Under this EIP the full schedule becomes computable one epoch ahead, roughly 64
committees times 16 aggregators for each of 32 slots.

### Targeting

Suppressing a committee's aggregates requires disabling all of its aggregators, so
the set an attacker must cover shrinks from the committee, about 512 members at
current validator counts, to 16. That is a 32x reduction.

The binding constraint is unchanged. An attacker still needs a validator index to
network address mapping, and with committee subscription made unconditional this
EIP does not help build one. Publication already reveals `aggregator_index` today,
so the mapping channel is the same before and after.

Three things bound the consequence: all 16 aggregators for a committee must fail
rather than one, committees reshuffle every epoch so a sustained attack must cover
the union of many independent sets rather than a fixed one, and blocks carry
`Attestation` rather than `AggregateAndProof`, so a broadly subscribed proposer can
build aggregates from the subnets itself.

Aggregation carries no protocol reward, so there is nothing to bribe an aggregator
for. Denial of service against the named set is the whole of the attack.

Operators who publish through a separate node do not expose the host holding the
key at all, since the message is self-authenticating. This protection is available
to operators running sentry architectures and not to solo stakers, so the residual
exposure is regressive.

### RANDAO grinding

Beacon committees are already derived from RANDAO, so deriving the aggregator set
from a prefix of them introduces no new grinding surface. Aggregation carries no
reward, so there is no prize to grind for.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
