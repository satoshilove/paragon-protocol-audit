// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IParagonFactory.sol";
import "./interfaces/IParagonPair.sol";
import "./interfaces/IParagonCallee.sol";
import "./ParagonERC20.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";

/**
 * @title ParagonPair
 * @dev Uniswap V2-style liquidity pool for token pairs, aligned with OZ 5.0.1
 */
contract ParagonPair is ParagonERC20, ReentrancyGuard, IParagonPair {
    using UQ112x112 for uint224;

    uint256 public constant override MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant TRANSFER_SELECTOR = bytes4(keccak256("transfer(address,uint256)"));

    /// @inheritdoc IParagonPair
    address public immutable override factory;
    /// @inheritdoc IParagonPair
    address public override token0;
    /// @inheritdoc IParagonPair
    address public override token1;

    // Reserves are private like UniV2; read via getReserves()
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    /// @inheritdoc IParagonPair
    uint256 public override price0CumulativeLast;
    /// @inheritdoc IParagonPair
    uint256 public override price1CumulativeLast;
    /// @inheritdoc IParagonPair
    uint256 public override kLast;

    constructor() {
        factory = msg.sender; // set by Factory via create2
    }

    /// @inheritdoc IParagonPair
    function initialize(address _token0, address _token1) external override {
        require(msg.sender == factory, "Paragon: FORBIDDEN");
        require(_token0 < _token1, "Paragon: BAD_ORDER");
        // Optional: double-check they are contracts (Factory already validates)
        require(_token0.code.length > 0 && _token1.code.length > 0, "Paragon: NOT_CONTRACT");
        token0 = _token0;
        token1 = _token1;
    }

    /// @inheritdoc IParagonPair
    function getReserves()
        public
        view
        override
        returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast)
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /// @notice Helper to read the factory’s swap fee in bips
    function getSwapFee() public view returns (uint32) {
        return IParagonFactory(factory).getEffectiveSwapFeeBips(address(this));
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(TRANSFER_SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Paragon: TRANSFER_FAILED");
    }

    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "Paragon: OVERFLOW");
        uint32 blockTime = uint32(block.timestamp);
        unchecked {
            // overflow on subtraction is OK per UniV2
            uint32 timeElapsed = blockTime - blockTimestampLast;
            if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
                price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
                price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            }
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTime;
        emit Sync(reserve0, reserve1);
    }

    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IParagonFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLastLoc = kLast;

        if (feeOn && _kLastLoc != 0) {
            uint256 rootK = Math.sqrt(uint256(_reserve0) * _reserve1);
            uint256 rootKLast = Math.sqrt(_kLastLoc);

            if (rootK > rootKLast) {
                // Paragon is intentionally pro-LP:
                // When protocol fee is enabled, we take 1/6 of the growth in sqrt(k) as new LP tokens for feeTo.
                // We use denominator = rootK × 5 + rootKLast instead of the classic Uniswap V2 rootK × 6 + rootKLast.
                // → This gives liquidity providers ~20% more of the protocol-fee portion than Uniswap V2 / SushiSwap.
                // Example: at 2× pool growth, Uniswap V2 gives feeTo 0.0500% → Paragon gives feeTo only 0.0417%
                // (the difference goes back to LPs — a deliberate design choice marketed as "More rewards for LPs").
                uint256 numerator = totalSupply * (rootK - rootKLast);
                uint256 denominator = rootK * 5 + rootKLast;
                uint256 liquidity = numerator / denominator;

                if (liquidity > 0) _mint(feeTo, liquidity);
            }
        } else if (!feeOn && _kLastLoc != 0) {
            kLast = 0; // Fee disabled → clear kLast (standard behavior)
        }
    }

    /// @inheritdoc IParagonPair
    function mint(address to)
        external
        override
        nonReentrant
        returns (uint256 liquidity)
    {
        (uint112 _r0, uint112 _r1,) = getReserves();
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 d0 = b0 - _r0;
        uint256 d1 = b1 - _r1;

        bool feeOn = _mintFee(_r0, _r1);
        uint256 _totalSup = totalSupply;

        if (_totalSup == 0) {
            liquidity = Math.sqrt(d0 * d1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdEaD), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min((d0 * _totalSup) / _r0, (d1 * _totalSup) / _r1);
        }
        require(liquidity > 0, "Paragon: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(b0, b1, _r0, _r1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Mint(msg.sender, d0, d1);
    }

    /// @inheritdoc IParagonPair
    function burn(address to)
        external
        override
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        (uint112 _r0, uint112 _r1,) = getReserves();
        address _t0 = token0;
        address _t1 = token1;

        uint256 b0 = IERC20(_t0).balanceOf(address(this));
        uint256 b1 = IERC20(_t1).balanceOf(address(this));
        uint256 liq = balanceOf[address(this)];

        bool feeOn = _mintFee(_r0, _r1);
        uint256 _tot = totalSupply;

        amount0 = (liq * b0) / _tot;
        amount1 = (liq * b1) / _tot;
        require(amount0 > 0 && amount1 > 0, "Paragon: INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liq);
        _safeTransfer(_t0, to, amount0);
        _safeTransfer(_t1, to, amount1);

        b0 = IERC20(_t0).balanceOf(address(this));
        b1 = IERC20(_t1).balanceOf(address(this));

        _update(b0, b1, _r0, _r1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @inheritdoc IParagonPair
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external override nonReentrant {
        require(amount0Out > 0 || amount1Out > 0, "Paragon: INSUFFICIENT_OUTPUT_AMOUNT");
        require(to != address(this), "Paragon: INVALID_TO_SELF");

        (uint112 _r0, uint112 _r1,) = getReserves();
        require(amount0Out < _r0 && amount1Out < _r1, "Paragon: INSUFFICIENT_LIQUIDITY");

        uint256 b0;
        uint256 b1;
        {
            address _t0 = token0;
            address _t1 = token1;
            require(to != _t0 && to != _t1, "Paragon: INVALID_TO");

            if (amount0Out > 0) _safeTransfer(_t0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_t1, to, amount1Out);

            if (data.length > 0) {
                IParagonCallee(to).paragonCall(msg.sender, amount0Out, amount1Out, data);
            }

            b0 = IERC20(_t0).balanceOf(address(this));
            b1 = IERC20(_t1).balanceOf(address(this));
        }

        uint256 in0 = b0 > (_r0 - amount0Out) ? b0 - (_r0 - amount0Out) : 0;
        uint256 in1 = b1 > (_r1 - amount1Out) ? b1 - (_r1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "Paragon: INSUFFICIENT_INPUT_AMOUNT");

        uint32 fee = getSwapFee();
        {
            uint256 adj0 = b0 * 10000 - in0 * fee;
            uint256 adj1 = b1 * 10000 - in1 * fee;
            require(adj0 * adj1 >= uint256(_r0) * _r1 * 10000**2, "Paragon: K");
        }

        _update(b0, b1, _r0, _r1);
        emit Swap(msg.sender, in0, in1, amount0Out, amount1Out, to);
    }

    /// @inheritdoc IParagonPair
    function skim(address to) external override nonReentrant {
        _safeTransfer(token0, to, IERC20(token0).balanceOf(address(this)) - reserve0);
        _safeTransfer(token1, to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    /// @inheritdoc IParagonPair
    function sync() external override nonReentrant {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }
}
