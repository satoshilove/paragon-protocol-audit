// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

error NonceMismatch(uint256 expected, uint256 actual);
error ZeroAddress();

contract MockBestExec {
    mapping(address => uint256) public nonces;

    event IntentCanceled(address indexed user, uint256 nonce);

    function nextNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    /// @notice Strictly enforces sequential nonces: must consume exactly the current nonce.
    function consume(address user, uint256 nonce) external {
        if (user == address(0)) revert ZeroAddress();
        uint256 expected = nonces[user];
        if (nonce != expected) revert NonceMismatch(expected, nonce);
        unchecked {
            nonces[user] = expected + 1;
        }
    }

    /// @notice Idempotent cancel if the provided expectedNonce matches the current.
    function cancel(address user, uint256 expectedNonce) external {
        if (user == address(0)) revert ZeroAddress();
        uint256 expected = nonces[user];
        if (expectedNonce != expected) revert NonceMismatch(expected, expectedNonce);
        unchecked {
            nonces[user] = expected + 1;
        }
        emit IntentCanceled(user, expected);
    }
}
