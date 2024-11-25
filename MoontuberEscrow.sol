// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; // Import SafeERC20
import "./EscrowIndividual.sol";

/**
 * @title MoontuberEscrow
 * @dev Escrow contract to facilitate payments between customers and Moontuber partners with support for ETH, supported stablecoins, and other ERC20 tokens.
 */
contract MoontuberEscrow is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20; // Use SafeERC20

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");

    /// @notice Wallet address where commission fees are sent
    address payable public commissionWallet;

    /// @notice Developer fee percentage (in basis points, i.e., 200 = 2%)
    uint256 public devFee;

    /// @notice Commission rate for Moontubers (e.g., 10 = 10%)
    uint256 public defaultCommissionRate;

    /// @notice Processing fee percentage for refunds (e.g., 2 = 2%)
    uint256 public defaultProcessingFeePercent;

    /// @notice Maps Moontuber addresses to their commission rates
    mapping(address => uint256) public moontuberCommissionRates;

    /// @notice Supported stablecoins for payments
    mapping(address => bool) public supportedTokens;

    /// @notice Maps an address to a list of escrow addresses
    mapping(address => address[]) public escrows;

    /// @notice Wallet address where commission token fees are sent
    address payable public commissionTokenWallet;

    /// @notice Event emitted when a deposit is made
    event DepositMade(address indexed escrowAddress, address indexed customer, uint256 index);

    /// @notice Event emitted when the developer fee is updated
    event DevFeeUpdated(uint256 newDevFee);

    /// @notice Event emitted when a Moontuber's commission rate is changed
    event CommissionRateUpdated(address indexed moontuber, uint256 newRate);

    /// @notice Event emitted when a new stablecoin is added
    event StablecoinAdded(address indexed token);

    /// @notice Event emitted when a stablecoin is removed
    event StablecoinRemoved(address indexed token);

    /// @notice Event emitted when funds are released to a Moontuber
    event FundsReleased(address indexed escrowAddress, address indexed moontuber);

    /// @notice Event emitted when a refund is processed for a customer
    event RefundProcessed(address indexed escrowAddress, address indexed customer);

    /// @notice Event emitted when default commission rate is updated
    event DefaultCommissionRateUpdated(uint256 newDefaultCommissionRate);

    /// @notice Event emitted when default processing fee percentage is updated
    event DefaultProcessingFeePercentUpdated(uint256 newDefaultProcessingFeePercent);

    /**
     * @dev Internal function to authorize contract upgrades.
     * @param newImplementation Address of the new contract implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @notice Initializes the contract with the commission wallet address.
     * @param _commissionWallet Address of the wallet to receive commission fees
     * @param _commissionTokenWallet Address of the wallet to receive commission token fees
     * @param _defaultCommissionRate Default commission rate for Moontubers
     * @param _defaultProcessingFeePercent Default processing fee percentage
     */
    function initialize(
        address payable _commissionWallet,
        address payable _commissionTokenWallet,
        uint256 _defaultCommissionRate,
        uint256 _defaultProcessingFeePercent
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        commissionWallet = _commissionWallet;
        commissionTokenWallet = _commissionTokenWallet;
        devFee = 200; // Initializing devFee to 2%
        defaultCommissionRate = _defaultCommissionRate;
        defaultProcessingFeePercent = _defaultProcessingFeePercent;
    }

    /**
     * @notice Deposits funds into an escrow.
     * @param moontuber Address of the Moontuber 
     * @param primaryAssetType Primary asset type ("ETH" or "ERC20")
     * @param primaryAssetAddress Address of the ERC20 token (zero address for ETH)
     * @param primaryAmount Amount to be deposited of primary asset type
     * @param additionalAssetAddresses Array of additional ERC20 token addresses
     * @param additionalAmounts Array of amounts to be deposited for each additional asset
     */
    function deposit(
        address moontuber,
        string memory primaryAssetType,
        address primaryAssetAddress,
        uint256 primaryAmount,
        address[] memory additionalAssetAddresses,
        uint256[] memory additionalAmounts
    ) external payable nonReentrant {
        require(moontuber != address(0), "Invalid Moontuber address");
        require(additionalAssetAddresses.length == additionalAmounts.length, "Array lengths do not match");
        require(primaryAmount > 0, "Primary amount cannot be 0");

        uint256 totalETHDeposited = msg.value;
        uint256 serviceFee = (primaryAmount * devFee) / 10000; // devFee is in basis points (e.g., 200 = 2%)
        uint256 totalPrimaryAmount = primaryAmount + serviceFee;

        if (keccak256(abi.encodePacked(primaryAssetType)) == keccak256(abi.encodePacked("ETH"))) {
            require(primaryAssetAddress == address(0), "Incorrect ETH specifications");
            require(totalETHDeposited >= totalPrimaryAmount, "Insufficient ETH sent");

            (bool feeTransferSuccess, ) = commissionWallet.call{value: serviceFee}("");
            require(feeTransferSuccess, "Failed to transfer service fee");
            totalETHDeposited = totalETHDeposited - serviceFee;
        } else {
            require(supportedTokens[primaryAssetAddress], "Primary token not supported");
            IERC20(primaryAssetAddress).safeTransferFrom(msg.sender, commissionWallet, serviceFee);
        }

        EscrowIndividual newEscrow = new EscrowIndividual{value: totalETHDeposited}(
            address(this),
            msg.sender,
            commissionWallet,
            commissionTokenWallet,
            devFee,
            moontuber,
            primaryAssetType,
            primaryAssetAddress,
            primaryAmount,
            additionalAssetAddresses,
            additionalAmounts
        );

        if (keccak256(abi.encodePacked(primaryAssetType)) != keccak256(abi.encodePacked("ETH"))) {
            IERC20(primaryAssetAddress).safeTransferFrom(msg.sender, address(newEscrow), primaryAmount);
        }

        for (uint256 i = 0; i < additionalAssetAddresses.length; i++) {
            if (additionalAssetAddresses[i] != address(0) && additionalAmounts[i] > 0) {
                serviceFee = (additionalAmounts[i] * devFee) / 10000;
                // Transfer service fee to commissionTokenWallet
                IERC20(additionalAssetAddresses[i]).safeTransferFrom(msg.sender, commissionTokenWallet, serviceFee);
                // Transfer additional amount to new escrow
                IERC20(additionalAssetAddresses[i]).safeTransferFrom(msg.sender, address(newEscrow), additionalAmounts[i]);
            }
        }

        escrows[moontuber].push(address(newEscrow));
        uint256 index = escrows[moontuber].length - 1;
        _grantRole(ESCROW_ROLE, address(newEscrow));
        emit DepositMade(address(newEscrow), moontuber, index);
    }

    /**
     * @notice Emits the FundsReleased event.
     * @param escrowAddress Address of the individual escrow contract
     * @param moontuber Address of the Moontuber
     */
    function emitFundsReleasedEvent(address escrowAddress, address moontuber) external onlyRole(ESCROW_ROLE) {
        _revokeRole(ESCROW_ROLE, escrowAddress);
        emit FundsReleased(escrowAddress, moontuber);
    }

    /**
     * @notice Emits the RefundProcessed event.
     * @param escrowAddress Address of the individual escrow contract
     * @param customer Address of the customer
     */
    function emitRefundProcessedEvent(address escrowAddress, address customer) external onlyRole(ESCROW_ROLE) {
        _revokeRole(ESCROW_ROLE, escrowAddress);
        emit RefundProcessed(escrowAddress, customer);
    }

    /**
     * @notice Releases funds to the Moontuber after service completion.
     * @param moontuber Address of the moontuber
     * @param index Index of the escrow in customer's list
     */
    function releaseFunds(address moontuber, uint256 index) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(index < escrows[moontuber].length, "Invalid index");
        address escrowAddr = escrows[moontuber][index];
        EscrowIndividual(payable(escrowAddr)).releaseFunds();
    }

    /**
     * @notice Processes a refund for the customer.
     * @param moontuber Address of the moontuber
     * @param index Index of the escrow in moontuber's list
     */
    function processRefund(address moontuber, uint256 index) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(index < escrows[moontuber].length, "Invalid index");
        address escrowAddr = escrows[moontuber][index];
        EscrowIndividual(payable(escrowAddr)).processRefund();
    }

    /**
     * @notice Updates the developer fee percentage.
     * @param _newDevFee New developer fee percentage (in percentage, 0-5)
     */
    function updateDevFee(uint256 _newDevFee) external onlyRole(ADMIN_ROLE) {
        require(_newDevFee >= 0 && _newDevFee <= 5, "Invalid fee percentage");
        devFee = _newDevFee * 100; // Convert to basis points
        emit DevFeeUpdated(_newDevFee);
    }

    /**
     * @notice Updates the commission rate for a specific Moontuber.
     * @param _moontuber Address of the Moontuber
     * @param _newRate New commission rate (must be 5, 10, or 20%)
     */
    function updateMoontuberCommissionRate(address _moontuber, uint256 _newRate) external onlyRole(ADMIN_ROLE) {
        require(_newRate <= 15, "Invalid commission rate");
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
     * @notice Adds a new supported stablecoin for deposits.
     * @param _tokenAddress Address of the ERC20 token contract
     */
    function addStablecoin(address _tokenAddress) external onlyRole(ADMIN_ROLE) {
        require(_tokenAddress != address(0), "Invalid token address");
        supportedTokens[_tokenAddress] = true;
        emit StablecoinAdded(_tokenAddress);
    }

    /**
     * @notice Removes a supported stablecoin from the list.
     * @param _tokenAddress Address of the ERC20 token contract
     */
    function removeStablecoin(address _tokenAddress) external onlyRole(ADMIN_ROLE) {
        require(supportedTokens[_tokenAddress], "Token not supported");
        supportedTokens[_tokenAddress] = false;
        emit StablecoinRemoved(_tokenAddress);
    }

    /**
     * @notice Retrieves an escrow record for a specific Moontuber.
     * @param customer Address of the customer
     * @param index Index of the escrow in customer's list
     * @return Address of the EscrowIndividual contract
     */
    function getEscrow(address customer, uint256 index) external view returns (address) {
        require(index < escrows[customer].length, "Invalid index");
        return escrows[customer][index];
    }

    /**
     * @notice Gets the default commission rates.
     * @return The default commission rate
     */
    function getCommissionRates() external view returns (uint256) {
        return defaultCommissionRate;
    }

    /**
     * @notice Gets the default processing fee percentage.
     * @return The default processing fee percentage
     */
    function getProcessingFeePercent() external view returns (uint256) {
        return defaultProcessingFeePercent;
    }

    /**
     * @notice Sets the default commission rate for Moontubers.
     * @param _newDefaultCommissionRate New default commission rate (in percentage)
     */
    function setDefaultCommissionRate(uint256 _newDefaultCommissionRate) external onlyRole(ADMIN_ROLE) {
        defaultCommissionRate = _newDefaultCommissionRate;
        emit DefaultCommissionRateUpdated(_newDefaultCommissionRate);
    }

    /**
     * @notice Sets the default processing fee percentage.
     * @param _newDefaultProcessingFeePercent New default processing fee percentage
     */
    function setDefaultProcessingFeePercent(uint256 _newDefaultProcessingFeePercent) external onlyRole(ADMIN_ROLE) {
        defaultProcessingFeePercent = _newDefaultProcessingFeePercent;
        emit DefaultProcessingFeePercentUpdated(_newDefaultProcessingFeePercent);
    }
}