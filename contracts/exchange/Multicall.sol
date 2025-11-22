// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title Multicall3
 * @notice Canonical-style Multicall3: batch calls (read/write) with optional ETH forwarding,
 *         per-call allowFailure, and helper view functions for block / chain metadata.
 */
contract Multicall3 {
    /*//////////////////////////////////////////////////////////////////////////
                                     TYPES
    //////////////////////////////////////////////////////////////////////////*/

    struct Call {
        address target;
        bytes callData;
    }

    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Call3Value {
        address target;
        bool allowFailure;
        uint256 value;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ERRORS & EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    error CallFailed();
    error ValueMismatch();
    error ReentrancyLock();

    // Events renamed to avoid clashes with struct identifiers
    event Call3Executed(address indexed target, bool success, bytes returnData);
    event Call3ValueExecuted(address indexed target, bool success, uint256 value, bytes returnData);

    // Simple non-reentrancy guard for value-sending aggregate3Value
    uint256 private locked = 1; // 1 = not entered, 2 = entered

    /*//////////////////////////////////////////////////////////////////////////
                                   RECEIVE
    //////////////////////////////////////////////////////////////////////////*/

    // Needed to receive ETH for aggregate3Value calls
    receive() external payable {}

    modifier nonReentrant() {
        if (locked == 2) revert ReentrancyLock();
        locked = 2;
        _;
        locked = 1;
    }

    /*//////////////////////////////////////////////////////////////////////////
                              LEGACY MULTICALL2
    //////////////////////////////////////////////////////////////////////////*/

    function aggregate(Call[] calldata calls)
        external
        payable
        returns (uint256 blockNumber, bytes[] memory returnData)
    {
        blockNumber = block.number;
        uint256 length = calls.length;
        returnData = new bytes[](length);

        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
                if (!success) revert CallFailed();
                returnData[i] = ret;
            }
        }
    }

    function tryAggregate(bool requireSuccess, Call[] calldata calls)
        external
        payable
        returns (Result[] memory returnData)
    {
        uint256 length = calls.length;
        returnData = new Result[](length);

        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
                if (requireSuccess && !success) revert CallFailed();
                returnData[i] = Result({ success: success, returnData: ret });
            }
        }
    }

    function blockAndAggregate(Call[] calldata calls)
        external
        payable
        returns (uint256 blockNumber, bytes32 blockHash, Result[] memory returnData)
    {
        blockNumber = block.number;
        blockHash = blockhash(block.number - 1);
        uint256 length = calls.length;
        returnData = new Result[](length);

        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
                if (!success) revert CallFailed();
                returnData[i] = Result({ success: success, returnData: ret });
            }
        }
    }

    function tryBlockAndAggregate(bool requireSuccess, Call[] calldata calls)
        external
        payable
        returns (uint256 blockNumber, bytes32 blockHash, Result[] memory returnData)
    {
        blockNumber = block.number;
        blockHash = blockhash(block.number - 1);
        uint256 length = calls.length;
        returnData = new Result[](length);

        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
                if (requireSuccess && !success) revert CallFailed();
                returnData[i] = Result({ success: success, returnData: ret });
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                AGGREGATE v3
                      (per-call allowFailure + value support)
    //////////////////////////////////////////////////////////////////////////*/

    function aggregate3(Call3[] calldata calls)
        external
        payable
        returns (Result[] memory returnData)
    {
        uint256 length = calls.length;
        returnData = new Result[](length);

        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                Call3 calldata c = calls[i];
                (bool success, bytes memory ret) = c.target.call(c.callData);

                if (!success && !c.allowFailure) revert CallFailed();

                Result memory result = Result({ success: success, returnData: ret });
                returnData[i] = result;

                emit Call3Executed(c.target, success, ret);
            }
        }
    }

    function aggregate3Value(Call3Value[] calldata calls)
        external
        payable
        nonReentrant
        returns (Result[] memory returnData)
    {
        uint256 length = calls.length;
        returnData = new Result[](length);

        uint256 valueAccumulator;

        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                Call3Value calldata c = calls[i];
                valueAccumulator += c.value;

                (bool success, bytes memory ret) =
                    c.target.call{ value: c.value }(c.callData);

                if (!success && !c.allowFailure) revert CallFailed();

                Result memory result = Result({ success: success, returnData: ret });
                returnData[i] = result;

                emit Call3ValueExecuted(c.target, success, c.value, ret);
            }
        }

        if (msg.value != valueAccumulator) revert ValueMismatch();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                VIEW HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function getBlockHash(uint256 blockNumber) external view returns (bytes32) {
        return blockhash(blockNumber);
    }

    function getBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function getCurrentBlockCoinbase() external view returns (address) {
        return block.coinbase;
    }

    function getCurrentBlockDifficulty() external view returns (uint256) {
        // Post-merge chains repurpose difficulty as random beacon (prevrandao)
        return block.prevrandao;
    }

    function getCurrentBlockGasLimit() external view returns (uint256) {
        return block.gaslimit;
    }

    function getCurrentBlockTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function getEthBalance(address addr) external view returns (uint256) {
        return addr.balance;
    }

    function getLastBlockHash() external view returns (bytes32) {
        return blockhash(block.number - 1);
    }

    function getBasefee() external view returns (uint256) {
        return block.basefee;
    }

    function getChainId() external view returns (uint256 chainId) {
        assembly {
            chainId := chainid()
        }
    }
}
