// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IParagonPair
 * @notice Interface for Paragon (UniV2-style) liquidity pair
 * @dev ABI matches ParagonPair exactly. `getReserves` returns a tuple (not a struct).
 */
interface IParagonPair {
    // ─────────────────────────────
    // Events
    // ─────────────────────────────

    /// @notice Emitted when liquidity is minted (LP tokens created)
    /// @param sender Address that provided the liquidity (msg.sender)
    /// @param amount0 Net token0 added
    /// @param amount1 Net token1 added
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);

    /// @notice Emitted when liquidity is burned (LP tokens destroyed)
    /// @param sender Address that initiated the burn (msg.sender)
    /// @param amount0 Token0 returned to `to`
    /// @param amount1 Token1 returned to `to`
    /// @param to Recipient of the underlying amounts
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);

    /// @notice Emitted on each successful swap
    /// @param sender Address that initiated the swap (msg.sender)
    /// @param amount0In Actual token0 input amount
    /// @param amount1In Actual token1 input amount
    /// @param amount0Out Token0 sent out to `to`
    /// @param amount1Out Token1 sent out to `to`
    /// @param to Recipient of the output tokens
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    /// @notice Emitted whenever reserves are synced/updated
    /// @param reserve0 New reserve for token0
    /// @param reserve1 New reserve for token1
    event Sync(uint112 reserve0, uint112 reserve1);

    // ─────────────────────────────
    // Immutable / public views
    // ─────────────────────────────

    /// @notice Minimum liquidity locked forever at first mint
    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    /// @notice Factory that deployed this pair
    function factory() external view returns (address);

    /// @notice Sorted token addresses (token0 < token1)
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Current reserves and last block timestamp (mod 2**32)
    /// @return reserve0 Reserve of token0
    /// @return reserve1 Reserve of token1
    /// @return blockTimestampLast Last block timestamp recorded (mod 2**32)
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice Cumulative prices used for TWAP
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);

    /// @notice Last value of reserve0 * reserve1, updated on liquidity events
    function kLast() external view returns (uint256);

    // ─────────────────────────────
    // Core actions
    // ─────────────────────────────

    /// @notice Mint liquidity to `to`
    /// @param to Recipient of LP tokens
    /// @return liquidity Amount of LP tokens minted
    function mint(address to) external returns (uint256 liquidity);

    /// @notice Burn liquidity from this pair and send underlying to `to`
    /// @param to Recipient of underlying tokens
    /// @return amount0 Amount of token0 sent
    /// @return amount1 Amount of token1 sent
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swap tokens, optionally with callback data (flash support)
    /// @param amount0Out Amount of token0 to send to `to`
    /// @param amount1Out Amount of token1 to send to `to`
    /// @param to Recipient address
    /// @param data Callback data; if non-empty, `paragonCall` will be invoked on `to`
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /// @notice Transfer any extra token balances to `to`
    function skim(address to) external;

    /// @notice Force reserves to match current token balances
    function sync() external;

    /// @notice One-time initializer called by Factory; tokens must be sorted
    /// @param _token0 Address of token0 (must be < _token1)
    /// @param _token1 Address of token1
    function initialize(address _token0, address _token1) external;
}
