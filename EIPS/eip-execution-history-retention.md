---
title: Execution History Retention Window
description: Require execution clients to retain recent block history for consensus-layer interoperability
author: Kevaundray Wedderburn (@kevaundray)
discussions-to: https://ethereum-magicians.org/t/eip-4444-bound-historical-data-in-execution-clients/7450
status: Draft
type: Standards Track
category: Networking
created: 2026-08-15
requires: 7642
---

## Abstract

Define `HISTORY_RETENTION_WINDOW = 1_056_768` blocks and require execution-layer
(EL) clients to retain and serve canonical block headers, bodies, and receipts
within this rolling window. This is the maximum number of execution payloads in
the consensus layer's existing 33,024-epoch block-serving window. History older
than the window may be pruned.

## Motivation

[EIP-4444](./eip-4444.md) established the goal of bounding historical data in
execution clients using a one-year window. Client implementations subsequently
introduced several different policies, including fork-based cutoffs,
approximately two-week minimums, and configurable one-year rolling windows.
The protocol does not currently define a common minimum rolling window.

The lack of a common minimum creates an interoperability risk between the
consensus layer (CL) and EL. CL clients are required to retain and serve recent
beacon blocks. A post-merge beacon block contains an execution payload, but not
all CL implementations persist the complete payload in their own database.
Some retrieve payload data from their paired EL when serving historical beacon
blocks. If the EL prunes payload data before the end of the CL block-serving
window, those CL implementations can no longer satisfy their networking
obligations.

A common window also gives node operators and downstream software a predictable
minimum. Operators may choose to retain more history, but software must not rely
on every ordinary node retaining history older than this minimum.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in
[RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and
[RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

### Parameters

| Parameter | Value | Description |
| - | - | - |
| `HISTORY_RETENTION_EPOCHS` | `33_024` | CL epoch range from which the window is derived |
| `SLOTS_PER_EPOCH` | `32` | Maximum execution payload opportunities per epoch |
| `HISTORY_RETENTION_WINDOW` | `1_056_768` | `HISTORY_RETENTION_EPOCHS * SLOTS_PER_EPOCH` |

### Retention requirement

Let `head` be the block number of the locally validated canonical execution head
and define:

```text
retention_start = max(0, head - HISTORY_RETENTION_WINDOW)
```

For every canonical block with number `n` such that
`retention_start <= n <= head`, EL clients MUST retain:

- the block header;
- the block body, including transactions, withdrawals, and any other data
  required to reconstruct the execution payload; and
- the transaction receipts.

The physical representation and storage location of this data are
implementation-defined. A client MAY satisfy the requirement using its primary
database, immutable files, or any other local representation, provided the data
can be returned without downloading it from an external source.

This EIP does not specify retention of non-canonical branches.

A client starting from a recent checkpoint MAY participate while backfilling,
but it does not satisfy the retention requirement until the backfill reaches
`retention_start`. While backfilling, it MUST advertise only its actual history
range as described below.

### Serving requirement

EL clients MUST serve retained headers, bodies, and receipts in response to
valid requests on supported versions of the `eth` peer-to-peer protocol,
subject to ordinary response-size, rate-limiting, and peer-scoring rules.

An EL exposing `engine_getPayloadBodiesByHashV1`,
`engine_getPayloadBodiesByRangeV1`, or successor versions MUST return locally
retained bodies for canonical blocks within `HISTORY_RETENTION_WINDOW`, subject
to the request limits of those methods. It MUST NOT return an unavailable or
`null` result for an in-window canonical body because the body was pruned. This
permits a paired CL that does not persist complete execution payloads to
reconstruct and serve recent beacon blocks.

This EIP does not prohibit retaining or serving older history. When implementing
[EIP-7642](./eip-7642.md), clients MUST advertise the range actually available
through the `eth` protocol. Pruning that changes the available range MUST be
reflected in `earliestBlock` and subsequent `BlockRangeUpdate` messages.

### Data outside the history window

This EIP does not require JSON-RPC methods to retrieve data older than
`HISTORY_RETENTION_WINDOW`. Clients MAY retrieve or import older data from an
out-of-band history archive.

This EIP does not constrain retention of historical world state, state diffs,
blob sidecars, or data-column sidecars. Their safety requirements and pruning
policies are independent of the block-history window defined here.

## Rationale

### Choice of window

The CL requires nodes to retain blocks for a minimum derived by
`compute_min_epochs_for_block_requests()`:

```text
MIN_VALIDATOR_WITHDRAWABILITY_DELAY + CHURN_LIMIT_QUOTIENT // 2
= 256 + 65_536 // 2
= 33_024 epochs
```

This formula was introduced as a static upper bound on the weak-subjectivity
calculation. Consensus networking deliberately selects the worst case of a very
large validator set, at least
`MIN_PER_EPOCH_CHURN_LIMIT * CHURN_LIMIT_QUOTIENT`, and maximal allowed safety
decay. It is not the result for a particular live validator set. The
weak-subjectivity guide's `SAFETY_DECAY` value is 10%, so 33,024 epochs must not
be interpreted as the expected depth of a reorganization or as the current
weak-subjectivity period. It is a conservative network-serving bound.

Matching the CL bound avoids introducing another retention period and ensures
that a CL which delegates execution-payload storage to its paired EL can serve
the same history as a CL which stores complete payloads itself.

There are at most 32 execution payloads per epoch. Expressing the EL requirement
as `33_024 * 32 = 1_056_768` blocks avoids requiring the EL to calculate epochs
from consensus state. Missed slots cause a block-denominated window to cover a
longer time span, never a shorter one. At 12 seconds per slot, the window is
approximately 146.8 days.

### Why not one year

The one-year window in EIP-4444 was selected to leave ample room for weak
subjectivity while still bounding disk growth. It was not derived from a
present protocol dependency. The 33,024-epoch CL serving window already
contains a substantial safety margin and provides a cross-layer reason for the
chosen value.

Reducing the minimum from one year to approximately 4.8 months lowers storage
requirements while preserving recent-history availability expected by the CL.
Clients and operators that need a year or complete history remain free to
retain it.

### Why not the current weak-subjectivity period

The weak-subjectivity guide's reference table gives 3,532 epochs for a 32 ETH
average validator balance, at least 262,144 validators, and `SAFETY_DECAY = 10`.
However, using that value would make the EL window shorter than the existing CL
block-serving window and would break CL implementations that rely on the EL for
payload storage.

The weak-subjectivity period also depends on consensus parameters and validator
set characteristics. A fixed EL window is easier to implement, configure, and
communicate than a dynamically computed floor.

### Why not the blob retention period

Blob and data-column sidecars use a 4,096-epoch availability window. These
objects are designed to expire after rollups have consumed them and are not
required to reconstruct execution payloads or serve historical beacon blocks.
Their retention period does not provide a basis for pruning execution history.

### History retention and reorg state retention

Processing a reorganization requires the EL to reconstruct state at the common
ancestor. It does not require retaining the displaced branch's canonical block
history, because blocks on the incoming branch are supplied through the Engine
API or peer-to-peer network. Conversely, retaining headers, bodies, and
receipts does not make historical state reconstructible.

The two requirements may use different windows and representations.
[EIP-8252](./eip-8252.md) proposes a separate state-reconstruction window for
reorganizations. This EIP only specifies block history.

### Receipts

The CL interoperability requirement directly depends on headers and execution
payload bodies, not receipts. Receipts are nevertheless included because they
are part of execution history under EIP-4444, are exchanged through the `eth`
protocol, and share the single available-history range advertised by EIP-7642.
A common window avoids advertising a block as available while being unable to
serve all standard history requests for it.

### Future independent CL and EL synchronization

[EIP-8237](./eip-8237.md) proposes allowing the CL to synchronize without
obtaining historical execution payloads. If all supported CL architectures
cease depending on EL payload retention, the cross-layer reason for matching
the CL block-serving window can be reconsidered in a subsequent proposal.

## Backwards Compatibility

This EIP does not change execution consensus rules and does not require a hard
fork.

This proposal narrows the one-year pruning boundary proposed by EIP-4444 and
changes the focus from stopping old-history service to guaranteeing a minimum
recent-history floor. It does not require clients to stop serving older history.

Clients whose pruning configuration retains less than
`HISTORY_RETENTION_WINDOW` must increase their minimum retention. Clients using
fork-based history cutoffs must implement a rolling cutoff to remain bounded.

Applications requesting older data may receive unavailable or not-found
responses, as already anticipated by EIP-4444. Applications requiring older
history must use a node configured for longer retention or an external history
archive.

## Test Cases

Given `HISTORY_RETENTION_WINDOW = 1_056_768`:

1. With `head = 2_000_000`, `retention_start` is `943_232`. Blocks from
   `943_232` through `2_000_000`, inclusive, must remain available.
2. Block `943_231` is eligible for pruning. Block `943_232` is not.
3. A checkpoint-synced client whose oldest local block is `1_500_000` does not
   yet satisfy this EIP at `head = 2_000_000`; it must backfill through block
   `943_232`.
4. After pruning changes the earliest available block, an EIP-7642
   `BlockRangeUpdate` must advertise the new range.
5. A paired CL requesting canonical block `1_000_000` through
   `engine_getPayloadBodiesByHashV1` at `head = 2_000_000` must receive the
   locally retained body.

## Security Considerations

### Weak-subjectivity sync

Nodes joining proof-of-stake Ethereum require a recent weak-subjectivity
checkpoint obtained out of band. A common recent-history floor ensures that a
node starting from a sufficiently recent checkpoint can obtain the execution
history needed to advance toward the head. It does not authenticate the
checkpoint or remove the weak-subjectivity assumption.

### Cross-layer availability

An EL that advertises history it cannot serve may cause peer churn, failed sync,
or failure of a paired CL to serve beacon blocks. Clients must update their
advertised range after pruning and must not count remotely retrievable data as
locally retained for the purpose of satisfying the minimum window.

### Older history availability

Pruning does not destroy the cryptographic commitments to old history, but it
reduces the number of ordinary nodes that can return the underlying data.
Independent archives and importable history formats remain necessary to avoid
centralizing access to expired history. Availability of data older than the
window is outside the security guarantees of this EIP.

### Clock and configuration changes

The normative window is block-denominated and therefore does not depend on an
EL client's wall clock. Changes to `SLOTS_PER_EPOCH`, the CL block-serving
window, or the relationship between beacon blocks and execution payloads should
trigger a review of `HISTORY_RETENTION_WINDOW`.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
