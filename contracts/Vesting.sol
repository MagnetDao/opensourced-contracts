// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./lib/SafeERC20.sol";
import "./lib/Ownable.sol";
import "./lib/SafeMath.sol";

interface IMagStaking {
    function stake(uint256 _amount, address _recipient) external returns (bool);

    function unstake(uint256 _amount, bool _trigger) external;

    function claim(address _recipient) external;
}

interface IsMag {
    function index() external view returns (uint256);
}

// vest mag, and the staking contract will stake them
// 1 year, linear vest, weekly unlock
// how to allocate later
contract Vesting is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public vestingToken;
    address public stakingContract;
    address public stakingToken;

    event Withdrawal(
        address indexed addr,
        uint256 amountFromInitial,
        uint256 totalAmount
    );

    uint256 totalAmountWithdrawn;
    uint256 totalAmountAdded;
    uint256 totalAMountWithdrawnFromAdded;

    struct ReceiverInfo {
        uint256 initialVestedTokens;
        uint256 amountRedemed;
        uint256 amountRedeemedFromInitialTokens;
        uint256 startDate;
        uint256 periodLength;
        uint256 numberOfPeriods;
        bool authorized;
    }

    mapping(address => ReceiverInfo) public receiverInfoMap;

    constructor(
        address _vestingToken,
        address _stakingContract,
        address _stakingToken
    ) {
        vestingToken = _vestingToken;
        stakingToken = _stakingToken;
        stakingContract = _stakingContract;
    }

    function setStaking(address _address) public onlyManager {
        // in case the staking contract changes
        require(_address != address(0));
        unstakeAllTokens();
        stakingContract = _address;
        stakeAllTokens();
    }

    function addReceiver(
        address _address,
        uint256 _amount,
        uint256 _startDate,
        uint256 _periodLength,
        uint256 _numberOfPeriod
    ) public onlyManager {
        require(
            !receiverInfoMap[_address].authorized,
            "Adress already have Vested tokens"
        );
        receiverInfoMap[_address] = ReceiverInfo({
            initialVestedTokens: _amount,
            amountRedemed: 0,
            amountRedeemedFromInitialTokens: 0,
            startDate: _startDate,
            periodLength: _periodLength,
            numberOfPeriods: _numberOfPeriod,
            authorized: true
        });
    }

    function deposit(uint256 _amount) public onlyManager {
        IERC20(vestingToken).transferFrom(msg.sender, address(this), _amount);
        stakeDepositedTokens(_amount);
        totalAmountAdded += _amount;
    }

    function stakeDepositedTokens(uint256 _amount) internal {
        IERC20(vestingToken).approve(stakingContract, _amount);
        IMagStaking(stakingContract).stake(_amount, address(this));
        IMagStaking(stakingContract).claim(address(this));
    }

    function withdrawDepositedTokens(uint256 _amount) internal {
        IERC20(stakingToken).approve(stakingContract, _amount);
        IMagStaking(stakingContract).unstake(_amount, true);
    }

    function remainingToWithdraw() public view returns (uint256 amount) {
        ReceiverInfo memory userInfo = receiverInfoMap[msg.sender];
        uint256 notWithdrawed = userInfo.initialVestedTokens -
            userInfo.amountRedeemedFromInitialTokens;
        amount = notWithdrawed * IsMag(stakingToken).index();
    }

    function unstakeAllTokens() internal {
        uint256 amount = IERC20(stakingToken).balanceOf(address(this));
        withdrawDepositedTokens(amount);
    }

    function stakeAllTokens() internal {
        uint256 amount = IERC20(vestingToken).balanceOf(address(this));
        stakeDepositedTokens(amount);
    }

    function withdraw() public {
        ReceiverInfo memory userInfo = receiverInfoMap[msg.sender];
        require(userInfo.authorized, "not authorized");
        require(
            userInfo.amountRedeemedFromInitialTokens <
                userInfo.initialVestedTokens,
            "Already withdrawn all tokens"
        );

        uint256 timeSinceStart = block.timestamp.sub(userInfo.startDate);
        uint256 validPeriodCount = timeSinceStart / userInfo.periodLength;
        if (validPeriodCount > userInfo.numberOfPeriods) {
            validPeriodCount = userInfo.numberOfPeriods;
        }
        uint256 amountPerPeriod = userInfo.initialVestedTokens.div(
            userInfo.numberOfPeriods
        );

        uint256 alreadyWithdrawn = userInfo.amountRedeemedFromInitialTokens;

        uint256 withdrawableAmountFromInitial = validPeriodCount
            .mul(amountPerPeriod)
            .sub(alreadyWithdrawn);
        require(
            withdrawableAmountFromInitial > 0,
            "vesting: no withdrawable tokens"
        );
        uint256 index = IsMag(stakingToken).index();
        uint256 withdrawableAmount = withdrawableAmountFromInitial
            .mul(index)
            .div(10**9);
        // transfer token
        withdrawDepositedTokens(withdrawableAmount);
        require(IERC20(vestingToken).transfer(msg.sender, withdrawableAmount));
        receiverInfoMap[msg.sender] = ReceiverInfo({
            initialVestedTokens: userInfo.initialVestedTokens,
            amountRedemed: userInfo.amountRedemed.add(withdrawableAmount),
            amountRedeemedFromInitialTokens: userInfo
                .amountRedeemedFromInitialTokens
                .add(withdrawableAmountFromInitial),
            startDate: userInfo.startDate,
            periodLength: userInfo.periodLength,
            numberOfPeriods: userInfo.numberOfPeriods,
            authorized: userInfo.authorized
        });
        totalAmountWithdrawn += withdrawableAmount;
        totalAMountWithdrawnFromAdded += withdrawableAmountFromInitial;
        emit Withdrawal(
            msg.sender,
            withdrawableAmountFromInitial,
            withdrawableAmount
        );
    }
}
