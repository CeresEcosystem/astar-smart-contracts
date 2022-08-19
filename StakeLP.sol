// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "./SafeMath.sol";
import "./Ownable.sol";
import "./TransferHelper.sol";
import "./EnumerableSet.sol";

contract StakeLP is Ownable {
    address public lpToken;
    address public rewardToken;

    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint public poolLimit;
    uint private _rewardsRemaining;
    uint private _totalDeposited;
    uint private _ceresPerPeriod;

    EnumerableSet.AddressSet private stakers;

    mapping(address => uint) public rewards;
    mapping(address => uint) public balances;

    event Deposited(address indexed owner, uint256 amount);
    event Withdrawn(address indexed owner, uint256 amount);
    event RewardsClaimed(address indexed owner, uint256 amount);

    constructor(address _lpToken, address _rewardToken, uint _poolLimit, uint __rewardsRemaining, uint __ceresPerPeriod) public {
        lpToken = _lpToken;
        rewardToken = _rewardToken;
        poolLimit = _poolLimit;
        _rewardsRemaining = __rewardsRemaining;
        _ceresPerPeriod = __ceresPerPeriod;
    }

    function setCeresPerPeriod(uint __ceresPerPeriod) public onlyOwner {
        _ceresPerPeriod = __ceresPerPeriod;
    }

    function setPoolLimit(uint _poolLimit) public onlyOwner {
        poolLimit = _poolLimit;
    }

    function setRewardsRemaining(uint __rewardsRemaining) public onlyOwner {
        _rewardsRemaining = __rewardsRemaining;
    }

    function deposit(uint _amount) external {
        require(_amount > 0, "Amount cannot be zero");
        require(_totalDeposited + _amount <= poolLimit, "Staking pool is full");

        _totalDeposited += _amount;
        balances[msg.sender] += _amount;
        TransferHelper.safeTransferFrom(lpToken, address(msg.sender), address(this), _amount);
        stakers.add(msg.sender);

        emit Deposited(msg.sender, _amount);
    }

    function withdraw() external {
        uint balance = balances[msg.sender];
        _totalDeposited = _totalDeposited.sub(balance);
        TransferHelper.safeTransfer(lpToken, msg.sender, balance);
        balances[msg.sender] = 0;
        stakers.remove(msg.sender);

        emit Withdrawn(msg.sender, balance);
    }

    function getRewards() external {
        uint reward = rewards[msg.sender];
        TransferHelper.safeTransfer(rewardToken, msg.sender, reward); 
        rewards[msg.sender] = 0;

        emit RewardsClaimed(msg.sender, reward);
    }

    function distributeRewards() external onlyOwner{
        if (_rewardsRemaining >= _ceresPerPeriod) {
            for (uint i = 0; i < stakers.length(); i++) {
                address account = stakers.at(i);
                uint shareInPool = balances[account].mul(1e18).div(_totalDeposited);
                uint reward = shareInPool.mul(_ceresPerPeriod).div(1e18);

                rewards[account] = rewards[account].add(reward);
            }
            _rewardsRemaining = _rewardsRemaining.sub(_ceresPerPeriod);
        }
    }

    function getRewardsRemaining() external view returns (uint) {
        return _rewardsRemaining;
    }

    function getTotalDeposited() external view returns (uint) {
        return _totalDeposited;
    }

    function getCeresPerPeriod() external view returns (uint) {
        return _ceresPerPeriod;
    }
}