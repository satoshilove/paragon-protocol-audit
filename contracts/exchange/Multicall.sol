// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title Multicall3
 * @author (based on mudgen's Multicall3)
 * @notice Aggregate multiple read/write calls and optionally forward ETH.
 *         Includes helpers for block metadata and chain/basefee info.
 *
 * Interfaces covered:
 *  - aggregate(Call[])
 *  - tryAggregate(bool, Call[])
 *  - blockAndAggregate(Call[])
 *  - tryBlockAndAggregate(bool, Call[])
 *  - aggregate3(Call3[])
 *  - aggregate3Value(Call3Value[])
 *  - helpers: getBlockHash, getLastBlockHash, getCurrentBlock*(), getBasefee, getChainId, getEthBalance
 */
contract Multicall3 {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                               RECEIVE
    //////////////////////////////////////////////////////////////*/

    // Needed to receive ETH for aggregate3Value calls
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                               AGGREGATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a batch of calls, all must succeed.
    /// @return blockNumber Current block number.
    /// @return returnData Return data for each call in order.
    function aggregate(Call[] calldata calls)
        external
        payable
        returns (uint256 blockNumber, bytes[] memory returnData)
    {
        blockNumber = block.number;
        uint256 length = calls.length;
        returnData = new bytes[](length);

        for (uint256 i = 0; i < length; ) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            require(success, "Multicall3: call failed");
            returnData[i] = ret;
            unchecked { ++i; }
        }
    }

    /// @notice Executes a batch of calls; optionally requires all to succeed.
    /// @param requireSuccess If true, reverts on first failure.
    /// @return returnData Success flag and return data per call.
    function tryAggregate(bool requireSuccess, Call[] calldata calls)
        external
        payable
        returns (Result[] memory returnData)
    {
        uint256 length = calls.length;
        returnData = new Result[](length);

        for (uint256 i = 0; i < length; ) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);

            if (requireSuccess) {
                require(success, "Multicall3: call failed");
            }
            returnData[i] = Result({ success: success, returnData: ret });
            unchecked { ++i; }
        }
    }

    /// @notice Executes a batch of calls, all must succeed, and returns block hash too.
    function blockAndAggregate(Call[] calldata calls)
        external
        payable
        returns (uint256 blockNumber, bytes32 blockHash, Result[] memory returnData)
    {
        blockNumber = block.number;
        blockHash = blockhash(block.number - 1);
        uint256 length = calls.length;
        returnData = new Result[](length);

        for (uint256 i = 0; i < length; ) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            require(success, "Multicall3: call failed");
            returnData[i] = Result({ success: success, returnData: ret });
            unchecked { ++i; }
        }
    }

    /// @notice Executes a batch of calls; optionally requires all to succeed, and returns block hash too.
    function tryBlockAndAggregate(bool requireSuccess, Call[] calldata calls)
        external
        payable
        returns (uint256 blockNumber, bytes32 blockHash, Result[] memory returnData)
    {
        blockNumber = block.number;
        blockHash = blockhash(block.number - 1);
        uint256 length = calls.length;
        returnData = new Result[](length);

        for (uint256 i = 0; i < length; ) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            if (requireSuccess) {
                require(success, "Multicall3: call failed");
            }
            returnData[i] = Result({ success: success, returnData: ret });
            unchecked { ++i; }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         AGGREGATE v3 (allowFailure)
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a batch of calls where each can opt-in to allow failure.
    function aggregate3(Call3[] calldata calls)
        external
        payable
        returns (Result[] memory returnData)
    {
        uint256 length = calls.length;
        returnData = new Result[](length);

        for (uint256 i = 0; i < length; ) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            if (!calls[i].allowFailure) {
                require(success, "Multicall3: call failed");
            }
            returnData[i] = Result({ success: success, returnData: ret });
            unchecked { ++i; }
        }
    }

    /// @notice Executes a batch of calls with ETH value per call and per-call failure policy.
    /// @dev Requires msg.value to exactly match the sum of values to avoid trapping ETH.
    function aggregate3Value(Call3Value[] calldata calls)
        external
        payable
        returns (Result[] memory returnData)
    {
        uint256 length = calls.length;
        returnData = new Result[](length);

        uint256 valueAccumulator = 0;

        for (uint256 i = 0; i < length; ) {
            valueAccumulator += calls[i].value;

            (bool success, bytes memory ret) =
                calls[i].target.call{ value: calls[i].value }(calls[i].callData);

            if (!calls[i].allowFailure) {
                require(success, "Multicall3: call failed");
            }
            returnData[i] = Result({ success: success, returnData: ret });
            unchecked { ++i; }
        }

        require(msg.value == valueAccumulator, "Multicall3: value mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER VIEW FUNCS
    //////////////////////////////////////////////////////////////*/

    function getBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function getBlockHash(uint256 blockNumber_) external view returns (bytes32) {
        return blockhash(blockNumber_);
    }

    function getLastBlockHash() external view returns (bytes32) {
        return blockhash(block.number - 1);
    }

    function getCurrentBlockTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function getCurrentBlockDifficulty() external view returns (uint256) {
        // Post-merge, difficulty is repurposed; kept for compatibility.
        return block.prevrandao;
    }

    function getCurrentBlockGasLimit() external view returns (uint256) {
        return block.gaslimit;
    }

    function getCurrentBlockCoinbase() external view returns (address) {
        return block.coinbase;
    }

    function getChainId() external view returns (uint256 chainId) {
        assembly {
            chainId := chainid()
        }
    }

    function getBasefee() external view returns (uint256) {
        return block.basefee;
    }

    function getEthBalance(address account) external view returns (uint256) {
        return account.balance;
    }
}
