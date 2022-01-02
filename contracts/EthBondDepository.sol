// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./lib/Ownable.sol";
import "./lib/SafeMath.sol";
import "./lib/Address.sol";
import "./lib/Counters.sol";
import "./lib/ERC20.sol";
import "./lib/SafeERC20.sol";
import "./lib/ERC20Permit.sol";
import "./lib/FullMath.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    // getRoundData and latestRoundData should both raise "No data present"
    // if they do not have data to report, instead of returning unset values
    // which could be misinterpreted as actual reported values.
    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface ITreasury {
    function deposit(
        uint256 _amount,
        address _token,
        uint256 _profit
    ) external returns (bool);

    function valueOf(address _token, uint256 _amount)
        external
        view
        returns (uint256 value_);

    function mintRewards(address _recipient, uint256 _amount) external;
}

interface IStaking {
    function stake(uint256 _amount, address _recipient) external returns (bool);
}

interface IStakingHelper {
    function stake(uint256 _amount, address _recipient) external;
}

interface IWETH9 is IERC20 {
    /// @notice Deposit ether to get wrapped ether
    function deposit() external payable;
}

contract EthTimeBondDepository is Ownable {
    using FixedPoint for uint256;
    using FixedPoint for FixedPoint.uq112x112;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using SafeMath for uint32;

    /* ======== EVENTS ======== */

    event BondCreated(
        uint256 deposit,
        uint256 indexed payout,
        uint256 indexed expires,
        uint256 indexed priceInUSD
    );
    event BondRedeemed(
        address indexed recipient,
        uint256 payout,
        uint256 remaining
    );
    event BondPriceChanged(
        uint256 indexed priceInUSD,
        uint256 indexed internalPrice,
        uint256 indexed debtRatio
    );
    event ControlVariableAdjustment(
        uint256 initialBCV,
        uint256 newBCV,
        uint256 adjustment,
        bool addition
    );

    /* ======== STATE VARIABLES ======== */
    address public immutable OHM; // token given as payment for bond
    address public immutable principle; // token used to create bond
    address public immutable treasury; // mints OHM when receives principle
    address public immutable DAO; // receives profit share from bond

    AggregatorV3Interface internal priceFeed;

    address public staking; // to auto-stake payout
    address public stakingHelper; // to stake and claim if no staking warmup
    bool public useHelper;

    Terms public terms; // stores terms for new bonds
    Adjust public adjustment; // stores adjustment to BCV data

    mapping(address => Bond) public bondInfo; // stores bond information for depositors

    uint256 public totalDebt; // total value of outstanding bonds; used for pricing
    uint32 public lastDecay; // reference block for debt decay

    /* ======== STRUCTS ======== */

    // Info for creating new bonds
    struct Terms {
        uint256 controlVariable; // scaling variable for price
        uint256 minimumPrice; // vs principle value. 4 decimals (1500 = 0.15)
        uint256 maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint256 maxDebt; // 9 decimal debt ratio, max % total supply created as debt
        uint32 vestingTerm; // in seconds
    }

    // Info for bond holder
    struct Bond {
        uint256 payout; // OHM remaining to be paid
        uint256 pricePaid; // In DAI, for front end viewing
        uint32 vesting; // Seconds left to vest
        uint32 lastTime; // Last interaction
    }

    // Info for incremental adjustments to control variable
    struct Adjust {
        bool add; // addition or subtraction
        uint256 rate; // increment
        uint256 target; // BCV when adjustment finished
        uint32 buffer; // minimum length (in seconds) between adjustments
        uint32 lastTime; // block when last adjustment made
    }

    /* ======== INITIALIZATION ======== */

    constructor(
        address _OHM,
        address _principle,
        address _treasury,
        address _DAO,
        address _feed
    ) {
        require(_OHM != address(0));
        OHM = _OHM;
        require(_principle != address(0));
        principle = _principle;
        require(_treasury != address(0));
        treasury = _treasury;
        require(_DAO != address(0));
        DAO = _DAO;
        require(_feed != address(0));
        priceFeed = AggregatorV3Interface(_feed);
    }

    /**
     *  @notice initializes bond parameters
     *  @param _controlVariable uint
     *  @param _vestingTerm uint
     *  @param _minimumPrice uint
     *  @param _maxPayout uint
     *  @param _maxDebt uint
     *  @param _initialDebt uint
     */
    function initializeBondTerms(
        uint256 _controlVariable,
        uint256 _minimumPrice,
        uint256 _maxPayout,
        uint256 _maxDebt,
        uint256 _initialDebt,
        uint32 _vestingTerm
    ) external onlyManager {
        require(currentDebt() == 0, "Debt must be 0 for initialization");
        terms = Terms({
            controlVariable: _controlVariable,
            vestingTerm: _vestingTerm,
            minimumPrice: _minimumPrice,
            maxPayout: _maxPayout,
            maxDebt: _maxDebt
        });
        totalDebt = _initialDebt;
        lastDecay = uint32(block.timestamp);
    }

    /* ======== POLICY FUNCTIONS ======== */

    enum PARAMETER {
        VESTING,
        PAYOUT,
        DEBT,
        MINPRICE,
        BCV
    }

    /**
     *  @notice set parameters for new bonds
     *  @param _parameter PARAMETER
     *  @param _input uint
     */
    function setBondTerms(PARAMETER _parameter, uint256 _input)
        external
        onlyManager
    {
        if (_parameter == PARAMETER.VESTING) {
            // 0
            require(_input >= 129600, "Vesting must be longer than 36 hours");
            terms.vestingTerm = uint32(_input);
        } else if (_parameter == PARAMETER.PAYOUT) {
            // 1
            require(_input <= 1000, "Payout cannot be above 1 percent");
            terms.maxPayout = _input;
        } else if (_parameter == PARAMETER.DEBT) {
            // 2
            terms.maxDebt = _input;
        } else if (_parameter == PARAMETER.MINPRICE) {
            // 3
            terms.minimumPrice = _input;
        } else if (_parameter == PARAMETER.BCV) {
            // 4
            terms.controlVariable = _input;
        }
    }

    /**
     *  @notice set control variable adjustment
     *  @param _addition bool
     *  @param _increment uint
     *  @param _target uint
     *  @param _buffer uint
     */
    function setAdjustment(
        bool _addition,
        uint256 _increment,
        uint256 _target,
        uint32 _buffer
    ) external onlyManager {
        require(
            _increment <= terms.controlVariable.mul(25).div(1000),
            "Increment too large"
        );

        adjustment = Adjust({
            add: _addition,
            rate: _increment,
            target: _target,
            buffer: _buffer,
            lastTime: uint32(block.timestamp)
        });
    }

    /**
     *  @notice set contract for auto stake
     *  @param _staking address
     *  @param _helper bool
     */
    function setStaking(address _staking, bool _helper) external onlyManager {
        require(_staking != address(0));
        if (_helper) {
            useHelper = true;
            stakingHelper = _staking;
        } else {
            useHelper = false;
            staking = _staking;
        }
    }

    /* ======== USER FUNCTIONS ======== */

    /**
     *  @notice deposit bond
     *  @param _amount uint
     *  @param _maxPrice uint
     *  @param _depositor address
     *  @return uint
     */
    function deposit(
        uint256 _amount,
        uint256 _maxPrice,
        address _depositor
    ) external payable returns (uint256) {
        require(_depositor != address(0), "Invalid address");

        decayDebt();
        require(totalDebt <= terms.maxDebt, "Max capacity reached");

        uint256 priceInUSD = bondPriceInUSD(); // Stored in bond info
        uint256 nativePrice = _bondPrice();

        require(
            _maxPrice >= nativePrice,
            "Slippage limit: more than max price"
        ); // slippage protection

        uint256 value = ITreasury(treasury).valueOf(principle, _amount);
        uint256 payout = payoutFor(value); // payout to bonder is computed

        require(payout >= 10000000, "Bond too small"); // must be > 0.01 OHM ( underflow protection )
        require(payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage

        /**
            asset carries risk and is not minted against
            asset transfered to treasury and rewards minted as payout
         */
        if (address(this).balance >= _amount) {
            // pay with WETH9
            IWETH9(principle).deposit{value: _amount}(); // wrap only what is needed to pay
            IWETH9(principle).transfer(treasury, _amount);
        } else {
            IERC20(principle).safeTransferFrom(msg.sender, treasury, _amount);
        }

        ITreasury(treasury).mintRewards(address(this), payout);

        // total debt is increased
        totalDebt = totalDebt.add(value);

        // depositor info is stored
        bondInfo[_depositor] = Bond({
            payout: bondInfo[_depositor].payout.add(payout),
            vesting: terms.vestingTerm,
            lastTime: uint32(block.timestamp),
            pricePaid: priceInUSD
        });

        // indexed events are emitted
        emit BondCreated(
            _amount,
            payout,
            block.timestamp.add(terms.vestingTerm),
            priceInUSD
        );
        emit BondPriceChanged(bondPriceInUSD(), _bondPrice(), debtRatio());

        adjust(); // control variable is adjusted
        refundETH(); //refund user if needed
        return payout;
    }

    /**
     *  @notice redeem bond for user
     *  @param _recipient address
     *  @param _stake bool
     *  @return uint
     */
    function redeem(address _recipient, bool _stake)
        external
        returns (uint256)
    {
        Bond memory info = bondInfo[_recipient];
        uint256 percentVested = percentVestedFor(_recipient); // (blocks since last interaction / vesting term remaining)

        if (percentVested >= 10000) {
            // if fully vested
            delete bondInfo[_recipient]; // delete user info
            emit BondRedeemed(_recipient, info.payout, 0); // emit bond data
            return stakeOrSend(_recipient, _stake, info.payout); // pay user everything due
        } else {
            // if unfinished
            // calculate payout vested
            uint256 payout = info.payout.mul(percentVested).div(10000);

            // store updated deposit info
            bondInfo[_recipient] = Bond({
                payout: info.payout.sub(payout),
                vesting: info.vesting.sub32(
                    uint32(block.timestamp).sub32(info.lastTime)
                ),
                lastTime: uint32(block.timestamp),
                pricePaid: info.pricePaid
            });

            emit BondRedeemed(_recipient, payout, bondInfo[_recipient].payout);
            return stakeOrSend(_recipient, _stake, payout);
        }
    }

    /* ======== INTERNAL HELPER FUNCTIONS ======== */

    /**
     *  @notice allow user to stake payout automatically
     *  @param _stake bool
     *  @param _amount uint
     *  @return uint
     */
    function stakeOrSend(
        address _recipient,
        bool _stake,
        uint256 _amount
    ) internal returns (uint256) {
        if (!_stake) {
            // if user does not want to stake
            IERC20(OHM).transfer(_recipient, _amount); // send payout
        } else {
            // if user wants to stake
            if (useHelper) {
                // use if staking warmup is 0
                IERC20(OHM).approve(stakingHelper, _amount);
                IStakingHelper(stakingHelper).stake(_amount, _recipient);
            } else {
                IERC20(OHM).approve(staking, _amount);
                IStaking(staking).stake(_amount, _recipient);
            }
        }
        return _amount;
    }

    /**
     *  @notice makes incremental adjustment to control variable
     */
    function adjust() internal {
        uint256 timeCanAdjust = adjustment.lastTime.add(adjustment.buffer);
        if (adjustment.rate != 0 && block.timestamp >= timeCanAdjust) {
            uint256 initial = terms.controlVariable;
            if (adjustment.add) {
                terms.controlVariable = terms.controlVariable.add(
                    adjustment.rate
                );
                if (terms.controlVariable >= adjustment.target) {
                    adjustment.rate = 0;
                }
            } else {
                terms.controlVariable = terms.controlVariable.sub(
                    adjustment.rate
                );
                if (terms.controlVariable <= adjustment.target) {
                    adjustment.rate = 0;
                }
            }
            adjustment.lastTime = uint32(block.timestamp);
            emit ControlVariableAdjustment(
                initial,
                terms.controlVariable,
                adjustment.rate,
                adjustment.add
            );
        }
    }

    /**
     *  @notice reduce total debt
     */
    function decayDebt() internal {
        totalDebt = totalDebt.sub(debtDecay());
        lastDecay = uint32(block.timestamp);
    }

    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @notice determine maximum bond size
     *  @return uint
     */
    function maxPayout() public view returns (uint256) {
        return IERC20(OHM).totalSupply().mul(terms.maxPayout).div(100000);
    }

    /**
     *  @notice calculate interest due for new bond
     *  @param _value uint
     *  @return uint
     */
    function payoutFor(uint256 _value) public view returns (uint256) {
        return
            FixedPoint.fraction(_value, bondPrice()).decode112with18().div(
                1e14
            );
    }

    /**
     *  @notice calculate current bond premium
     *  @return price_ uint
     */
    function bondPrice() public view returns (uint256 price_) {
        price_ = terms.controlVariable.mul(debtRatio()).div(1e5);
        if (price_ < terms.minimumPrice) {
            price_ = terms.minimumPrice;
        }
    }

    /**
     *  @notice calculate current bond price and remove floor if above
     *  @return price_ uint
     */
    function _bondPrice() internal returns (uint256 price_) {
        price_ = terms.controlVariable.mul(debtRatio()).div(1e5);
        if (price_ < terms.minimumPrice) {
            price_ = terms.minimumPrice;
        } else if (terms.minimumPrice != 0) {
            terms.minimumPrice = 0;
        }
    }

    /**
     *  @notice get asset price from chainlink
     */
    function assetPrice() public view returns (int256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return price;
    }

    /**
     *  @notice converts bond price to DAI value
     *  @return price_ uint
     */
    function bondPriceInUSD() public view returns (uint256 price_) {
        price_ = bondPrice().mul(uint256(assetPrice())).mul(1e6);
    }

    /**
     *  @notice calculate current ratio of debt to OHM supply
     *  @return debtRatio_ uint
     */
    function debtRatio() public view returns (uint256 debtRatio_) {
        uint256 supply = IERC20(OHM).totalSupply();
        debtRatio_ = FixedPoint
            .fraction(currentDebt().mul(1e9), supply)
            .decode112with18()
            .div(1e18);
    }

    /**
     *  @notice debt ratio in same terms as reserve bonds
     *  @return uint
     */
    function standardizedDebtRatio() external view returns (uint256) {
        return debtRatio().mul(uint256(assetPrice())).div(1e8); // ETH feed is 8 decimals
    }

    /**
     *  @notice calculate debt factoring in decay
     *  @return uint
     */
    function currentDebt() public view returns (uint256) {
        return totalDebt.sub(debtDecay());
    }

    /**
     *  @notice amount to decay total debt by
     *  @return decay_ uint
     */
    function debtDecay() public view returns (uint256 decay_) {
        uint32 timeSinceLast = uint32(block.timestamp).sub32(lastDecay);
        decay_ = totalDebt.mul(timeSinceLast).div(terms.vestingTerm);
        if (decay_ > totalDebt) {
            decay_ = totalDebt;
        }
    }

    /**
     *  @notice calculate how far into vesting a depositor is
     *  @param _depositor address
     *  @return percentVested_ uint
     */
    function percentVestedFor(address _depositor)
        public
        view
        returns (uint256 percentVested_)
    {
        Bond memory bond = bondInfo[_depositor];
        uint256 secondsSinceLast = uint32(block.timestamp).sub(bond.lastTime);
        uint256 vesting = bond.vesting;

        if (vesting > 0) {
            percentVested_ = secondsSinceLast.mul(10000).div(vesting);
        } else {
            percentVested_ = 0;
        }
    }

    /**
     *  @notice calculate amount of OHM available for claim by depositor
     *  @param _depositor address
     *  @return pendingPayout_ uint
     */
    function pendingPayoutFor(address _depositor)
        external
        view
        returns (uint256 pendingPayout_)
    {
        uint256 percentVested = percentVestedFor(_depositor);
        uint256 payout = bondInfo[_depositor].payout;

        if (percentVested >= 10000) {
            pendingPayout_ = payout;
        } else {
            pendingPayout_ = payout.mul(percentVested).div(10000);
        }
    }

    /* ======= AUXILLIARY ======= */

    /**
     *  @notice allow anyone to send lost tokens (excluding principle or OHM) to the DAO
     *  @return bool
     */
    function recoverLostToken(address _token) external returns (bool) {
        require(_token != OHM);
        require(_token != principle);
        IERC20(_token).safeTransfer(
            DAO,
            IERC20(_token).balanceOf(address(this))
        );
        return true;
    }

    function refundETH() internal {
        if (address(this).balance > 0)
            safeTransferETH(DAO, address(this).balance);
    }

    /// @notice Transfers ETH to the recipient address
    /// @dev Fails with `STE`
    /// @param to The destination of the transfer
    /// @param value The value to be transferred
    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "STE");
    }
}
