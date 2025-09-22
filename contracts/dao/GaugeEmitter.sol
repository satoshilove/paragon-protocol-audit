// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IGC {
    function n_gauges() external view returns (uint256);
    function gaugesAt(uint256) external view returns (address);
    function gaugeWeight(address) external view returns (uint256);
    function totalWeight() external view returns (uint256);
}

contract GaugeEmitterToFarmBps is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable reward;       // XPGN
    IGC    public immutable controller;   // GaugeController (BPS)
    address public farm;                  // FarmController
    mapping(address => uint256) public poolIdOf; // gauge -> farm poolId

    event FarmSet(address farm);
    event GaugeMapped(address gauge, uint256 poolId);
    event Notified(uint256 weekTs, uint256 amount);

    constructor(address _reward, address _controller, address _farm, address _owner) Ownable(_owner) {
        require(_reward != address(0) && _controller != address(0) && _farm != address(0) && _owner != address(0), "Emitter: zero");
        reward = IERC20(_reward);
        controller = IGC(_controller);
        farm = _farm;
    }

    function setFarm(address f) external onlyOwner {
        require(f != address(0), "Emitter: farm=0");
        farm = f;
        emit FarmSet(f);
    }

    function setPoolId(address gauge, uint256 pid) external onlyOwner {
        require(gauge != address(0), "Emitter: gauge=0");
        poolIdOf[gauge] = pid;
        emit GaugeMapped(gauge, pid);
    }

    /// @notice Treasury/owner calls this weekly after giving allowance to this contract.
    /// @dev Distributes `amount` across gauges pro-rata by controller BPS weight.
    ///      Any integer-division dust remains in this contract (unchanged from original behavior).
    function notifyRewardAmount(uint256 weekTs, uint256 amount) external onlyOwner {
        reward.safeTransferFrom(msg.sender, address(this), amount);

        uint256 tot = controller.totalWeight();
        require(tot > 0, "no weights");

        uint256 n = controller.n_gauges();
        for (uint256 i = 0; i < n; i++) {
            address g = controller.gaugesAt(i);
            uint256 w = controller.gaugeWeight(g);
            if (w == 0) continue;

            uint256 pid = poolIdOf[g];

            // NOTE: This preserves the original semantics: if mapping is unset and pid == 0,
            // the gauge is skipped. If your farm uses poolId=0 as a valid pool, this will also
            // skip it (matching the original behavior).
            if (pid == 0 && poolIdOf[g] == 0) continue;

            uint256 share = (amount * w) / tot;
            if (share == 0) continue;

            // push tokens to farm
            reward.safeTransfer(farm, share);

            // notify farm (try two common signatures)
            (bool ok, ) = farm.call(abi.encodeWithSignature("notifyRewardAmount(uint256,uint256)", pid, share));
            if (!ok) {
                (ok, ) = farm.call(abi.encodeWithSignature("notifyRewardAmount(uint256,address,uint256)", pid, address(reward), share));
                require(ok, "farm notify failed");
            }
        }

        emit Notified(weekTs, amount);
    }
}
