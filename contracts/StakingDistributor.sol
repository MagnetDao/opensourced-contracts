// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity 0.7.5;

import "./lib/SafeMath.sol";
import "./lib/Address.sol";
import "./lib/SafeERC20.sol";
import "./lib/Ownable.sol";

interface ITreasury {
    function mintRewards(address _recipient, uint256 _amount) external;
}

contract Distributor is Ownable {
    using SafeMath for uint256;
    using SafeMath for uint32;
    using SafeERC20 for IERC20;

    /* ====== VARIABLES ====== */

    address public immutable MAG;
    address public immutable treasury;

    uint32 public immutable epochLength;
    uint32 public nextEpochTime;

    mapping(uint256 => Adjust) public adjustments;

    /* ====== STRUCTS ====== */

    struct Info {
        uint256 rate; // in ten-thousandths ( 5000 = 0.5% )
        address recipient;
    }
    Info[] public dinfo;

    struct Adjust {
        bool add;
        uint256 rate;
        uint256 target;
    }

    /* ====== CONSTRUCTOR ====== */

    constructor(
        address _treasury,
        address _mag,
        uint32 _epochLength,
        uint32 _nextEpochTime
    ) {
        require(_treasury != address(0));
        treasury = _treasury;
        require(_mag != address(0));
        MAG = _mag;
        epochLength = _epochLength;
        nextEpochTime = _nextEpochTime;
    }

    /* ====== PUBLIC FUNCTIONS ====== */

    /**
        @notice send epoch reward to staking contract
     */
    function distribute() external returns (bool) {
        if (nextEpochTime <= uint32(block.timestamp)) {
            nextEpochTime = nextEpochTime.add32(epochLength); // set next epoch time

            // distribute rewards to each recipient
            for (uint256 i = 0; i < dinfo.length; i++) {
                if (dinfo[i].rate > 0) {
                    ITreasury(treasury).mintRewards( // mint and send from treasury
                        dinfo[i].recipient,
                        nextRewardAt(dinfo[i].rate)
                    );
                    adjust(i); // check for adjustment
                }
            }
            return true;
        } else {
            return false;
        }
    }

    /* ====== INTERNAL FUNCTIONS ====== */

    /**
        @notice increment reward rate for collector
     */
    function adjust(uint256 _index) internal {
        Adjust memory adjustment = adjustments[_index];
        if (adjustment.rate != 0) {
            if (adjustment.add) {
                // if rate should increase
                dinfo[_index].rate = dinfo[_index].rate.add(adjustment.rate); // raise rate
                if (dinfo[_index].rate >= adjustment.target) {
                    // if target met
                    adjustments[_index].rate = 0; // turn off adjustment
                }
            } else {
                // if rate should decrease
                dinfo[_index].rate = dinfo[_index].rate.sub(adjustment.rate); // lower rate
                if (dinfo[_index].rate <= adjustment.target) {
                    // if target met
                    adjustments[_index].rate = 0; // turn off adjustment
                }
            }
        }
    }

    /* ====== VIEW FUNCTIONS ====== */

    /**
        @notice view function for next reward at given rate
        @param _rate uint
        @return uint
     */
    function nextRewardAt(uint256 _rate) public view returns (uint256) {
        return IERC20(MAG).totalSupply().mul(_rate).div(1000000);
    }

    /**
        @notice view function for next reward for specified address
        @param _recipient address
        @return uint
     */
    function nextRewardFor(address _recipient) public view returns (uint256) {
        uint256 reward;
        for (uint256 i = 0; i < dinfo.length; i++) {
            if (dinfo[i].recipient == _recipient) {
                reward = nextRewardAt(dinfo[i].rate);
            }
        }
        return reward;
    }

    /* ====== POLICY FUNCTIONS ====== */

    /**
        @notice adds recipient for distributions
        @param _recipient address
        @param _rewardRate uint
     */
    function addRecipient(address _recipient, uint256 _rewardRate)
        external
        onlyManager
    {
        require(_recipient != address(0));
        dinfo.push(Info({recipient: _recipient, rate: _rewardRate}));
    }

    /**
        @notice removes recipient for distributions
        @param _index uint
        @param _recipient address
     */
    function removeRecipient(uint256 _index, address _recipient)
        external
        onlyManager
    {
        require(_recipient == dinfo[_index].recipient);
        dinfo[_index].recipient = address(0);
        dinfo[_index].rate = 0;
    }

    /**
        @notice set adjustment info for a collector's reward rate
        @param _index uint
        @param _add bool
        @param _rate uint
        @param _target uint
     */
    function setAdjustment(
        uint256 _index,
        bool _add,
        uint256 _rate,
        uint256 _target
    ) external onlyManager {
        adjustments[_index] = Adjust({add: _add, rate: _rate, target: _target});
    }
}
