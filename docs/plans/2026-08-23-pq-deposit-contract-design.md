# Post-Quantum Deposit Contract Design

Date: 2026-08-23

## Purpose

This proposal adds a validator deposit contract with variable-length signing credentials.
The contract supports BLS deposits first and post-quantum credential formats in later forks.

The new contract does not replace the code of the immutable legacy deposit contract.
Consensus accepts deposits from both contracts during the migration period.

## Goals

- Accept a variable-length `pubkey`.
- Rename `signature` to `credential_metadata` and make it variable-length.
- Keep the 32-byte withdrawal credentials field.
- Keep the existing deposit amount rules.
- Forward every accepted deposit from the execution layer to the consensus layer.
- Process the `48`-byte and `96`-byte pair as BLS before PQ retirement.
- Permanently reject that pair in the new contract after a future system call.
- Let future forks define and process new credential formats.

## Non-goals

- The contract does not validate a public key or credential metadata.
- This proposal does not define a PQ signature scheme.
- This proposal does not recover ETH from an invalid or unsupported deposit.
- This proposal cannot stop the legacy deposit contract from receiving ETH.

## Contract interface

The user interface is:

```solidity
function deposit(
    bytes calldata pubkey,
    bytes32 withdrawal_credentials,
    bytes calldata credential_metadata
) external payable;
```

The contract applies these amount rules:

1. `msg.value` is at least 1 ETH.
2. `msg.value` is a multiple of 1 gwei.
3. The gwei amount fits in a `uint64`.

The contract does not apply generic maximum lengths.
Calldata, execution, and log gas costs bound the accepted data in each block.

The contract also does not reject empty or unsupported credential fields.
Such a deposit can lock its ETH permanently.

## Contract modes

The contract has three modes:

```text
INHIBITED -> BLS_ENABLED -> BLS_RETIRED
```

Only `SYSTEM_ADDRESS` can change the mode.
Each transition is monotonic, and `BLS_RETIRED` is permanent.

The EIP-7997 factory deploys the contract before the initial activation fork.
The specification pins the contract address, initialization code, and runtime code.

A start-of-block system call changes `INHIBITED` to `BLS_ENABLED` at the initial fork.
A later start-of-block system call changes `BLS_ENABLED` to `BLS_RETIRED` at the PQ fork.
A failed required system call makes the block invalid.

In `BLS_RETIRED` mode, the contract reverts only when both conditions are true:

```text
pubkey.length == 48
credential_metadata.length == 96
```

This pair is the format discriminator for legacy BLS credentials.
All other length combinations remain acceptable to the contract.

## Event and execution request

A successful deposit emits:

```solidity
event CredentialDepositEvent(
    bytes pubkey,
    bytes32 withdrawal_credentials,
    uint64 amount,
    bytes credential_metadata
);
```

Execution clients collect all matching logs from the pinned contract address.
They preserve receipt and log order.
They do not classify credential formats or ignore a valid event.

The execution layer supplies the events through a new EIP-7685 request type.
The request data uses SSZ progressive types, so the schema has no fixed credential-size capacity.

## Consensus request and processing

The consensus request is:

```python
class CredentialDepositRequest(ProgressiveContainer):
    pubkey: ProgressiveByteList
    withdrawal_credentials: Bytes32
    amount: Gwei
    credential_metadata: ProgressiveByteList
```

The execution request collection is a progressive list of these requests.
Runtime payload-size rules and execution gas bound the data that clients process.

Before PQ support, consensus classifies the `48`-byte and `96`-byte pair as BLS.
It casts the fields to `BLSPubkey` and `BLSSignature`.
It then uses the existing BLS signature and pending-deposit processing.

Consensus ignores all unsupported formats.
The execution layer still includes these formats in the committed request data.

A future PQ fork adds format validation and processing for its supported credentials.
That fork also activates `BLS_RETIRED` in the contract.

## Legacy contract transition

During the BLS migration period, consensus accepts BLS deposits from both contracts.
The new contract uses the generalized request path.
The legacy contract continues to use the EIP-6110 request path.

At PQ retirement, consensus stops processing legacy deposit requests.
The new contract rejects BLS-shaped deposits.

The legacy contract remains able to receive ETH after retirement.
Wallets, launchpads, and staking tools must mark its address as retired.

## Failure behavior

The new contract reverts in these cases:

- The contract is in `INHIBITED` mode.
- The deposit amount violates an amount rule.
- A BLS-shaped deposit occurs in `BLS_RETIRED` mode.
- A caller other than `SYSTEM_ADDRESS` requests a mode transition.
- A system call requests an invalid or non-monotonic transition.

Unsupported credentials do not cause a contract revert.
Consensus ignores them, and the deposited ETH remains locked.

## Security properties

The mode cannot return to BLS after retirement.
The exact conjunction of both legacy lengths identifies the BLS format.
A single matching length does not cause a rejection.

The contract does not promise that an accepted deposit creates or funds a validator.
Deposit tooling must validate the credential format before it sends ETH.

The execution layer charges for calldata and event data.
Thus, large credential fields consume block gas in proportion to their encoded size.

The immutable legacy contract remains a fund-loss hazard after retirement.
Client software must communicate that risk and stop offering the old address.

## Test plan

Tests must cover:

- Deployment with the `INHIBITED` mode.
- The initial system transition to `BLS_ENABLED`.
- The future system transition to `BLS_RETIRED`.
- Rejection of unauthorized and non-monotonic transitions.
- All deposit amount boundaries.
- Empty and variable-length credential fields.
- The `48`/`96` pair before and after retirement.
- Cases where only one legacy length matches.
- Event encoding and canonical log ordering.
- Inclusion of every event in the generalized request.
- BLS conversion into the existing pending-deposit path.
- Consensus handling of unsupported formats.
- Processing from both contracts during migration.
- Legacy request retirement at the PQ fork.

## Alternatives considered

A queued contract gives explicit request rate limits.
It adds queue storage, fees, and delayed processing.

A modified deposit accumulator preserves the old Merkle root interface.
It requires a new root definition for variable fields that EIP-6110 does not need.

The selected log-based design has less contract state and follows the EIP-7685 request model.
