// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./lib/ERC20.sol";

contract StakingWarmup {
    address public immutable staking;
    address public immutable sMag;

    constructor(address _staking, address _sMag) {
        require(_staking != address(0));
        staking = _staking;
        require(_sMag != address(0));
        sMag = _sMag;
    }

    function retrieve(address _staker, uint256 _amount) external {
        require(msg.sender == staking);
        IERC20(sMag).transfer(_staker, _amount);
    }
}
