---
title: Post-Quantum Meta
description: List of EIPs for moving validator authentication from BLS to post-quantum signatures
author: Kevaundray Wedderburn (@kevaundray)
discussions-to:
status: Draft
type: Meta
created: 2026-08-26
requires: 6110, 7002, 7251, 7685, 7732, 8015, 8282, 8321
---

## Abstract

This Meta EIP bundles the changes that move the consensus layer away from
BLS. Concretely, the beacon chain will stop using BLS signatures
in place of hash-based signatures. Since we cannot stop the chain while this
process happens, it will be done in two phases.

Currently out of scope:

- Blob commitments and data availability sampling rely on BLS12-381 pairings as well,
however they have not been specified in this meta EIP. This will be revised.
- Withdrawal credentials live on the EL, however if the CL is PQ ready but the EL is not,
then all validator collateral will be at stake since 7002 is how validators exit.

## Motivation

A cryptographically relevant quantum computer breaks BLS12-381. This is the elliptic
curve that the safety of the consensus layer relies on; every way a validator proves
anything to the protocol today relies on a BLS signature.

Rough speaking, the signature usages fall into two categories.

Signatures that guard stake, where a forgery moves funds or changes who is a
validator:

- validator registration and exits (including voluntary exits)
- builder registration and exit
- withdrawal credential changes (upgrading a 0x00 validator)

Signatures that perform duties, where a forgery could attack liveness or
finality:

- attestations
- block proposals
- RANDAO reveals
- aggregator selection proofs (a verifiable random function)
- builder bids
- ptc and proposer preferences under [EIP-7732](./eip-7732.md)
- sync committee messages
- slashing evidence, which re-verifies the signatures of the messages it cites
- authentication of every signed gossip message

We also note the transport layer's secp256k1 peer
identities and X25519 key agreement are not post-quantum either.

Replacing the attestation signature is the well known part of upgrading the CL to PQ;
the rest are smaller mechanisms that sometimes lean on properties of BLS beyond
unforgeability. The table indexes the transition by those properties, since
each one explains the shape of its replacement.

| BLS property | Used for | Without it | Replace with |
| - | - | - | - |
| Signature aggregation: signatures add | attestations, the sync aggregate, [EIP-7732](./eip-7732.md) payload attestations | we need to concatenate signatures: tens of thousands of kilobyte-size votes per slot | succinct proofs over batches of signatures, which puts a prover on the critical path |
| Uniqueness: one valid signature per key and message, a VRF | RANDAO reveals, aggregator selection proofs | randomness and selection lotteries become grindable | commitments registered in advance: a hash chain for randomness, merkle proofs for selection proofs or we make aggregator selection depend on randao |
| Proof of possession | the deposit signature's rogue-key defense | hash-based keys need no proof of possession; the deposit signature survives only to bind the key to withdrawal credentials | nothing |
| Statelessness: a key signs anything and is not bounded | every duty, every signed gossip message | - | stateful signatures where one needs to ensure they don't use the same subkey more than once |
| Linearity | distributed validator clusters | currently no threshold scheme exists for stateful hash-based signatures | nothing yet; one key per operator |

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in
[RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and
[RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

### Transition at a glance

Since we want to uphold liveness, the ordering is fixed; a validator cannot use a pq key until
it has registered one and the protocol cannot stop accepting BLS until enough active validators
hold the necessary pq material their duties need (this is more than a pq key).

So validators register the post-quantum material required for consensus while
BLS remains the signature scheme for validator duties.
Once enough active stake is ready, a single hard fork switches every consensus duty
to the post-quantum protocol.

In this design, there is no mixed BLS/post-quantum attestations to reduce complexity.

| Stage | Validator duties | Validator entry | Purpose |
| - | - | - | - |
| Today | BLS | BLS | current protocol |
| Phase 1: preparation | BLS | BLS | make the validator set post-quantum-ready by register PQ credentials on the CL |
| Phase 2: cutover | post-quantum only | PQ deposit contract | switch CL to use PQ, close BLS registrations, retire BLS paths |

Note: we can derisk this further by incrementally converting components on the CL.
The attestations are the highest risk components, however with decoupled consensus
we can afford finalization time to be slowed down, without affecting liveness.

### Target post-quantum architecture

The migration is easier to reason about if the destination is specified
independently of how we reach it. In the end state:

- each validator has one stable validator identity and one active
  post-quantum signing credential
- committee votes are aggregated using a stark proof where proof size is 300KB
- RANDAO uses a hashchain
- aggregator selection either uses randao or a merkle tree as a VRF
- new validators use a new pq deposit contract to register their pq credentials
- validator exits are authorized through the execution-layer withdrawal
  credential path
- 0x00 validators are no longer supported; their leftover balances follow
  open decision 7's rule
- validators who did not register their pq credentials have been exited
- slashing works the same except we now use pq signatures
- validator-authenticated gossip uses a lattice signature scheme, so its stateless.
  We have an operation on the CL, that allows to upgrade this without needing the
  validator to exit
- light clients either verify the post-quantum replacement for sync-committee
  authentication or the sync committee is removed
- `BLSToExecutionChange` operations are disabled
- the original deposit contract serves only top-ups, resolved through the
  retained pre-fold lookup
- builders register, top up, rotate, bid, and exit under post-quantum keys
  and request types
- `Validator.pubkey` holds the post-quantum encoding; the pre-fold BLS
  pubkey stays resolvable for immutable staking contracts; `pq_pubkeys` is
  gone
- transport uses post-quantum or hybrid key agreement and a post-quantum
  peer identity

### Migration requirements

**Stake lifecycle**

#### Validator deposits

- **Purpose:** This registers a new validator via the execution layer, with
  the deposited stake, their withdrawal credentials, and the validator's
  public key.

- **Mechanism:**
  - `DepositData` object is signed under the validator's BLS key
  - This is sent to the deposit contract with an `amount`
  - If surface level checks pass (like pubkey length), then a log is emitted from the contract
  - This log is then sent to the CL through [EIP-6110](./eip-6110.md) requests
  - The CL does additional checks like pubkey/signature validity. If those checks
  fail, then deposit is lost. If they pass, then the validator goes into the entry queue.

- **Relies on:** BLS signature for proof of possession against rogue-key attacks, binding
  the key to the depositor's withdrawal credentials, and DoS resistance for
  the validator ID.

Note: on the last point, imagine that no signature was needed to register a validator with a particular
public key on the CL. Then an attacker would do it as a DoS vector while attaching their withdrawal
credentials to the deposit.

<!-- TODO: 
We could have an endpoint that verifies deposits:

POST /eth/v1/.../verify_deposit

{
  pubkey,
  withdrawal_credentials,
  amount,
  signature
}
→ valid / invalid

-->

- **Migration:**

- There is an open question as to whether we modify the existing contract via
and irregular state transition function or deploy a new contract. As a default,
we assume that there will be a new deposit contract.  

- Phase 1: users are able to deposit with bls credentials
- Phase 2: at the pq fork, bls is no longer supported and new users deposit with pq credentials

**Requirements:**

- The new pq deposit contract will be deployed in the pq readiness phase.
- The new deposit contract will support BLS and PQ deposits, up until the PQ fork
where BLS deposits will be reverted. This will give the ecosystem enough time to
migrate to the new contract, which will have revert functionality for bls deposits,
so users do not lose their funds at the pq hardfork.
- The new deposit contract will specify the new format for `DepositData`

- [Post-quantum pubkey registry EIP](insert eip): This is an EIP that specifies
that existing validators will need to register 32 bytes as part of their PQ credentials.
- [Post-quantum-ready deposit contract](insert eip): This is an EIP that specifies
    the new contract that accepts BLS and post-quantum deposits.
- Libraries that are able to generate XMSS public keys/all pq credentials

#### Validator exits

- **Purpose:** lets a validator leave the active set and reclaim its stake.

- **CL-triggered:**
  - the validator signs a `VoluntaryExit` message
  - the message is eventually included in a block
  - the validator enters the exit queue and is deactivated
  - once withdrawable, the sweep credits the withdrawal address through the
    execution payload's withdrawals list

Note: 0x00 validators cannot withdraw since they have no attached execution address.
They will simply stop validating and the balance stays in the beacon state.

- **EL-triggered:**
  - the withdrawal address makes a call to the [EIP-7002](./eip-7002.md)
    predeploy
  - at the end of the block the EL dequeues the request from the contract
    through a system call and carries it as an [EIP-7685](./eip-7685.md)
    execution request
  - the CL processes the request when given the EL block
  - the validator is then put into the exit queue and is deactivated
  - once withdrawable, the sweep credits the withdrawal address as above

- **Relies on:** nothing BLS-specific: any post-quantum scheme can sign the
  CL-triggered operation; the EL-triggered path uses the execution
  account's security.

The [EIP-7002](./eip-7002.md) contract only accepts 48-byte public keys to
identify the validator. We may want to make this forward compatible, even
though XMSS public keys can fit under 50 bytes; otherwise post-quantum
validators stay reachable only through the retained pre-fold lookup.

- **Migration:**

- Phase 1: 0x00 validators are retired, so users can only exit with bls 0x01 or 0x02 validators
- Phase 2: users can only exit with 0x01/0x02 pq validators. BLS validators will be exited at the pq fork.

**Requirements:**:

- remove `SignedVoluntaryExit` and its gossip topic. Exits can only be done by the EL.

Note: consolidations are similar to exits and follow the same logic.
<!-- TODO: Add a header for consolidations or propose to remove them-->

#### Withdrawal credential changes

- **Purpose:** let a validator change their withdrawal credentials.

- **0x00**

  - a `0x00` credential stores `sha256(withdrawal_pubkey)` and not the pubkey,
    where the withdrawal key is a second BLS key, separate from the signing key.
  - the validator signs a `BLSToExecutionChange` with the withdrawal key,
    identifying the validator and the new `0x01` address that withdrawals should be redirected to
  - once included in the beacon block, the validator credentials point to an
    execution layer address, and the funds become sweepable.

**0x01**

- Currently 0x01/0x02 validators cannot change their withdrawal credentials without exiting and re-entering the
validator set.

- **Migration:**

- Phase 1: only 0x00 validators should convert to 0x01 validators
- Phase 2: Given there are PQ accounts on the EL, the user will call a withdrawal change contract
which will allow them to change their withdrawal credentials without exiting the validator.

**Requirements:**

- [Retire 0x00 validators](insert EIP here): This EIP will disallow new
validators from being created with 0x00 credentials, and exit all of the 0x00 validators.
At this point they will still be able to change to 0x01 by using `BLSToExecutionChange`
- [Withdrawal credentials change](insert EIP here): This is an EIP that specifies a new
EL-triggered withdrawal credentials change contract. Enabling the withdrawal credentials to
be changed without exiting and entering the 0x01/0x02 validator.

#### Builder deposits and exits

- **Purpose:** register a builder's slashable stake behind its bids, top it
  up, and exit it.

- **Mechanism:**
  - registration and top-ups call the [EIP-8282](./eip-8282.md) deposit
    predeploy. This is similar to the validator deposit and exit contract.
  - the main difference between the two contracts is not consequential for
    our purposes.
  - Similar to the deposit/exit contracts both use 7685 to send the information to
    the CL.

- **Relies on:** nothing BLS-specific; the deposit signature proves key
  possession, and the exit leans on the execution account instead.

- **Migration:** post-quantum registration is recorded dormant in Phase 1;
  the BLS deposit predeploy stops being read at Phase 2b and top-ups move
  to the post-quantum request type; unrotated builders are exited at Phase
  2c. Open: no decision; the builder-key EIP (TBD) specifies it.

**Requirements:** EIP TBD, post-quantum builder keys. The
[EIP-8282](./eip-8282.md) predeploys are BLS-shaped: the deposit
dispatches on fixed calldata, the exit identifies builders by their 48-byte
key. The EIP MUST:

- define new [EIP-7685](./eip-7685.md) request types and predeploys for
  registration, top-up, rotation authorized by the execution address,
  and exit, with a lookup from a BLS-registered builder's pubkey to its
  record
- specify bid and envelope signing under the new key from Phase 2a; keys
  registered in Phase 1 stay dormant
- state the Phase 2b cutover: the BLS deposit predeploy stops being read
  and value sent after is locked, top-ups move to the new request type,
  and the BLS exit predeploy keeps serving builders it can identify

#### Validator identification

- **Purpose:** everything outside the state needs a stable identifier for a
  validator.

- **Mechanism:** the 48-byte `Validator.pubkey` doubles as that identifier;
  no signature is involved:
  - the [EIP-7002](./eip-7002.md) and [EIP-7251](./eip-7251.md) request
    contracts identify validators by a pubkey they do not validate
  - top-up deposits match on it
  - contracts and light clients prove it at an index against the
    [EIP-4788](./eip-4788.md) root
  - beacon APIs accept it as a validator identifier

- **Relies on:** The identifier being 48 bytes or less.

- **Migration:** Phase 1 fixes the encoding; the Phase 2a fold replaces
  switched keys in `Validator.pubkey` and retains a lookup for the pre-fold
  pubkey; `pq_pubkeys` is removed at Phase 2c. Open: decision 4 picks the
  `Validator.pubkey` model.

**Requirements:** none of its own: the [EIP-7002](./eip-7002.md) and
[EIP-7251](./eip-7251.md) request contracts stay unchanged, identifying
validators by the pre-fold BLS pubkey that staking contracts hard-code.
The cutover-integration EIP's retained lookup MUST keep resolving it;
without it, immutable staking contracts lose exit, consolidation, and
top-ups.

**Duties**

#### Attestations

- **Purpose:** Before DC, it is a vote for: head, source, and target.

- **Mechanism:**
  - each epoch, every active validator is shuffled into one committee at
    one slot; at that slot it signs its `AttestationData`
  - the single attestation is gossiped on its committee's subnet
  - selected aggregators sum the signatures over identical data into one
    aggregate per committee
  - the next slot's proposer merges aggregates across committees into up to
    `MAX_ATTESTATIONS_ELECTRA` on-chain `Attestation`s; a block carries
    votes about earlier slots, never about itself, since the proposer's
    signature seals the whole block
  - votes that miss the block, late arrivals or divergent data, ride a
    later block at reduced reward

- **Relies on:** signature aggregation, to fit tens of thousands of votes
  per slot into a handful of on-chain objects.

- **Migration:** signing moves to the post-quantum scheme at Phase 2a;
  aggregation becomes proof-based under the vote-aggregation EIP. Open:
  decision 6 picks the producer, in Phase 1.

**Requirements:** EIP TBD, post-quantum vote aggregation (Phase 2a).
The proof, block layout, and timing budget are leanSpec's; the EIP MUST
integrate them and name the proof producer (decision 6). The layout
choice, up to eight per-attestation proofs versus one proof over all of
a block's votes, sets every block's verification cost and who can prove
when. Selected committee members prove, so their proving capability is a
Phase 2a entry condition; [EIP-8292](./eip-8292.md)'s two-layer layout
folds per-message proofs into one block proof, which puts proving
capacity at the proposer too.

#### Aggregator selection

- **Purpose:** someone must aggregate the votes from each committee

- **Mechanism:**
  - If a validator is chosen to attest at a slot, they will run a VRF to see if
    they should also be an aggregator for their committee.
  - This VRF is essentially `hash(bls_sign(epoch)) < THRESHOLD`.
    The BLS signature is proof they won. This is called a selection proof.
  - Threshold is set in such a way that the number of aggregators selected per committee
    is on average 16.
  - aggregators will listen on a particular subnet for votes to aggregate
  - aggregators publish their aggregate wrapped with the selection proof, and
    peers verify they won before forwarding.
  - The vote aggregate is included in a block by the proposer.

Note: the sync committee runs the same VRF under a different message.

- **Relies on:** uniqueness. We do not want for there to be many valid signatures for
    a particular message, because this means that they can grind the lottery.

- **Migration:** replaced ahead of the switch, in Phase 1: assigned draft
  8384 on the sync side, the attestation side per decision 6. Open:
  decision 6; only its hash-tree option registers a Phase 1 credential.

**Requirements:** the selection replacement lands in Phase 1, ahead of
the switch.

- **Deterministic sync committee aggregators (assigned draft 8384):**
  replaces the sync side's BLS selection proof with selection as a
  function of beacon state. Needed only from Phase 2a, placed in Phase 1
  by choice since it needs no post-quantum material;
  [EIP-8390](./eip-8390.md) would supersede it by removing the committee,
  so decision 11 gates its placement.
- Attestation aggregator selection is open decision 6, with two options;
  only the hash-tree option adds a credential, so the decision MUST be
  made before finalizing Phase 1. An opt-in role with no selection was
  rejected: it made finality depend on altruistic provers.

| Option | Who aggregates | Phase 1 credential | Aggregator secrecy | Cost | EIP |
| - | - | - | - | - | - |
| Deterministic | a fixed prefix of each committee | none | no | aggregator set is public an epoch ahead; selected members must prove | same construction as assigned draft 8384: [Deterministic attestation aggregators](./eip-deterministic-attestation-aggregators.md) (draft) |
| Hash-tree VRF | committee members that win a private draw | Merkle commitment, registered by operation | yes | 800 byte openings and a registration operation; drawn members must prove | [Hash-Tree Aggregator Selection](./eip-committed-attestation-aggregators.md) (draft) |

#### Block proposals

- **Purpose:** enforce leader election: the shuffle names one proposer per
  slot, and the signature is what makes that exclusive.

- **Mechanism:**
  - a proposer is chosen per slot from the RANDAO-seeded shuffle
  - the block it builds packs the previous slot's attestation aggregates
  - it signs the block and propagates it to attesters

- **Relies on:** nothing BLS specific

- **Migration:** flips at Phase 2a with the verification EIP. Open:
  nothing.

#### RANDAO

- **Purpose:** randomness for the chain; it seeds proposer selection and
  committee shuffling.

- **Mechanism:**
  - the proposer signs the current epoch and uses the signature as random bytes to
    mix into randao(randomness accumulator)

- **Relies on:** uniqueness; since there is one valid signature per epoch
    a proposer cannot grind signatures in order to bias their randao contribution.

- **Migration:** the [EIP-8321](./eip-8321.md) chain is registered in
  Phase 1, dormant, and goes live at Phase 2a; an active commitment is half
  of the definition of switched. Open: nothing; EIP-8321's activation
  timing must change to match.

**Requirements:** [EIP-8321: Hash-Chain RANDAO](./eip-8321.md),
replacing signature uniqueness with a hash chain. The commitment
registers in Phase 1 but stays dormant until Phase 2a; EIP-8321 as
written activates it shortly after registration and must change to
match. Deposit-time registration is the deposit candidate's job, per the
Validator deposits entry.

#### Sync committee and light clients

- **Purpose:** let a client track the consensus chain, without needing to follow all
               all 1 million validators.

- **Mechanism:**
  - every 27 hours, 512 validators are chosen as the sync committee.
  - each slot, members sign the head block root
  - a light client listens to those 512 committee members as a proxy
    for the whole consensus set

- **Relies on:** same as attestor aggregation, the VRF being used requires the signature
    scheme to be deterministic.

- **Migration:** if the committee is kept, the sync aggregate goes
  post-quantum at Phase 2a alongside a light-client EIP; if removed,
  [EIP-8390](./eip-8390.md) supersedes both and the Phase 1 placement of
  assigned draft 8384. Open: decision 11 comes first.

**Requirements:** EIP TBD, post-quantum light client protocol, needed
only if the committee is kept. The EIP MUST specify how a client holding
only the committee's keys verifies that a supermajority subset signed
the header, presumably by proof, and the update format carrying it;
[EIP-8390](./eip-8390.md) removes the need by removing the committee.

#### Proposer preferences

- **Purpose:** For a proposer that is not building their own block, they will
               want to specify their preferences to the builders. This can be
               gas limit target, fee recipient etc. To do this, they will sign
               a preference message.

- **Mechanism:**
  - ahead of its slot, the proposer signs and gossips its preferences
  - gossip validation checks the sender is the slot's scheduled proposer.
    The actual message is never recorded on-chain.
  - builders read it and bid against it for the slot that the proposer is chosen

- **Relies on:** nothing BLS-specific. Since it is signed with the validator key
                 it draws from the proposer's one-time-index budget.

Note: a proposer should not try to update their preferences after sending it. It would
confused builders and would make XMSS more difficult.

- **Migration:** flips at Phase 2a with the gossip-authentication EIP,
  which budgets its one-time indices. Open: nothing.

#### Builder bids and payload envelopes

- **Purpose:** under [EIP-7732](./eip-7732.md), the builder commits to a
  payload with a bid the proposer can include, then reveals the payload
  envelope.

- **Mechanism:**
  - the builder signs its bid under its registered key and gossips it; the
    topic forwards one bid per builder per parent context, and only bids
    that beat the best value seen, so the public auction is between
    builders, not a builder against itself
  - the proposer commits to a bid in its block, and the state transition
    verifies the bid signature
  - the builder then reveals the signed payload envelope within its
    deadline

Note: in protocol builders, should only be sending one bid per slot. This is enforced
on the networking layer, so there are no slashing penalties if they send more.

- **Relies on:** nothing BLS-specific

- **Migration:** BLS bids end at Phase 2a: from the fork only bids signed
  under a post-quantum builder key are valid, and a builder that has not
  rotated cannot bid until it does. Open: nothing; the builder-key EIP
  (TBD) specifies the signing.

#### Payload attestations

- **Purpose:** report whether the [EIP-7732](./eip-7732.md) builder
  revealed its payload on time, so the chain can distinguish a withholding
  builder from a censoring proposer.

- **Mechanism:**
  - a payload-timeliness committee (PTC) is chosen for each slot, an epoch in advance
  - members sign whether the payload appeared on time
  - the next block carries their votes as `PayloadAttestation` objects,
    participation bits plus one aggregate signature

- **Relies on:** nothing specific for BLS.

Note: If votes are not aggregated, then we add another 512 * XMSS signature to blocks.

- **Migration:** the committee votes flip at Phase 2a with the
  vote-aggregation EIP. Open: nothing.

**Requirements:** covered by the vote-aggregation EIP (Phase 2a),
which MUST replace the `PayloadAttestation` aggregate with a
post-quantum proof and define its producer, gossip object, block layout,
size limit, production deadline, and whether it folds into the
beacon-attestation block proof or stays separate.

#### Inclusion lists

- **Purpose:** force transactions into blocks against a censoring proposer.

- **Mechanism:**
  - a [EIP-7805](./eip-7805.md) committee of 16 validators is chosen per
    slot, computed an epoch ahead
  - each member signs and gossips its list; lists are never aggregated
  - fork choice enforces that the next payload satisfies the lists, so the
    signatures are verified at gossip and are not put on-chain

- **Relies on:** nothing BLS-specific: any post-quantum scheme substitutes.

- **Migration:** flips at Phase 2a with the gossip-authentication EIP.
  Open: nothing.

#### Slashing

- **Purpose:** make equivocation punishable: anyone can submit two
  conflicting signed messages as evidence.

- **Mechanism:**
  - `AttesterSlashing` cites two conflicting `IndexedAttestation`s;
    `ProposerSlashing` cites two signed headers for the same slot
  - the state re-verifies the cited signatures from chain data, slashes
    every validator that signed both sides, and rewards the including
    proposer

- **Relies on:** aggregates staying re-verifiable from chain data.

Note: we ideally want validator identities to remain stable across the pq fork.
For example, if slashing identifies a validator by it's public key, and this
changes between PQ forks, then this could cause issues. TODO: need to check

- **Migration:** the post-quantum evidence format arrives at Phase 2a;
  pre-switch BLS evidence closes no later than Phase 2c. Open: decision 10
  sets the pre-switch evidence window.

**Requirements:** EIP TBD, post-quantum slashing evidence (Phase 2a).
Proof-aggregated votes leave no aggregate signature to cite, so the EIP
MUST define the evidence format for conflicting votes, the individual
signatures or a proof of the two, and its block size budget;
`ProposerSlashing` keeps its form but the budget covers two post-quantum
block signatures. Pre-switch BLS evidence is decision 10: keeping it
valid lets a forger fabricate pre-fork double votes against switched
validators, and past one third the correlation penalty takes their whole
balance.

#### Gossip authentication

- **Purpose:** attribute a subset of gossip messages to a validator.
              There are messages in the protocol that should only be sent by
              validators, these `SignedMessages` are checked on the p2p layer
              to ensure that it originated from a validator.

- **Mechanism:**
  - Given a p2p object `Message` that should only originate from a validator.
    We make a `SignedMessage` wrapper that is signed by the validator.
  - Upon receiving a `SignedMessage`, the node should verify that it was signed
    by a validator before forwarding.

- **Relies on:** Nothing special about BLS.

Note: using a stateful signature scheme here is harder because these messages are not synced
with a slot.

- **Migration:** flips at Phase 2a with the gossip-authentication EIP,
  which sets the one-time-index budget per message type. Open: nothing.

**Requirements:** EIP TBD, post-quantum gossip authentication (Phase
2a). For each gossip-only signed message, aggregate and contribution
wrappers, [EIP-7805](./eip-7805.md) inclusion lists,
[EIP-7732](./eip-7732.md) proposer preferences, the EIP MUST name the
signing validator key and the one-time-index budget for messages that
are not attestations.

**Substrate**

#### Transport

- **Purpose:** encrypt and authenticate peer connections.

- **Mechanism:** secp256k1 peer identities over a Noise handshake with
  X25519 key agreement; discovery records are signed by the identity key.

- **Relies on:** not BLS, this is the layer below it.

- **Migration:** Phase 1, before everything else: it depends on nothing
  and nothing depends on it. Open: nothing; the transport EIP (TBD)
  specifies it.

**Requirements:** EIP TBD, post-quantum transport (Phase 1). MUST
specify a post-quantum or hybrid key agreement for the libp2p handshake,
the peer identity key type, and the needed discovery record changes.

**Cross-cutting**

#### History and sync

- **What changes:** from the switch, pre-switch history verifies nothing
  against the assumed attacker: the switch state is a weak subjectivity
  checkpoint distributed out of band, syncing from genesis ends, and the
  weak subjectivity period computation must absorb the churn-free set
  changes at Phase 2a and Phase 2c.
- **What survives:** block roots chain by hash, which the attacker does not
  break, so backfill, history serving, and proofs of any pre-switch block
  against the checkpoint root work as before. What ends is authentication of
  history by its signatures, not its integrity against the checkpoint.
- **Open:** decision 9.

#### Distributed validators

- **Problem:** no threshold scheme exists for stateful hash-based keys, so a
  cluster cannot split a post-quantum key the way it splits a BLS key, and
  cannot register without a construction.
- **Stakes:** clusters hold a material share of stake, so this bears on
  whether the Phase 1 threshold is reachable at all.
- **Open:** decision 8.

#### Networking

- **Problem:** every size assumption in the gossip layer is calibrated to
  96-byte signatures and 48-byte keys. A hash-based signature is kilobytes,
  so every signed message grows by an order of magnitude, and an aggregate
  becomes a succinct proof in the hundreds of kilobytes
  ([EIP-8292](./eip-8292.md)'s envelope), so the aggregation topics grow by
  three.

- **Scale:** a committee subnet that carries tens of kilobytes of
  attestations per slot today carries megabytes at kilobyte signature
  sizes, and publishing one aggregate proof to a gossipsub mesh consumes a
  large fraction of a slot at the [EIP-7870](./eip-7870.md) attester
  uplink, so propagation latency, not proving time, can become the
  binding constraint on aggregation depth.

- **Levers:** batching attestations at source so co-located validators
  publish one message ([EIP-8243](./eip-8243.md)); shrinking the signer
  count through [EIP-7251](./eip-7251.md) consolidation; partitioning
  signers across subnets with per-subnet aggregation; gossip-protocol
  changes that announce large messages instead of pushing them to the full
  mesh; holding proof sizes to soft targets; and, last, raising the
  [EIP-7870](./eip-7870.md) baseline.

- **Open:** no numbered decision; the p2p-validation EIP owns the limits
  and the bandwidth and verification budgets, and the vote-aggregation EIP
  owns the message sizes they must accommodate.

**Requirements:** EIP TBD, post-quantum p2p validation (Phase 2a).
MUST specify the validation conditions for every signed topic under the
post-quantum scheme, the gossip and req/resp size limits for
multi-kilobyte signatures and aggregate proofs, and the per-slot
bandwidth and per-block verification budgets those limits imply against
the [EIP-7870](./eip-7870.md) baseline.

#### Cutover integration

Cross-cutting by construction: one EIP integrates the post-quantum scheme
into the beacon chain at Phase 2a, touching several mechanisms at once.

**Requirements:** EIP TBD, post-quantum signature verification. The
scheme, proof system, and consensus rules are leanSpec's; this EIP is
the beacon-chain integration. It MUST:

- resolve every existing way of identifying a validator, request-contract and
  top-up pubkeys, [EIP-4788](./eip-4788.md) proofs, API identifiers, to
  the same index after the switch, representing the post-quantum key in
  `Validator.pubkey` per decision 4: the fold for switched validators,
  the BLS pubkey plus retained lookup for the rest, `pq_pubkeys` kept
  through Phase 2c
- keep registration open to unswitched validators until Phase 2c, if
  decision 10 keeps a way back; the operation completing both credentials
  MUST fold atomically, and nothing may replace the BLS pubkey before
  the RANDAO commitment is active
- treat a validator as switched only with an active commitment,
  activating each chain at the later of the fork and its EIP-8321
  activation epoch
- apply decision 10 to unswitched validators: status, exit path, and
  pre-switch BLS evidence
- cover every remaining BLS-signed duty: sync committee messages and the
  `SyncAggregate`, individual EIP-7732 payload-attestation messages,
  proposer preferences
- carry the key-replacement operation, if decision 12 provides one
- handle committee and proposer lookahead across the fork, computed
  before the unswitched validators' status changed
- if the sync committee is kept, handle the period spanning the fork:
  unswitched members, `aggregate_pubkey`, light clients already holding
  `next_sync_committee`
- specify the block-level vote layout with the vote-aggregation EIP

**Out of scope**

#### Data availability

- **Purpose:** blob data availability sampling.

- **Mechanism:** KZG commitments over BLS12-381; pairings rather than
  signatures, but broken by the same attacker.

- **Migration:** out of scope for this document; a separate track, as the
  Abstract records. Nothing here gates it and it gates nothing here.

#### Execution accounts

- **Purpose:** the address a validator's `0x01`/`0x02` credential points at
  is where swept funds land, and it authorizes [EIP-7002](./eip-7002.md)
  exits and [EIP-7251](./eip-7251.md) consolidations through `msg.sender`;
  after the switch it is the only exit path.

- **Mechanism:** an externally owned account signs with secp256k1. Its
  public key is hidden behind the address hash until the account's first
  outgoing transaction reveals it, the same reveal-on-first-use structure
  as the `0x00` withdrawal credential. Contracts are exposed wherever
  their control path still depends on such a key.

- **Relies on:** secp256k1, not BLS; it sits beside this document's scope,
  but everything above routes funds authority into it.

- **Migration:** out of scope for this document; the separate
  execution-layer track (decision 13) must let an existing address
  permanently replace vulnerable authorization. This document records only
  the dependency: the track's deployment with notice is a Phase 2a entry
  condition, adoption cannot be enforced, and accounts that never migrate
  stay exposed; that residual risk is accepted.

**Requirements:** out of scope; EIP TBD on the separate
execution-layer track, which MUST define how an existing withdrawal
address permanently replaces vulnerable authorization, covering
externally owned accounts whose secp256k1 public key is already public.
Until it lands, the transition does not protect those funds.

### Migration plan

The plan below is the deployment schedule for the requirements above: it
says when each change ships, not what it is. Mechanism detail and
constituent-EIP contracts live in the Migration requirements entries.

The transition runs in two phases, with Phase 2 split into three steps.
A phase may span multiple forks and adjacent steps may share a fork. The phase
sections below specify entry conditions and the changes each fork activates.
**EIP TBD** marks
a required mechanism that does not yet have a specification; **draft** marks an
unnumbered draft.

A validator is **switched** after Phase 2a when it satisfies the
post-quantum-readiness predicate defined above and the post-quantum duty rules
are live. Before Phase 2a, the same material makes the validator
**post-quantum-ready**, not switched. The **fold** is the Phase 2a replacement
of a switched validator's `Validator.pubkey` by its registered key. A
**partial registration** holds only one item or holds a RANDAO commitment that
is not active yet. The **post-fork registration path** lets an unswitched
validator register after the Phase 2a fork if open decision 10 keeps this
path. The path can use the existing operation or a new operation.

The schedule is grouped by track, using the transition model defined
above: **lifecycle** work prepares and retires validator-facing state and
moves gradually across phases; **duty** work flips atomically at Phase
2a; the **substrate**, transport, is independent and can move first.

The phase sections below are the authoritative schedule: each states its
entry conditions and the changes it activates, and each mechanism's
Migration field in its requirements entry restates its own path. Where
they disagree, the phase sections win; constituent-EIP requirements live
only in the Migration requirements entries.

### Phase 1: preparation

Under BLS as the sole duty scheme, the network becomes post-quantum-ready.
In this phase, with each mechanism's detail in its Migration requirements
entry:

- the post-quantum system contracts are deployed; what they record stays
  dormant until the cutover (Validator deposits; Builder deposits and
  exits)
- existing validators register post-quantum keys through the pubkey
  registry and RANDAO chains through [EIP-8321](./eip-8321.md) (Validator
  deposits; RANDAO)
- `0x00` credential validators rotate or are exited by assigned draft
  8365, and balance sunset starts if open decision 7 chooses it
  (Withdrawal credential changes)
- aggregator selection loses its dependence on BLS signature uniqueness,
  and open decision 6 is made; only its hash-tree option adds a Phase 1
  readiness credential (Aggregator selection)
- the transport layer moves to post-quantum key agreement (Transport)
- the separate execution-layer account track is deployed with notice
  (Execution accounts)

Phase 1 may itself span several forks; the registry should ship as early
as possible and need not wait for transport.

#### Validators

- Existing validators register their PQ metadata. A `0x00` validator
  rotates to `0x01` first; rotation after the retirement fork still
  recovers the full balance through the sweep, but the validator exits on
  the retirement schedule, must re-enter, and cannot register a key after
  its exit starts. Validators whose withdrawal address uses vulnerable
  authorization also use the execution-account migration path when it
  becomes available.
- New validators deposit through the existing contract and register their
  PQ metadata in two steps, or deposit through the post-quantum contract
  and wait in the activation queue until the cutover.

#### Exiting phase 1

The active stake that is post-quantum-ready is readable from the beacon
state, per the readiness predicate above. The threshold for scheduling the
Phase 2a fork is open decision 1; it cannot be 100% because new validators keep
joining via the BLS deposit contract. The fork epoch is chosen only once the
threshold holds, so the count is taken before scheduling, over
`get_total_active_balance` at the epoch of evaluation, and re-checked at the
fork epoch itself: stake whose credential-retirement exit is initiated cannot
register a key but remains active until its exit epoch, so it counts as
unswitched in the denominator rather than being dropped. The threshold is
Phase 2a's entry condition, where its safety role is stated.

### Phase 2: cutover

Phase 2 executes the cutover: Phase 2a switches every validator duty to
post-quantum authentication, Phase 2b closes legacy entry, and Phase 2c
retires the remaining BLS machinery. The steps are ordering constraints
with entry conditions, not three reserved forks: 2a and 2b may share a
fork, in which case 2a's window of BLS deposits is empty, while 2c can
never share a fork with 2b, since its force-exit bound is measured after
legacy entry has closed and any permitted late-registration window has
run. There is no mixed BLS/post-quantum duty authentication at any point:
if the same validator could authenticate a duty under either scheme, its
security would be that of the weaker scheme.

#### Phase 2a: duty cutover

The fork at which every duty moves to post-quantum signing, and at which the
keys, commitments, and deposits recorded dormant in Phase 1 become live. BLS
deposits stay enabled, so a new validator may still deposit under BLS and
then register. The flip is co-designed against the post-quantum consensus
specification (leanSpec).

A validator that does not hold both an active RANDAO commitment and a
registered key at the fork
cannot sign. What the state does with it is open decision 10: either it stays
in the active set and leaks, which requires the switched fraction to exceed
two thirds of active balance for finality, or it is made inactive and rejoins
through the churn-limited activation queue, which is what the pubkey registry
and retire-BLS drafts describe and which keeps finality independent of
unswitched stake, but which the beacon state cannot represent without a new
status, a lookahead delay, and rules for its slashability and its exit
eligibility clock. Under the
second option it also needs an exit path, since EIP-7002 exits require an
active validator. Whether it can still register through the operations of
the post-fork registration path and return, or must exit and re-enter, is
the same decision's second part.

BLS is still verified after the fork, all of it closed by Phase 2c: the
registration operations and, if open decision 10 keeps it, the conversion
operation, the signatures on BLS-form deposits,
`BLSToExecutionChange`, the EIP-8282 builder deposit signature until Phase 2b,
the hash-tree registration if adopted, and pre-switch slashing evidence if
open decision 10 keeps it. Each is a path a BLS forger can use during Phase 2,
and the ones that change membership are the reason for the safety bound in
open decision 1.

##### Entry conditions

Post-quantum readiness saturation (open decision 1); proving capability
among the selected aggregators sufficient for post-quantum attestation
aggregation; a post-quantum execution-account migration path deployed on the
execution layer, with notice enough for withdrawal-address owners to adopt it
before the switch, since adoption itself cannot be required; and the
credential-retirement draft active with its initial
backlog of `0x00` exits initiated. Its rule is standing, so later arrivals are
retired as they surface. If
open decision 10 keeps post-fork registration open until Phase 2c, the threshold
is also a safety bound: stake that is not switched at the fork remains
capturable by a BLS forger until then, so the unswitched fraction plus any
attacker stake MUST stay below one third until Phase 2c.

##### Changes activated

At this fork, with each mechanism's requirements in its Migration
requirements entry:

- every validator duty switches to the post-quantum scheme, and the
  material recorded dormant in Phase 1 goes live (Cutover integration)
- RANDAO switches to the registered hash chains (RANDAO)
- attestation and payload-attestation aggregation become proof-based
  (Attestations; Payload attestations)
- post-quantum slashing evidence activates (Slashing)
- the light-client protocol switches, or the sync committee is removed
  under open decision 11 (Sync committee and light clients)
- gossip authentication and p2p validation switch (Gossip authentication;
  Networking)
- BLS builder bids end (Builder bids and payload envelopes)
- `SignedVoluntaryExit` is removed (Validator exits)

No BLS-authenticated validator duty is valid from this fork onward.

##### Validators

- **Existing**: sign every duty with the registered key from the fork. Those
  that have not registered cannot sign; open decision 10 covers their status
  and their way back.
- **New**: deposit through the post-quantum contract, which activates
  directly from this fork; or, only if open decision 10 keeps post-fork
  registration open, deposit under BLS and then register.

#### Phase 2b: legacy entry closure

BLS-form deposits stop creating validators, so the post-quantum deposit path
from Phase 1 is the only way in and the two-step lifecycle closes. Validators
that entered under BLS shortly before this step, in the entry queue or newly
active, register through the post-fork registration path if open decision 10
keeps it open, and otherwise exit and re-deposit. After this step every new validator
holds post-quantum credentials.

##### Changes activated

- BLS-form deposits stop creating validators at the cutover epoch of open
  decision 3 (Validator deposits)
- the BLS builder deposit predeploy stops being read, and builder top-ups
  move to the post-quantum request type (Builder deposits and exits)

##### Validators

- **Existing**: nothing. Those in the entry queue or newly active under BLS
  register or re-deposit per open decision 10.
- **New**: deposit with a post-quantum key and execution credentials.

#### Phase 2c: BLS retirement

##### Entry conditions

The stake still held by validators that are not switched, whenever they
entered, is below an agreed bound, so that force-exiting it is acceptable
(open decision 1); a rule
for balances still held by retired `0x00` validators is in place (open
decision 7); and every Phase 2a and 2b item has landed, since each is a place
where retirement would otherwise strand a validator.

##### Changes activated

- [Retire BLS validator keys](./eip-retire-bls-validator-keys.md): closes the
  BLS-authorized key registration path and force-exits every validator that is
  not switched, whether it lacks the key or the commitment and whenever it
  entered; its `has_pq_pubkey` predicate reads the prefix of
  `Validator.pubkey`, which identifies exactly the switched validators because
  Phase 2a folds only those. Its stated end state is that no BLS signature is
  verified anywhere in the state transition, so the sunsets below are assigned
  to this fork and this EIP MUST specify them or name the companion that does:
  - the BLS-signed registration operations of the pubkey registry and
    EIP-8321, and the post-fork registration path if it exists. EIP-8321
    specifies that at this fork its registration signature migrates to the
    post-quantum scheme and the operation is deprecated only once deposits
    carry the commitment; this document follows that, and the pubkey
    registry's operation ends the same way. EIP-8321 names this fork
    differently, and the names must be reconciled;
  - BLS signature verification on BLS-form deposits from the existing
    contract, while top-ups through the retained lookup continue;
  - whatever pre-switch slashing evidence open decision 10 kept;
  - builders without a post-quantum key, which are exited;
  - `pq_pubkeys`, after every remaining validator with a partial registration
    is exited. Until this point the list preserves the single-use property of
    Phase 1 registrations and supplies keys for the post-fork registration path;
  - the remaining `0x00` machinery: `BLSToExecutionChange`, its gossip topic,
    and the registry entries that open decision 7 leaves. The
    credential-retirement draft defers this
    to "the post-quantum fork"; this document places it here rather than at
    Phase 2a.

Removal applies to the state transition for new blocks. Under the attacker
this document assumes, every pre-switch signature is forgeable, including the
registrations that bound post-quantum keys to indices, so verifying pre-switch
history with BLS provides no assurance: the switch state is a weak
subjectivity checkpoint that MUST be distributed out of band, and the
churn-free set changes at Phase 2a and here MUST be reflected in how the weak
subjectivity period is computed (open decision 9). Syncing from genesis
therefore ends at the switch: every client sync path starts from the
distributed checkpoint, whose distribution becomes infrastructure the
protocol depends on.

##### Validators

- **Existing**: nothing, if registered. Unregistered validators are exited.
- **New**: unchanged from Phase 2b.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
