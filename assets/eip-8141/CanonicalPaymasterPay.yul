/// Pay path of the EIP-8141 canonical paymaster. `CanonicalPaymaster.sol` calls it through `DELEGATECALL`,
/// because Solidity cannot emit `HASCLAIM` or `APPROVE`.
///
/// Calldata is two words: `verifier || owner`. The transaction must carry a leading `PROOF` frame with
/// target `verifier`, resolved key `owner` left-padded to 32 bytes, and `msg` zero (i.e., `owner`'s
/// signature over the canonical signature hash). If `HASCLAIM` returns 1, the helper calls
/// `APPROVE(APPROVE_PAYMENT)`, which under `DELEGATECALL` approves the calling paymaster as payer.
/// Otherwise it reverts with `InvalidClaim()`.
///
/// The helper refuses direct calls, so a balance it holds can never pay for a transaction.
object "CanonicalPaymasterPay" {
    code {
        let size := datasize("runtime")
        datacopy(0, dataoffset("runtime"), size)
        setimmutable(0, "self", address())
        return(0, size)
    }

    object "runtime" {
        code {
            if eq(address(), loadimmutable("self")) { revert(0, 0) }
            if iszero(eq(calldatasize(), 64)) { revert(0, 0) }

            let verifier := calldataload(0)
            let owner := calldataload(32)
            if iszero(hasClaim(verifier, owner, 0)) { invalidClaim() }

            // APPROVE(scope = APPROVE_PAYMENT, length = 0, offset = 0) approves payment and exits.
            verbatim_0i_0o(hex"600160006000aa")

            // HASCLAIM takes verifier on top of stack, key second, msg third.
            function hasClaim(verifier, key, msg) -> ok {
                ok := verbatim_3i_1o(hex"b4", verifier, key, msg)
            }

            function invalidClaim() {
                mstore(0, shl(224, 0xed3c247c)) // InvalidClaim()
                revert(0, 4)
            }
        }
    }
}
