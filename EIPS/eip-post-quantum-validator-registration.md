---
title: Post-quantum validator registration
description: Register hash-based validator keys through the existing deposit contract by reusing its unvalidated pubkey and signature fields
author: Kevaundray Wedderburn (@kevaundray)
discussions-to: 
status: Draft
type: Standards Track
category: Core
created: 2026-08-20
requires: 6110, 8015, 8321
---

## Abstract

This EIP defines an encoding that lets the deposit contract register
post-quantum validator keys without redeploying it.

The deposit contract never checks that `pubkey` is a BLS point or that
`signature` is a BLS signature; it validates only the field lengths and the
deposit value. We can therefore safely reinterpret those 144 bytes, provided the
encoding is distinct from the BLS one.

A `pubkey` whose leading bit is clear is not a valid compressed BLS12-381 point,
so setting that bit to zero separates the two encodings with no ambiguity. This
EIP puts a version byte and the leanSig (generalized XMSS) public key in the
`pubkey` field, and the hash-chain RANDAO commitment that
[EIP-8321](./eip-8321.md) defers to this fork in the `signature` field. The
`pubkey` field is stored verbatim as `Validator.pubkey`, so the key is the
validator's registry identity and nothing is derived.

Validators registered this way activate and operate normally. Because such a
validator has no BLS key, this encoding must activate in the same fork that
enables post-quantum verification and retires BLS, so that the two schemes are
never in use at the same time.

We further note that existing validators will use a mechanism like [EIP-8321](./eip-8321.md)
whereas in the future, new validators would use the mechanism outlined in this EIP.

## Motivation

Migrating Ethereum's consensus layer to post-quantum signatures requires a way
to get _new_ post-quantum public keys into the validator registry.

The most straightforward path is a new deposit contract, however this is disruptive because:
every staking provider, custodian, exchange, distributed-validator cluster, and
launchpad has the current contract address hardcoded, audited, and in some cases
committed to in on-chain contracts that cannot be changed.

The current deposit contract validates only the field lengths and the deposit
value, and performs no cryptographic validation of the field contents. It
computes `deposit_data_root` over whatever bytes it is given and emits them. All
cryptographic meaning is assigned by the consensus layer in
`apply_pending_deposit`. If we want to change the meaning of those bytes
we only require a consensus-layer change alone.

A second motivation is closing a gap [EIP-8321](./eip-8321.md) left open. That
EIP registers each validator's hash-chain RANDAO commitment through a beacon
operation, and notes that setting it at deposit time is "deferred to a fork that
already needs to change the deposit flow, such as the one that retires the
transitional BLS-signature path for a post-quantum scheme."

This is that fork. Existing BLS validators are unaffected and continue to
register through EIP-8321's operation as normal. A leanSig validator, however,
has no BLS key, so neither EIP-8321 path is open to it. The legacy reveal is a
BLS signature it cannot produce, and the registration operation verifies with
`bls.Verify(validator.pubkey, ...)` against a `Validator.pubkey` that holds a
leanSig key rather than a BLS point, so no signature can satisfy it.

Registering the commitment at deposit time is therefore necessary rather than
merely convenient. It is also the safer construction: giving a post-quantum
validator a BLS-authenticated way to set its RANDAO commitment would reintroduce
precisely the quantum-vulnerable dependency the validator exists to remove.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be
interpreted as described in RFC 2119 and RFC 8174.

### Constants

| Name                     | Value            |
| ------------------------ | ---------------- |
| `PQ_PUBKEY_PREFIX`       | `Bytes1('0x01')`    |
| `LEANSIG_PUBKEY_VERSION` | `Bytes1('0x01')`    |
| `LEANSIG_PUBKEY_LEN`     | `32`                |
| `LEANSIG_KEY_ID_DST`     | `b'LEANSIG_KEY_ID'` |

`blake3` is as defined by [EIP-8321](./eip-8321.md).

### Deposit encoding

<!-- TODO: should we say non-BLS? -->
A deposit is a *post-quantum deposit* if and only if
`pubkey[0] == PQ_PUBKEY_PREFIX`.

It is a *leanSig deposit* if in addition
`pubkey[1] == LEANSIG_PUBKEY_VERSION`.

The 48-byte `pubkey` field carries the validator's identity:

| Range      | Contents                 |
| ---------- | ------------------------ |
| `[0]`      | `PQ_PUBKEY_PREFIX`       |
| `[1]`      | `LEANSIG_PUBKEY_VERSION` |
| `[2:34]`   | `key_id`                 |
| `[34:48]`  | MUST be zero             |

The 96-byte `signature` field carries the key and the RANDAO commitment:

| Range      | Contents                                    |
| ---------- | ------------------------------------------- |
| `[0:32]`   | `randao_commitment`, as defined by EIP-8321 |
| `[32:64]`  | `leansig_pubkey`                            |
| `[64:96]`  | MUST be zero                                |

where

```
key_id = blake3(LEANSIG_KEY_ID_DST + leansig_pubkey + withdrawal_credentials[12:])
```

`withdrawal_credentials[12:]` is the execution address. A post-quantum deposit
MUST use execution withdrawal credentials, `0x01` or `0x02`, since a `0x00`
credential is BLS-derived and has no address to bind.

The identity binds the address as well as the key, so a deposit under different
withdrawal credentials is a different validator rather than a collision. This is
what prevents a third party who has merely seen the key from registering it under
their own address. See
[Unowned keys and deposit front-running](#unowned-keys-and-deposit-front-running).

The `pubkey` field is stored as is in `Validator.pubkey`, so
`process_deposit_request` is unmodified. The key itself is written to
`state.pq_pubkeys`.

`randao_commitment` MUST NOT be `UNSET_RANDAO_COMMITMENT`. That value is
EIP-8321's sentinel for "use the legacy BLS reveal", which is not a reachable
state for a validator with no BLS key.

`pubkey[0]` is `PQ_PUBKEY_PREFIX` for every post-quantum encoding.
It does not vary and it is being used to distinguish between BLS pubkeys.

`pubkey[1]` is the version, which determines the interpretation of everything after
it. A future version MAY reinterpret the whole of `pubkey[2:48]` and `signature`,
including but not limited to the layout.

### Cutover

The *cutover* is the fork at which the chain stops accepting BLS signatures and
starts accepting post-quantum ones.

This EIP MUST NOT be activated except in a fork that simultaneously enables verification of leanSig signatures.
since a validator it registers has no BLS key and cannot operate until leanSig signatures verify.

For completeness, the migration to PQ will be complete if the following are also met:

- fork stops accepting BLS signatures on blocks, attestations, and RANDAO reveals
  from any validator
- stop duties for any validator that holds no post-quantum key

Once these are done, then BLS onboarding would be retired. See
[Why the cutover is a single fork](#why-the-cutover-is-a-single-fork).

### External state

This EIP writes to `state.pq_pubkeys`, a list with one entry per validator
holding that validator's post-quantum public key, or `UNSET_PQ_PUBKEY` if it has
none. This EIP does not define it. That list, the `UNSET_PQ_PUBKEY` value, and
the version of `add_validator_to_registry` that initializes a new entry come from
the earlier upgrade in which existing validators record a post-quantum key, which
must activate first.

`Validator.pubkey` is a commitment to the key, not the key itself, so
`pq_pubkeys` is the only place a validator's post-quantum key is stored. Both
registration paths write it, so a verifier reads one location for every
validator.

### Helpers

#### New `is_valid_leansig_deposit`

Both the prefix and the version are checked here:

- The prefix establishes that the value is not a BLS pubkey
- The version check establishes a deposit's encoding has been registered in a fork

On normalization: The padding must be zero because `Validator.pubkey` is the
registry index, so any variation there produces a different identity for the same
key and registers it as a second validator see [Reserved space](#reserved-space).

```python
def is_valid_leansig_deposit(
    pubkey: Bytes48, withdrawal_credentials: Bytes32, signature: Bytes96
) -> bool:
    # Not a BLS pubkey, and an assigned version
    if pubkey[0:1] != PQ_PUBKEY_PREFIX:
        return False
    if pubkey[1:2] != LEANSIG_PUBKEY_VERSION:
        return False
    # The address the identity binds must exist
    if not has_execution_withdrawal_credential_bytes(withdrawal_credentials):
        return False
    # The identity must commit to the key and the withdrawal address
    key_id = blake3(
        LEANSIG_KEY_ID_DST
        + signature[32 : 32 + LEANSIG_PUBKEY_LEN]
        + withdrawal_credentials[12:]
    )
    if pubkey[2:34] != key_id:
        return False
    # Padding must be zero
    if pubkey[34:48] != bytes(14):
        return False
    # A leanSig validator has no BLS key, so it must register a RANDAO commitment
    if signature[0:32] == UNSET_RANDAO_COMMITMENT:
        return False
    if signature[32 + LEANSIG_PUBKEY_LEN : 96] != bytes(64 - LEANSIG_PUBKEY_LEN):
        return False
    return True
```

#### New `has_execution_withdrawal_credential_bytes`

*Note*: The existing `has_execution_withdrawal_credential` takes a `Validator`.
The deposit is checked before any validator exists, so the same test is expressed
over the raw credentials.

```python
def has_execution_withdrawal_credential_bytes(withdrawal_credentials: Bytes32) -> bool:
    return withdrawal_credentials[:1] in (
        ETH1_ADDRESS_WITHDRAWAL_PREFIX,
        COMPOUNDING_WITHDRAWAL_PREFIX,
    )
```

### Beacon chain state transition

#### Modified `add_validator_to_registry`

`add_validator_to_registry` is modified to take the RANDAO commitment and the
leanSig public key as parameters, so that both are set at registration. The key
is not recoverable from `pubkey`, which is a commitment to it.

```python
def add_validator_to_registry(
    state: BeaconState,
    pubkey: Bytes48,
    withdrawal_credentials: Bytes32,
    amount: Uint64,
    randao_commitment: Bytes32,  # [New in this EIP]
    pq_pubkey: Bytes32,  # [New in this EIP]
) -> None:
    index = get_index_for_new_validator(state)
    validator = get_validator_from_deposit(pubkey, withdrawal_credentials, amount)
    set_or_append_list(state.validators, index, validator)
    set_or_append_list(state.balances, index, amount)
    set_or_append_list(state.previous_epoch_participation, index, ParticipationFlags(0b0000_0000))
    set_or_append_list(state.current_epoch_participation, index, ParticipationFlags(0b0000_0000))
    set_or_append_list(state.inactivity_scores, index, Uint64(0))
    # [Modified in this EIP]
    set_or_append_list(state.randao_commitments, index, randao_commitment)
    # [Modified in this EIP]
    set_or_append_list(state.pq_pubkeys, index, pq_pubkey)
```

#### Modified `apply_pending_deposit`

`apply_pending_deposit` is modified so that the only path to a new
validator is a leanSig deposit. The BLS proof-of-possession branch is removed, as
required by [New BLS deposits](#new-bls-deposits).

```python
def apply_pending_deposit(state: BeaconState, deposit: PendingDeposit) -> None:
    """
    Applies ``deposit`` to the ``state``.
    """
    validator_pubkeys = [v.pubkey for v in state.validators]
    if deposit.pubkey not in validator_pubkeys:
        # [Modified in this EIP]
        if is_valid_leansig_deposit(
            deposit.pubkey, deposit.withdrawal_credentials, deposit.signature
        ):
            add_validator_to_registry(
                state,
                deposit.pubkey,
                deposit.withdrawal_credentials,
                deposit.amount,
                Bytes32(deposit.signature[0:32]),
                Bytes32(deposit.signature[32 : 32 + LEANSIG_PUBKEY_LEN]),
            )
    else:
        validator_index = ValidatorIndex(validator_pubkeys.index(deposit.pubkey))
        increase_balance(state, validator_index, deposit.amount)
```

Top-ups take the `else` branch and never read the `signature` field, so a
validator's leanSig public key and RANDAO commitment are set once, at
registration, and are not changed by later deposits.

<!-- TODO: Emile noted that we could make parameter changes easier, but this needs a new deposit contract-->
This preserves EIP-8321's one-chain-to-one-key binding.

#### Modified `is_eligible_for_activation_queue`

*Note*: The identity binds the withdrawal address, so one key can back more than
one validator — a depositor who registers the same key under two addresses gets
two entries. leanSig is stateful, and two *active* validators sharing a key would
reuse a one-time key, so activation is gated on the key not already being in use.

*Note*: Registration is not gated, only activation. Rejecting the second
registration would let a third party consume a key by registering it first, which
is the behaviour this EIP exists to prevent.

*Note*: The condition is re-evaluated each epoch by `process_registry_updates`,
so a blocked validator becomes eligible once the validator holding its key is no
longer active. Registering under a new address and exiting the old validator is
therefore a supported way to change a withdrawal address.

```python
def is_eligible_for_activation_queue(state: BeaconState, index: ValidatorIndex) -> bool:
    """
    Check if the validator at ``index`` is eligible to be placed into the activation queue.
    """
    validator = state.validators[index]
    return (
        validator.activation_eligibility_epoch == FAR_FUTURE_EPOCH
        and validator.effective_balance >= MIN_ACTIVATION_BALANCE
        # [New in this EIP]
        and not is_pq_pubkey_active(state, index)
    )
```

#### New `is_pq_pubkey_active`

*Note*: Implementations SHOULD maintain an index from key to active validator
rather than scanning, since this is evaluated for every candidate every epoch.

```python
def is_pq_pubkey_active(state: BeaconState, index: ValidatorIndex) -> bool:
    pq_pubkey = state.pq_pubkeys[index]
    if pq_pubkey == UNSET_PQ_PUBKEY:
        return False
    epoch = get_current_epoch(state)
    return any(
        other != index and state.pq_pubkeys[other] == pq_pubkey
        and is_active_validator(state.validators[other], epoch)
        for other in range(len(state.validators))
    )
```

### The legacy Eth1 deposit path

[EIP-8015](./eip-8015.md) removes `body.deposits` and the `BeaconState` fields
that supported Eth1 bridge deposits, which leaves `process_deposit`,
`apply_deposit`, and `is_valid_deposit_signature` unreachable.

This simplifies the diff because we need to modify all places that could
call `add_validator_to_registry` to disallow new bls deposits and `apply_deposit`
was one of those codepaths.

After 8015, `apply_pending_deposit` is the only function that adds a
validator to the registry.

### New BLS deposits

A deposit that would register a new BLS validator MUST be
ignored from this fork and onwards.

Top-ups to existing BLS validators continue to be applied, and existing
BLS validators are otherwise unaffected.

<!-- TODO: Does this mean that anyone who starts a deposit just before the fork may have their deposit burned, since we cannot stop deposits, just reject them on the CL, maybe we leave it and just allow them to be withdrawn? -->
<!-- TODO: should talk about the existing queue when this becomes active -->

## Rationale

### Why the first byte separates the encodings

A validator public key is a BLS12-381 G1 point, serialized by the consensus layer
in compressed _ZCash_ format. In that format the most significant bit of byte 0 is
the compression flag and is always set. A 48-byte string with that bit clear is
therefore not a valid compressed point, and we use this property to distinguish
between BLS deposits and leanSig deposits. `PQ_PUBKEY_PREFIX` is `0x01`, so
`pubkey[0] & 0x80 == 0`.

We could use one byte for the version in place of the prefix, however we would
then need every future version assignment to stay below `0x80`. Since we have space in the
`pubkey` field, separating the two fixes `pubkey[0]` for every non-BLS
encoding, which is easier to not mess up.

We also note that `Validator.pubkey` is fixed-width and zero-filled before use, so
an all-zero value must never be a valid encoding. This is why the prefix starts
with `0x01` rather than `0x00`.

### Why proof of possession is dropped

For BLS, the deposit signature is a BLS proof of possession.
It was designed to mitigate an attack that is inherent to BLS since it has
certain algebraic structure.

leanSig does not have this structure and moreover, aggregation is done
via a SNARK, so there is no algebraic combination of the individual
public keys or signatures.

What we do lose from not having a PoP, is a way to demonstrate that
the depositor does indeed control the public key.
This is not a reasonable attack vector however, because an attacker would be
burning their own stake in order to register a validator that can never attest.

We also note for completeness that a leanSig signature is 2-3KiB, so if a
PoP was required, we would need to update the deposit contract or use a
different mechanism to verify it on the consensus layer.

### Why the cutover is a single fork

For reference, the migration has two stages:

- (1) validators register a post-quantum key while continuing to sign with BLS.

This is a separate fork and a pre-requisite for this. It does not change a
validator's behaviour, and it runs for some extended period of time.

(2) Every validator that has registered switches at a fork boundary.

This is where this EIP is activated. We simultaneously stop onboarding BLS
and enforce that the protocol should only use the PQ variant.

Validators that have not registered by the second stage, will not be ejected,
but will also not be able to perform their duties.

Similar to 0x0 validators, they will be able to use their existing BLS key to
upgrade to a PQ validator using the mechanism from stage 1.

Note: in a later upgrade, these validators that have not
upgraded to PQ will be force exited.

<!-- TODO: For force exiting non-PQ validators, we can perhaps give one fork notice -->

<!-- TODO: do they slowly bleed out from inactivity? -->

<!-- TODO: note this is different from NCs thing to retire 0x0 validators -->

### Why the identity binds the withdrawal address

`Validator.pubkey` is the registry index. `apply_pending_deposit` uses it to tell
a new registration from a top-up, and the first deposit to claim an index fixes
its withdrawal credentials permanently — every later deposit naming it is credited
without its credentials being read.

Today that is safe only because the deposit signature proves the first registrant
holds the key. This EIP has no signature to offer, and none fits, so an identity
derived from the key alone would be claimable by anyone who has merely seen the
key. Binding the address instead makes the two things an attacker needs mutually
exclusive: registering under their own address produces a different validator and
leaves the depositor untouched, and registering under the depositor's address
pays the depositor. There is no third choice, because the same field decides both.

The cost is that the key is no longer recoverable from `Validator.pubkey`, so it
must be stored in `pq_pubkeys`. That is not a new list — the upgrade in which
existing validators record a key already introduces it, and this EIP writes the
same one. It also means every post-quantum key lives in exactly one place from
the start, for validators registered by either route, so no later fork has to
unify them.

Binding the *address* rather than the whole credential field is deliberate.
`switch_to_compounding_validator` rewrites `withdrawal_credentials[:1]` while
preserving `[1:]`, so a `0x01` to `0x02` switch leaves the identity intact.

## Backwards Compatibility

This EIP requires a consensus-layer fork, since we are interpreting the deposit
logs differently.

- It requires no change to the deposit contract and no change to its address

- The `Validator` _container_ is unchanged, so validator Merkle proofs, light-client
proofs, and execution-layer contracts that verify validator inclusion still work.

- The `PendingDeposit` container is unchanged. `DepositRequest` and the
[EIP-6110](./eip-6110.md) execution request encoding are unchanged.

- The `BeaconState` container is not changed by this EIP. It writes `pq_pubkeys`,
which the pubkey registry upgrade introduces and which must already exist. The
leanSig public key is stored there; `Validator.pubkey` holds a commitment to it.

- `randao_commitments[index]` is non-zero from registration for new validators.
where EIP-8321 initializes every new entry to `UNSET_RANDAO_COMMITMENT`.
Anything that was reliant on a newly registered validator having an unset commitment
which meant it was using the legacy BLS reveal will no longer be sound.

- Networking is largely unaffected. No gossip topic, request/response method, or Engine API
method changes, and deposits continue to reach the consensus layer as
[EIP-6110](./eip-6110.md) execution requests with an unchanged encoding. The main change here
is that PQ signatures are much larger than BLS, so we would want to ensure that it can be
handled by the network.

- `Validator.pubkey` remains 48 bytes and remains unique per validator, but for
leanSig validators it is not a BLS public key, so tooling that deserializes every
`Validator.pubkey` as a BLS point will fail on these entries and MUST check
the version and prefix byte first.

- A deposit's `pubkey` field is unchanged as an identifier for a validator, since
the depositor writes the identity directly and it is stored verbatim. Deposit-contract
logs and `DepositRequest`s continue to identify a validator by it, so block explorers,
deposit monitors, staking dashboards, distributed-validator tooling and beacon API
deposit endpoints keep working on the field they key on today. What they can no longer
do is read a validator's key out of it; that is in `pq_pubkeys`.

- A validator's withdrawal address is now part of its identity, so it cannot be
changed without changing the validator. This is not a regression: no operation to
change an execution address exists today either, since `process_bls_to_execution_change`
applies only to `0x00` credentials and `switch_to_compounding_validator` preserves
the address. It does foreclose adding one later without also rewriting
`Validator.pubkey`.

- Deposits that register new BLS validators are ignored from this fork. Deposit
tooling that submits BLS deposits after the fork will consume the deposited ETH
without creating an active validator. Top-ups to existing validators are unaffected.

<--! TODO: some people will send ETH after the deadline, so we should try and get them their funds -->

## Security Considerations

### LeanSig Deposits made before the fork are lost

Before this fork, a leanSig-encoded deposit fails `is_valid_deposit_signature`,
because a pubkey with the compression bit clear cannot be deserialized and
verification returns false.

Importantly, the funds are unrecoverable. Deposit tooling SHOULD refuse to construct
a leanSig deposit until the fork epoch is both scheduled and reached.

This is not a new failure mode as a BLS deposit with a malformed signature today
would cause the same issue.

### Malformed leanSig deposits are silently dropped

Also similar to BLS, a deposit that fails `is_valid_leansig_deposit`; non-zero padding in either
field, or a zero RANDAO commitment, is ignored and the deposited ETH is lost.

Client implementations SHOULD surface these rejections in logs, and deposit tooling
SHOULD validate the full encoding locally before submitting.

### Non-canonical keys register as distinct validators

Because `leansig_pubkey` is opaque; we want to ensure that the keys are normalised.

Two byte strings that a verifier would reduce to the same key because field elements
are encoded at or above the field modulus, for example, become different identities
and therefore register as two separate validators backed by one underlying key.

Since leanSig is stateful, each epoch's one-time key may sign at most once.
Two validators sharing a key would be asked to sign different messages
at the same epoch, and one-time key reuse breaks the security of the key at that epoch/slot.

<!-- TODO: might belong in other EIP -->
<!-- TODO: can't we somehow reject them in is_leansig_pubkey or something? we just assume that there exists a is_canonical method -->
The companion verification EIP MUST therefore reject non-canonically encoded keys
rather than reducing them, and similarly funds would essentially be burned.

### Unowned keys and deposit front-running

The BLS deposit signature is not only a proof of possession. It signs
`DepositMessage(pubkey, withdrawal_credentials, amount)`, so it authenticates the
binding between a key and the credentials it is registered under. This EIP drops
that signature, and no post-quantum signature fits in the 96 bytes available, so
the binding is re-established by the identity instead.

Without it the attack would be as follows. Deposits are ordinary public
transactions, so a leanSig public key is visible before its deposit confirms, and
staking services and distributed-validator clusters routinely publish deposit data
in advance. An attacker front-runs with the same key under their own withdrawal
address and a minimal amount. Their deposit lands first and claims the identity.
The depositor's deposit then finds the pubkey present, takes the top-up branch,
and credits a validator whose withdrawal address belongs to the attacker. The
depositor's client finds the validator by key and attests for it. After
`SHARD_COMMITTEE_PERIOD` the attacker exits it with an
[EIP-7002](./eip-7002.md) withdrawal request and takes the balance.

Binding the withdrawal address into the identity removes the attack rather than
pricing it. The attacker must both collide with the depositor's identity and be
paid, and the address decides both:

- under the attacker's own address the identity differs, so no collision occurs,
  the depositor registers normally, and the attacker holds a validator they
  cannot sign for;
- under the depositor's address the identity collides, but the balance is
  withdrawable only to the depositor.

An attacker's leftover validator is not merely useless to them. Below
`MIN_ACTIVATION_BALANCE` it never activates, and an unactivated validator
satisfies neither exit path, so the stake is unrecoverable.

What remains is that a key not being registered by anyone can still be registered
by a stranger under their own address. That produces a validator that can never
attest, at the registrant's expense, and affects no one else.

### Two validators may share a key

Because the identity binds the address, one key can back more than one validator:
the same key registered under two addresses yields two entries. This is what
keeps a front-runner from consuming a depositor's key, but leanSig is stateful,
and two *active* validators sharing a key would sign different messages at the
same epoch with the same one-time key, which breaks Winternitz security outright.

`is_eligible_for_activation_queue` therefore refuses to activate a validator
whose key is already held by an active one. At most one validator per key is ever
in committees, so the one-time key is never reused, and the hazard is closed
without letting a third party block a registration.

The reachable case is not adversarial but ordinary: a depositor who registers
their key under a second address expecting to change their withdrawal address.
The second validator registers and waits, and becomes eligible once the first is
no longer active. An attacker can instead fund their own duplicate to
`MIN_ACTIVATION_BALANCE` so that it activates first, which delays the depositor
until that validator leaks to `EJECTION_BALANCE` and is ejected. That costs the
attacker most of their stake and delays rather than destroys.

### Key lifetime is not registered

leanSig keys are generated for a bounded slot range within a lifetime of `2**32`
slots. The public key commits to the tree but does not expose the range.

A validator whose key range expires can no longer sign; this is a
validator-operational concern rather than a consensus one. However, the idea
is to define such a large range that one can effectively view it as unbounded.

### Reserved space

`pubkey[34:48]` MUST be zero, since we use it to initialise `Validator.pubkey`
and as mentioned above, we want it to be normalised.

The RANDAO commitment is in the other field and is not part of the identity,
because it is a value that can change without the validator's signing key or
withdrawal address changing.

`signature[64:96]` MUST also be zero. Requiring zero keeps deposits canonical and
reserves the space for a future version.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
