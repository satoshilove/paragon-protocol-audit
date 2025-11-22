// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IParagonFactory.sol";
import "./interfaces/IParagonPair.sol";
import "./libraries/ParagonLibrary.sol";

library ParagonRouterSwapHelper {
    function swap(
        uint256[] memory amounts,
        address[] memory path,
        address factory,
        address to
    ) internal {
        unchecked {
            address factory_ = factory;
            for (uint256 i; i < path.length - 1; ++i) {
                address input  = path[i];
                address output = path[i + 1];
                (address token0, ) = ParagonLibrary.sortTokens(input, output);

                uint256 amountOut = amounts[i + 1];
                (uint256 amount0Out, uint256 amount1Out) =
                    input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));

                address pair   = ParagonLibrary.pairFor(factory_, input, output);
                address nextTo = i < path.length - 2
                    ? ParagonLibrary.pairFor(factory_, output, path[i + 2])
                    : to;

                IParagonPair(pair).swap(amount0Out, amount1Out, nextTo, new bytes(0));
            }
        }
    }

    function swapSupportingFeeOnTransferTokens(
        address[] memory path,
        address factory,
        address to
    ) internal {
        unchecked {
            address factory_ = factory;
            for (uint256 i; i < path.length - 1; ++i) {
                address input  = path[i];
                address output = path[i + 1];
                (address token0, ) = ParagonLibrary.sortTokens(input, output);

                address pairAddr = ParagonLibrary.pairFor(factory_, input, output);
                IParagonPair pair = IParagonPair(pairAddr);

                (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
                (uint256 reserveIn, uint256 reserveOut) =
                    input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);

                uint256 balIn = IERC20(input).balanceOf(pairAddr);
                require(balIn > reserveIn, "FOT_INSUFF_INPUT");
                uint256 amountIn = balIn - reserveIn;

                uint32 feeBips = IParagonFactory(factory_).getEffectiveSwapFeeBips(pairAddr);
                uint256 amountOut = ParagonLibrary.getAmountOut(amountIn, reserveIn, reserveOut, feeBips);

                (uint256 amount0Out, uint256 amount1Out) =
                    input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));

                address nextTo = i < path.length - 2
                    ? ParagonLibrary.pairFor(factory_, output, path[i + 2])
                    : to;

                pair.swap(amount0Out, amount1Out, nextTo, new bytes(0));
            }
        }
    }
}
