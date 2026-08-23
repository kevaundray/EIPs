---
eip: TBD
title: Decoupled Validator Funding and Registration
description: Decouple validator funding from signing-credential registration through withdrawal-authorized deposits
author: TBD
discussions-to: TBD
status: Draft
type: Standards Track
category: Core
created: 2026-08-22
requires: 6110, 7251, 7685, 7997
---

## Abstract

This EIP decouples validator funding from BLS credential registration.

A withdrawal authority deposits ETH through a new execution-layer contract. The call carries a withdrawal credential type and a fixed-size credential reference. For BLS, the reference contains the public key. Repeated deposits by the same authority for the same reference accumulate as pending funding.

The validator operator separately broadcasts an amount-free consensus-layer registration. This registration transfers no ETH. It proves control of the referenced BLS key and binds that key to the withdrawal credentials. The consensus layer then converts all accumulated EL funding into one `PendingDeposit`. Existing finality, deposit-churn, validator-creation, and activation rules then apply.

The execution-layer contract treats the credential reference as opaque. A future EIP can assign another reference version and define its consensus-layer registration and state changes.

The existing validator deposit contract remains available. This EIP records unresolved funding but does not provide cancellation or recovery. A complete trust-minimized delegated-staking workflow is out of scope.

This EIP retains the trust assumptions of the existing deposit path. After registration, a legacy deposit cannot redirect the funding to different withdrawal credentials.

## Motivation

The existing validator deposit mechanism combines four operations into one:

1. funding stake
2. selecting a BLS public key
3. selecting withdrawal credentials
4. proving control of the BLS key (registering a validator)

Its fixed fields are:

```text
pubkey:                 48 bytes
withdrawal_credentials: 32 bytes
amount:                  8 bytes
signature:              96 bytes
```

This format is specific to BLS. A post-quantum signature scheme can require key material that does not fit these fixed fields.

The deposit contract checks the exact field lengths but does not validate their cryptographic content. A future scheme can reuse these fields only if its key material fits their fixed 144 bytes.

If a future registration signature travels through the EL only for verification on the CL, the caller must pay its calldata gas. Even a 1 to 2 KB signature is 10 to 20 times larger than the current 96-byte BLS signature. Some schemes use larger signatures. This data also consumes execution-payload and EL-to-CL request bandwidth.

This EIP sends only the fixed 64-byte credential reference through the EL. The registration signature travels directly on the CL, where the CL verifies it. The signature still consumes CL gossip and block bandwidth.

This separation can also support cases where the funding authority and validator operator are different parties, as with delegated staking.

The withdrawal authority `W` controls the economic stake. The operator controls the BLS public key `P` and performs consensus duties.

This EIP lets `W` fund a reference to `P`. The operator registers `P` independently on the consensus layer. The operator cannot choose the withdrawal credentials; they are bound to `W`.

This EIP does not make delegated staking trustless. It does not recover funding if the operator never registers or preempts registration through the legacy path.

### Goals

This EIP aims to:

1. decouple execution-layer funding from BLS registration,
2. authenticate the withdrawal authority through `msg.sender`,
3. support incremental funding through the existing `PendingDeposit` lifecycle,
4. keep the EL funding interface independent of BLS key and signature sizes, and
5. preserve the existing deposit contract and `Validator` representation.

### Non-Goals

This EIP does not:

1. remove or deprecate the existing validator deposit path,
2. define a post-quantum validator credential,
3. change an existing validator's signing key,
4. provide cancellation or recovery mechanisms,
5. guarantee that an operator supplies a registration,
6. provide a complete trust-minimized delegated-staking workflow, or
7. let the execution layer validate validator public keys or signatures.

Several of these limitations also apply to the existing deposit path.

### Terminology

#### Withdrawal authority

The **withdrawal authority** `W` is the execution address authenticated as `msg.sender` when funding is deposited.

#### Credential reference

A **credential reference** `R` is a fixed 64-byte identifier for a validator credential:

```text
byte 0:      credential reference version
bytes 1:64:  version-specific payload
```

This EIP assigns version `0x00` to an inline BLS public key:

```text
BLS_CREDENTIAL_REFERENCE_VERSION = 0x00

R = 0x00 || pubkey[48] || zero[15]
```

```python
def make_bls_credential_reference(pubkey):
    return Bytes64(
        bytes([BLS_CREDENTIAL_REFERENCE_VERSION])
        + pubkey
        + b'\x00' * 15
    )


def is_bls_credential_reference(reference):
    return (
        reference[0] == BLS_CREDENTIAL_REFERENCE_VERSION
        and reference[49:] == b'\x00' * 15
    )


def get_bls_pubkey(reference):
    assert is_bls_credential_reference(reference)
    return BLSPubkey(reference[1:49])
```

Future EIPs can assign versions with another canonical inline key or a hash commitment for a larger key. Each version MUST define its payload and padding.

#### Pending validator funding

**Pending validator funding** is ETH associated with `(W, R)` without an accepted valid BLS registration. The first deposit records the intended withdrawal credential type `T`.

Like the existing deposit flow, the first funding request fixes the withdrawal credential type. Later funding adds to the same record but cannot change this type.

#### Registered pending credential

A **registered pending credential** records a valid BLS registration whose initial `PendingDeposit` has not yet created the validator.

Registration processing creates this record and appends one `PendingDeposit` for all recorded funding. The record remains until pending-deposit processing creates the validator after finality and churn.

## Specification

### Execution Layer

#### Execution-layer constants

Unresolved values are marked `TBD`:

| Name | Value | Comment |
| --- | --- | --- |
| `VALIDATOR_DEPOSIT_CONTRACT_ADDRESS` | `TBD` | Address of the validator deposit contract |
| `VALIDATOR_DEPOSIT_CONTRACT_SALT` | `TBD` | Salt for the `CREATE2` deployment |
| `VALIDATOR_DEPOSIT_CONTRACT_INIT_CODE` | `TBD` | Init code for the contract |
| `VALIDATOR_DEPOSIT_CONTRACT_RUNTIME_CODE` | `TBD` | Expected runtime code |
| `SYSTEM_ADDRESS` | `0xfffffffffffffffffffffffffffffffffffffffe` | Address that invokes the system call |
| `SYSTEM_CALL_GAS_LIMIT` | `30_000_000` | Dedicated gas limit for the system call |
| `VALIDATOR_DEPOSIT_INHIBITOR_STORAGE_SLOT` | `0` | Storage slot for the activation inhibitor |
| `VALIDATOR_DEPOSIT_INHIBITOR` | `2**256 - 1` | Value that disables deposits before activation |
| `VALIDATOR_DEPOSIT_EVENT_SIGNATURE_HASH` | `0x2384dd3a4bc7dccb459fb56f95fedd1f2c8cd54395f3ee8888e916a279b7b49a` | Event-signature hash |
| `VALIDATOR_DEPOSIT_REQUEST_TYPE` | `TBD` | [EIP-7685](./eip-7685.md) request-type byte |
| `VALIDATOR_DEPOSIT_CALLDATA_SIZE` | `65` | Required user calldata length in bytes |
| `VALIDATOR_DEPOSIT_REQUEST_SIZE` | `93` | Encoded request length in bytes |
| `MIN_VALIDATOR_DEPOSIT_AMOUNT` | `1_000_000_000` | Minimum amount in Gwei (1 ETH) |
| `MAX_VALIDATOR_DEPOSIT_REQUESTS_PER_PAYLOAD` | `TBD` | Maximum requests in one execution payload |

The event hash is:

```text
keccak256(
    "ValidatorDepositEvent(bytes20,uint8,bytes32,bytes32,uint64)"
)
```

#### Deployment and activation

The [EIP-7997](./eip-7997.md) `CREATE2` factory MUST deploy the contract before activation. Its call input MUST be `VALIDATOR_DEPOSIT_CONTRACT_SALT || VALIDATOR_DEPOSIT_CONTRACT_INIT_CODE`.

The resulting address and runtime code MUST equal `VALIDATOR_DEPOSIT_CONTRACT_ADDRESS` and `VALIDATOR_DEPOSIT_CONTRACT_RUNTIME_CODE`.

The constructor MUST write `VALIDATOR_DEPOSIT_INHIBITOR` to `VALIDATOR_DEPOSIT_INHIBITOR_STORAGE_SLOT`. While the slot contains this value, every call from an address other than `SYSTEM_ADDRESS` MUST revert.

After activation, a block is invalid if the contract is absent or has different runtime code.

At the end of every execution block at or after activation, the execution layer MUST call `VALIDATOR_DEPOSIT_CONTRACT_ADDRESS` with:

```text
caller:   SYSTEM_ADDRESS
calldata: empty
value:    0
gas:      SYSTEM_CALL_GAS_LIMIT
```

The call uses dedicated gas that does not count against the block gas limit. It MUST write zero to `VALIDATOR_DEPOSIT_INHIBITOR_STORAGE_SLOT`, return no data, and emit no log. Writing zero to the zero-valued slot is valid, so later calls are idempotent. A call from `SYSTEM_ADDRESS` with non-empty calldata or non-zero value MUST revert.

If the system call fails, the block is invalid. This call only enables deposits. It does not dequeue or create an [EIP-7685](./eip-7685.md) request.

Because the call runs after transactions, deposits before activation and during the first activation block MUST revert. Deposits are enabled from the following block.

#### Deposit operation

Calls from `SYSTEM_ADDRESS` use the activation path above. Every other call MUST revert while the inhibitor is set.

The user path accepts ETH with exactly 65 bytes of raw calldata and no Solidity ABI selector:

| Bytes | Field |
| --- | --- |
| `0:1` | `withdrawal_credential_type` |
| `1:65` | `credential_reference` |

If the calldata length is not 65 bytes, the call MUST revert.

The contract MUST treat both fields as opaque. In particular, it MUST NOT validate `withdrawal_credential_type` or interpret `credential_reference`.

The call MUST revert unless:

1. `msg.value` is a multiple of 1 gwei,
2. `msg.value / 1 gwei` is at most `2**64 - 1`, and
3. the resulting amount is at least `MIN_VALIDATOR_DEPOSIT_AMOUNT`.

These three conditions match the existing deposit contract.
The amount and withdrawal authority are:

```text
amount = uint64(msg.value / 1 gwei)
source_address = msg.sender
```

The caller cannot supply another `source_address`. All accepted value remains in the contract. Unlike [EIP-7002](./eip-7002.md) withdrawal requests, this contract stores no queue and charges no fee. The 1 ETH minimum provides spam resistance.

A successful call MUST return no data and emit exactly one validator deposit event. Acceptance by the contract does not guarantee validator registration. Tooling MUST validate `T` and `R` before sending.

#### Request encoding

Each successful user call produces:

```text
ValidatorDepositRequest {
    source_address: Bytes20
    withdrawal_credential_type: uint8
    credential_reference: Bytes64
    amount: uint64  # Gwei
}
```

The event has exactly one topic:

```text
topics[0] = VALIDATOR_DEPOSIT_EVENT_SIGNATURE_HASH
```

Its data is the following packed 93-byte request:

| Bytes | Field | Encoding |
| --- | --- | --- |
| `0:20` | `source_address` | 20 raw bytes |
| `20:21` | `withdrawal_credential_type` | `uint8` |
| `21:85` | `credential_reference` | 64 raw bytes |
| `85:93` | `amount` | little-endian `uint64` Gwei |

The log is not ABI padded. The Solidity-style topic represents the 64-byte reference as two `bytes32` values because Solidity has no `bytes64` type. The log data still contains one contiguous reference. The topic is only domain separation.

Execution clients derive request data from receipt logs in canonical order:

```python
def get_validator_deposit_request_data(receipts):
    requests = []
    for receipt in receipts:
        for log in receipt.logs:
            if log.address != VALIDATOR_DEPOSIT_CONTRACT_ADDRESS:
                continue
            assert len(log.topics) == 1
            assert log.topics[0] == VALIDATOR_DEPOSIT_EVENT_SIGNATURE_HASH
            assert len(log.data) == VALIDATOR_DEPOSIT_REQUEST_SIZE
            requests.append(log.data)
    return b''.join(requests)
```

Every log emitted by `VALIDATOR_DEPOSIT_CONTRACT_ADDRESS` MUST have exactly one topic equal to `VALIDATOR_DEPOSIT_EVENT_SIGNATURE_HASH` and exactly 93 bytes of data. Otherwise, the block is invalid. The pinned runtime code makes these checks defensive.

If request data is non-empty, the execution layer adds:

```text
VALIDATOR_DEPOSIT_REQUEST_TYPE || request_data
```

to the block request list committed by `requests_hash`. Empty request data MUST be omitted. Request data MUST be in the same block and order as its events.

A block is invalid if the request data length is not a multiple of 93 or its request count exceeds `MAX_VALIDATOR_DEPOSIT_REQUESTS_PER_PAYLOAD`.

`VALIDATOR_DEPOSIT_REQUEST_TYPE` MUST be unique among all request types active in the fork.

#### Engine API

This EIP does not change the Engine API schema. The execution client includes `VALIDATOR_DEPOSIT_REQUEST_TYPE || request_data` in the existing `executionRequests` sequence returned by `engine_getPayload`.

The item is omitted when `request_data` is empty. The consensus client supplies the sequence through `engine_newPayload` when it submits the proposed payload for validation. The Engine API version active at this fork MUST accept the new request type and encoding.

### Consensus Layer

#### Consensus-layer constants

| Name | Value | Comment |
| --- | --- | --- |
| `PENDING_VALIDATOR_FUNDINGS_LIMIT` | `2**27` | Maximum pending funding records in the beacon state |
| `REGISTERED_PENDING_CREDENTIALS_LIMIT` | `2**27` | Maximum registered pending credentials in the beacon state |
| `MAX_VALIDATOR_REGISTRATIONS_PER_BLOCK` | `2**7` | Maximum validator registrations in one beacon block |
| `DOMAIN_VALIDATOR_REGISTRATION` | `DomainType('0x15000000')` | Provisional domain. Reconcile with the consensus-specs domain registry before the PR |

#### New consensus types

```python
class ValidatorDepositRequest(Container):
    source_address: ExecutionAddress
    withdrawal_credential_type: uint8
    credential_reference: Bytes64
    amount: Gwei


class PendingValidatorFunding(Container):
    withdrawal_authority: ExecutionAddress
    credential_reference: Bytes64
    withdrawal_credential_type: uint8
    amount: Gwei
    first_funding_slot: Slot


class RegisteredPendingCredential(Container):
    credential_reference: Bytes64
    withdrawal_credentials: Bytes32


class ValidatorRegistrationMessage(Container):
    pubkey: BLSPubkey
    withdrawal_credentials: Bytes32


class ValidatorRegistration(Container):
    pubkey: BLSPubkey
    withdrawal_credentials: Bytes32
    signature: BLSSignature


class ValidatorDepositRequests(
    List[ValidatorDepositRequest, MAX_VALIDATOR_DEPOSIT_REQUESTS_PER_PAYLOAD]
):
    pass


class PendingValidatorFundings(
    List[PendingValidatorFunding, PENDING_VALIDATOR_FUNDINGS_LIMIT]
):
    pass


class RegisteredPendingCredentials(
    List[RegisteredPendingCredential, REGISTERED_PENDING_CREDENTIALS_LIMIT]
):
    pass


class ValidatorRegistrations(
    List[ValidatorRegistration, MAX_VALIDATOR_REGISTRATIONS_PER_BLOCK]
):
    pass
```

`ValidatorRegistration` is BLS-specific. A future credential EIP can define another registration operation without changing the EL funding contract.

#### Modified containers

The following existing containers gain fields:

```python
class ExecutionRequests(Container):
    # Fields from previous forks omitted
    # [New in this EIP]
    validator_deposits: ValidatorDepositRequests


class BeaconState(Container):
    # Fields from previous forks omitted
    # [New in this EIP]
    pending_validator_fundings: PendingValidatorFundings
    # [New in this EIP]
    registered_pending_credentials: RegisteredPendingCredentials


class BeaconBlockBody(Container):
    # Fields from previous forks omitted
    # [New in this EIP]
    validator_registrations: ValidatorRegistrations
```

The two state lists start empty at fork activation.

#### Withdrawal credentials

This EIP supports new validators with `0x01` and `0x02` withdrawal credentials:

```python
def is_supported_withdrawal_credential_type(T):
    return T in (0x01, 0x02)


def make_withdrawal_credentials(T, W):
    assert is_supported_withdrawal_credential_type(T)
    return Bytes32(bytes([T]) + b'\x00' * 11 + W)
```

The execution contract remains opaque to these values.

#### State lookups

```python
def get_pending_validator_funding(state, W, R):
    for funding in state.pending_validator_fundings:
        if (
            funding.withdrawal_authority == W
            and funding.credential_reference == R
        ):
            return funding
    return None


def get_registered_pending_credential(state, R):
    for registered in state.registered_pending_credentials:
        if registered.credential_reference == R:
            return registered
    return None


def get_validator_index_by_reference(state, R):
    if not is_bls_credential_reference(R):
        return None

    pubkey = get_bls_pubkey(R)
    for index, validator in enumerate(state.validators):
        if validator.pubkey == pubkey:
            return ValidatorIndex(index)
    return None


def get_target(state, R):
    validator_index = get_validator_index_by_reference(state, R)
    if validator_index is not None:
        validator = state.validators[validator_index]
        return validator.pubkey, validator.withdrawal_credentials

    registered = get_registered_pending_credential(state, R)
    if registered is not None:
        return get_bls_pubkey(R), registered.withdrawal_credentials

    return None


def is_own_target(withdrawal_credentials, W):
    return (
        withdrawal_credentials[0] in (0x01, 0x02)
        and withdrawal_credentials[12:] == W
    )
```

Implementations SHOULD maintain a derived index for `(W, R)` and the existing BLS public-key index. These indexes are not consensus state.

#### Funding helpers

```python
def add_pending_validator_funding(state, W, R, T, amount):
    funding = get_pending_validator_funding(state, W, R)
    if funding is not None:
        # Total deposited ETH is less than UINT64_MAX gwei.
        assert funding.amount <= UINT64_MAX - amount
        funding.amount += amount
        # The first deposit fixes T. Later T values are ignored.
        return

    state.pending_validator_fundings.append(
        PendingValidatorFunding(
            withdrawal_authority=W,
            credential_reference=R,
            withdrawal_credential_type=T,
            amount=amount,
            first_funding_slot=state.slot,
        )
    )


def remove_pending_validator_funding(state, W, R):
    for index, funding in enumerate(state.pending_validator_fundings):
        if (
            funding.withdrawal_authority == W
            and funding.credential_reference == R
        ):
            state.pending_validator_fundings = PendingValidatorFundings(
                state.pending_validator_fundings[:index]
                + state.pending_validator_fundings[index + 1:]
            )
            return
    assert False


def remove_registered_pending_credential(state, R):
    for index, registered in enumerate(state.registered_pending_credentials):
        if registered.credential_reference == R:
            state.registered_pending_credentials = RegisteredPendingCredentials(
                state.registered_pending_credentials[:index]
                + state.registered_pending_credentials[index + 1:]
            )
            return
    assert False
```

There is at most one funding record for `(W, R)` and one registered pending credential for `R`. The first deposit that creates a funding record fixes its withdrawal credential type. Adding funding does not change `first_funding_slot` or the stored type.

#### Processing funding requests

```python
def process_validator_deposit(state, request):
    W = request.source_address
    T = request.withdrawal_credential_type
    R = request.credential_reference
    A = request.amount

    target = get_target(state, R)
    if target is not None and is_own_target(target[1], W):
        pubkey, withdrawal_credentials = target
        funding = get_pending_validator_funding(state, W, R)
        if funding is not None:
            assert A <= UINT64_MAX - funding.amount
            A += funding.amount
            remove_pending_validator_funding(state, W, R)

        state.pending_deposits.append(
            PendingDeposit(
                pubkey=pubkey,
                withdrawal_credentials=withdrawal_credentials,
                amount=A,
                signature=BLSSignature(),
                slot=state.slot,
            )
        )
        return

    add_pending_validator_funding(state, W, R, T, A)
```

The request becomes an ordinary pending top-up only when `R` already identifies a registered credential or validator whose execution withdrawal address is `W`.

Otherwise, the amount remains pending under `(W, R)`. This includes:

1. funding without a target,
2. funding whose first `T` is unsupported,
3. funding for an existing target with another execution address, and
4. funding for a `0x00` target, which has no execution address.

All such funding remains recorded for a future recovery EIP. This EIP does not classify it into a separate rejected list.

#### BLS registration

A `ValidatorRegistration` propagates on the consensus layer and appears in `block.body.validator_registrations`. It is not transported through the execution layer and transfers no ETH.

The signature proves control of the BLS key and authorizes its withdrawal credentials. The signed message contains no amount:

```python
def is_valid_validator_registration(state, registration):
    message = ValidatorRegistrationMessage(
        pubkey=registration.pubkey,
        withdrawal_credentials=registration.withdrawal_credentials,
    )
    domain = compute_domain(
        DOMAIN_VALIDATOR_REGISTRATION,
        fork_version=GENESIS_FORK_VERSION,
        genesis_validators_root=state.genesis_validators_root,
    )
    signing_root = compute_signing_root(message, domain)
    return bls.Verify(
        registration.pubkey,
        signing_root,
        registration.signature,
    )


def process_validator_registration(state, registration):
    R = make_bls_credential_reference(registration.pubkey)
    W = ExecutionAddress(registration.withdrawal_credentials[12:])
    funding = get_pending_validator_funding(state, W, R)

    assert funding is not None
    assert is_supported_withdrawal_credential_type(
        funding.withdrawal_credential_type
    )
    assert registration.withdrawal_credentials == make_withdrawal_credentials(
        funding.withdrawal_credential_type,
        W,
    )
    assert get_target(state, R) is None
    assert is_valid_validator_registration(state, registration)

    state.registered_pending_credentials.append(
        RegisteredPendingCredential(
            credential_reference=R,
            withdrawal_credentials=registration.withdrawal_credentials,
        )
    )
    state.pending_deposits.append(
        PendingDeposit(
            pubkey=registration.pubkey,
            withdrawal_credentials=registration.withdrawal_credentials,
            amount=funding.amount,
            signature=BLSSignature(),
            slot=state.slot,
        )
    )
    remove_pending_validator_funding(state, W, R)
```

`GENESIS_FORK_VERSION` makes the signature stable across forks. `genesis_validators_root` separates chains. Including the public key in the signed message provides proof of possession.

An accepted registration converts the complete funding record into one `PendingDeposit`. The entry carries an empty deposit signature because `RegisteredPendingCredential` supplies the authorization.

Every registration included in a block MUST pass `process_validator_registration`. An invalid registration makes the beacon block invalid.

#### Legacy deposit interaction

The existing `apply_pending_deposit` function is modified as follows:

```python
# [Modified in this EIP]
def apply_pending_deposit(state, deposit):
    validator_pubkeys = [v.pubkey for v in state.validators]
    if deposit.pubkey not in validator_pubkeys:
        R = make_bls_credential_reference(deposit.pubkey)
        registered = get_registered_pending_credential(state, R)
        withdrawal_credentials = deposit.withdrawal_credentials
        if registered is None:
            if not is_valid_deposit_signature(
                deposit.pubkey,
                deposit.withdrawal_credentials,
                deposit.amount,
                deposit.signature,
            ):
                return
        else:
            withdrawal_credentials = registered.withdrawal_credentials

        add_validator_to_registry(
            state,
            deposit.pubkey,
            withdrawal_credentials,
            deposit.amount,
        )
        if registered is not None:
            remove_registered_pending_credential(state, R)
        return

    validator_index = ValidatorIndex(
        validator_pubkeys.index(deposit.pubkey)
    )
    increase_balance(state, validator_index, deposit.amount)
```

Thus, `RegisteredPendingCredential` authorizes creation without a deposit signature. If a legacy pending deposit creates the BLS validator after registration, the registered withdrawal credentials override the credentials carried by that deposit. Its ETH funds the registered validator instead of redirecting it.

When the registration-created entry creates the validator, the same branch uses its registered credentials and removes the registration record. Later entries for the public key follow the ordinary top-up path.

No change is made when no registered pending credential exists.

#### Pending-deposit processing and churn

This EIP adds no second pending-deposit list and does not change `process_pending_deposits`. Each registration converts its complete funding record into one pending entry. Legacy deposits, registration entries, and later top-ups consume the existing count and balance-churn allowances in queue order.

#### Gossip validation

Clients MUST propagate registrations on `/eth2/{fork_digest}/validator_registration/ssz_snappy`. They MUST apply these rules in order against the current head state:

1. `[REJECT]` if SSZ decoding fails.
2. Compute the BLS reference `R` and derive `W` from `registration.withdrawal_credentials`.
3. `[IGNORE]` if funding for `(W, R)` does not exist.
4. `[REJECT]` if the stored `T` is unsupported or the credentials do not equal `make_withdrawal_credentials(T, W)`.
5. `[IGNORE]` if `R` already has a registered pending credential or validator.
6. `[IGNORE]` if the client already accepted a valid registration for `R`.
7. `[REJECT]` if `is_valid_validator_registration(state, registration)` returns `False`.
8. `[ACCEPT]` otherwise.

An ignored registration is not re-propagated. The sender SHOULD broadcast only after the funding block is imported and retry if the registration is not included.

Funding is checked before the BLS signature. A public key without matching funding cannot force expensive verification.

A public key with matching funding can cause verification of invalid signatures. Peer scoring and gossip rate limits bound repeated invalid messages.

#### Operation ordering

Without ePBS, the consensus layer processes relevant operations in this order:

1. existing [EIP-6110](./eip-6110.md) deposit requests,
2. validator deposit requests from this EIP, and
3. validator registrations.

```python
for_ops(body.execution_requests.deposits, process_deposit_request)
# [New in this EIP]
for_ops(
    body.execution_requests.validator_deposits,
    process_validator_deposit,
)
# [New in this EIP]
for_ops(body.validator_registrations, process_validator_registration)
```

A registration can consume funding from the same block under this ordering. Existing deposit requests enter `state.pending_deposits` before registration entries from the same block.

Under an ePBS design such as [EIP-7732](./eip-7732.md), a registration can reference only funding present in its pre-state. Same-slot execution requests are not available when beacon-block operations are processed.

#### State growth and recovery

`PendingValidatorFunding` can remain indefinitely when no registration is accepted or `R` already belongs to another withdrawal address. `RegisteredPendingCredential` exists only until a pending deposit creates the validator.

Each funding record is backed by at least 1 ETH. The bounded lists match the existing `PENDING_DEPOSITS_LIMIT` scale. Clients SHOULD index `(W, R)` and BLS public keys to avoid linear scans.

`first_funding_slot` exists so a future recovery mechanism can apply an age condition. This EIP defines no recovery mechanism or recovery right.

## Rationale

### Why use a new deposit contract?

The existing contract requires BLS-sized public-key and signature fields. The new contract transports only `T`, `R`, and the amount. It can remain unchanged if a future EIP defines another credential-reference version.

### Why use one deposit mode?

The contract cannot know whether `R` is registered. The CL therefore applies one safe rule: a request is a top-up only when the effective target has `msg.sender` as its execution withdrawal address. Otherwise it remains funding owned by the caller.

This removes mode-selection mistakes. Third parties can continue to top up BLS validators through the legacy deposit contract.

### Why key funding by `(W, R)`?

`W` owns the pending value and `R` identifies the intended credential. The first deposit that creates pending funding stores `T`. Later deposits cannot change it.

This prevents `(0x01, W, R)` and `(0x02, W, R)` from becoming separate stranded records. If `W` wants compounding credentials after validator creation, it can use the existing [EIP-7251](./eip-7251.md) switch.

### Why keep unsupported withdrawal types?

The EL contract deliberately treats `T` as opaque. The CL records the first value without trying to apply it. This preserves an on-chain funding record for a future recovery EIP instead of silently dropping the deposit.

Tooling must avoid making an unsupported first deposit because later deposits for the same `(W, R)` cannot replace its `T`.

### Why use a dedicated registration message?

Validator funding belongs to `W`, not to the operator's proof. Omitting the amount lets the operator authorize the BLS key and withdrawal credentials before any funding exists.

A dedicated domain prevents use of the signature as a legacy deposit or another protocol message. The accepted registration authorizes one pending entry for the complete recorded amount.

The EL reference remains fixed-size. A future credential EIP can assign another reference version and define another CL operation without changing the funding contract.

### Why use a 64-byte credential reference?

Version `0x00` carries the BLS public key directly. Clients can use their existing BLS public-key index and do not need a commitment hash or commitment index.

The 64-byte size aligns the reference as two 32-byte words. A future version can place a domain-separated 32-byte hash and version-specific metadata in its 63-byte payload.

The trade-off is 32 more bytes in each funding request and record than an always-hashed 32-byte commitment.

### Why can registered credentials override a legacy deposit?

Registration proves that the BLS key authorized `W`'s withdrawal credentials. If a legacy pending deposit for the same public key creates the validator first, using its credentials would let the BLS key preempt the registered relationship.

Using the registered credentials fixes the collision at validator creation. The legacy depositor's ETH still funds the validator, but it cannot redirect withdrawals.

### Why use `msg.sender` as the authority?

The EVM authenticates EOAs and contract accounts. The CL does not need to reproduce smart-account policy.

The account that will control withdrawals must make the call and provide the ETH. A separate funding account must route the ETH through that account or vault.

### Why retain `first_funding_slot` without recovery?

Removing the timestamp would force a future recovery EIP to treat every pre-existing record as newly created at its activation fork. Eight bytes per funding record preserve the actual age without adding a transition branch today.

### Why inhibit the contract before activation?

The contract must exist before the fork to obtain its deterministic CREATE2 address. Without an inhibitor, a pre-fork caller could deposit before clients derive its requests.

The first mandatory end-of-block system call clears the inhibitor. This follows the request-contract activation pattern and keeps identical bytecode and addresses across networks.

An activation timestamp in the runtime code would remove the system call. It would also create network-specific bytecode and contract addresses. This EIP selects the established system-call pattern.

### Future work

A future EIP can define cancellation or recovery of unresolved funding to `W`. It can use `first_funding_slot` when defining an age requirement.

Another EIP can define a non-BLS credential registration operation while reusing the EL request format and assigning another reference version.

Beacon API extensions must expose pending funding and registered credentials for tooling pre-flight checks. Their exact endpoints are future work.

The intended long-term migration is to deprecate legacy BLS validator creation. Deprecation is not part of this EIP.

### Open questions

1. What request type, deployment salt, init code, and runtime code are assigned?
2. What value is assigned to `MAX_VALIDATOR_DEPOSIT_REQUESTS_PER_PAYLOAD` after bytecode gas analysis?
3. If EIP-7997 is unavailable for the fork, should deployment use the Nick's-method pattern from [EIP-7002](./eip-7002.md) and [EIP-7251](./eip-7251.md)?

## Backwards Compatibility

The existing deposit contract and existing validators remain supported. Existing EIP-6110 deposit processing continues.

When no `RegisteredPendingCredential` exists, legacy pending deposits behave exactly as before. When one exists for the same BLS public key, its withdrawal credentials control new-validator creation. The registered credential supplies authorization, so the legacy deposit signature is no longer required for creation. This interaction prevents registered stake from being redirected.

This EIP does not add a withdrawal credential prefix or change `Validator.pubkey`.

## Test Cases

Execution-layer tests MUST cover:

1. exact 65-byte calldata and 93-byte request encoding,
2. the event topic and packed field order,
3. little-endian request amount encoding,
4. rejection of non-gwei and sub-1-ETH value,
5. opaque acceptance of every `uint8` withdrawal type and `Bytes64` reference,
6. canonical receipt-log ordering,
7. empty request-data omission,
8. the per-payload request cap,
9. Engine API transport and validation,
10. contract absence, code mismatch, and system-call failure,
11. user-call rejection before activation and during the activation block,
12. inhibitor removal by the first activation-block system call, and
13. idempotent later system calls that emit no deposit event.

Consensus tests MUST cover:

1. first funding creates `(W, R)` with `T` and `first_funding_slot`,
2. later funding adds its amount without changing `T` or `first_funding_slot`,
3. unsupported first `T` remains recorded and cannot register,
4. BLS version `0x00` extracts the 48-byte key and requires 15 zero padding bytes,
5. an unknown or non-canonical reference remains recorded and cannot use BLS registration,
6. a target with `W`'s `0x01` or `0x02` address receives an ordinary pending top-up,
7. a target with another address or `0x00` credentials leaves funding in `(W, R)`,
8. an own-target deposit sweeps earlier `(W, R)` funding into the same top-up,
9. registration requires a supported stored `T`, matching credentials, a valid BLS key, and a valid registration signature,
10. registration signatures use `DOMAIN_VALIDATOR_REGISTRATION`, `GENESIS_FORK_VERSION`, and `genesis_validators_root`,
11. registration converts the complete funding amount into one pending entry with an empty deposit signature,
12. registration removes its funding record and creates one registered pending credential,
13. the registered credential authorizes validator creation without a deposit signature,
14. validator creation removes the registered pending credential,
15. an existing validator or registered credential prevents another registration for `R`,
16. ordinary pending-deposit finality, count, balance-churn, exit, and withdrawal rules remain unchanged,
17. a same-slot legacy entry precedes the registration-created entry under non-ePBS ordering, and
18. ePBS registration can use only funding present in the pre-state.

Legacy-interaction tests MUST apply a legacy deposit before and after:

1. initial funding,
2. registration acceptance,
3. the registration-created pending entry,
4. validator creation.

They MUST show that:

1. a legacy deposit that creates the validator while registration exists uses the registered withdrawal credentials,
2. the legacy depositor's amount is credited once,
3. the registration-created pending entry becomes an ordinary top-up afterward,
4. a legacy validator created before registration causes registration to fail without consuming `(W, R)`,
5. an invalid legacy deposit signature cannot redirect registered funding, and
6. at most one validator exists for each BLS public key and reference.

Gossip tests MUST cover all reject, ignore, and accept branches in their specified order. They MUST show that the funding check precedes BLS verification.

## Reference Implementation

The init code and runtime bytecode are TBD.

## Security Considerations

### Unresolved funding

This EIP provides no cancellation, timeout, or withdrawal for `PendingValidatorFunding`. Funding can remain indefinitely when:

1. the operator never registers,
2. the first deposit uses an unsupported `T`,
3. the BLS key already identifies a validator with another withdrawal address, or
4. the BLS key is registered through the legacy contract before this registration is accepted.

The CL retains each case as a funding record. A future EIP can define recovery, but this EIP creates no recovery right.

### Staged funding

The operator can produce the amount-free registration before funding. `W` SHOULD validate it, deposit only 1 ETH, and submit the registration. After validator creation, `W` can deposit the remainder.

This limits exposure to operator inactivity or legacy preemption. It does not make delegated staking trustless.

### Legacy preemption

Before registration is accepted, a holder of the BLS secret key can create the validator through the legacy contract with other withdrawal credentials. A 1 ETH legacy deposit can then strand a much larger `(W, R)` funding record. The attacker keeps its 1 ETH as validator balance.

After registration is accepted, registered withdrawal credentials override a legacy creation deposit. The legacy deposit then funds `W`'s validator rather than redirecting it.

An accepted registration also replaces the need for a deposit signature during validator creation. An invalid legacy deposit signature can accelerate creation only by contributing stake to the registered validator.

### Registration replay

The dedicated domain prevents replay through the legacy deposit contract or another protocol. `genesis_validators_root` prevents cross-chain replay. On the same chain, an accepted registration or existing validator prevents another registration for `R`.

### First withdrawal type wins

The first deposit that creates funding fixes `T` for `(W, R)`. Later deposits cannot correct it. An unsupported or mistaken first value usually leaves all funding for that key unresolved.

One escape path exists. If the legacy contract creates the validator with `W`'s credentials, a later deposit from `W` sweeps the funding into a top-up.

Tooling MUST construct canonical `R` and validate `T` and the intended withdrawal address before sending.

### Credential-reference mistakes

The EL contract accepts every 64-byte reference. This EIP registers only canonical BLS version `0x00`. Funding for another version or non-zero BLS padding remains unresolved until a future EIP supports or recovers it.

### Target selection

The new contract tops up only a `0x01` or `0x02` target whose execution address is `msg.sender`. A caller targeting another address or a `0x00` validator creates unresolved funding instead.

The new contract does not support direct third-party top-ups. A third party can use the legacy deposit contract.

### Smart accounts

The CL trusts the EL-authenticated `source_address`. A smart account or vault must call the deposit contract itself. Consensus does not reproduce its ownership, governance, or module checks.

### Proof-verification denial of service

Registration gossip checks funding before verifying the BLS signature. A public key without a matching `(W, R)` funding record cannot cause verification.

A funded public key can cause verification of invalid signatures. Peer scoring and gossip rate limits bound repeated invalid messages.

### Request-processing bound

The contract has no request queue or per-block counter. Every successful deposit emits one request in the same block. `MAX_VALIDATOR_DEPOSIT_REQUESTS_PER_PAYLOAD` independently caps CL input.

Before activation, the specification MUST calculate:

```text
max_requests_per_block = floor(
    execution_block_gas_limit /
    minimum_gas_per_successful_deposit
)
```

The analysis MUST use batched calls with warm account access, state its gas-limit assumption, and include headroom for later gas-limit increases. The final cap and client implementations MUST safely handle the corresponding receipt logs, request bytes, and funding updates.

### Activation

The pre-fork inhibitor prevents deposits that execution clients would not expose as requests. A block is invalid if the required post-fork system call fails or the pinned contract code is absent or different.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
