// SPDX-License-Identifier: UNLICENSED

// This contract locks ERC-20 tokens. Used to give investors peace of mind a token team has team/marketing/other tokens
// and that the tokens cannot be unlocked until the specified unlock date has been reached.

pragma solidity 0.6.12;

import "./TransferHelper.sol";
import "./EnumerableSet.sol";
import "./SafeMath.sol";
import "./Ownable.sol";
import "./ReentrancyGuard.sol";

interface IMigrator {
    function migrate(address token, uint256 amount, uint256 unlockDate, address owner) external returns (bool);
}

contract CeresTokenLocker is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

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
    // Map token to its locks
    mapping(address => LockInfo[]) public tokenLocks;
    // Token Locker fee
    uint256 public fee;

    EnumerableSet.AddressSet private whitelist;

    address payable devaddr;

    IMigrator migrator;

    event onDeposit(address token, address user, uint256 amount, uint256 lockDate, uint256 unlockDate);
    event onWithdraw(address token, uint256 amount);

    constructor() public {
        devaddr = msg.sender;
        // 0.5%
        fee = 5;
    }

    function setDev(address payable _devaddr) public onlyOwner {
        devaddr = _devaddr;
    }

    /**
     * @notice set the migrator contract which allows locked tokens to be migrated to new locker contract
   */
    function setMigrator(IMigrator _migrator) public onlyOwner {
        migrator = _migrator;
    }

    function setFee(uint256 _fee) public onlyOwner {
        fee = _fee;
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
     * @notice locks tokens
   */
    function lockTokens(address _token, uint256 _amount, uint256 _unlock_date, address _user) external nonReentrant {
        // prevents errors when timestamp entered in milliseconds
        require(_unlock_date < 10000000000, 'TIMESTAMP INVALID');
        require(_amount > 0, 'INSUFFICIENT');

        TransferHelper.safeTransferFrom(_token, address(msg.sender), address(this), _amount);

        uint amountLocked = _amount;
        if (!whitelist.contains(msg.sender)) {
            uint tokenFee = _amount.mul(fee).div(1000);
            TransferHelper.safeTransfer(_token, devaddr, tokenFee);
            amountLocked = _amount.sub(tokenFee);
        }

        LockInfo memory lock_info;
        lock_info.lockDate = block.timestamp;
        lock_info.amount = amountLocked;
        lock_info.unlockDate = _unlock_date;
        lock_info.lockID = tokenLocks[_token].length;
        lock_info.owner = _user;

        // store the lock for the token
        tokenLocks[_token].push(lock_info);
        lockedTokens.add(_token);

        // store the lock for the user
        UserInfo storage user = users[_user];
        user.lockedTokens.add(_token);
        uint256[] storage user_locks = user.locksForToken[_token];
        user_locks.push(lock_info.lockID);

        emit onDeposit(_token, msg.sender, lock_info.amount, lock_info.lockDate, lock_info.unlockDate);
    }

    /**
     * @notice withdraw a specified amount from a lock. _index and _lockID ensure the correct lock is changed
   * this prevents errors when a user performs multiple tx per block possibly with varying gas prices
   */
    function withdraw(address _token, uint256 _index, uint256 _lockID, uint256 _amount) external nonReentrant {
        require(_amount > 0, 'CANT WITHDRAW ZERO TOKENS');
        uint256 lockID = users[msg.sender].locksForToken[_token][_index];
        LockInfo storage userLock = tokenLocks[_token][lockID];
        // ensures correct lock is affected
        require(lockID == _lockID && userLock.owner == msg.sender, 'LOCK MISMATCH');
        require(userLock.unlockDate < block.timestamp, 'TOKENS LOCKED');
        userLock.amount = userLock.amount.sub(_amount);

        // clean user storage
        if (userLock.amount == 0) {
            uint256[] storage userLocks = users[msg.sender].locksForToken[_token];
            userLocks[_index] = userLocks[userLocks.length - 1];
            userLocks.pop();
            if (userLocks.length == 0) {
                users[msg.sender].lockedTokens.remove(_token);
            }
        }

        TransferHelper.safeTransfer(_token, msg.sender, _amount);
        emit onWithdraw(_token, _amount);
    }

    /**
     * @notice transfer a lock to a new owner, e.g. presale project -> project owner
   */
    function transferLockOwnership(address _token, uint256 _index, uint256 _lockID, address payable _newOwner) external {
        require(msg.sender != _newOwner, 'ALREADY OWNER');
        uint256 lockID = users[msg.sender].locksForToken[_token][_index];
        LockInfo storage transferredLock = tokenLocks[_token][lockID];
        // ensures correct lock is affected
        require(lockID == _lockID && transferredLock.owner == msg.sender, 'LOCK MISMATCH');

        // store the lock for the new Owner
        UserInfo storage user = users[_newOwner];
        user.lockedTokens.add(_token);
        uint256[] storage user_locks = user.locksForToken[_token];
        user_locks.push(transferredLock.lockID);

        // remove the lock from the old owner
        uint256[] storage userLocks = users[msg.sender].locksForToken[_token];
        userLocks[_index] = userLocks[userLocks.length - 1];
        userLocks.pop();
        if (userLocks.length == 0) {
            users[msg.sender].lockedTokens.remove(_token);
        }
        transferredLock.owner = _newOwner;
    }

    /**
     * @notice migrates tokens to new locker contract
   */
    function migrate(address _token, uint256 _index, uint256 _lockID, uint256 _amount) external nonReentrant {
        require(address(migrator) != address(0), "NOT SET");
        require(_amount > 0, 'ZERO MIGRATION');

        uint256 lockID = users[msg.sender].locksForToken[_token][_index];
        LockInfo storage userLock = tokenLocks[_token][lockID];

        // ensures correct lock is affected
        require(lockID == _lockID && userLock.owner == msg.sender, 'LOCK MISMATCH');
        userLock.amount = userLock.amount.sub(_amount);

        // clean user storage
        if (userLock.amount == 0) {
            uint256[] storage userLocks = users[msg.sender].locksForToken[_token];
            userLocks[_index] = userLocks[userLocks.length - 1];
            userLocks.pop();
            if (userLocks.length == 0) {
                users[msg.sender].lockedTokens.remove(_token);
            }
        }

        TransferHelper.safeApprove(_token, address(migrator), _amount);
        migrator.migrate(_token, _amount, userLock.unlockDate, msg.sender);
    }

    function getNumLocksForToken(address _token) external view returns (uint256) {
        return tokenLocks[_token].length;
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

    function getUserNumLocksForToken(address _user, address _token) external view returns (uint256) {
        UserInfo storage user = users[_user];
        return user.locksForToken[_token].length;
    }

    function getUserLockForTokenAtIndex(address _user, address _token, uint256 _index) external view
    returns (uint256, uint256, uint256, uint256, address) {
        uint256 lockID = users[_user].locksForToken[_token][_index];
        LockInfo storage tokenLock = tokenLocks[_token][lockID];
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
