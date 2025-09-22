// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IParagonFactory.sol";
import "./libraries/ParagonLibrary.sol";
import "../XpgnToken/XPGNToken.sol";

contract ParagonRouterAdmin is Ownable {
    uint32 public maxSlippageBips = 50; // 0.5%
    uint32 public maxPriceImpactBips = 100; // 1%
    uint32 public feeOnTransferTolerance = 200; // 2%
    uint32 public twapToleranceBips = 500; // 5%
    uint32 public autoYieldPercent = 300; // 3%
    address public twapOracle;
    bool public useTwap;
    bool public whitelistEnabled;

    mapping(address => bool) public whitelist;

    address public constant XPGN_TOKEN = 0x91F1250f93AD3aEE7315fdeCDC011900795F5DBE;

    // Events...
    event SlippageUpdated(uint32 bips);
    event PriceImpactUpdated(uint32 bips);
    event FeeToleranceUpdated(uint32 tolerance);
    event TwapToleranceUpdated(uint32 tolerance);
    event TwapOracleConfigured(address indexed oracle, bool enabled);
    event WhitelistStatusChanged(bool enabled);
    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);
    event AutoYieldPercentUpdated(uint32 oldPercent, uint32 newPercent);

    constructor(address initialOwner) Ownable(initialOwner) {}

    // === ADMIN SETTERS ===
    function setMaxSlippageBips(uint32 _bips) external onlyOwner {
        require(_bips <= 10000, "INVALID_SLIPPAGE");
        maxSlippageBips = _bips;
        emit SlippageUpdated(_bips);
    }

    function setMaxPriceImpactBips(uint32 _bips) external onlyOwner {
        require(_bips <= 10000, "INVALID_PRICE_IMPACT");
        maxPriceImpactBips = _bips;
        emit PriceImpactUpdated(_bips);
    }

    function setFeeOnTransferTolerance(uint32 _tolerance) external onlyOwner {
        require(_tolerance <= 1000, "INVALID_TOLERANCE");
        feeOnTransferTolerance = _tolerance;
        emit FeeToleranceUpdated(_tolerance);
    }

    function setTwapToleranceBips(uint32 _tolerance) external onlyOwner {
        require(_tolerance <= 2000, "INVALID_TWAP_TOLERANCE");
        twapToleranceBips = _tolerance;
        emit TwapToleranceUpdated(_tolerance);
    }

    function configureTwapOracle(address _oracle, bool _enabled) external onlyOwner {
        if (_enabled) {
            require(_oracle != address(0), "ZERO_ORACLE");
            uint256 size;
            assembly { size := extcodesize(_oracle) }
            require(size > 0, "INVALID_ORACLE");
        }
        twapOracle = _oracle;
        useTwap = _enabled;
        emit TwapOracleConfigured(_oracle, _enabled);
    }

    function setWhitelistEnabled(bool _on) external onlyOwner {
        whitelistEnabled = _on;
        emit WhitelistStatusChanged(_on);
    }

    function addToWhitelist(address _acct) external onlyOwner {
        require(_acct != address(0), "Invalid account");
        whitelist[_acct] = true;
        emit WhitelistAdded(_acct);
    }

    function removeFromWhitelist(address _acct) external onlyOwner {
        require(_acct != address(0), "Invalid account");
        whitelist[_acct] = false;
        emit WhitelistRemoved(_acct);
    }

    function batchUpdateWhitelist(address[] calldata accounts, bool[] calldata statuses) external onlyOwner {
        require(accounts.length == statuses.length, "ARRAY_LENGTH_MISMATCH");
        for (uint i; i < accounts.length;) {
            require(accounts[i] != address(0), "Invalid account");
            whitelist[accounts[i]] = statuses[i];
            if (statuses[i]) {
                emit WhitelistAdded(accounts[i]);
            } else {
                emit WhitelistRemoved(accounts[i]);
            }
            unchecked { ++i; }
        }
    }

    function setAutoYieldPercent(uint32 _percent) external onlyOwner {
        require(_percent <= 500, "INVALID_AUTO_YIELD_PERCENT");
        uint32 oldPercent = autoYieldPercent;
        autoYieldPercent = _percent;
        emit AutoYieldPercentUpdated(oldPercent, _percent);
    }

    // === VALIDATION ===
    function checkPriceImpactMultiHop(address factory, uint amountIn, address[] memory path) external view {
        require(path.length >= 2, "INVALID_PATH");
        uint currentIn = amountIn;
        uint32 swapFeeBips = IParagonFactory(factory).swapFeeBips();

        for (uint i; i < path.length - 1;) {
            if (path[i] == XPGN_TOKEN || path[i + 1] == XPGN_TOKEN) {
                require(!XPGNToken(XPGN_TOKEN).paused(), "XPGN_TOKEN_PAUSED");
            }

            (uint112 reserveA, uint112 reserveB, ) = ParagonLibrary.getReserves(factory, path[i], path[i + 1]);
            require(reserveA > 0 && reserveB > 0, "INSUFFICIENT_LIQUIDITY");

            uint256 priceImpact = (currentIn * 10000) / (reserveA + currentIn);
            require(priceImpact <= maxPriceImpactBips, "PRICE_IMPACT_EXCEEDED");

            currentIn = ParagonLibrary.getAmountOut(currentIn, reserveA, reserveB, swapFeeBips);
            unchecked { ++i; }
        }
    }

    function checkSlippageExactOut(address factory, uint amountOut, uint amountInMax, address[] memory path) external view {
        require(path.length >= 2, "INVALID_PATH");
        uint32 swapFeeBips = IParagonFactory(factory).swapFeeBips();

        if (path[0] == XPGN_TOKEN || path[path.length - 1] == XPGN_TOKEN) {
            require(!XPGNToken(XPGN_TOKEN).paused(), "XPGN_TOKEN_PAUSED");
        }

        if (path.length == 2) {
            (uint112 reserveA, uint112 reserveB, ) = ParagonLibrary.getReserves(factory, path[0], path[1]);
            uint256 expectedIn = (reserveA * amountOut * 10000) / ((reserveB - amountOut) * (10000 - swapFeeBips)) + 1;
            require(expectedIn <= amountInMax, "EXCESSIVE_INPUT_AMOUNT");
        } else {
            uint[] memory amounts = ParagonLibrary.getAmountsIn(factory, amountOut, path);
            require(amounts[0] <= amountInMax, "EXCESSIVE_INPUT_AMOUNT");
        }
    }

    // === VIEWS ===
    function isWhitelisted(address account) external view returns (bool) {
        return whitelist[account];
    }

    function getConfig() external view returns (
        uint32, uint32, uint32, uint32, address, bool, bool
    ) {
        return (
            maxSlippageBips,
            maxPriceImpactBips,
            feeOnTransferTolerance,
            twapToleranceBips,
            twapOracle,
            useTwap,
            whitelistEnabled
        );
    }

    function getMaxSwapAmount(address factory, address[] calldata path) external view returns (uint maxAmount) {
        require(path.length >= 2, "INVALID_PATH");
        maxAmount = type(uint).max;

        for (uint i; i < path.length - 1;) {
            (uint112 reserveA,,) = ParagonLibrary.getReserves(factory, path[i], path[i + 1]);
            if (reserveA > 0) {
                uint maxForHop = (reserveA * maxPriceImpactBips) / (10000 - maxPriceImpactBips);
                if (maxForHop < maxAmount) {
                    maxAmount = maxForHop;
                }
            } else {
                return 0;
            }
            unchecked { ++i; }
        }
    }

    function getPathPriceImpact(address factory, uint amountIn, address[] calldata path) external view returns (uint[] memory impacts) {
        require(path.length >= 2, "INVALID_PATH");
        impacts = new uint[](path.length - 1);
        uint currentIn = amountIn;
        uint32 swapFeeBips = IParagonFactory(factory).swapFeeBips();

        for (uint i; i < path.length - 1;) {
            (uint112 reserveA, uint112 reserveB, ) = ParagonLibrary.getReserves(factory, path[i], path[i + 1]);
            if (reserveA > 0) {
                impacts[i] = (currentIn * 10000) / (reserveA + currentIn);
                currentIn = ParagonLibrary.getAmountOut(currentIn, reserveA, reserveB, swapFeeBips);
            }
            unchecked { ++i; }
        }

        return impacts;
    }

    // === UTILITIES ===
    function validatePath(address[] calldata path) external pure returns (bool valid) {
        if (path.length < 2 || path.length > 5) return false;
        for (uint i; i < path.length - 1; i++) {
            if (path[i] == path[i + 1] || path[i] == address(0)) return false;
        }
        return true;
    }

    function calculateOptimalSlippage(address factory, uint amountIn, address[] calldata path) external view returns (uint32 optimalSlippage) {
        if (path.length < 2) return maxSlippageBips;
        uint[] memory impacts = this.getPathPriceImpact(factory, amountIn, path);
        uint totalImpact;

        for (uint i; i < impacts.length; i++) {
            totalImpact += impacts[i];
        }

        optimalSlippage = uint32(50 + (totalImpact / 2)); // Base 0.5% + dynamic
        if (optimalSlippage > maxSlippageBips) {
            optimalSlippage = maxSlippageBips;
        }
    }

    function isSwapSafe(address factory, uint amountIn, address[] calldata path) external view returns (bool safe, string memory reason) {
        if (!this.validatePath(path)) {
            return (false, "Invalid path");
        }

        try this.checkPriceImpactMultiHop(factory, amountIn, path) {
            uint maxSwap = this.getMaxSwapAmount(factory, path);
            if (amountIn > maxSwap) {
                return (false, "Amount exceeds max swap limit");
            }
            return (true, "");
        } catch Error(string memory err) {
            return (false, err);
        } catch {
            return (false, "Unknown validation error");
        }
    }
}
