# Sync Committees: Structure, Lifetimes, and Deterministic Aggregator Selection

**Summary.** Sync committee aggregators are self-selected today, via a BLS
selection proof. Replacing that with a deterministic function of state is clean
and well-precedented: FOCIL already selects a 16-member committee this way for a
duty carrying more consensus weight (§6). But the proof buys two properties, not
one. Proposer-independence is cheap to give up here (§7.1, §7.3). Secrecy is not
clearly cheap: it currently protects light clients against a halt costing an
attacker 256 targeted nodes, which this proposal would reduce to 32 (§7.2). That
8x is unmeasured, and §9 argues the construct may not survive SNARK-verifiable
consensus at all. No recommendation is reached here. The aim is to isolate the
one number that would produce one.

---

## 1. What the sync committee is for

The sync committee exists to serve **light clients**. A light client wants to
follow the chain head without tracking the full validator set, which at ~1M
validators means ~48 MB of pubkeys plus the shuffling logic to know who is
supposed to be attesting.

Instead, the protocol nominates 512 validators for an extended period and has
them sign the head every slot. A light client tracks those 512 pubkeys, refreshes
them once per period, and verifies a single aggregated signature per block.

The output is one field in the beacon block:

```python
class SyncAggregate:
    sync_committee_bits: Bitvector[SYNC_COMMITTEE_SIZE]   # 512 bits
    sync_committee_signature: BLSSignature                # 96 bytes
```

**The sync committee carries no consensus weight.** Fork choice does not read it.
Finality does not depend on it. It is a light-client convenience with an
attached reward. That framing drives much of the analysis below, but §7.2 marks
where it stops holding: no consensus weight is not the same as no consequence.

---

## 2. Structure

| Parameter | Value | Notes |
|---|---|---|
| `SYNC_COMMITTEE_SIZE` | 512 | validators per committee |
| `SYNC_COMMITTEE_SUBNET_COUNT` | 4 | gossip subnets |
| Subcommittee size | 128 | 512 / 4 |
| `TARGET_AGGREGATORS_PER_SYNC_SUBCOMMITTEE` | 16 | aggregators per subnet |
| `EPOCHS_PER_SYNC_COMMITTEE_PERIOD` | 256 | ~27.3 hours |
| `SYNC_REWARD_WEIGHT` | 2 (of 64) | share of total issuance |

The committee is split across four gossip subnets purely for bandwidth. Each
subnet carries the raw messages from its 128 members; aggregation folds each
subnet into one contribution before anything reaches the global topic.

---

## 3. Lifetimes

Three distinct clocks operate here, and conflating them causes confusion.

### 3.1 Committee period: 256 epochs (~27.3 hours)

Membership is fixed for the whole period. State holds two committees at once:

```python
class BeaconState:
    ...
    current_sync_committee: SyncCommittee
    next_sync_committee: SyncCommittee
```

At each period boundary, `process_sync_committee_updates` rotates `next` into
`current` and computes a fresh `next`.

The consequence: **membership is known ~27 hours in advance.** This is by far the
longest lookahead anywhere in the protocol, and it is deliberate: light clients
need the next committee's pubkeys before the handover so they can verify across
the boundary without a trusted update.

### 3.2 Duty cadence: every slot

Unlike attestation duty, which fires once per epoch, sync duty fires **every
slot** for the entire period. A member signs 8192 times across its term.

### 3.3 Selection lookahead: how far ahead each thing is knowable

| Selection | Known in advance |
|---|---|
| Sync committee membership (512) | ~27 hours |
| Beacon proposer | ~6.4 min (one epoch) |
| Attestation committee assignment | 1–2 epochs |
| Sync aggregators (today, self-selected) | **zero**, revealed on publish |

The last row is the property the rest of this document examines.

---

## 4. Membership selection

Membership is already derived from RANDAO. `get_next_sync_committee` seeds from
`get_seed(state, epoch + 1, DOMAIN_SYNC_COMMITTEE)` and performs
effective-balance-weighted rejection sampling over the active validator set:

```python
# Electra: 16-bit random value, since MAX_EFFECTIVE_BALANCE_ELECTRA is 2048 ETH
random_value = bytes_to_uint64(hash(seed + uint_to_bytes(uint64(i // 16)))[...])
if effective_balance * MAX_RANDOM_VALUE >= MAX_EFFECTIVE_BALANCE_ELECTRA * random_value:
    sync_committee_indices.append(candidate_index)
```

Two consequences worth noting:

**Duplicates are permitted but do not occur at mainnet scale.** The spec
docstring says "with possible duplicates," and the validator spec accordingly
handles a validator holding several positions. The mechanism is the
`i % active_validator_count` wraparound: `compute_shuffled_index` is a bijection,
so within a single pass every candidate is distinct, and a validator can repeat
only once the loop walks past the end of the active set. Expected iterations are
`512 * MAX_EFFECTIVE_BALANCE_ELECTRA / E[eb]`, so wraparound requires a total
effective balance below `512 * 2048 = 1,048,576` ETH. Mainnet sits roughly 33x
above that, so committees hold 512 distinct validators.

Note the cause is network size, not balance: a high effective balance raises
acceptance *probability*, not multiplicity. Gloas refactors this loop into
`compute_balance_weighted_selection` with the same `i % total` structure, so the
property is unchanged there.

**Membership inherits RANDAO's tail-slot bias.** A proposer controlling `k` slots
at the end of the epoch preceding a period boundary has `2^k` choices over the
entire next committee. Sync slots pay a predictable lump over 27 hours, so the
payoff is easy to read off in advance. A proposal slot's payoff is probabilistic
but, once MEV is counted, of comparable expected value with a much fatter tail.
So this is a legible manipulation target, not obviously a more attractive one
than proposer selection.

---

## 5. Aggregation, and the selection proof

### 5.1 The slot pipeline

Timings below are the current mainnet values: `SYNC_MESSAGE_DUE_BPS` is 3333 and
`CONTRIBUTION_DUE_BPS` is 6667 basis points of `SLOT_DURATION_MS = 12000`. Gloas
moves these to 2500 and 5000, making the same steps 3s and 6s.

**t ≈ 4s, members sign.** Each of the 512 signs `beacon_block_root` under
`DOMAIN_SYNC_COMMITTEE` and publishes to `sync_committee_{subnet}`. One signature
value regardless of position count, rebroadcast once per distinct subnet the
validator occupies.

**The lottery.** Separately, each member signs:

```python
class SyncAggregatorSelectionData:
    slot: Slot
    subcommittee_index: uint64
```

under `DOMAIN_SYNC_COMMITTEE_SELECTION_PROOF`, then checks:

```python
modulo = max(1, SYNC_COMMITTEE_SIZE // SYNC_COMMITTEE_SUBNET_COUNT
                // TARGET_AGGREGATORS_PER_SYNC_SUBCOMMITTEE)   # 128 // 16 = 8
return bytes_to_uint64(hash(selection_proof)[0:8]) % modulo == 0
```

~1 in 8 wins, giving ~16 aggregators per subnet and ~64 network-wide per slot.
Note the input is a **tuple**, so a validator in multiple subnets draws
independently per subnet. Per §4 that case does not arise at mainnet scale; the
tuple indexing exists to keep the degenerate case well-defined.

**t ≈ 8s, aggregators publish.** Winners fold their subnet's messages:

```python
class SyncCommitteeContribution:
    slot: Slot
    beacon_block_root: Root
    subcommittee_index: uint64
    aggregation_bits: Bitvector[128]
    signature: BLSSignature
```

wrapped and signed under `DOMAIN_CONTRIBUTION_AND_PROOF`:

```python
class ContributionAndProof:
    aggregator_index: ValidatorIndex
    contribution: SyncCommitteeContribution
    selection_proof: BLSSignature
```

published to the global `sync_committee_contribution_and_proof` topic.

**Slot N+1, the proposer merges.** Best contribution per subnet, four 128-bit
vectors concatenated into `Bitvector[512]`, four signatures aggregated into one.

### 5.2 What the aggregator subset buys

- **Bandwidth.** Fan-in happens on subnets. Only ~64 contributions cross the
  global topic instead of 512 raw messages.
- **Availability.** All 16 aggregators fold the same subnet's messages, so any
  single survivor produces a usable contribution. Losing a subnet outright
  requires all 16 to fail or censor.
- **Coverage.** Aggregators do not observe identical gossip subsets. The proposer
  takes a max over independent views, so late messages get picked up by whichever
  aggregator happened to hear them.

Availability and coverage trade against each other, and the analysis in §7
inherits the weaker one. A single surviving aggregator yields *a* contribution, not
necessarily the *best* one: the proposer's max over independent views is exactly
what suppressing the other 15 destroys. Availability degrades gracefully under
suppression; coverage does not.

### 5.3 What the selection *proof* buys

The proof supplies three properties simultaneously:

| Property | Source |
|---|---|
| Unbiasable by anyone, proposers included | BLS signature uniqueness: one possible value, no retrying into a win |
| Private until published | Derived from a secret key; nobody can compute your ticket |
| Publicly verifiable | Any peer recomputes the hash; no dealer, no extra round |

---

## 6. Deterministic selection

### 6.1 The construction

Replace self-selection with a pure function of state:

```python
def get_sync_aggregators(state, slot, subcommittee_index):
    seed = hash(get_seed(state, compute_epoch_at_slot(slot),
                         DOMAIN_SYNC_COMMITTEE_AGGREGATOR)
                + uint_to_bytes(slot)
                + uint_to_bytes(subcommittee_index))
    subcommittee = get_sync_subcommittee(state, subcommittee_index)  # 128 members
    return [
        subcommittee[compute_shuffled_index(Uint64(i), Uint64(len(subcommittee)), seed)]
        for i in range(TARGET_AGGREGATORS_PER_SYNC_SUBCOMMITTEE)
    ]
```

The seed must come from `get_seed`, not from `get_randao_mix(state,
get_current_epoch(state))`. `process_randao` rewrites the current epoch's mix on
*every block*, so that mix is not fixed at epoch start. Deriving from it would
make the aggregator set change every slot, leave nothing to schedule in advance,
hand every proposer rather than only tail-slot proposers a grinding handle on the
following slots, and, worst, make the set a function of the head block, so nodes
on competing forks would derive different aggregator sets and gossip validation
would diverge during a reorg. `get_seed` reads the mix from
`epoch - MIN_SEED_LOOKAHEAD - 1`, which is stable for the whole epoch and yields
exactly the one-epoch lookahead §7 prices. It also supplies domain separation,
which a bare `hash(mix + slot + index)` does not.

The selection is a fixed-size prefix of a shuffling, which is the existing spec
idiom rather than a new primitive: `compute_committee` derives every beacon
committee the same way. Because `compute_shuffled_index` is a bijection over the
subcommittee, the prefix is without replacement by construction, so no separate
sampling function is needed. The cost profile is the one `compute_committee`
already accepts, namely a full `compute_shuffled_permutation` over 128 elements
for a 16-element answer.

Every node derives the same set. Gossip validation becomes a hash and a
membership check. Removed from the spec:

- `DOMAIN_SYNC_COMMITTEE_SELECTION_PROOF`
- `SyncAggregatorSelectionData`
- `get_sync_committee_selection_proof`
- the `selection_proof` field of `ContributionAndProof`

Added in exchange: one domain constant, `DOMAIN_SYNC_COMMITTEE_AGGREGATOR`. FOCIL
needs no equivalent because it reuses the attester shuffling wholesale; see §6.3.

*Open:* this domain is avoidable. Hashing `get_seed(state, epoch,
DOMAIN_SYNC_COMMITTEE)` together with `slot` and `subcommittee_index` already
separates the aggregator value from the membership seed, which is derived at a
different epoch and with neither of those inputs, so the design could reuse the
existing domain and add no constants at all, matching FOCIL exactly. The argument
for keeping a fresh domain is only that separation-by-extra-hash-inputs is the
kind of thing reviewers relitigate, and a domain constant is one line. Not
decided here.

`TARGET_AGGREGATORS_PER_SYNC_SUBCOMMITTEE` survives, with its meaning changed
from an expected count to an exact one. That is a small improvement in its own
right: the per-subnet aggregator count stops being `Binomial(128, 1/8)` and
becomes exactly 16, removing the low tail.

### 6.2 Which properties come free

Two of the three properties in §5.3 come **free** from the protocol computing the
selection. Public verifiability is trivial, since every node recomputes the same
function. Unbiasability *by the selected validator* is likewise trivial, since
the validator supplies no input to its own selection.

The third does not come free, and neither does the rest of the second.
State-derived selection is unbiasable by the selectee but **biasable by RANDAO
contributors**, whereas the BLS proof is unbiasable by everyone, proposers
included. So the selection proof buys two things, not one: **secrecy**, and
**proposer-independence**. §7.1 prices the first and §7.3 prices the second. The
case for removing the proof is that neither is worth its cost *here*, not that
only one of them exists.

### 6.3 Precedent

This is not exotic, and there is now a much closer precedent than proposer
selection.

FOCIL's `get_inclusion_list_committee` (EIP-7805, specced for Heze) is a pure
function of state, derived from the beacon committees and therefore publicly
computable an epoch ahead, with `INCLUSION_LIST_COMMITTEE_SIZE = 16`. That is the
same committee size as sync aggregators, known on the same lookahead, for a duty
that is **fork-choice enforced** and so carries strictly more consensus weight
than sync aggregation. The protocol is already accepting deterministic,
publicly-known, 16-member committee selection at higher stakes than this proposal
asks for.

The parallel is structural as well as rhetorical: both designs are a fixed-size
prefix of a state-derived shuffling. They diverge in one place, and the reason is
worth stating. FOCIL introduces no randomness of its own, because the attester
shuffling already partitions validators across the slots of an epoch, so
`get_beacon_committee(state, slot, index)` varies per slot for free and the
committee is just its prefix. Sync subcommittees are fixed for the whole 27-hour
period, so there is no existing per-slot ordering to take a prefix of. Hence the
explicit `slot` in the seed above.

That rotation is not optional, though its absence costs an epoch rather than a
period. `get_seed` already advances once per epoch, so dropping `slot` would fix
the 16 aggregators for 32 consecutive slots, not for the full 27 hours; the
period fixes the 128-member pool, not the draw from it. Even so, an epoch-fixed
set means one strike against 16 nodes suppresses a subnet for a whole epoch,
whereas per-slot rotation forces an attacker to cover the union of 32 independent
draws of 16 from 128, roughly 126 members. That difference is what keeps the
two-subnet light client halt in §7.2 expensive.

`get_beacon_proposer_index` is the older form of the same argument: a pure
function of RANDAO and the active set, publicly computable an epoch ahead, with
the resulting DoS exposure accepted. Deterministic aggregators are the same trade
at substantially lower stakes than either.

---

## 7. Trade-off analysis

### 7.1 Cost: ~6.4 minutes of warning

`get_seed` reads the RANDAO mix from `epoch - MIN_SEED_LOOKAHEAD - 1`, which is
settled before the epoch begins, so aggregator sets become computable one epoch
ahead. An attacker faces 16 named targets per subnet instead of 128 anonymous
candidates, roughly an **8x cheaper** targeting problem.

Three attack shapes open up:

- **DoS** the winners shortly before their slot
- **Bribery** to omit specific participants from `aggregation_bits`
- **Deanonymization** over time, since a validator publishing in predictable
  slots is easier to map to an IP than one surfacing at random

All three bottleneck on validator-index-to-IP mapping, which is hard but not
impossible, and is the same bottleneck that already applies to proposers.

Note also that aggregating carries **no protocol reward**. `process_sync_aggregate`
pays the 512 participants and the block proposer; the aggregator is paid nothing
for aggregating. There is no rent to extract from the role, which weakens the
bribery case above and, in §7.3, the case for grinding into it.

TODO: are the aggregators chosen from the sync committee or the larger set?

### 7.2 Why it is mostly tolerable, and where it is not

**Redundancy is forgiving.** All 16 aggregators fold the same subnet's messages,
so one survivor still publishes a usable contribution. A bribed aggregator
accomplishes nothing while an honest one remains. Per §5.2 the survivor's
contribution need not be the *best* one, so what redundancy protects is
availability rather than completeness.

**The per-slot economic cost is small, but it is a penalty, not a shortfall.**
`process_sync_aggregate` applies `decrease_balance(state, participant_index,
participant_reward)` to non-participants. Suppressing a subnet therefore costs
its 128 members a 2x swing rather than a foregone reward, and costs the proposer
its share as well. Small in absolute terms, but not free.

**The real ceiling is the light client protocol, and §7.1's 8x applies to it
directly.** This is the strongest argument against the proposal and it deserves
stating plainly. Light clients have hard participation thresholds:

- `process_light_client_update` requires
  `get_set_bit_count(bits) * 3 >= len(bits) * 2`, so at least 342 of 512, to
  advance the finalized header.
- `get_safety_threshold` is `max_active_participants // 2`, so more than 256, to
  advance the optimistic header.

Killing one subnet leaves 384 bits set and both thresholds still pass. Killing
**two** leaves 256 and both fail: light clients stop advancing entirely. Under
deterministic selection that costs 32 targeted nodes, where today it costs 256.
So the 8x is not 8x on a rounding error in rewards, it is 8x on a liveness attack
against precisely the constituency the sync committee exists to serve.

The usual rebuttal, that fork choice does not read sync data and so finality is
untouched, is true but answers the wrong question. Nobody claims sync affects
finality. The claim that has to be defended is that cheaper suppression does not
harm light clients, and on the numbers above it does. Whether an 8x reduction in
the cost of a temporary light client halt is acceptable is a judgement call, but
it should be made explicitly rather than assumed away. It is also where the
contrast drawn in §7.5 narrows: the difference from the attestation case is one
of degree in the consequence, not a clean absence of consequence.

### 7.3 Cost: compounded RANDAO bias

Tail-slot proposers already get `2^k` choices over sync committee *membership*.
Deterministic aggregator selection extends the same channel to who aggregates
within the committee.

This is a deepening of an existing coupling, not a new one. The marginal prize,
16 aggregator slots for one slot, is negligible against the committee membership
already at stake, and per §7.1 the role pays nothing, so a grinder optimising
tail slots would not spend them here. But "the prize is currently too small to
bother" is a weaker guarantee than "structurally impossible," and should be
recorded as such.

EIP-8321 does not close this channel. Its hash-chain reveal is unique given the
registered commitment, so a proposer still cannot grind its own contribution to
the mix, exactly as under BLS. What that scheme never prevented, and still does
not, is *withholding*: a proposer that declines to propose gets the same `2^k`
choice. The tail-slot analysis above therefore survives the post-quantum RANDAO
change unchanged.

### 7.4 Benefit: attributable non-performance, and cheaper gossip

Under self-selection, a validator that lost the lottery is indistinguishable from
one that won and stayed silent. Deterministic selection makes aggregation duty
**measurable**, enabling monitoring and, if desired, penalties. This is an
improvement independent of any other motivation.

It is also cheaper on the wire.
`validate_sync_committee_contribution_and_proof_gossip` currently performs a full
BLS verification of the selection proof against the derived
`SyncAggregatorSelectionData`, on top of the outer signature and the
contribution's own aggregate. Deterministic selection replaces that verification
with a hash and a membership check, dropping one of three BLS verifications per
contribution message (roughly 64 per slot network-wide) and 96 bytes from every
such message.

### 7.5 Where the same trade fails

Attestation aggregators (`DOMAIN_SELECTION_PROOF`) carry consensus votes.
Suppressing them keeps attestations off-chain, drops participation, and with
enough slots can stall finality. Identical 8x targeting improvement, vastly
higher payoff.

**Conclusion.** On the attestation side, both properties the proof buys are
clearly worth their cost. On the sync side the answer splits.
Proposer-independence is cheap to give up: the role pays nothing and the marginal
grinding prize is negligible (§7.1, §7.3). Secrecy is the contested half. §7.2
shows it currently protects against a light client halt that costs 256 targeted
nodes and would cost 32 under this proposal. Whether that 8x is acceptable is the
one thing this document cannot settle by argument; appendix item 3 names the
measurement that would.

---

## 8. Post-quantum motivation

The transition supplies an independent reason to revisit this.

Self-selection's unbiasability rests on BLS signature uniqueness. Hash-based
signature schemes using target-sum encoding are **not unique**: the signer grinds
a randomizer `r` in `H(r, m)` to hit the encoding's target sum, so many valid
signatures exist for one message. A validator could grind its way into the
aggregator set, and cheaply, since satisfying a 1-in-8 predicate on top of the
target sum costs roughly 8x the normal signing search.

This is not a hypothetical worry about the encoding. EIP-8321 replaces the
BLS-signature RANDAO reveal for exactly this reason and says so directly: RANDAO
grinding resistance "relies on BLS signatures being *unique*," and a hash chain
substitutes collision resistance for that uniqueness and preimage resistance for
the unpredictability. Sync self-selection rests on the same property and loses it
at the same moment.

Preserving self-selection after BLS therefore requires replacing the signature
with a commit-reveal primitive: a value committed on-chain, opened once per use,
unpredictable to everyone else until opened. Binding comes from collision
resistance, hiding from preimage resistance.

The cheap construction is EIP-8321's: a hash chain, one 32-byte reveal per use
and one 32-byte word of state per validator. Sync aggregation duty is per-slot
and sequential, so a chain fits it directly, one link per slot. The
index-addressable variant, a Merkle tree over `PRF(seed, index)` at roughly 700
bytes of authentication path per proof, is only needed if links must be opened
out of order, which a per-slot duty does not require. Any argument that
commit-reveal is too expensive here should be made against the 32-byte chain, not
the 700-byte tree.

The remaining problems are real, but mostly not differential:

- **Exhaustion.** The chain or tree is finite. Running past the last link
  silently disables aggregation. EIP-8321 hits this too and answers with
  "obtain a new validator index," while explicitly leaving open how to push
  already-onboarded validators onto a fresh commitment. Exhaustion is thus a
  property of the whole post-quantum commit-reveal family, not a cost specific to
  preserving self-selection.
- **DVT.** Threshold BLS works because the scheme is *linear*: Lagrange
  interpolation over partial signatures yields the group signature with no
  operator holding the key. Hash chains and PRFs offer no comparable structure,
  so clusters would need a post-quantum threshold construction or a DKG-style
  ceremony over a shared root. This too is not specific to selection proofs.
  Post-quantum threshold signing is already an open problem for a cluster's
  *main* signing key, so solving it is a precondition for post-quantum DVT
  generally rather than an extra bill this design incurs.

What deterministic selection genuinely avoids is a *second* commitment to
provision, exhaust, and split across operators, on top of whatever the main
signing key already demands. That is a real saving, but a narrower one than
"avoids all of this."

---

## 9. The prior question

Everything above assumes sync committees survive.

Their entire purpose is to let light clients follow the chain without tracking
the validator set. If consensus becomes SNARK-verifiable, a light client
verifies the proof directly and the construct has no job. Deleting it removes:

- three validator duties: the sync committee message, the sync selection proof,
  and the `SignedContributionAndProof` broadcast
- `SyncCommittee`, `SyncAggregate`, `SyncCommitteeContribution`
- `current_sync_committee` and `next_sync_committee` from state
- `get_next_sync_committee`, `process_sync_aggregate`,
  `process_sync_committee_updates`
- five gossip topics
- `SYNC_REWARD_WEIGHT` and its share of issuance
- the 27-hour lookahead handing attackers 512 known identities per period

Note that this also dissolves §7.2's objection. The cost of cheaper aggregator
suppression is entirely a cost to light clients; if light clients no longer
depend on the sync committee, there is nothing left to protect and the secrecy
property has no remaining buyer. The two questions are therefore not independent,
and §7.2 is the reason to resolve this one first.

The blocker is not proof size. It is **liveness**. 512 validators signing every
slot is an extraordinarily robust availability story; replacing it with a proof
someone must compute is a regression unless the prover set is designed with
comparable fault tolerance. That is the same problem the execution-layer zkEVM
work is addressing, and it is the question to resolve before investing further
in either the deterministic selection design or a post-quantum port of the
existing one.

---

## Appendix: open questions

1. **Seed grinding at registration.** For any commitment-based scheme, nothing
   prevents grinding the seed pre-commitment to bias which indices win. This
   applies to BLS today (grind `sk` so `hash(sign(sk, slot))` wins often) and is
   blunted because committee assignments depend on RANDAO unpredictable at
   deposit time. But hash-chain and PRF evaluation are far cheaper than BLS
   signing, so the search gets cheaper without getting qualitatively easier.

   EIP-8321 already specifies an answer: `COMMITMENT_REGISTRATION_DELAY = 3`,
   required to be at least `MIN_SEED_LOOKAHEAD + 2` "so that a registrant cannot
   know whether it proposes in the activation epoch at the time its registration
   is included." A registration delay is simpler than deriving the effective seed
   as `H(s, deposit_randao_mix)`, and it needs no change to the deposit flow,
   which EIP-8321 notes is unavailable because the deposit contract's fields are
   fixed. What remains open is only whether the same delay is sized correctly for
   a duty selected per-slot rather than per-proposal.

2. **Does DVT tooling actually run a per-slot signing round for sync selection
   proofs?** The spec requires the selection proof to be a valid threshold
   signature under the cluster's group key, but whether Obol/SSV run a full round
   for a ticket that usually loses, or batch it with other duties, is an
   implementation question not settled here.

3. **Empirical DoS resistance.** Whether 16-way redundancy absorbs targeted DoS
   better than secrecy does has not, as far as I can tell, been measured. The
   specific quantity §7.2 turns on: how reliably can an attacker who knows 32
   validator indices an epoch ahead actually suppress two full subnets for the
   slots it needs, given that the mapping to IPs is the binding constraint. This
   is the number that would settle §7 rather than argue it.

4. **Vestigial duplicate handling.** Per §4, sync committee duplicates require
   the selection loop to wrap past the active validator set, which does not
   happen at mainnet scale. The tuple-indexed selection proof, the deduplicating
   `compute_subnets_for_sync_committee`, and the repeated-signature handling in
   contribution aggregation therefore all exist to keep a devnet-scale degenerate
   case well-defined. Whether that machinery is worth keeping is separate from
   this proposal, but deterministic selection would inherit it, so it is worth
   deciding at the same time.