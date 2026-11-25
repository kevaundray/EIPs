// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @notice Canonical paymaster for EIP-8141 frame transactions.
/// @dev A `pay` frame that targets an instance carries empty calldata.
///      The transaction must include a leading `PROOF` frame with target `SECP256K1_VERIFIER`,
///      resolved key `owner` left-padded to 32 bytes, and `msg` zero (the owner's secp256k1
///      signature over the canonical signature hash). The protocol verifies every `PROOF` frame
///      before any non-`PROOF` frame executes, so the paymaster checks `HASCLAIM` and approves
///      payment. Solidity cannot emit `HASCLAIM` or `APPROVE`, so that pay path runs in
///      `CanonicalPaymasterPay.yul`, which this contract delegatecalls; `APPROVE` under
///      `DELEGATECALL` approves this contract as payer.
///      Ether leaves an instance only as payment for a transaction, or through a withdrawal
///      that the owner requests and, after `WITHDRAWAL_DELAY`, executes.
contract CanonicalPaymaster {
    uint256 public constant WITHDRAWAL_DELAY = 12 hours;

    // Immutables are part of the runtime code. Canonical instances are deployed with the pay helper's fixed
    // address and with the SECP256K1_VERIFIER address, which EIP-8141 has yet to assign, so they share their
    // runtime code and nodes recognize them by code match.
    address public immutable payHelper;
    address public immutable secp256k1Verifier;

    // Stored in contract storage instead of immutable so the deployed runtime code
    // is identical across all instances and can be recognized canonically by code match.
    // This is the authorized secp256k1 signer address, not a generic contract-signature authority.
    address public owner;

    address payable public pendingWithdrawalTo;
    uint256 public pendingWithdrawalAmount;
    uint256 public pendingWithdrawalReadyAt;

    error NotOwner();
    error ZeroAddress();
    error InvalidClaim();
    error NoPendingWithdrawal();
    error WithdrawalNotReady();
    error TransferFailed();

    event WithdrawalRequested(address indexed to, uint256 amount, uint256 readyAt);
    event WithdrawalExecuted(address indexed to, uint256 amount);

    constructor(address owner_, address payHelper_, address secp256k1Verifier_) payable {
        if (owner_ == address(0) || payHelper_ == address(0) || secp256k1Verifier_ == address(0)) {
            revert ZeroAddress();
        }
        owner = owner_;
        payHelper = payHelper_;
        secp256k1Verifier = secp256k1Verifier_;
    }

    receive() external payable {}

    /// @dev Raw paymaster validation entrypoint: the target of the `pay` frame.
    ///      Expects empty calldata; checks for the owner's `PROOF` frame via `HASCLAIM`.
    fallback() external payable {
        if (msg.data.length != 0) revert InvalidClaim();

        (bool ok, bytes memory ret) =
            payHelper.delegatecall(abi.encode(secp256k1Verifier, owner));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function requestWithdrawal(address payable to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();

        pendingWithdrawalTo = to;
        pendingWithdrawalAmount = amount;
        pendingWithdrawalReadyAt = block.timestamp + WITHDRAWAL_DELAY;

        emit WithdrawalRequested(to, amount, pendingWithdrawalReadyAt);
    }

    function executeWithdrawal() external {
        if (msg.sender != owner) revert NotOwner();

        address payable to = pendingWithdrawalTo;
        uint256 amount = pendingWithdrawalAmount;
        uint256 readyAt = pendingWithdrawalReadyAt;

        if (readyAt == 0) revert NoPendingWithdrawal();
        if (block.timestamp < readyAt) revert WithdrawalNotReady();

        delete pendingWithdrawalTo;
        delete pendingWithdrawalAmount;
        delete pendingWithdrawalReadyAt;

        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit WithdrawalExecuted(to, amount);
    }
}
