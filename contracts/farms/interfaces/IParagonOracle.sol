// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IParagonOracle
 * @dev Interface for the Paragon Oracle contract
 */
interface IParagonOracle {
    function validateOraclePrice(
        uint amountIn, 
        uint amountOut, 
        address[] memory path, 
        uint maxSlippageBips, 
        bool useChainlink
    ) external view returns (bool);
    
    function getTwapAmountOut(
        uint amountIn, 
        address tokenIn, 
        address tokenOut, 
        uint32 minTimeWindow
    ) external view returns (uint amountOut);
    
    function getAmountsOutUsingTwap(
        uint amountIn, 
        address[] memory path, 
        uint32 timeWindow
    ) external view returns (uint[] memory amounts);
    
    function getAmountsOutUsingChainlink(
        uint amountIn, 
        address[] memory path
    ) external view returns (uint[] memory amounts);
    
    function hasChainlinkFeed(address token) external view returns (bool);
    
    function canUseTwap(address tokenA, address tokenB, uint32 minTimeWindow) external view returns (bool canUse, string memory reason);
    
    function consult(address tokenIn, uint amountIn, address tokenOut) external view returns (uint amountOut);
    
    function consultIn(address tokenIn, address tokenOut, uint amountOut) external view returns (uint amountIn);
}