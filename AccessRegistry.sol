// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/access/Ownable2Step.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/IERC20.sol";

/**
 * @title AccessRegistry
 * @notice Users register and pre-approve token budgets.
 *         The owner can later pull from those budgets; funds go
 *         directly to the treasury wallet (never held by the contract).
 *
 *         Deployable on BSC, Polygon, and Base.
 *         Owner should be a Safe multisig on mainnet.
 */
contract AccessRegistry is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Wallet that receives every charged amount.
    address public treasury;

    struct UserInfo {
        bool registered;
        uint256 registeredAt;
        uint256 lastChargedAt;
    }

    /// @notice Registration + timing data per user.
    mapping(address => UserInfo) public users;

    /// @notice Total amount charged per user per token (audit trail).
    mapping(address => mapping(address => uint256)) public totalCharged;

    address[] private _userList;

    // ============ EVENTS ============

    event Registered(address indexed user, uint256 timestamp);
    event Charged(address indexed user, address indexed token, uint256 amount, address to);
    event TreasuryUpdated(address indexed newTreasury);

    // ============ CONSTRUCTOR ============

    /**
     * @param initialOwner  Address that can call charge()/setTreasury()/transferOwnership().
     *                      Use a Safe multisig for mainnet.
     * @param _treasury     Wallet that receives charged funds. Can be changed later.
     */
    constructor(address initialOwner, address _treasury) Ownable(initialOwner) {
        require(_treasury != address(0), "Zero treasury");
        treasury = _treasury;
    }

    // ============ USER ACTIONS ============

    /**
     * @notice Register the caller. Can only be called once per address.
     *         Users must approve token budgets separately via token.approve().
     */
    function register() external {
        require(!users[msg.sender].registered, "Already registered");

        users[msg.sender] = UserInfo({
            registered: true,
            registeredAt: block.timestamp,
            lastChargedAt: 0
        });
        _userList.push(msg.sender);

        emit Registered(msg.sender, block.timestamp);
    }

    // ============ OWNER ACTIONS ============

    /**
     * @notice Pull `amount` of `token` from a registered user's approved budget.
     *         Funds go directly to `treasury`.
     */
    function charge(address user, address token, uint256 amount) external onlyOwner {
        _charge(user, token, amount);
    }

    /**
     * @notice Charge multiple users the same token in one transaction.
     *         Reverts entirely if any single charge fails.
     */
    function batchCharge(
        address[] calldata recipients,
        address token,
        uint256[] calldata amounts
    ) external onlyOwner {
        require(recipients.length == amounts.length, "Length mismatch");
        for (uint256 i = 0; i < recipients.length; i++) {
            _charge(recipients[i], token, amounts[i]);
        }
    }

    /**
     * @notice Change where future charges are sent.
     *         Useful for upgrading from a hot wallet to a Safe.
     */
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Zero treasury");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    // ============ VIEWS ============

    function userCount() external view returns (uint256) {
        return _userList.length;
    }

    function getUser(address user) external view returns (UserInfo memory) {
        return users[user];
    }

    /**
     * @notice Paginated list of registered users.
     *         Use offset=0, limit=50, then offset=50, limit=50, etc.
     */
    function getUsers(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = _userList.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = _userList[i];
        }
        return result;
    }

    /**
     * @notice Convenience view — how much budget a user still has for a token.
     *         Equivalent to token.allowance(user, address(this)).
     */
    function remainingAllowance(address user, address token) external view returns (uint256) {
        return IERC20(token).allowance(user, address(this));
    }

    // ============ INTERNAL ============

    function _charge(address user, address token, uint256 amount) internal {
        require(users[user].registered, "Not registered");
        require(amount > 0, "Zero amount");
        require(token != address(0), "Zero token");

        // Pull tokens directly from the user to the treasury.
        // Requires the user to have called token.approve(address(this), >= amount).
        IERC20(token).safeTransferFrom(user, treasury, amount);

        totalCharged[user][token] += amount;
        users[user].lastChargedAt = block.timestamp;

        emit Charged(user, token, amount, treasury);
    }
}
