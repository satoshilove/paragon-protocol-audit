// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IGC {
    function n_gauges() external view returns (uint256);
    function gaugesAt(uint256 i) external view returns (address);
    function totalWeightNow() external view returns (uint256);
    function gaugeWeightNow(address gauge) external view returns (uint256);
    function isGauge(address gauge) external view returns (bool);
}

contract GaugeEmitterToFarmBps is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable reward;
    IGC public immutable controller;
    address public farm;

    mapping(address => uint256) public poolIdOf;
    mapping(address => bool) public isGaugeMapped;

    event FarmSet(address farm);
    event GaugeMapped(address gauge, uint256 poolId);
    event Notified(uint256 weekTs, uint256 amount);

    constructor(address _reward, address _controller, address _farm, address _owner) Ownable(_owner) {
        require(_reward != address(0) && _controller != address(0) && _farm != address(0) && _owner != address(0), "bad args");
        reward = IERC20(_reward);
        controller = IGC(_controller);
        farm = _farm;
    }

    function setFarm(address f) external onlyOwner {
        require(f != address(0), "farm=0");
        farm = f;
        emit FarmSet(f);
    }

    function setPoolId(address gauge, uint256 pid) external onlyOwner {
        require(gauge != address(0), "g=0");
        poolIdOf[gauge] = pid;
        isGaugeMapped[gauge] = true;
        emit GaugeMapped(gauge, pid);
    }

    function notifyRewardAmount(uint256 weekTs, uint256 amount) external onlyOwner {
        reward.safeTransferFrom(msg.sender, address(this), amount);

        uint256 tot = controller.totalWeightNow();
        require(tot > 0, "no weights");

        uint256 n = controller.n_gauges();
        uint256 allocated;

        for (uint256 i = 0; i < n; ++i) {
            address g = controller.gaugesAt(i);
            if (!controller.isGauge(g)) continue;
            if (!isGaugeMapped[g]) continue;

            uint256 w = controller.gaugeWeightNow(g);
            if (w == 0) continue;

            uint256 share = (amount * w) / tot;
            if (share == 0) continue;

            allocated += share;
            reward.safeTransfer(farm, share);

            uint256 pid = poolIdOf[g];
            (bool ok,) = farm.call(
                abi.encodeWithSignature("notifyRewardAmount(uint256,uint256)", pid, share)
            );

            if (!ok) {
                (ok,) = farm.call(
                    abi.encodeWithSignature(
                        "notifyRewardAmount(uint256,address,uint256)",
                        pid,
                        address(reward),
                        share
                    )
                );
                require(ok, "farm notify failed");
            }
        }

        emit Notified(weekTs, allocated);
    }
}