---
title: leanSPHINCS Claim Verifier
description: Post-quantum leanSPHINCS signatures as an EIP-8141 protocol verifier
author: TBD
discussions-to: https://ethereum-magicians.org/t/TBD
status: Draft
type: Standards Track
category: Core
created: 2026-11-27
requires: 8141
---

## Abstract

This EIP adds one protocol verifier to [EIP-8141](./eip-8141.md), `LEANSPHINCS_VERIFIER`, which checks leanSPHINCS signatures. leanSPHINCS is a stateless, hash-based, post-quantum signature scheme whose only hash is Keccak-256. A transaction is signed with it like with any other EIP-8141 claim, and contracts check it with `HASCLAIM`.

## Motivation

Accounts need a post-quantum signature scheme that the protocol checks natively, outside the EVM, so that accounts can migrate away from secp256k1 and so that [EIP-8288](./eip-8288.md) can later aggregate these signatures into one proof per block.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

| Name                           | Value   |
|--------------------------------|---------|
| `LEANSPHINCS_VERIFIER`         | TBD     |
| `LEANSPHINCS_VERIFICATION_GAS` | `13200` |
| `LEANSPHINCS_SIGNATURE_SIZE`   | `7740`  |

This EIP adds one entry to EIP-8141's `PROTOCOL_VERIFIERS`:

```python
PROTOCOL_VERIFIERS[LEANSPHINCS_VERIFIER] = (
    LEANSPHINCS_VERIFICATION_GAS,
    LEANSPHINCS_SIGNATURE_SIZE,
    leansphincs_verifier,
)
```

| Verifier               | `key`           | `witness` encoding       | Gas cost |
|------------------------|-----------------|--------------------------|----------|
| `LEANSPHINCS_VERIFIER` | public key `pk` | `signature (7740 bytes)` | `13200`  |

```python
def leansphincs_verifier(input) -> bool:
    if len(input) != 7804:
        return False
    key, msg, signature = input[0:32], input[32:64], input[64:7804]
    # Every 7740-byte string encodes exactly one leanSPHINCS signature, and the scheme is
    # strongly unforgeable, so a valid signature cannot be altered without the secret key.
    return leansphincs_verify(key, msg, signature)
```

A leanSPHINCS public key `pk` is its 16-byte `PK.seed` followed by its 16-byte `PK.root`, the root of its top tree. leanSPHINCS is the stateless hash-based signature scheme over Keccak-256 (SLH-DSA as specified in FIPS 205, instantiated with Keccak-256 and WOTS+C) defined by the `Cryptography/Sphincs` module of `ethereum/EthLib` at commit `f0e41b61ed6349f7ae35e8a4528c7da847bf27a8`, which fixes both encodings. `leansphincs_verify(pk, msg, signature)` is that module's `verify`: it returns whether `signature` is a valid signature of the 32-byte `msg` under the public key `pk`.

As for every EIP-8141 protocol verifier, `LEANSPHINCS_VERIFIER` is claim-only: calling it from EVM code behaves as calling an account without code. Its address is reserved outside the active EVM precompile range and the range that EIP-7587 reserves for RIPs. Its `key` is the 32-byte `pk`, so EIP-8141's 12-zero-byte key check does not apply. This EIP activates in the same fork as EIP-8141.

## Rationale

### leanSPHINCS signatures

leanSPHINCS gives frame transactions a post-quantum signature scheme validated natively by the protocol from day one. It is stateless: unlike a stateful hash-based scheme, its signer keeps no index whose reuse would compromise the key, so one key can sign from several devices and be restored from backup. Its only hash primitive is Keccak-256, which every client already implements.

The key of a `LEANSPHINCS_VERIFIER` claim is the 32-byte public key itself (`PK.seed || PK.root`) rather than a 20-byte address derived from it, preserving full 256-bit binding and allowing accounts to store and pass the public key directly to `HASCLAIM`. Verification takes a constant 515 Keccak-f[1600] permutations; at 25.5 gas per 136-byte permutation (matching `KECCAK256`'s 6 gas per 32-byte word), `515 * 25.5 = 13,132.5`, rounded up to `13,200` gas.

### A separate EIP

EIP-8141 defines claims, `HASCLAIM`, segregated witnesses, the protocol verifier interface and the secp256k1 and P-256 verifiers. Each further scheme is its own EIP that adds one entry to `PROTOCOL_VERIFIERS`, so it can be specified, priced and reviewed on its own, and EIP-8141 stays small.

## Backwards Compatibility

This EIP adds a protocol verifier. Transaction encoding and verification at other addresses are unchanged.

## Security Considerations

### Signature limit

A leanSPHINCS key is specified for at most `2**30` signatures. Each message digest selects one of the key's few-time Forest of Random Subsets (FORS) instances at random, so instances are reused across messages and each additional signature weakens security. Signing is deterministic, so signing the same message again reveals nothing new, but every distinct message counts toward the limit. High-volume signers (such as paymasters) must track their signature count and rotate keys before reaching the limit.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
