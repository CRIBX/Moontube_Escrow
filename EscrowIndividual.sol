// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IMoontuberEscrow.sol";

/**
 * @title EscrowIndividual
 * @dev Individual escrow contract created per customer deposit for transferring funds to Moontuber upon service completion.
 * This contract handles both ETH and ERC20 token transfers with built-in commission calculations and refund capabilities.
 */
contract EscrowIndividual is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Address of the main escrow contract that created this individual escrow
    address public mainEscrow;

    /// @notice Address of the customer who made the deposit
    address public customer;

    /// @notice Wallet address where ETH commission fees are sent
    address payable public commissionWallet;

    /// @notice Wallet address where token commission fees are sent
    address payable public commissionTokenWallet;

    /// @notice Developer fee percentage in basis points (e.g., 200 = 2%)
    uint256 public devFee;

    /// @notice Address of the Moontuber who will receive the funds
    address public moontuber;

    /// @notice Timestamp when the escrow was created
    uint256 public timestamp;

    /// @notice Flag indicating if funds have been released
    bool public released;

    /// @notice Flag indicating if funds have been refunded
    bool public refunded;

    /// @notice Structure defining an asset (ETH or ERC20) held in escrow
    struct Asset {
        /// @notice Type of asset ("ETH" or "ERC20")
        string assetType;
        /// @notice Contract address of the asset (address(0) for ETH)
        address assetAddress;
        /// @notice Amount of the asset held in escrow
        uint256 amount;
    }

    /// @notice Primary asset held in escrow
    Asset public primaryAsset;

    /// @notice Additional assets held in escrow
    Asset[] public additionalAssets;

    /// @notice Ensures function can only be called by the main escrow contract
    modifier onlyMainEscrow() {
        require(msg.sender == mainEscrow);
        _;
    }

    /**
     * @dev Sets up an individual escrow contract
     * @param _mainEscrow Address of the main escrow
     * @param _customer Address of the customer
     * @param _commissionWallet Address of the wallet to receive commission fees
     * @param _commissionTokenWallet Address of the wallet to receive token commission fees
     * @param _devFee Developer fee percentage (in basis points)
     * @param _moontuber Address of the Moontuber
     * @param primaryAssetType Primary asset type ("ETH" or "ERC20")
     * @param primaryAssetAddress Address of the ERC20 token (zero address for ETH)
     * @param primaryAmount Amount to be deposited of primary asset type
     * @param additionalAssetAddresses Array of additional ERC20 token addresses
     * @param additionalAmounts Array of amounts to be deposited for each additional asset
     */
    constructor(
        address _mainEscrow,
        address _customer,
        address payable _commissionWallet,
        address payable _commissionTokenWallet,
        uint256 _devFee,
        address _moontuber,
        string memory primaryAssetType,
        address primaryAssetAddress,
        uint256 primaryAmount,
        address[] memory additionalAssetAddresses,
        uint256[] memory additionalAmounts
    ) payable {
        mainEscrow = _mainEscrow;
        customer = _customer;
        commissionWallet = _commissionWallet;
        commissionTokenWallet = _commissionTokenWallet;
        devFee = _devFee;
        moontuber = _moontuber;

        require(additionalAssetAddresses.length == additionalAmounts.length);

        if (keccak256(abi.encodePacked(primaryAssetType)) == keccak256(abi.encodePacked("ETH"))) {
            primaryAsset = Asset({
                assetType: "ETH",
                assetAddress: address(0),
                amount: primaryAmount
            });
        } else {
            primaryAsset = Asset({
                assetType: "ERC20",
                assetAddress: primaryAssetAddress,
                amount: primaryAmount
            });
        }
 
        for (uint256 i = 0; i < additionalAssetAddresses.length; i++) {
            if (additionalAssetAddresses[i] != address(0) && additionalAmounts[i] > 0) {
                additionalAssets.push(Asset({
                    assetType: "ERC20",
                    assetAddress: additionalAssetAddresses[i],
                    amount: additionalAmounts[i]
                }));
            }
        }

        timestamp = block.timestamp;
    }

    /**
     * @notice Releases the funds to the Moontuber upon service completion
     * @dev Can only be called by the main escrow contract
     */
    function releaseFunds() external onlyMainEscrow nonReentrant {
        require(!released);

        uint256 commissionRate = IMoontuberEscrow(payable(mainEscrow)).moontuberCommissionRates(moontuber) == 0 
            ? IMoontuberEscrow(payable(mainEscrow)).defaultCommissionRate() 
            : IMoontuberEscrow(payable(mainEscrow)).moontuberCommissionRates(moontuber);

        uint256 commissionAmount = primaryAsset.amount * commissionRate / 100;
        uint256 payoutAmount = primaryAsset.amount - commissionAmount;

        if (keccak256(abi.encodePacked(primaryAsset.assetType)) == keccak256(abi.encodePacked("ETH"))) {
            (bool moontuberSuccess,) = payable(moontuber).call{value: payoutAmount}("");
            require(moontuberSuccess);

            (bool commissionFeeSuccess,) = commissionWallet.call{value: commissionAmount}("");
            require(commissionFeeSuccess);
        } else {
            IERC20 token = IERC20(primaryAsset.assetAddress);
            token.safeTransfer(moontuber, payoutAmount);
            token.safeTransfer(commissionWallet, commissionAmount);
        }

        for (uint256 i = 0; i < additionalAssets.length; i++) {
            IERC20 token = IERC20(additionalAssets[i].assetAddress);
            commissionAmount = additionalAssets[i].amount * commissionRate / 100;
            payoutAmount = additionalAssets[i].amount - commissionAmount;

            token.safeTransfer(moontuber, payoutAmount);
            token.safeTransfer(commissionTokenWallet, commissionAmount);
        }

        released = true;
    }

    /**
     * @notice Processes a refund for the customer
     * @dev Can only be called by the main escrow contract
     */
    function processRefund() external onlyMainEscrow nonReentrant {
        require(!refunded);
        require(!released);

        refunded = true;

        uint256 processingFeePercent = IMoontuberEscrow(payable(mainEscrow)).defaultProcessingFeePercent();

        uint256 processingFee = primaryAsset.amount * processingFeePercent / 100;
        uint256 refundAmount = primaryAsset.amount - processingFee;

        if (keccak256(abi.encodePacked(primaryAsset.assetType)) == keccak256(abi.encodePacked("ETH"))) {
            (bool feeSuccess,) = commissionWallet.call{value: processingFee}("");
            require(feeSuccess);

            (bool customerSuccess,) = payable(customer).call{value: refundAmount}("");
            require(customerSuccess);
        } else {
            IERC20 token = IERC20(primaryAsset.assetAddress);
            token.safeTransfer(commissionWallet, processingFee);
            token.safeTransfer(customer, refundAmount);
        }

        for (uint256 i = 0; i < additionalAssets.length; i++) {
            IERC20 token = IERC20(additionalAssets[i].assetAddress);
            processingFee = additionalAssets[i].amount * processingFeePercent / 100;
            refundAmount = additionalAssets[i].amount - processingFee;

            token.safeTransfer(customer, refundAmount);
            token.safeTransfer(commissionTokenWallet, processingFee);
        }
    }

    /**
     * @dev Fallback function to receive ETH
     */
    receive() external payable onlyMainEscrow {}
}