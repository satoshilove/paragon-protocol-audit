// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IParagonFactory
 * @dev Interface for the Paragon Factory contract
 */
interface IParagonFactory {
    // Core events
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);
    event FeeToUpdated(address indexed feeTo);
    event FeeToSetterUpdated(address indexed feeToSetter);
    event SwapFeeUpdated(uint32 swapFeeBips);

    // XPGN config (used by ParagonLibrary pause-guard)
    event XPGNTokenUpdated(address indexed xpgn);

    // Views
    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function swapFeeBips() external view returns (uint32);
    function xpgnToken() external view returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
    function INIT_CODE_PAIR_HASH() external view returns (bytes32);
    function getEffectiveSwapFeeBips(address pair) external view returns (uint32);
    function calculateInitialPairFeeBips(address tokenA, address tokenB) external view returns (uint32 bips, uint8 category);

    // Mutations
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
    function setSwapFee(uint32) external;
    function setXPGNToken(address _xpgnToken) external;
    function setPairSwapFee(address pair, uint32 bips) external;
    function setDefaultNonBaseFees(uint32 nonBaseWithBaseFeeBips, uint32 nonBaseFeeBips) external;
    function setBaseToken(address token, bool isBase) external;
    function setBaseTokens(address[] calldata tokens, bool[] calldata flags) external;
    function setPairAllowlist(address tokenA, address tokenB, bool allowed) external;
    function clearPairSwapFee(address pair) external;
}
