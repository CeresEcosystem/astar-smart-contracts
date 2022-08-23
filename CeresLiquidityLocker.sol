// SPDX-License-Identifier: UNLICENSED

// This contract locks arthswap liquidity tokens. Used to give investors peace of mind a token team has locked liquidity
// and that the arthswap tokens cannot be removed from arthswap until the specified unlock date has been reached.

pragma solidity 0.6.12;

import "./TransferHelper.sol";
import "./EnumerableSet.sol";
import "./SafeMath.sol";
import "./Ownable.sol";
import "./ReentrancyGuard.sol";

interface IArthswapPair {
    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);
}

interface IArthFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IMigrator {
    function migrate(address lpToken, uint256 amount, uint256 unlockDate, address owner) external returns (bool);
}

interface IERCBurn {
    function burn(uint256 _amount) external;

    function approve(address spender, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external returns (uint256);

    function balanceOf(address account) external view returns (uint256);
}

contract TestLocker is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    IArthFactory public arthswapFactory;

    struct LockInfo {
        uint256 lockDate;
        uint256 amount;
        uint256 unlockDate;
        uint256 lockID;
        address owner;
    }

    struct UserInfo {
        // User's locked tokens
        EnumerableSet.AddressSet lockedTokens;
        // Map address to lock id for that token
        mapping(address => uint256[]) locksForToken;
    }

    mapping(address => UserInfo) private users;

    // All locked tokens
    EnumerableSet.AddressSet private lockedTokens;
    // Map pair to its locks
    mapping(address => LockInfo[]) public tokenLocks;

    struct FeeStruct {
        // Fee on liquidity tokens for option 1
        uint256 liquidityFeeOptionOne;
        // Fee on liquidity tokens for option 2
        uint256 liquidityFeeOptionTwo;
        // Ceres token address
        IERCBurn ceresToken;
        // Ceres fee for option 2
        uint256 ceresFee;
    }

    FeeStruct public fees;
    EnumerableSet.AddressSet private whitelist;

    address payable devaddr;

    IMigrator migrator;

    event onDeposit(address lpToken, address user, uint256 amount, uint256 lockDate, uint256 unlockDate);
    event onWithdraw(address lpToken, uint256 amount);

    constructor(IArthFactory _arthswapFactory) public {
        devaddr = msg.sender;
        // 1%
        fees.liquidityFeeOptionOne = 10;
        // 0.5%
        fees.liquidityFeeOptionTwo = 5;
        // 2 CERES
        fees.ceresFee = 2e18;
        arthswapFactory = _arthswapFactory;
    }

    function setDev(address payable _devaddr) public onlyOwner {
        devaddr = _devaddr;
    }

    /**
     * @notice set the migrator contract which allows locked lp tokens to be migrated to new locker contract
   */
    function setMigrator(IMigrator _migrator) public onlyOwner {
        migrator = _migrator;
    }

    function setCeresToken(address _ceresToken) public onlyOwner {
        fees.ceresToken = IERCBurn(_ceresToken);
    }

    function setFees(uint256 _liquidityFeeOptionOne, uint256 _liquidityFeeOptionTwo, uint256 _ceresFee) public onlyOwner {
        fees.liquidityFeeOptionOne = _liquidityFeeOptionOne;
        fees.liquidityFeeOptionTwo = _liquidityFeeOptionTwo;
        fees.ceresFee = _ceresFee;
    }

    /**
     * @notice whitelisted accounts dont pay fees on locking
   */
    function whitelistFeeAccount(address _user, bool _add) public onlyOwner {
        if (_add) {
            whitelist.add(_user);
        } else {
            whitelist.remove(_user);
        }
    }

    /**
     * @notice locks LP tokens
   */
    function lockLPToken(address _lpToken, uint256 _amount, uint256 _unlock_date, bool _fee_option, address payable _user) external nonReentrant {
        // prevents errors when timestamp entered in milliseconds
        require(_unlock_date < 10000000000, 'TIMESTAMP INVALID');
        require(_amount > 0, 'INSUFFICIENT');

        // ensure this pair is a arthswap pair by querying the factory
        IArthswapPair pair = IArthswapPair(address(_lpToken));
        address factoryPairAddress = arthswapFactory.getPair(pair.token0(), pair.token1());
        require(factoryPairAddress == address(_lpToken), 'NOT ARTHSWAP PAIR');

        TransferHelper.safeTransferFrom(_lpToken, address(msg.sender), address(this), _amount);

        uint256 liquidityFee = 0;
        uint256 amountLocked = 0;

        if (!whitelist.contains(msg.sender)) {
            if (_fee_option) {// fee option one
                liquidityFee = fees.liquidityFeeOptionOne;
            } else {// fee option two
                liquidityFee = fees.liquidityFeeOptionTwo;
                TransferHelper.safeTransferFrom(address(fees.ceresToken), address(msg.sender), devaddr, fees.ceresFee);
            }

            liquidityFee = _amount.mul(liquidityFee).div(1000);
            TransferHelper.safeTransfer(_lpToken, devaddr, liquidityFee);
            amountLocked = _amount.sub(liquidityFee);
        }

        LockInfo memory lock_info;
        lock_info.lockDate = block.timestamp;
        lock_info.amount = amountLocked;
        lock_info.unlockDate = _unlock_date;
        lock_info.lockID = tokenLocks[_lpToken].length;
        lock_info.owner = _user;

        // store the lock for the pair
        tokenLocks[_lpToken].push(lock_info);
        lockedTokens.add(_lpToken);

        // store the lock for the user
        UserInfo storage user = users[_user];
        user.lockedTokens.add(_lpToken);
        uint256[] storage user_locks = user.locksForToken[_lpToken];
        user_locks.push(lock_info.lockID);

        emit onDeposit(_lpToken, msg.sender, lock_info.amount, lock_info.lockDate, lock_info.unlockDate);
    }

    /**
     * @notice withdraw a specified amount from a lock. _index and _lockID ensure the correct lock is changed
   * this prevents errors when a user performs multiple tx per block possibly with varying gas prices
   */
    function withdraw(address _lpToken, uint256 _index, uint256 _lockID, uint256 _amount) external nonReentrant {
        require(_amount > 0, 'CANT WITHDRAW ZERO LP');
        uint256 lockID = users[msg.sender].locksForToken[_lpToken][_index];
        LockInfo storage userLock = tokenLocks[_lpToken][lockID];
        // ensures correct lock is affected
        require(lockID == _lockID && userLock.owner == msg.sender, 'LOCK MISMATCH');
        require(userLock.unlockDate < block.timestamp, 'LP LOCKED');
        userLock.amount = userLock.amount.sub(_amount);

        // clean user storage
        if (userLock.amount == 0) {
            uint256[] storage userLocks = users[msg.sender].locksForToken[_lpToken];
            userLocks[_index] = userLocks[userLocks.length - 1];
            userLocks.pop();
            if (userLocks.length == 0) {
                users[msg.sender].lockedTokens.remove(_lpToken);
            }
        }

        TransferHelper.safeTransfer(_lpToken, msg.sender, _amount);
        emit onWithdraw(_lpToken, _amount);
    }

    /**
     * @notice transfer a lock to a new owner, e.g. presale project -> project owner
   */
    function transferLockOwnership(address _lpToken, uint256 _index, uint256 _lockID, address payable _newOwner) external {
        require(msg.sender != _newOwner, 'ALREADY OWNER');
        uint256 lockID = users[msg.sender].locksForToken[_lpToken][_index];
        LockInfo storage transferredLock = tokenLocks[_lpToken][lockID];
        // ensures correct lock is affected
        require(lockID == _lockID && transferredLock.owner == msg.sender, 'LOCK MISMATCH');

        // store the lock for the new Owner
        UserInfo storage user = users[_newOwner];
        user.lockedTokens.add(_lpToken);
        uint256[] storage user_locks = user.locksForToken[_lpToken];
        user_locks.push(transferredLock.lockID);

        // remove the lock from the old owner
        uint256[] storage userLocks = users[msg.sender].locksForToken[_lpToken];
        userLocks[_index] = userLocks[userLocks.length - 1];
        userLocks.pop();
        if (userLocks.length == 0) {
            users[msg.sender].lockedTokens.remove(_lpToken);
        }
        transferredLock.owner = _newOwner;
    }

    /**
     * @notice migrates liquidity to new locker contract
   */
    function migrate(address _lpToken, uint256 _index, uint256 _lockID, uint256 _amount) external nonReentrant {
        require(address(migrator) != address(0), "NOT SET");
        require(_amount > 0, 'ZERO MIGRATION');

        uint256 lockID = users[msg.sender].locksForToken[_lpToken][_index];
        LockInfo storage userLock = tokenLocks[_lpToken][lockID];

        // ensures correct lock is affected
        require(lockID == _lockID && userLock.owner == msg.sender, 'LOCK MISMATCH');
        userLock.amount = userLock.amount.sub(_amount);

        // clean user storage
        if (userLock.amount == 0) {
            uint256[] storage userLocks = users[msg.sender].locksForToken[_lpToken];
            userLocks[_index] = userLocks[userLocks.length - 1];
            userLocks.pop();
            if (userLocks.length == 0) {
                users[msg.sender].lockedTokens.remove(_lpToken);
            }
        }

        TransferHelper.safeApprove(_lpToken, address(migrator), _amount);
        migrator.migrate(_lpToken, _amount, userLock.unlockDate, msg.sender);
    }

    function getNumLocksForToken(address _lpToken) external view returns (uint256) {
        return tokenLocks[_lpToken].length;
    }

    function getNumLockedTokens() external view returns (uint256) {
        return lockedTokens.length();
    }

    function getLockedTokenAtIndex(uint256 _index) external view returns (address) {
        return lockedTokens.at(_index);
    }

    // user functions
    function getUserNumLockedTokens(address _user) external view returns (uint256) {
        UserInfo storage user = users[_user];
        return user.lockedTokens.length();
    }

    function getUserLockedTokenAtIndex(address _user, uint256 _index) external view returns (address) {
        UserInfo storage user = users[_user];
        return user.lockedTokens.at(_index);
    }

    function getUserNumLocksForToken(address _user, address _lpToken) external view returns (uint256) {
        UserInfo storage user = users[_user];
        return user.locksForToken[_lpToken].length;
    }

    function getUserLockForTokenAtIndex(address _user, address _lpToken, uint256 _index) external view
    returns (uint256, uint256, uint256, uint256, address) {
        uint256 lockID = users[_user].locksForToken[_lpToken][_index];
        LockInfo storage tokenLock = tokenLocks[_lpToken][lockID];
        return (tokenLock.lockDate, tokenLock.amount, tokenLock.unlockDate, tokenLock.lockID, tokenLock.owner);
    }

    // whitelist
    function getWhitelistedUsersLength() external view returns (uint256) {
        return whitelist.length();
    }

    function getWhitelistedUserAtIndex(uint256 _index) external view returns (address) {
        return whitelist.at(_index);
    }

    function getUserWhitelistStatus(address _user) external view returns (bool) {
        return whitelist.contains(_user);
    }
}
