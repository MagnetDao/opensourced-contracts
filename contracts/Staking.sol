// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./lib/SafeMath.sol";
import "./lib/ERC20.sol";
import "./lib/Address.sol";
import "./lib/Ownable.sol";
import "./lib/SafeERC20.sol";

interface IMemo {
    function rebase(uint256 ohmProfit_, uint256 epoch_)
        external
        returns (uint256);

    function circulatingSupply() external view returns (uint256);

    function balanceOf(address who) external view returns (uint256);

    function gonsForBalance(uint256 amount) external view returns (uint256);

    function balanceForGons(uint256 gons) external view returns (uint256);

    function index() external view returns (uint256);
}

interface IWarmup {
    function retrieve(address staker_, uint256 amount_) external;
}

interface IDistributor {
    function distribute() external returns (bool);
}

contract MagStaking is Ownable {
    using SafeMath for uint256;
    using SafeMath for uint32;
    using SafeERC20 for IERC20;

    address public immutable Mag;
    address public immutable sMag;

    struct Epoch {
        uint256 number;
        uint256 distribute;
        uint32 length;
        uint32 endTime;
    }
    Epoch public epoch;

    address public distributor;

    address public locker;
    uint256 public totalBonus;

    address public warmupContract;
    uint256 public warmupPeriod;

    constructor(
        address _Mag,
        address _sMag,
        uint32 _epochLength,
        uint256 _firstEpochNumber,
        uint32 _firstEpochTime
    ) {
        require(_Mag != address(0));
        Mag = _Mag;
        require(_sMag != address(0));
        sMag = _sMag;

        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endTime: _firstEpochTime,
            distribute: 0
        });
    }

    struct Claim {
        uint256 deposit;
        uint256 gons;
        uint256 expiry;
        bool lock; // prevents malicious delays
    }
    mapping(address => Claim) public warmupInfo;

    /**
        @notice stake MAG to enter warmup
        @param _amount uint
        @return bool
     */
    function stake(uint256 _amount, address _recipient)
        external
        returns (bool)
    {
        //trigger rebase
        rebase();

        IERC20(Mag).safeTransferFrom(msg.sender, address(this), _amount);

        Claim memory info = warmupInfo[_recipient];
        require(!info.lock, "Deposits for account are locked");

        warmupInfo[_recipient] = Claim({
            deposit: info.deposit.add(_amount),
            gons: info.gons.add(IMemo(sMag).gonsForBalance(_amount)),
            expiry: epoch.number.add(warmupPeriod),
            lock: false
        });

        IERC20(sMag).safeTransfer(warmupContract, _amount);
        return true;
    }

    /**
        @notice retrieve sMag from warmup
        @param _recipient address
     */
    function claim(address _recipient) public {
        Claim memory info = warmupInfo[_recipient];
        if (epoch.number >= info.expiry && info.expiry != 0) {
            delete warmupInfo[_recipient];
            IWarmup(warmupContract).retrieve(
                _recipient,
                IMemo(sMag).balanceForGons(info.gons)
            );
        }
    }

    /**
        @notice forfeit sMag in warmup and retrieve Mag
     */
    function forfeit() external {
        Claim memory info = warmupInfo[msg.sender];
        delete warmupInfo[msg.sender];

        IWarmup(warmupContract).retrieve(
            address(this),
            IMemo(sMag).balanceForGons(info.gons)
        );
        IERC20(Mag).safeTransfer(msg.sender, info.deposit);
    }

    /**
        @notice prevent new deposits to address (protection from malicious activity)
     */
    function toggleDepositLock() external {
        warmupInfo[msg.sender].lock = !warmupInfo[msg.sender].lock;
    }

    /**
        @notice redeem sOHM for OHM
        @param _amount uint
        @param _trigger bool
     */
    function unstake(uint256 _amount, bool _trigger) external {
        if (_trigger) {
            rebase();
        }
        IERC20(sMag).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(Mag).safeTransfer(msg.sender, _amount);
    }

    /**
        @notice returns the sOHM index, which tracks rebase growth
        @return uint
     */
    function index() public view returns (uint256) {
        return IMemo(sMag).index();
    }

    /**
        @notice trigger rebase if epoch over
     */
    function rebase() public {
        if (epoch.endTime <= uint32(block.timestamp)) {
            IMemo(sMag).rebase(epoch.distribute, epoch.number);

            epoch.endTime = epoch.endTime.add32(epoch.length);
            epoch.number++;

            if (distributor != address(0)) {
                IDistributor(distributor).distribute();
            }

            uint256 balance = contractBalance();
            uint256 staked = IMemo(sMag).circulatingSupply();

            if (balance <= staked) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub(staked);
            }
        }
    }

    /**
        @notice returns contract OHM holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns (uint256) {
        return IERC20(Mag).balanceOf(address(this)).add(totalBonus);
    }

    /**
        @notice provide bonus to locked staking contract
        @param _amount uint
     */
    function giveLockBonus(uint256 _amount) external {
        require(msg.sender == locker);
        totalBonus = totalBonus.add(_amount);
        IERC20(sMag).safeTransfer(locker, _amount);
    }

    /**
        @notice reclaim bonus from locked staking contract
        @param _amount uint
     */
    function returnLockBonus(uint256 _amount) external {
        require(msg.sender == locker);
        totalBonus = totalBonus.sub(_amount);
        IERC20(sMag).safeTransferFrom(locker, address(this), _amount);
    }

    enum DEPENDENCIES {
        DISTRIBUTOR,
        WARMUP,
        LOCKER
    }

    /**
        @notice sets the contract address for LP staking
        @param _dependency address
     */
    function setContract(DEPENDENCIES _dependency, address _address)
        external
        onlyManager
    {
        if (_dependency == DEPENDENCIES.DISTRIBUTOR) {
            // 0
            distributor = _address;
        } else if (_dependency == DEPENDENCIES.WARMUP) {
            // 1
            require(
                warmupContract == address(0),
                "Warmup cannot be set more than once"
            );
            warmupContract = _address;
        } else if (_dependency == DEPENDENCIES.LOCKER) {
            // 2
            require(
                locker == address(0),
                "Locker cannot be set more than once"
            );
            locker = _address;
        }
    }

    /**
     * @notice set warmup period in epoch's numbers for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmup(uint256 _warmupPeriod) external onlyManager {
        warmupPeriod = _warmupPeriod;
    }
}
