---
title: Retire BLS validator keys
description: Close the BLS-authorized key registration path and force-exit validators that hold no post-quantum key
author: Kevaundray Wedderburn (@kevaundray)
discussions-to: 
status: Draft
type: Standards Track
category: Core
created: 2026-08-20
requires: 8321
---

## Abstract

This EIP ends the transitional period in which a validator could still act on the
strength of a BLS key.

It does two things. It removes the operation that lets a validator record a
post-quantum key by authorizing the registration with its BLS signature, and it
exits every validator that still holds no post-quantum key.

After this fork the chain verifies no BLS signature for any purpose. Every
validator in the active set holds a post-quantum key, and no mechanism remains by
which a forged BLS signature could place one there.

## Motivation

The migration to post-quantum signatures happens in stages. An earlier upgrade
adds a registry and an operation that records a post-quantum key for a validator,
authorized by that validator's BLS signature. A later upgrade — the cutover —
enables post-quantum verification, stops accepting BLS signatures on blocks,
attestations and RANDAO reveals, and leaves validators that hold no key inactive
rather than ejected, so that an operator who missed the window can still record a
key and rejoin.

That last allowance is the loose end this EIP ties off. The registration
operation is authorized by a BLS signature, which is the thing the cutover
otherwise stopped trusting. For as long as it remains available, an adversary
able to forge BLS signatures can record keys it controls for every validator that
has not registered, and bring them back into the active set. The exposure is
bounded — such validators are inactive, and re-entry is limited by the activation
churn — but it is real, and it does not diminish on its own.

It is also, by then, a path with no legitimate users left. Its purpose was to
give operators who were late a way back. Once that has run its course, what
remains is a standing capture vector kept open for validators that have not acted
on it.

The precedent here is worth naming. `BLS_WITHDRAWAL_PREFIX` credentials have been
convertible to execution credentials by BLS signature since Capella, and that
path is still open years later, because closing it requires deliberate action
while leaving it open requires none. This EIP exists so that the same thing does
not happen to post-quantum key registration.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be
interpreted as described in RFC 2119 and RFC 8174.

### Constants

| Name               | Value            |
| ------------------ | ---------------- |
| `PQ_PUBKEY_PREFIX` | `Bytes1('0x01')` |

*Note*: `PQ_PUBKEY_PREFIX` is not introduced here. It is the first byte of every
post-quantum `Validator.pubkey`, fixed across all encoding versions by the
upgrade that first registers such keys, and it is restated for reference because
this EIP dispatches on it.

### Containers

#### Modified `BeaconBlockBody`

*Note*: `pq_pubkey_registrations` is retired. The field is deactivated rather than
removed, so the generalized indices of the surrounding fields are unchanged.

```python
class BeaconBlockBody(ProgressiveContainer(active_fields=[1] * 15 + [0])):
    # ... fields unchanged ...
    # [Removed in this EIP] pq_pubkey_registrations
```

A block MUST NOT contain post-quantum public key registrations. Blocks that do
are invalid.

### Beacon chain state transition

#### Modified `process_operations`

*Note*: `process_operations` is modified to drop the registration operation.

```python
def process_operations(state: BeaconState, body: BeaconBlockBody) -> None:
    # ... existing operation processing unchanged ...
    # [Removed in this EIP]
    # for_ops(body.pq_pubkey_registrations, process_pq_pubkey_registration)
```

`process_pq_pubkey_registration` is removed. No path remains by which a BLS
signature can alter consensus state.

### Fork transition

#### New `has_pq_pubkey`

*Note*: The test is on `Validator.pubkey`, not on a separate list. The cutover
moves every recorded post-quantum key into `Validator.pubkey` and retires
`pq_pubkeys`, so by this fork the identity field is the only place a key lives,
for validators registered by deposit and for validators that recorded one
beforehand alike.

A validator that holds no post-quantum key still carries a BLS public key here.
Every post-quantum encoding begins with `PQ_PUBKEY_PREFIX`, whatever version
follows it, and no valid compressed BLS12-381 point can begin with that byte
because its leading bit is clear. The test therefore needs no knowledge of which
version a validator was registered under.

```python
def has_pq_pubkey(validator: Validator) -> bool:
    return validator.pubkey[0:1] == PQ_PUBKEY_PREFIX
```

#### New `retire_bls_validators`

*Note*: This runs once, during the upgrade to this fork.

*Note*: The exit is applied directly rather than through
`initiate_validator_exit`, so it consumes no activation-exit churn. These
validators have been unable to sign since the cutover and are therefore not
contributing to the active set; the churn limit exists to keep the active set
from draining faster than it can be replaced, and removing validators that were
already contributing nothing does not drain it. Routing them through the queue
would instead delay genuine exits by however much stake was never migrated.

```python
def retire_bls_validators(state: BeaconState) -> None:
    epoch = get_current_epoch(state)
    exit_epoch = Epoch(epoch + 1)
    withdrawable_epoch = Epoch(exit_epoch + MIN_VALIDATOR_WITHDRAWABILITY_DELAY)

    for validator in state.validators:
        if has_pq_pubkey(validator):
            continue
        if validator.exit_epoch != FAR_FUTURE_EPOCH:
            continue
        validator.exit_epoch = exit_epoch
        validator.withdrawable_epoch = withdrawable_epoch
```

#### Modified `is_eligible_for_activation_queue`

*Note*: A validator that holds no post-quantum key can no longer obtain one, so
it must never be activated. This closes the case of a validator that was exited
above but whose balance is not yet swept, and the case of a validator created by
any future path that does not set a key.

```python
def is_eligible_for_activation_queue(validator: Validator) -> bool:
    """
    Check if ``validator`` is eligible to be placed into the activation queue.
    """
    return (
        validator.activation_eligibility_epoch == FAR_FUTURE_EPOCH
        and validator.effective_balance >= MIN_ACTIVATION_BALANCE
        and validator.exit_epoch == FAR_FUTURE_EPOCH
        # [New in this EIP]
        and has_pq_pubkey(validator)
    )
```

## Rationale

### Why the registration operation is removed rather than restricted

The operation could have been kept and narrowed — to validators below some
balance, or to a bounded number per epoch, or behind a deadline parameter. Each
of those leaves a BLS-authorized write to consensus state in the specification,
and the security argument does not improve much: the value to an adversary is not
the rate at which validators can be captured but that they can be captured at
all.

Removing it entirely also produces a property that is easy to state and easy to
check: after this fork, no BLS signature is verified anywhere in the state
transition. A narrowed operation would leave the answer to "does the chain still
depend on BLS" as "yes, partially, under these conditions".

### Why exits bypass the churn limit

The activation-exit churn limit protects the active validator set from draining
faster than it can be replaced. The validators exited here have been unable to
sign since the cutover, so they are not part of what the limit protects. Passing
them through the queue would consume `MAX_PER_EPOCH_ACTIVATION_EXIT_CHURN_LIMIT`
for as long as it took to drain them — at 256 ETH per epoch, one million ETH of
unmigrated stake would occupy the exit queue for roughly 3,900 epochs — and every
genuine exit during that period would be delayed behind stake that had already
stopped participating.

Their departure also cannot destabilize the chain in the direction the limit
guards against. Removing non-participating validators raises the participation
ratio rather than lowering it, so finality is easier after the exit than before.

### Why activation eligibility is also gated

Exiting a validator sets `exit_epoch`, but its balance remains until
`withdrawable_epoch`, and during that window `effective_balance` is still above
`MIN_ACTIVATION_BALANCE`. Without the additional condition, a validator exited by
this fork would satisfy the activation predicate and could be queued for
activation despite having already exited.

The condition is written against the key rather than against the exit, so it also
covers any future path that creates a validator without one.

### What this EIP assumes and does not do

It assumes the cutover has already moved recorded post-quantum keys into
`Validator.pubkey` and retired `pq_pubkeys`. That fold has to happen there rather
than here, because between the cutover and this fork the two registration paths
would otherwise write to different places: a validator that recorded a key
beforehand would have it in the list, and one registered by deposit afterwards
would have it in the identity field. Every consumer, including this EIP's own
predicate, would need to know which kind of validator it was looking at.

The fold is not free, and its cost lands on the cutover, not here.
`Validator.pubkey` is what deposits are matched against, so rewriting it means a
deposit naming a validator by its pre-fold pubkey no longer finds it, fails to
register a new validator, and the funds are lost. Resolving that needs either a
retained mapping from old pubkey to validator index or a coordinated change
across deposit tooling. This EIP takes no position on which; it only requires
that the fold has happened, so that a single field answers whether a validator
holds a key.

This EIP therefore touches no key material. It reads `Validator.pubkey` to
classify validators and writes only exit epochs.

## Backwards Compatibility

This EIP requires a consensus-layer fork.

`BeaconBlockBody` loses a field. As a `ProgressiveContainer` deactivation this
does not disturb the generalized indices of the remaining fields. Blocks
containing post-quantum key registrations are invalid from this fork; block
producers MUST stop including them.

No container changes shape, and no key material moves. `Validator` and
`BeaconState` are unchanged; this EIP reads `Validator.pubkey` and writes only
exit epochs.

Validators exited by this fork follow the ordinary exit path from that point:
they become withdrawable after `MIN_VALIDATOR_WITHDRAWABILITY_DELAY` and their
balances are swept to their withdrawal credentials by `process_withdrawals`. No
special handling is required by clients or by withdrawal tooling.

Operators of validators that never recorded a post-quantum key lose nothing but
the validator: the stake is returned in full to the withdrawal address, less
whatever was leaked by inactivity between the cutover and this fork. Re-entering
requires a fresh deposit under a post-quantum key.

## Security Considerations

### This is the point at which BLS stops mattering

Before this fork, an adversary able to forge BLS signatures could record
post-quantum keys of its choosing for every validator that had not registered,
and bring those validators back through the activation queue. After it, no BLS
signature is verified anywhere in the state transition, so that capability has no
target.

The window closes on a schedule rather than on the arrival of the adversary,
which is the only ordering that helps. An EIP written in response to a break
would be too late for exactly the validators it was meant to protect.

### The exit is irreversible and unauthenticated

A validator exited here did not consent to the exit and cannot cancel it. This is
deliberate: requiring consent would mean accepting a signature from a validator
whose only key is one the chain no longer trusts.

The consequence is that an operator who was slow, rather than absent, loses the
validator. The stake is not lost — it is swept to the withdrawal credentials —
but the position in the validator set is, and re-entry means a fresh deposit and
the activation queue. This is the residual cost of the migration, and it falls
entirely on validators that had the whole registry period and the whole
post-cutover period to act.

### Mass exit at a single fork

The number of validators exited here is not bounded by the specification. In the
worst case a large fraction of the registry exits in one epoch.

Because the exit bypasses churn, this is a large discontinuity in
`get_total_active_balance` — but in the direction that helps, since every
validator removed had a zero participation rate. Attestation participation ratios
rise, and finality becomes easier rather than harder. The risk that the churn
limit exists to manage does not apply.

Clients SHOULD expect the fork-transition function to iterate the full validator
registry and SHOULD not assume the number of exits at this fork is small.

### Stragglers cannot be distinguished from captured validators

If BLS were broken before this fork and an adversary had already recorded keys
for dormant validators, this EIP does not detect or undo that. It only prevents
further captures. Validators whose keys were recorded by an adversary hold valid
post-quantum keys as far as the chain is concerned and are unaffected by the
exit.

This is a reason to schedule this fork by reference to the expected arrival of
the threat rather than to the convenience of the remaining stragglers, and to
treat any evidence of BLS weakness as grounds to accelerate it.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
