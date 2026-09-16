# Consensus-client historical block backfill audit

Date: 2026-08-15

## Scope

This note records how production consensus-layer clients acquire historical
beacon blocks after checkpoint sync. It focuses on the approximately five-month
window associated with the current mainnet block-serving requirement:

```text
MIN_EPOCHS_FOR_BLOCK_REQUESTS = 33_024 epochs

33_024 epochs * 32 slots/epoch * 12 seconds/slot
= 12_681_216 seconds
~= 146.8 days
```

The audit distinguishes:

- forward sync, which brings a node from its checkpoint to the current head;
- reverse backfill, which downloads blocks older than the checkpoint; and
- pruning and serving, which determine how much acquired history remains
  available to peers.

The clients do not calculate a weak-subjectivity period using
`SAFETY_DECAY = 100` while backfilling. They consume the configured networking
window, derive an equivalent static horizon, or use an implementation-specific
target. The connection to maximal safety decay is the historical origin of the
networking requirement, not a runtime backfill calculation.

## Audited codebases

The findings are pinned to the following revisions:

- [Lighthouse at `b263df596671a2bd42bf1034e1cdc8188ba8a9b0`](https://github.com/sigp/lighthouse/tree/b263df596671a2bd42bf1034e1cdc8188ba8a9b0)
- [Prysm at `462e52404e3965fc0ed4bc1bf7717812d9dd3ef7`](https://github.com/OffchainLabs/prysm/tree/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7)
- [Teku at `3003f5443ac53e53d856978871b951c28805b08b`](https://github.com/Consensys/teku/tree/3003f5443ac53e53d856978871b951c28805b08b)
- [Nimbus at `4110bc7828a45518d22d60e2f60438ae81ff17e9`](https://github.com/status-im/nimbus-eth2/tree/4110bc7828a45518d22d60e2f60438ae81ff17e9)
- [Lodestar at `ec596194e2b909e30e3c6b095fb836427af0c4fb`](https://github.com/ChainSafe/lodestar/tree/ec596194e2b909e30e3c6b095fb836427af0c4fb)
- [Grandine at `eaf220e60699cd63d4223ad2481e42fd15f67802`](https://github.com/grandinetech/grandine/tree/eaf220e60699cd63d4223ad2481e42fd15f67802)

## Summary

| Client | Backfill after checkpoint sync | Default target | Can reach head first? |
| --- | --- | --- | --- |
| Lighthouse | Automatic | Fixed 32,896-epoch startup horizon | Yes |
| Prysm | Disabled by default; `--enable-backfill` | Moving 33,024-epoch horizon | Yes |
| Teku | Automatic | 33,024 epochs in MINIMAL mode; genesis in PRUNE or ARCHIVE | Yes |
| Nimbus | Automatic | Moving 33,024-epoch horizon | Yes |
| Lodestar | Disabled by default | Genesis when enabled | Yes |
| Grandine | Disabled by default; `--back-sync` | Moving configured horizon; genesis in archive mode | Yes |

Three of the six audited implementations automatically backfill the historical
serving window after checkpoint sync. The other three allow a checkpoint-synced
node to operate without automatically acquiring that window.

This does not establish what proportion of live nodes possess the full window.
Nodes that synchronized from genesis or reused an existing database may already
have the history, and this audit does not measure operator flags in the wild.

## Lighthouse

### Default and target

Lighthouse automatically starts reverse backfill after forward range sync has
reached the head. Range sync takes priority and can pause backfill. Lighthouse
treats `BackFillSyncing` as operationally synced and subscribes to core gossip
while the historical download continues.

Sources:

- [Sync-manager scheduling and state transitions](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/network/src/sync/manager.rs#L605-L755)
- [`BackFillSyncing` sync-state semantics](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/common/eth2/src/lighthouse/sync_state.rs#L80-L115)

Its default target is not exactly `MIN_EPOCHS_FOR_BLOCK_REQUESTS`. Lighthouse
calculates:

```text
(MIN_VALIDATOR_WITHDRAWABILITY_DELAY + CHURN_LIMIT_QUOTIENT) / 2
= (256 + 65_536) / 2
= 32_896 epochs
```

The networking calculation is instead:

```text
MIN_VALIDATOR_WITHDRAWABILITY_DELAY + CHURN_LIMIT_QUOTIENT / 2
= 256 + 65_536 / 2
= 33_024 epochs
```

The 128-epoch difference appears to result from parenthesization rather than an
intentional safety margin. Lighthouse fixes the target from the wall-clock
epoch at startup; it does not continuously move the target with the head.

Sources:

- [Backfill target calculation](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/beacon_chain/src/builder.rs#L913-L937)
- [Mainnet chain-spec values](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/consensus/types/src/core/chain_spec.rs#L1062-L1117)

`--genesis-backfill` extends the target to genesis, and archive mode also
enables genesis backfill. There is no ordinary runtime flag that disables the
bounded default backfill. Backfill processing is rate-limited by default to
reduce contention with validator duties.

Sources:

- [`--genesis-backfill`](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/src/cli.rs#L420-L426)
- [Archive-mode configuration](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/src/config.rs#L580-L583)
- [Backfill rate-limiting option](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/src/cli.rs#L510-L517)

### Availability and execution payloads

Lighthouse persists its oldest acquired block and advertises the available
boundary through status v2. Requests below the acquired boundary receive
`ResourceUnavailable` while backfill is incomplete.

Sources:

- [Persisted anchor and oldest block](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/store/src/metadata.rs#L85-L132)
- [Status-v2 earliest available slot](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/network/src/status.rs#L33-L56)
- [Range-request availability check](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/network/src/network_beacon_processor/rpc_methods.rs#L1289-L1308)

Lighthouse prunes execution payload bodies from historical CL storage by
default. Backfilled blocks are stored blinded, and full-block serving asks the
execution client to reconstruct the payload. A missing EL payload can therefore
make the complete signed block unavailable despite the CL having its beacon
block shell.

Sources:

- [Blinded historical import](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/beacon_chain/src/historical_blocks.rs#L145-L157)
- [Payload-pruning default](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/store/src/config.rs#L105-L123)
- [EL payload reconstruction when serving](https://github.com/sigp/lighthouse/blob/b263df596671a2bd42bf1034e1cdc8188ba8a9b0/beacon_node/network/src/network_beacon_processor/rpc_methods.rs#L1142-L1188)

## Prysm

### Default and target

Prysm disables reverse backfill by default. It is enabled with the experimental
`--enable-backfill` flag and only applies to checkpoint-synced nodes. When
enabled, the service waits for forward initial sync to reach the head before it
runs in the background.

Sources:

- [`--enable-backfill`](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/cmd/beacon-chain/sync/backfill/flags/flags.go#L11-L17)
- [Disabled service behavior](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/beacon-chain/sync/backfill/service.go#L253-L270)
- [Waiting for forward sync](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/beacon-chain/sync/backfill/service.go#L290-L338)

When enabled, Prysm uses a moving slot-level window:

```text
[current_slot - 33_024 * SLOTS_PER_EPOCH, current_slot)
```

Queued batches that age outside the moving window can be discarded. An operator
may request older history with `--backfill-oldest-slot`, but cannot use that
option to shorten the mandatory window.

Sources:

- [Mainnet `MIN_EPOCHS_FOR_BLOCK_REQUESTS`](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/config/params/mainnet_config.go#L371-L377)
- [Backfill-window calculation](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/beacon-chain/das/needs.go#L68-L105)
- [Discarding batches outside the moving window](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/beacon-chain/sync/backfill/batcher.go#L19-L58)
- [`--backfill-oldest-slot`](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/cmd/beacon-chain/das/flags/flags.go#L8-L13)

### Pruning and execution payloads

Prysm database pruning is separately opt-in. Its default pruning window is one
epoch longer than the networking value:

```text
MIN_EPOCHS_FOR_BLOCK_REQUESTS + 1 = 33_025 epochs
```

The pruner waits for forward sync and the backfill service before starting. A
disabled backfill service immediately reports completion, so pruning does not
cause reverse backfill to occur.

Sources:

- [Pruning flag](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/cmd/beacon-chain/flags/base.go#L332-L343)
- [Retention margin and sync waiters](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/beacon-chain/db/pruner/pruner.go#L33-L120)

Fresh Prysm databases store blinded blocks unless full execution-payload storage
is explicitly enabled. Backfill uses the same storage path. When serving,
Prysm attempts to reconstruct payloads through the EL and skips blocks it cannot
reconstruct.

Sources:

- [Blinded-storage default](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/beacon-chain/db/kv/kv.go#L355-L407)
- [Backfilled block storage](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/beacon-chain/db/kv/blocks.go#L609-L668)
- [EL reconstruction during range serving](https://github.com/OffchainLabs/prysm/blob/462e52404e3965fc0ed4bc1bf7717812d9dd3ef7/beacon-chain/sync/rpc_beacon_blocks_by_range.go#L160-L216)

## Teku

Teku automatically runs its historical-block sync service after forward sync.
The service only fetches history while the forward-sync state is `IN_SYNC`.

In the default MINIMAL storage mode, the terminal slot is:

```text
start_slot(latest_finalized_epoch - MIN_EPOCHS_FOR_BLOCK_REQUESTS) - 1
```

The extra parent is fetched to validate linkage. MINIMAL pruning keeps the
required epoch boundary inclusively and can remove that extra validation
parent. Teku's PRUNE and ARCHIVE modes fetch blocks to genesis; PRUNE primarily
refers to historical-state pruning rather than bounded block backfill.

Sources:

- [Historical sync scheduling](https://github.com/Consensys/teku/blob/3003f5443ac53e53d856978871b951c28805b08b/beacon/sync/src/main/java/tech/pegasys/teku/beacon/sync/historical/HistoricalBlockSyncService.java#L231-L262)
- [Terminal-slot calculation](https://github.com/Consensys/teku/blob/3003f5443ac53e53d856978871b951c28805b08b/beacon/sync/src/main/java/tech/pegasys/teku/beacon/sync/historical/HistoricalBlockSyncService.java#L209-L223)
- [Block pruning boundary](https://github.com/Consensys/teku/blob/3003f5443ac53e53d856978871b951c28805b08b/storage/src/main/java/tech/pegasys/teku/storage/server/pruner/BlockPruner.java#L90-L114)

Teku tracks its earliest available block, rejects requests below that boundary,
and advertises an earliest-available value through status v2.

Sources:

- [Range-request availability check](https://github.com/Consensys/teku/blob/3003f5443ac53e53d856978871b951c28805b08b/networking/eth2/src/main/java/tech/pegasys/teku/networking/eth2/rpc/beaconchain/methods/BeaconBlocksByRangeMessageHandler.java#L158-L174)
- [Status-message construction](https://github.com/Consensys/teku/blob/3003f5443ac53e53d856978871b951c28805b08b/networking/eth2/src/main/java/tech/pegasys/teku/networking/eth2/rpc/beaconchain/methods/StatusMessageFactory.java#L100-L160)

## Nimbus

Nimbus automatically acquires the historical window through one of two paths.
The `trustedNodeSync` command defaults to REST backfill before beacon-node
startup. Setting `--backfill=false` delays that work, but the ordinary node can
later start P2P reverse backfill once forward sync is within one slot of head.

Sources:

- [`trustedNodeSync` backfill option](https://github.com/status-im/nimbus-eth2/blob/4110bc7828a45518d22d60e2f60438ae81ff17e9/beacon_chain/conf.nim#L922-L925)
- [Trusted-node REST backfill loop](https://github.com/status-im/nimbus-eth2/blob/4110bc7828a45518d22d60e2f60438ae81ff17e9/beacon_chain/trusted_node_sync.nim#L440-L558)
- [P2P backfill scheduling](https://github.com/status-im/nimbus-eth2/blob/4110bc7828a45518d22d60e2f60438ae81ff17e9/beacon_chain/sync/sync_overseer.nim#L395-L423)

Its inclusive target is approximately:

```text
min(finalized_head_slot, head_slot - N * SLOTS_PER_EPOCH)
```

where mainnet configures `N = 33_024`. The cursor moves as backfill proceeds.
Requests below the acquired cursor receive `ResourceUnavailable`. Default
pruning trails the desired horizon by a 32-epoch state-snapshot interval, so a
steady-state pruned node generally retains approximately `N + 32` epochs.

Sources:

- [Backfill horizon](https://github.com/status-im/nimbus-eth2/blob/4110bc7828a45518d22d60e2f60438ae81ff17e9/beacon_chain/consensus_object_pools/block_pools_types.nim#L442-L450)
- [Mainnet preset](https://github.com/status-im/nimbus-eth2/blob/4110bc7828a45518d22d60e2f60438ae81ff17e9/beacon_chain/spec/presets.nim#L378-L388)
- [Range serving and availability checks](https://github.com/status-im/nimbus-eth2/blob/4110bc7828a45518d22d60e2f60438ae81ff17e9/beacon_chain/sync/sync_protocol.nim#L295-L345)
- [Pruning behavior](https://github.com/status-im/nimbus-eth2/blob/4110bc7828a45518d22d60e2f60438ae81ff17e9/beacon_chain/consensus_object_pools/blockchain_dag.nim#L2390-L2428)

## Lodestar

Lodestar disables reverse backfill by default:

```text
backfillBatchSize = 0
```

The corresponding CLI option is hidden. When enabled, backfill runs separately
from ordinary forward synchronization and follows parent links to genesis. It
does not stop at the 33,024-epoch networking boundary.

Sources:

- [Default sync options](https://github.com/ChainSafe/lodestar/blob/ec596194e2b909e30e3c6b095fb836427af0c4fb/packages/beacon-node/src/sync/options.ts#L19-L44)
- [Hidden CLI option](https://github.com/ChainSafe/lodestar/blob/ec596194e2b909e30e3c6b095fb836427af0c4fb/packages/cli/src/options/beaconNodeOptions/sync.ts#L58-L64)
- [Backfill construction](https://github.com/ChainSafe/lodestar/blob/ec596194e2b909e30e3c6b095fb836427af0c4fb/packages/beacon-node/src/node/nodejs.ts#L280-L303)
- [Genesis completion condition](https://github.com/ChainSafe/lodestar/blob/ec596194e2b909e30e3c6b095fb836427af0c4fb/packages/beacon-node/src/sync/backfill/backfill.ts#L284-L405)

History pruning is also disabled by default. If enabled, it deletes blocks
strictly before:

```text
min(current_epoch - MIN_EPOCHS_FOR_BLOCK_REQUESTS, finalized_epoch)
```

Consequently, optional genesis backfill can download blocks that optional
history pruning later removes.

Source:

- [History pruning](https://github.com/ChainSafe/lodestar/blob/ec596194e2b909e30e3c6b095fb836427af0c4fb/packages/beacon-node/src/chain/archiveStore/utils/pruneHistory.ts#L8-L49)

## Grandine

Grandine disables historical back-sync by default. With `--back-sync`, standard
storage targets the configured block-serving boundary, while archive storage
targets genesis.

Sources:

- [`--back-sync` behavior](https://github.com/grandinetech/grandine/blob/eaf220e60699cd63d4223ad2481e42fd15f67802/runtime/src/grandine_args.rs#L419-L429)
- [Initial target selection](https://github.com/grandinetech/grandine/blob/eaf220e60699cd63d4223ad2481e42fd15f67802/p2p/src/block_sync_service.rs#L152-L204)

In standard mode, completion is dynamically checked against:

```text
start_slot(current_epoch - min_epochs_for_block_requests())
```

Grandine forward-syncs first and then switches to reverse sync. It subscribes to
core gossip after forward sync, although its HTTP syncing endpoint continues to
report syncing until reverse sync completes. It advertises the moving backfill
cursor as its earliest available slot.

Sources:

- [Standard-mode completion boundary](https://github.com/grandinetech/grandine/blob/eaf220e60699cd63d4223ad2481e42fd15f67802/p2p/src/back_sync.rs#L99-L123)
- [Configured serving-boundary helper](https://github.com/grandinetech/grandine/blob/eaf220e60699cd63d4223ad2481e42fd15f67802/helper_functions/src/misc.rs#L724-L731)
- [Forward-to-reverse direction switch](https://github.com/grandinetech/grandine/blob/eaf220e60699cd63d4223ad2481e42fd15f67802/p2p/src/block_sync_service.rs#L1517-L1542)
- [HTTP syncing status](https://github.com/grandinetech/grandine/blob/eaf220e60699cd63d4223ad2481e42fd15f67802/http_api/src/standard.rs#L2634-L2673)
- [Earliest-slot advertisement](https://github.com/grandinetech/grandine/blob/eaf220e60699cd63d4223ad2481e42fd15f67802/p2p/src/block_sync_service.rs#L292-L303)

Standard pruning deletes blocks strictly below the same computed boundary, so
the required window survives. Backfill obtains one additional parent for
validation; that parent can subsequently be pruned.

Sources:

- [Extra validation parent](https://github.com/grandinetech/grandine/blob/eaf220e60699cd63d4223ad2481e42fd15f67802/p2p/src/block_sync_service.rs#L1038-L1052)
- [Pruning boundary](https://github.com/grandinetech/grandine/blob/eaf220e60699cd63d4223ad2481e42fd15f67802/fork_choice_control/src/mutator.rs#L3620-L3678)

## Implications for the retention-window EIP

### The backfill cost is real but not universal

The current window creates an automatic checkpoint-sync cost in Lighthouse,
Teku, and Nimbus. It creates an opt-in cost in Prysm and standard-mode Grandine.
Lodestar's optional backfill goes to genesis and therefore does not directly
implement the networking window.

The EIP should not state that every checkpoint-synced node currently downloads
five months of history. More precise wording is:

> To satisfy the mandatory block-serving window, a checkpoint-synced client
> must acquire the corresponding historical blocks. Client implementations
> differ: some perform this backfill automatically, while others disable it by
> default or backfill to a different boundary.

### Changing the configured value will not affect every client identically

Reducing the configured window to 8,192 epochs would directly reduce bounded
backfill in Teku, Nimbus, Prysm when enabled, and standard-mode Grandine when
enabled. Additional client changes would be needed for consistent behavior:

- Lighthouse should replace its independent 32,896-epoch expression with the
  configured value.
- Lodestar would need a bounded backfill mode if it is expected to acquire the
  mandatory serving window rather than either skipping backfill or going to
  genesis.

### CL and EL retention must be aligned

Historical beacon-block availability is not necessarily self-contained in the
CL. Lighthouse and Prysm default to blinded historical storage and depend on
the EL to reconstruct execution payloads when serving full signed blocks.
Reducing or defining the CL block-serving window without ensuring compatible EL
payload retention can leave peers unable to obtain complete signed beacon
blocks even when the CL retains their beacon block shells.

## Limitations

This is a source-code audit, not a measurement of live operator behavior. It
does not establish:

- how many operators enable optional backfill or pruning flags;
- how many nodes were initialized by checkpoint sync rather than genesis sync;
- how much history existing databases already contain; or
- whether paired execution clients can reconstruct every retained historical
  payload.

Client behavior may change after the pinned revisions above. Any normative EIP
claim should be based on protocol requirements, with these implementation
findings used to describe current operational impact.
