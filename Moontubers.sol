// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 

/**
 * @title MoontuberEscrow
 * @dev Escrow contract to facilitate payments between customers and Moontuber partners with support for both ETH and ERC20 tokens.
 */
contract MoontuberEscrow is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    /// @notice Role identifier for admins
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Wallet address where commission fees are sent
    address payable public commissionWallet;
    
    /// @notice Developer fee percentage (in basis points, i.e., 2 = 2%)
    uint256 public devFee;
    
    /// @notice Data structure to hold escrow details
    struct Escrow {
        address customer;
        address moontuber;
        uint256 amount;
        uint256 timestamp;
        string assetType;
        address assetAddress;
        bool released;
        bool refunded;
    }

    /// @notice Maps an address to a list of escrow entries
    mapping(address => Escrow[]) public escrows;
    
    /// @notice Maps Moontuber addresses to their commission rates
    mapping(address => uint256) public moontuberCommissionRates;
    
    /// @notice Supported tokens for payments
    mapping(address => bool) public supportedTokens;
    
    /// @notice Event emitted when a deposit is made
    /// @param customer Address of the customer who made the deposit
    /// @param amount Amount deposited
    /// @param assetType Type of the asset deposited
    event DepositMade(address indexed customer, uint256 amount, address assetType);
    
    /// @notice Event emitted when funds are released to a Moontuber
    /// @param escrowIndex Index of the escrow in the escrows mapping
    /// @param moontuber Address of the Moontuber receiving funds
    event FundsReleased(uint256 indexed escrowIndex, address indexed moontuber);
    
    /// @notice Event emitted when a refund is processed
    /// @param escrowIndex Index of the escrow in the escrows mapping
    /// @param customer Address of the customer receiving the refund
    event RefundProcessed(uint256 indexed escrowIndex, address indexed customer);
    
    /// @notice Event emitted when the developer fee is updated
    /// @param newDevFee New developer fee percentage
    event DevFeeUpdated(uint256 newDevFee);
    
    /// @notice Event emitted when a Moontuber's commission rate is changed
    /// @param moontuber Address of the Moontuber
    /// @param newRate New commission rate
    event CommissionRateUpdated(address indexed moontuber, uint256 newRate);
    
    /// @notice Event emitted when a new supported token is added
    /// @param token Address of the token added
    event SupportedTokenAdded(address indexed token);
    
    /// @notice Event emitted when a supported token is removed
    /// @param token Address of the token removed
    event SupportedTokenRemoved(address indexed token);

    /**
     * @dev Internal function to authorize contract upgrades.
     * @param newImplementation Address of the new contract implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @notice Initializes the contract with the commission wallet address.
     * @param _commissionWallet Address of the wallet to receive commission fees
     */
    function initialize(address payable _commissionWallet) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        
        commissionWallet = _commissionWallet;
        devFee = 2; // Initializing devFee to 2%
    }

    /**
     * @notice Deposits funds into an escrow.
     * @param moontuber Address of the Moontuber
     * @param amount Amount to be deposited
     * @param assetType Type of asset, either "ETH" or "ERC20"
     * @param assetAddress Address of the ERC20 token contract (zero address for ETH)
     */
    function deposit(address moontuber, uint256 amount, string memory assetType, address assetAddress) external payable nonReentrant {
        require(amount > 0, "Deposit amount must be greater than 0");
        require(moontuber != address(0), "Invalid moontuber address");

        uint256 feeAmount = amount * devFee / 100;
        uint256 depositAmount = amount - feeAmount;

        if (keccak256(abi.encodePacked(assetType)) == keccak256(abi.encodePacked("ETH"))) {
            require(msg.value == amount, "Incorrect ETH deposit amount");
            (bool feeSuccess, ) = commissionWallet.call{value: feeAmount}("");
            require(feeSuccess, "Fee Transfer failed");
            (bool depositSuccess, ) = address(this).call{value: depositAmount}("");
            require(depositSuccess, "Deposit transfer failed");
        } else {
            require(msg.value == 0, "ETH value must be 0 for token deposits");
            require(supportedTokens[assetAddress], "Unsupported token address");
            bool feeSuccess = IERC20(assetAddress).transferFrom(msg.sender, commissionWallet, feeAmount);
            require(feeSuccess, "Token fee transfer failed");
            bool depositSuccess = IERC20(assetAddress).transferFrom(msg.sender, address(this), depositAmount);
            require(depositSuccess, "Token deposit transfer failed");
        }

        Escrow memory newEscrow = Escrow({
            customer: msg.sender,
            moontuber: moontuber,
            amount: depositAmount,
            timestamp: block.timestamp,
            assetType: assetType,
            assetAddress: assetAddress,
            released: false,
            refunded: false
        });
        escrows[moontuber].push(newEscrow);

        emit DepositMade(msg.sender, depositAmount, assetAddress);
    }

    /**
     * @notice Releases funds to the Moontuber after service completion.
     * @param moontuber Address of the Moontuber
     * @param escrowIndex Index of the escrow record in Moontuber's list
     */
    function releaseFunds(address moontuber, uint256 escrowIndex) external onlyRole(ADMIN_ROLE) nonReentrant {
        Escrow storage escrow = escrows[moontuber][escrowIndex];
        require(!escrow.released, "Funds already released.");
        uint256 commissionRate = moontuberCommissionRates[moontuber];
        uint256 commissionAmount = escrow.amount * commissionRate / 100;
        uint256 serviceFee = escrow.amount * 1 / 100; // 1% service fee
        uint256 payoutAmount = escrow.amount - commissionAmount - serviceFee;

        escrow.released = true;

        if (keccak256(abi.encodePacked(escrow.assetType)) == keccak256(abi.encodePacked("ETH"))) {
            (bool moontuberSuccess, ) = payable(moontuber).call{value: payoutAmount}("");
            require(moontuberSuccess, "Failed to send ETH to moontuber");
            (bool serviceFeeSuccess, ) = payable(commissionWallet).call{value: serviceFee}("");
            require(serviceFeeSuccess, "Failed to transfer service fee");
        } else {
            bool tokenTransferSuccess = IERC20(escrow.assetAddress).transfer(moontuber, payoutAmount);
            require(tokenTransferSuccess, "Failed to send tokens to moontuber");
            bool serviceFeeTransferSuccess = IERC20(escrow.assetAddress).transfer(commissionWallet, serviceFee);
            require(serviceFeeTransferSuccess, "Failed to transfer service fee");
        }

        emit FundsReleased(escrowIndex, moontuber);
    }

    /**
     * @notice Processes a refund for the customer.
     * @param moontuber Address of the Moontuber
     * @param escrowIndex Index of the escrow record in Moontuber's list
     */
    function processRefund(address moontuber, uint256 escrowIndex) external onlyRole(ADMIN_ROLE) nonReentrant {
        Escrow storage escrow = escrows[moontuber][escrowIndex];
        require(!escrow.refunded, "Refund already processed.");
        require(!escrow.released, "Funds already released, can't refund");

        escrow.refunded = true;
        uint256 processingFee = escrow.amount * 2 / 100; // 2% processing fee
        uint256 refundAmount = escrow.amount - processingFee;
        require(refundAmount > 0, "Refund amount must be greater than processing fee");

        if (keccak256(abi.encodePacked(escrow.assetType)) == keccak256(abi.encodePacked("ETH"))) {
            (bool feeSuccess, ) = commissionWallet.call{value: processingFee}("");
            require(feeSuccess, "Fee Transfer failed");
            (bool customerSuccess, ) = payable(escrow.customer).call{value: refundAmount}("");
            require(customerSuccess, "Failed to refund ETH");
        } else {
            bool feeSuccess = IERC20(escrow.assetAddress).transfer(commissionWallet, processingFee);
            require(feeSuccess, "Token fee transfer failed");
            bool refundSuccess = IERC20(escrow.assetAddress).transfer(escrow.customer, refundAmount);
            require(refundSuccess, "Failed to refund tokens");
        }

        emit RefundProcessed(escrowIndex, escrow.customer);
    }

    /**
     * @notice Updates the developer fee percentage.
     * @param _newDevFee New developer fee percentage (in basis points, 0-5)
     */
    function updateDevFee(uint256 _newDevFee) external onlyRole(ADMIN_ROLE) {
        require(_newDevFee >= 0 && _newDevFee <= 5, "Invalid fee percentage");
        devFee = _newDevFee;
        emit DevFeeUpdated(_newDevFee);
    }

    /**
     * @notice Updates the commission rate for a specific Moontuber.
     * @param _moontuber Address of the Moontuber
     * @param _newRate New commission rate (must be 5, 10, or 20)
     */
    function updateMoontuberCommissionRate(address _moontuber, uint256 _newRate) external onlyRole(ADMIN_ROLE) {
        require(_newRate == 5 || _newRate == 10 || _newRate == 20, "Invalid commission rate");
        moontuberCommissionRates[_moontuber] = _newRate;
        emit CommissionRateUpdated(_moontuber, _newRate);
    }

    /**
     * @notice Grants ADMIN_ROLE to an account.
     * @param account Address of the account to be granted the role
     */
    function grantRoleToAccount(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(ADMIN_ROLE, account);
    }

    /**
     * @notice Revokes ADMIN_ROLE from an account.
     * @param account Address of the account to be revoked the role
     */
    function revokeRoleFromAccount(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(ADMIN_ROLE, account);
    }

    /**
     * @notice Adds a new supported token for deposits.
     * @param _tokenAddress Address of the ERC20 token contract
     */
    function addSupportedToken(address _tokenAddress) external onlyRole(ADMIN_ROLE) {
        require(_tokenAddress != address(0), "Invalid token address");
        supportedTokens[_tokenAddress] = true;
        emit SupportedTokenAdded(_tokenAddress);
    }

    /**
     * @notice Removes a supported token from the list.
     * @param _tokenAddress Address of the ERC20 token contract
     */
    function removeSupportedToken(address _tokenAddress) external onlyRole(ADMIN_ROLE) {
        require(supportedTokens[_tokenAddress], "Token not supported");
        supportedTokens[_tokenAddress] = false;
        emit SupportedTokenRemoved(_tokenAddress);
    }

    /**
     * @notice Retrieves an escrow record for a specific Moontuber.
     * @param moontuber Address of the Moontuber
     * @param index Index of the escrow in Moontuber's list
     * @return An Escrow struct containing the escrow details
     */
    function getEscrow(address moontuber, uint256 index) external view returns (Escrow memory) {
        require(index < escrows[moontuber].length, "Invalid index");
        return escrows[moontuber][index];
    }
}