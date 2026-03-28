// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VoterEscrow
/// @notice Checkpointed ve-style escrow with historical reads.
/// @dev Production-hardened:
/// - correct negative slope scheduling
/// - historical balance/supply reads
/// - longer checkpoint catch-up bound (520 weeks)
/// - minimum lock duration enforced at 4 weeks
contract VoterEscrow is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    IERC20 public immutable XPGN;

    uint256 public constant WEEK = 7 days;
    uint256 public constant MIN_LOCK_TIME = 4 weeks;
    uint256 public constant MAXTIME = 4 * 365 days;
    uint256 internal constant MAX_WEEKS_FORWARD = 520; // ~10 years

    // global epoch => point
    uint256 public epoch;
    mapping(uint256 => Point) public pointHistory;

    // future week => delta slope
    mapping(uint256 => int128) public slopeChanges;

    // user => current lock
    mapping(address => LockedBalance) public locked;

    // user => latest user epoch
    mapping(address => uint256) public userPointEpoch;

    // user => epoch => point
    mapping(address => mapping(uint256 => Point)) public userPointHistory;

    event Deposit(
        address indexed provider,
        address indexed beneficiary,
        uint256 value,
        uint256 locktime,
        uint8 depositType,
        uint256 ts
    );
    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event Supply(uint256 previousSupply, uint256 supply);
    event Checkpoint(uint256 indexed globalEpoch, uint256 ts, int128 bias, int128 slope);

    constructor(address _token, address initialOwner) Ownable(initialOwner) {
        require(_token != address(0), "token=0");
        XPGN = IERC20(_token);

        pointHistory[0] = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });
    }

    function token() external view returns (address) {
        return address(XPGN);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================================
    // Lock creation / management
    // ============================================================

    function create_lock(uint256 amount, uint256 unlockTime)
        external
        whenNotPaused
        nonReentrant
    {
        _createLockFor(msg.sender, amount, unlockTime);
    }

    function create_lock_for(
        address to,
        uint256 amount,
        uint256 unlockTime
    ) external whenNotPaused nonReentrant returns (uint256 tokenId) {
        _createLockFor(to, amount, unlockTime);
        return 0;
    }

    function create_lock_for(
        uint256 amount,
        uint256 unlockTime,
        address to
    ) external whenNotPaused nonReentrant returns (uint256 tokenId) {
        _createLockFor(to, amount, unlockTime);
        return 0;
    }

    function _createLockFor(address beneficiary, uint256 amount, uint256 unlockTime) internal {
        require(beneficiary != address(0), "beneficiary=0");
        require(amount > 0, "amount=0");

        LockedBalance memory oldLocked = locked[beneficiary];
        require(oldLocked.amount == 0, "lock exists");

        uint256 end = _roundDownWeek(unlockTime);
        require(end >= block.timestamp + MIN_LOCK_TIME, "min 4 weeks");
        require(end <= block.timestamp + MAXTIME, "end>maxtime");

        LockedBalance memory newLocked = LockedBalance({
            amount: _toInt128(amount),
            end: end
        });

        uint256 supplyBefore = XPGN.balanceOf(address(this));
        locked[beneficiary] = newLocked;

        _checkpoint(beneficiary, oldLocked, newLocked);

        XPGN.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, beneficiary, amount, end, 0, block.timestamp);
        emit Supply(supplyBefore, XPGN.balanceOf(address(this)));
    }

    function increase_amount(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "amount=0");

        LockedBalance memory oldLocked = locked[msg.sender];
        require(oldLocked.amount > 0, "no lock");
        require(oldLocked.end > block.timestamp, "expired");

        LockedBalance memory newLocked = oldLocked;
        newLocked.amount += _toInt128(amount);

        uint256 supplyBefore = XPGN.balanceOf(address(this));
        locked[msg.sender] = newLocked;

        _checkpoint(msg.sender, oldLocked, newLocked);

        XPGN.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, msg.sender, amount, newLocked.end, 1, block.timestamp);
        emit Supply(supplyBefore, XPGN.balanceOf(address(this)));
    }

    function increase_unlock_time(uint256 newUnlockTime) external whenNotPaused nonReentrant {
        LockedBalance memory oldLocked = locked[msg.sender];
        require(oldLocked.amount > 0, "no lock");
        require(oldLocked.end > block.timestamp, "expired");

        uint256 end = _roundDownWeek(newUnlockTime);
        require(end > oldLocked.end, "not extended");
        require(end >= block.timestamp + MIN_LOCK_TIME, "min 4 weeks");
        require(end <= block.timestamp + MAXTIME, "end>maxtime");

        LockedBalance memory newLocked = oldLocked;
        newLocked.end = end;
        locked[msg.sender] = newLocked;

        _checkpoint(msg.sender, oldLocked, newLocked);

        emit Deposit(msg.sender, msg.sender, 0, end, 2, block.timestamp);
    }

    function withdraw() external nonReentrant {
        LockedBalance memory oldLocked = locked[msg.sender];
        require(oldLocked.amount > 0, "nothing");
        require(block.timestamp >= oldLocked.end, "not unlocked");

        LockedBalance memory newLocked = LockedBalance({amount: 0, end: 0});
        locked[msg.sender] = newLocked;

        _checkpoint(msg.sender, oldLocked, newLocked);

        uint256 value = uint256(uint128(oldLocked.amount));
        XPGN.safeTransfer(msg.sender, value);

        emit Withdraw(msg.sender, value, block.timestamp);
    }

    function checkpoint() external {
        LockedBalance memory empty;
        _checkpoint(address(0), empty, empty);
    }

    // ============================================================
    // Views
    // ============================================================

    function balanceOf(address addr) public view returns (uint256) {
        uint256 uEpoch = userPointEpoch[addr];
        if (uEpoch == 0) return 0;

        Point memory pt = userPointHistory[addr][uEpoch];
        if (block.timestamp < pt.ts) return 0;

        int256 bias = int256(pt.bias) - int256(pt.slope) * int256(block.timestamp - pt.ts);
        if (bias <= 0) return 0;
        return uint256(bias);
    }

    function balanceOfAtTime(address addr, uint256 ts) public view returns (uint256) {
        uint256 uEpoch = _findUserEpoch(addr, ts);
        if (uEpoch == 0) return 0;

        Point memory pt = userPointHistory[addr][uEpoch];
        if (ts < pt.ts) return 0;

        int256 bias = int256(pt.bias) - int256(pt.slope) * int256(ts - pt.ts);
        if (bias <= 0) return 0;
        return uint256(bias);
    }

    function totalSupply() public view returns (uint256) {
        return totalSupplyAtTime(block.timestamp);
    }

    function totalSupplyAtTime(uint256 ts) public view returns (uint256) {
        uint256 gEpoch = _findGlobalEpoch(ts);
        Point memory pt = pointHistory[gEpoch];
        return _supplyAt(pt, ts);
    }

    // ============================================================
    // Internal checkpointing
    // ============================================================

    function _checkpoint(
        address addr,
        LockedBalance memory oldLocked,
        LockedBalance memory newLocked
    ) internal {
        Point memory uOld;
        Point memory uNew;
        int128 oldDSlope;
        int128 newDSlope;

        if (addr != address(0)) {
            if (oldLocked.end > block.timestamp && oldLocked.amount > 0) {
                uOld.slope = oldLocked.amount / int128(int256(MAXTIME));
                uOld.bias = uOld.slope * _toInt128(oldLocked.end - block.timestamp);
            }
            if (newLocked.end > block.timestamp && newLocked.amount > 0) {
                uNew.slope = newLocked.amount / int128(int256(MAXTIME));
                uNew.bias = uNew.slope * _toInt128(newLocked.end - block.timestamp);
            }

            oldDSlope = slopeChanges[oldLocked.end];
            if (newLocked.end != 0) {
                if (newLocked.end == oldLocked.end) {
                    newDSlope = oldDSlope;
                } else {
                    newDSlope = slopeChanges[newLocked.end];
                }
            }
        }

        uint256 _epoch = epoch;
        Point memory lastPoint = pointHistory[_epoch];
        uint256 lastCheckpointTs = lastPoint.ts;

        if (block.timestamp > lastPoint.ts) {
            uint256 ti = _roundDownWeek(lastCheckpointTs);

            for (uint256 i = 0; i < MAX_WEEKS_FORWARD; ++i) {
                ti += WEEK;
                int128 dSlope = 0;

                if (ti > block.timestamp) {
                    ti = block.timestamp;
                } else {
                    dSlope = slopeChanges[ti];
                }

                int256 newBias = int256(lastPoint.bias) - int256(lastPoint.slope) * int256(ti - lastCheckpointTs);
                if (newBias < 0) newBias = 0;

                int256 newSlope = int256(lastPoint.slope) + int256(dSlope);
                if (newSlope < 0) newSlope = 0;

                lastPoint.bias = int128(newBias);
                lastPoint.slope = int128(newSlope);
                lastCheckpointTs = ti;
                lastPoint.ts = ti;
                lastPoint.blk = block.number;

                _epoch += 1;
                pointHistory[_epoch] = lastPoint;

                if (ti == block.timestamp) {
                    break;
                }
            }
        }

        epoch = _epoch;

        if (addr != address(0)) {
            int256 bias_ = int256(lastPoint.bias) + int256(uNew.bias) - int256(uOld.bias);
            int256 slope_ = int256(lastPoint.slope) + int256(uNew.slope) - int256(uOld.slope);

            if (bias_ < 0) bias_ = 0;
            if (slope_ < 0) slope_ = 0;

            lastPoint.bias = int128(bias_);
            lastPoint.slope = int128(slope_);
            pointHistory[_epoch] = lastPoint;

            // old end: cancel previously scheduled negative slope, then re-apply based on new state
            if (oldLocked.end > block.timestamp) {
                oldDSlope += uOld.slope;
                if (newLocked.end == oldLocked.end) {
                    oldDSlope -= uNew.slope;
                }
                slopeChanges[oldLocked.end] = oldDSlope;
            }

            // new end: schedule negative slope at expiry
            if (newLocked.end > block.timestamp && newLocked.end > oldLocked.end) {
                newDSlope -= uNew.slope;
                slopeChanges[newLocked.end] = newDSlope;
            }

            uint256 userEpoch_ = userPointEpoch[addr] + 1;
            userPointEpoch[addr] = userEpoch_;

            uNew.ts = block.timestamp;
            uNew.blk = block.number;
            userPointHistory[addr][userEpoch_] = uNew;
        }

        emit Checkpoint(_epoch, block.timestamp, pointHistory[_epoch].bias, pointHistory[_epoch].slope);
    }

    function _supplyAt(Point memory point, uint256 t) internal view returns (uint256) {
        Point memory lastPoint = point;
        uint256 ti = _roundDownWeek(lastPoint.ts);

        for (uint256 i = 0; i < MAX_WEEKS_FORWARD; ++i) {
            ti += WEEK;
            int128 dSlope = 0;

            if (ti > t) {
                ti = t;
            } else {
                dSlope = slopeChanges[ti];
            }

            int256 bias = int256(lastPoint.bias) - int256(lastPoint.slope) * int256(ti - lastPoint.ts);
            if (bias < 0) bias = 0;

            lastPoint.bias = int128(bias);
            if (ti == t) break;

            int256 slope_ = int256(lastPoint.slope) + int256(dSlope);
            if (slope_ < 0) slope_ = 0;

            lastPoint.slope = int128(slope_);
            lastPoint.ts = ti;
        }

        if (lastPoint.bias < 0) return 0;
        return uint256(uint128(lastPoint.bias));
    }

    function _findUserEpoch(address addr, uint256 ts) internal view returns (uint256) {
        uint256 min = 0;
        uint256 max = userPointEpoch[addr];

        for (uint256 i = 0; i < 128; ++i) {
            if (min >= max) break;
            uint256 mid = (min + max + 1) / 2;
            if (userPointHistory[addr][mid].ts <= ts) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    function _findGlobalEpoch(uint256 ts) internal view returns (uint256) {
        uint256 min = 0;
        uint256 max = epoch;

        for (uint256 i = 0; i < 128; ++i) {
            if (min >= max) break;
            uint256 mid = (min + max + 1) / 2;
            if (pointHistory[mid].ts <= ts) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    function _roundDownWeek(uint256 t) internal pure returns (uint256) {
        return (t / WEEK) * WEEK;
    }

    function _toInt128(uint256 x) internal pure returns (int128) {
        require(x <= uint256(uint128(type(int128).max)), "int128 overflow");
        return int128(uint128(x));
    }
}