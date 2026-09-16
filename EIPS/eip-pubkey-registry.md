---
title: Post-quantum pubkey registry
description: Let existing BLS validators register a post-quantum public key while continuing to sign with BLS
author: Kevaundray Wedderburn (@kevaundray)
discussions-to: 
status: Draft
type: Standards Track
category: Core
created: 2026-08-20
requires: 8321
---

## Abstract

This EIP adds a registry mapping each validator index to a post-quantum public
key, and a beacon operation that lets a validator populate its own entry.

Registration changes nothing else. The validator keeps its BLS key in
`Validator.pubkey`, keeps its duties, and keeps signing with BLS. The registered
key is inert until a later upgrade defines how post-quantum signatures are
verified.

The point of separating registration from use is timing. The operation is
authenticated by the validator's BLS signature, so it is only trustworthy while
BLS is. It should therefore be deployed as early as possible, and left running
for as long as it takes, because the fraction of the validator set that has
recorded a key when the switchover arrives is the fraction that survives it.

## Motivation

Migrating the beacon chain to post-quantum signatures requires every existing
validator to be associated with a post-quantum key. There are two ways to do
that, and only one of them scales.

The first is to exit and re-deposit under a new key. Exits and activations are
bounded by `MAX_PER_EPOCH_ACTIVATION_EXIT_CHURN_LIMIT`, which is 256 ETH per
epoch. At roughly 34 million ETH staked, draining the validator set takes about
133,000 epochs — around 1.6 years — and re-entry takes as long again. A migration
measured in years is not a migration that can be run against a deadline.

The second is to record the new key in place, leaving the validator active and
its BLS key untouched. That is what this EIP does. It is a state addition, not a
state transition: no validator changes status, no churn is consumed, and no duty
is interrupted.

The reason to do it now rather than as part of the upgrade that uses the keys is
that the registration is only as strong as the signature authorising it. An
adversary able to forge BLS signatures can register a key it controls and capture
the validator. Registration is therefore safe only while BLS is unbroken, and
every epoch of delay narrows that window. Deploying the registry early, and
separately from anything that consumes it, maximises the number of validators
whose keys are already recorded when it matters.

This upgrade is built on [EIP-8321](./eip-8321.md), whose hash-chain RANDAO
commitments follow the same register-once pattern.

This registry has one consumer: the later fork that switches the chain to
post-quantum signatures. That fork enables post-quantum verification, stops
accepting BLS signatures, ejects validators holding no key, and moves the keys
recorded here into `Validator.pubkey`, after which this list is retired.

The migration therefore has two stages and no overlap. During this one, every
validator signs with BLS and the keys recorded here are inert. At the next, every
validator switches at once. The chain never accepts both schemes, which matters
because a validator set that accepts two is only as strong as the weaker one.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be
interpreted as described in RFC 2119 and RFC 8174.

### Constants

#### Domains

| Name                            | Value                      |
| ------------------------------- | -------------------------- |
| `DOMAIN_PQ_PUBKEY_REGISTRATION` | `DomainType('0x14000000')` |

#### Registry

| Name              | Value       |
| ----------------- | ----------- |
| `UNSET_PQ_PUBKEY` | `Bytes32()` |

### Presets

| Name                        | Value                  |
| --------------------------- | ---------------------- |
| `MAX_PQ_PUBKEY_REGISTRATIONS` | `Uint64(2**7)` (= 128) |

### Types

#### New `PQPubkeys`

```python
class PQPubkeys(ProgressiveList[Bytes32]):
    """
    The post-quantum public key of every validator. An `UNSET_PQ_PUBKEY` entry
    means that the validator has not registered one.
    """
```

#### New `PQPubkeyRegistrations`

```python
class PQPubkeyRegistrations(ProgressiveList[SignedPQPubkeyRegistration]):
    """
    The post-quantum public key registrations included in a beacon block.
    """
```

### Containers

#### New containers

##### `PQPubkeyRegistration`

```python
class PQPubkeyRegistration(Container):
    validator_index: ValidatorIndex
    pq_pubkey: Bytes32
```

##### `SignedPQPubkeyRegistration`

```python
class SignedPQPubkeyRegistration(Container):
    message: PQPubkeyRegistration
    signature: BLSSignature
```

#### Modified containers

##### `BeaconState`

```python
class BeaconState(ProgressiveContainer(active_fields=[1] * 49)):
    # ... fields unchanged through EIP-8321 ...
    randao_commitments: RandaoCommitments
    pending_randao_commitments: PendingRandaoCommitments
    # [New in this EIP]
    pq_pubkeys: PQPubkeys
```

##### `BeaconBlockBody`

```python
class BeaconBlockBody(ProgressiveContainer(active_fields=[1] * 16)):
    # ... fields unchanged through EIP-8321 ...
    hash_chain_reveal: Bytes32
    randao_commitment_registrations: RandaoCommitmentRegistrations
    # [New in this EIP]
    pq_pubkey_registrations: PQPubkeyRegistrations
```

### The registered key is opaque

`pq_pubkey` is 32 bytes and this EIP assigns them no structure. It is the
serialized public key of whatever post-quantum signature scheme the verification
upgrade adopts, and only that upgrade interprets it.

The consequence is that this EIP cannot reject a malformed key. A validator that
registers one has recorded a key that will never verify, and, because
registration is single-use, cannot record another. See Security Considerations.

### Helpers

#### Modified `add_validator_to_registry`

*Note*: `add_validator_to_registry` is modified to initialize the new validator's
entry in `pq_pubkeys`, preserving the invariant that the list has exactly one
entry per validator.

```python
def add_validator_to_registry(
    state: BeaconState, pubkey: Bytes48, withdrawal_credentials: Bytes32, amount: Uint64
) -> None:
    index = get_index_for_new_validator(state)
    validator = get_validator_from_deposit(pubkey, withdrawal_credentials, amount)
    set_or_append_list(state.validators, index, validator)
    set_or_append_list(state.balances, index, amount)
    set_or_append_list(state.previous_epoch_participation, index, ParticipationFlags(0b0000_0000))
    set_or_append_list(state.current_epoch_participation, index, ParticipationFlags(0b0000_0000))
    set_or_append_list(state.inactivity_scores, index, Uint64(0))
    set_or_append_list(state.randao_commitments, index, UNSET_RANDAO_COMMITMENT)
    # [New in this EIP]
    set_or_append_list(state.pq_pubkeys, index, UNSET_PQ_PUBKEY)
```

### Beacon chain state transition

#### Block processing

##### Modified `process_operations`

*Note*: `process_operations` is modified to process the new operation.

```python
def process_operations(state: BeaconState, body: BeaconBlockBody) -> None:
    # ... existing operation processing unchanged ...
    # [New in this EIP]
    for_ops(body.pq_pubkey_registrations, process_pq_pubkey_registration)
```

##### New `process_pq_pubkey_registration`

*Note*: Registration is single-use in both directions. An index may register
once, and a key may back at most one validator. `pq_pubkeys` is never cleared, so
a validator index keeps its registered key for as long as the index exists.

*Note*: The domain is fork-agnostic, so a registration signed once remains valid
across forks. A validator may therefore sign its registration long before a block
that includes it.

```python
def process_pq_pubkey_registration(
    state: BeaconState, signed_registration: SignedPQPubkeyRegistration
) -> None:
    registration = signed_registration.message
    index = registration.validator_index

    assert index < len(state.validators)
    assert registration.pq_pubkey != UNSET_PQ_PUBKEY
    # Registration is single-use
    assert state.pq_pubkeys[index] == UNSET_PQ_PUBKEY
    # A key may back at most one validator
    assert registration.pq_pubkey not in state.pq_pubkeys

    validator = state.validators[index]
    # A validator that is leaving has no use for a post-quantum key
    assert validator.exit_epoch == FAR_FUTURE_EPOCH

    # Fork-agnostic domain since registrations are valid across forks
    domain = compute_domain(
        DOMAIN_PQ_PUBKEY_REGISTRATION,
        genesis_validators_root=state.genesis_validators_root,
    )
    signing_root = compute_signing_root(registration, domain)
    assert bls.Verify(validator.pubkey, signing_root, signed_registration.signature)

    state.pq_pubkeys[index] = registration.pq_pubkey
```

## Rationale

### Why registration is separated from use

The upgrade that defines post-quantum verification is large. It must fix the
signature scheme and its parameters, the message encoding, the epoch-to-slot
mapping, the aggregation scheme, and the verification rules for attestations,
blocks, and sync committees. None of that is settled.

The registry is settled, and it is the part with a deadline. Binding it to the
verification upgrade would mean the registration window opens only when that
upgrade ships — which is exactly backwards, because the window is bounded on the
far end by the arrival of a quantum adversary, not by our readiness.

Separating them also means registration can proceed at whatever rate validators
manage, over months or years, rather than being a step every operator must
complete inside one fork's activation. That is the only part of the migration
that can absorb delay: the cutover itself is atomic, and everything not done
before it is lost at it.

### Why the registration is authenticated by BLS

The validator's BLS key is the credential its operator already holds and already
uses. Withdrawal credentials are the only alternative, and they are ECDSA, which
is no more quantum-resistant and is held by a different party in most staking
arrangements — the intent here is that the operator running the validator
registers the key it will sign with.

The honest limitation is that either choice is quantum-vulnerable, so this
mechanism cannot be used to recover from a break; it can only be used before one.
That is why the Motivation argues for deploying it early rather than for
deploying it well.

### Why registration is single-use

If a registered key could be replaced, an adversary able to forge one BLS
signature could overwrite an honest registration at any later time, and the
honest party could not durably reclaim the index — each side would simply
re-register. Making registration single-use means the first registration wins
permanently, so an operator who registers early is safe even if BLS is broken
later.

The cost is that a validator that registers a key it cannot use has no way to
correct it. That is the same trade [EIP-8321](./eip-8321.md) makes for hash-chain
commitments, and the same remedy applies: onboard a new validator under a new
key.

### Why a key may back at most one validator

Registered keys are public, so without a uniqueness check anyone could register
another validator's key against an index of their own. Two validators would then
share one key, which is unsafe under any stateful signature scheme: each epoch's
one-time key may sign at most once, and two validators asked to sign different
messages at the same epoch would reuse it.

The check also protects the sweep performed at the cutover. Once BLS is retired
no validator needs its BLS key, so each recorded key moves into
`Validator.pubkey` and this list is retired — but that is only sound if the keys
are unique, because `Validator.pubkey` is the registry index. Duplicates would
produce two validators with the same identity, and a lookup returning the first
match would silently direct one validator's deposits to the other.

Enforcing it costs one scan of `pq_pubkeys` per registration, comparable to the
existing scan of `validator_pubkeys` in `apply_pending_deposit`.

### Why there is no activation delay

EIP-8321 places its commitment registrations in a queue with
`COMMITMENT_REGISTRATION_DELAY`, so that a registrant cannot know whether it
proposes in the epoch its commitment activates. That protection exists because a
hash-chain commitment feeds the RANDAO accumulator, and a proposer who could
choose between two commitments with knowledge of its own proposal slot could
grind.

A public key feeds no randomness and confers no advantage in the epoch it is
recorded. The queue would add a container, an epoch-processing hook, and a
pending-duplicate check for no security benefit, so registration is applied
directly.

### Why a parallel list rather than a field on `Validator`

`Validator` is a plain `Container`, so adding a field to it changes its hash-tree
layout and invalidates every existing validator Merkle proof, including
light-client proofs and execution-layer contracts that verify validator
inclusion. `BeaconState` is a `ProgressiveContainer`, where appended fields are
cheap and non-breaking, and it already holds five lists keyed by validator index:
`balances`, both participation lists, `inactivity_scores`, and EIP-8321's
`randao_commitments`.

The cost is that the one-entry-per-validator invariant is maintained by hand
wherever validators are added or indices are reused. That obligation already
exists for `randao_commitments`; this EIP adds a list subject to the same rule
rather than a new kind of rule.

### Why exited validators cannot register

A validator that has initiated exit will not be signing under the new scheme, so
recording a key for it consumes an entry and a block's registration budget for no
purpose. Rejecting the registration is free, since a failed operation invalidates
the block rather than costing the registrant anything, and the check is
unambiguous.

## Backwards Compatibility

This EIP requires a consensus-layer fork.

The `Validator` container is unchanged, so validator Merkle proofs, light-client
proofs, and execution-layer contracts that verify validator inclusion continue to
work.

`BeaconState` and `BeaconBlockBody` each gain one field. Both are
`ProgressiveContainer`s, so the appends do not disturb the generalized indices of
existing fields.

No validator's status, duties, rewards, penalties, or signing behaviour change.
A validator that never registers is indistinguishable from one that could not,
and continues to operate exactly as before. Clients that do not implement
registration still follow the chain; they simply cannot construct the operation
for their validators.

## Security Considerations

### The registration window closes with BLS

An adversary able to forge BLS signatures can register a post-quantum key of its
choosing for any validator that has not already registered, and because
registration is single-use, the honest operator can never displace it. Once the
verification upgrade begins accepting post-quantum signatures, that adversary
controls the validator.

This is not a flaw that can be engineered away at this layer: any registration
authorised by a pre-quantum signature inherits that signature's security.
The mitigation is temporal. Validators SHOULD register as soon as this upgrade is
live, and clients SHOULD make registration part of routine validator setup rather
than an action deferred until a later upgrade makes it useful.

### A malformed key is unrecoverable

`pq_pubkey` is opaque to this EIP, so a validator can register bytes that no
verifier will ever accept — a truncated key, a key for the wrong scheme, or the
output of a buggy key generator. Because registration is single-use, the entry
cannot be corrected, and the validator will be unable to sign once BLS is
retired. Recovery means exiting and onboarding a new validator.

Validator tooling SHOULD derive the registered key from the same key material it
will later sign with, and SHOULD verify a self-signature locally before
submitting the registration.

### Denial of service via registration volume

Each registration costs one BLS verification. A block may carry
`MAX_PQ_PUBKEY_REGISTRATIONS` of them, and EIP-8321 permits the same number of
commitment registrations, so a block may carry 256 signature verifications
between the two. This is bounded and comparable to other per-block operation
budgets, but implementations SHOULD verify registrations in parallel with other
operation processing where possible.

Registrations are not economically rate-limited beyond the per-block cap. Because
each is single-use per validator index and requires a valid BLS signature from
that validator, the total number that can ever be included is bounded by the
validator set size.

### State growth

`pq_pubkeys` adds 32 bytes per validator, including validators that never
register, whose entries are zero. At one million validators this is 32 MB of
additional state, the same cost EIP-8321's `randao_commitments` already carries.

Merkleization is unaffected in practice, since zero subtrees have cached roots,
but clients that materialize the list in full will pay the storage.
Implementations SHOULD store it sparsely and treat a missing entry as
`UNSET_PQ_PUBKEY`.

### Validators that never register go inactive

This EIP provides a way to register and no way to compel registration. At the
cutover, a validator holding no key cannot sign anything the chain will accept,
so it performs no duties from that fork onward.

**The fraction of the validator set that has registered when the cutover arrives
is the fraction that keeps operating through it.** Registering here is not
optional preparation; it is the whole of it, and it can only be done while BLS is
still trusted.

Such a validator is expected to remain recoverable. The cutover is expected to
provide a conversion operation, authorized by the validator's existing BLS key,
that records a key after the fact and lets the validator rejoin through the
activation queue. That is a transitional mechanism authorized by a signature the
chain has otherwise stopped trusting, and it is expected to be deprecated by a
later upgrade; it is not specified here.

Note what that does and does not concede. The consensus path stays entirely
post-quantum from the cutover — no block, attestation, or RANDAO reveal is ever
verified against a BLS key again. Only a one-time key registration is, for a
validator that is inactive until it succeeds. An adversary who forges one
captures an idle validator and must still bring it through the activation queue,
which is churn-limited.

None of that makes late registration cheap. A validator that converts after the
cutover has missed however long the fork takes to notice and reactivate it, and
depends on a mechanism scheduled for removal. This upgrade should ship early and
registration should be pushed hard while it runs.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
