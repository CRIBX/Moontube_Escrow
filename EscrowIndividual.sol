// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MoontuberEscrow.sol";

/**
 * @title EscrowIndividual
 * @dev Individual escrow contract created per customer deposit for transferring funds to Moontuber upon service completion
 */
contract EscrowIndividual is ReentrancyGuard {
    address public mainEscrow;
    address public customer;
    address payable public commissionWallet;
    address payable public commissionTokenWallet;
    uint256 public devFee;

    address public moontuber;
    uint256 public timestamp;
    bool public released;
    bool public refunded;

    struct Asset {
        string assetType; // "ETH" or "ERC20"
        address assetAddress;
        uint256 amount;
    }

    Asset public primaryAsset;
    Asset[] public additionalAssets;

    modifier onlyMainEscrow() {
        require(msg.sender == mainEscrow, "Caller is not the main escrow contract");
        _;
    }

    /**
     * @dev Sets up an individual escrow contract
     * @param _mainEscrow Address of the main escrow
     * @param _customer Address of the customer
     * @param _commissionWallet Address of the wallet to receive commission fees
     * @param _devFee Developer fee percentage (in basis points, i.e., 200 = 2%)
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
        address payable _comissionTokenWallet,
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
        commissionTokenWallet = _comissionTokenWallet;
        devFee = _devFee;
        moontuber = _moontuber;

        require(additionalAssetAddresses.length == additionalAmounts.length, "Array lengths do not match");

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
     */
    function releaseFunds() external onlyMainEscrow nonReentrant {
        require(!released, "Funds already released.");

        uint256 commissionRate = MoontuberEscrow(mainEscrow).moontuberCommissionRates(moontuber) == 0 ? MoontuberEscrow(mainEscrow).getCommissionRates() : MoontuberEscrow(mainEscrow).moontuberCommissionRates(moontuber);

        uint256 commissionAmount = primaryAsset.amount * commissionRate / 100;
        uint256 payoutAmount = primaryAsset.amount - commissionAmount;

        if (keccak256(abi.encodePacked(primaryAsset.assetType)) == keccak256(abi.encodePacked("ETH"))) {
            (bool moontuberSuccess,) = payable(moontuber).call{value: payoutAmount}("");
            require(moontuberSuccess, "Failed to send ETH to Moontuber");

            (bool commissionFeeSuccess,) = commissionWallet.call{value: commissionAmount}("");
            require(commissionFeeSuccess, "Failed to transfer ETH commission fee");
        } else {
            IERC20 token = IERC20(primaryAsset.assetAddress);

            bool tokenTransferSuccess = token.transfer(moontuber, payoutAmount);
            require(tokenTransferSuccess, "Failed to send primary tokens to Moontuber");

            bool commissionFeeTransferSuccess = token.transfer(commissionWallet, commissionAmount);
            require(commissionFeeTransferSuccess, "Failed to transfer primary token commission fees");
        }

        for (uint256 i = 0; i < additionalAssets.length; i++) {
            IERC20 token = IERC20(additionalAssets[i].assetAddress);
            commissionAmount = additionalAssets[i].amount * commissionRate / 100;
            payoutAmount = additionalAssets[i].amount - commissionAmount;

            bool tokenTransferSuccess = token.transfer(moontuber, payoutAmount);
            require(tokenTransferSuccess, "Failed to send additional tokens to Moontuber");

            bool commissionFeeTransferSuccess = token.transfer(commissionTokenWallet, commissionAmount);
            require(commissionFeeTransferSuccess, "Failed to transfer primary token commission fees");
        }

        released = true;
        MoontuberEscrow(mainEscrow).emitFundsReleasedEvent(address(this), moontuber);
    }

    /**
     * @notice Processes a refund for the customer.
     */
    function processRefund() external onlyMainEscrow nonReentrant {
        require(!refunded, "Refund already processed.");
        require(!released, "Funds already released, can't refund");

        refunded = true;

        uint256 processingFeePercent = MoontuberEscrow(mainEscrow).getProcessingFeePercent();

        uint256 processingFee = primaryAsset.amount * processingFeePercent / 1000;
        uint256 refundAmount = primaryAsset.amount - processingFee;

        if (keccak256(abi.encodePacked(primaryAsset.assetType)) == keccak256(abi.encodePacked("ETH"))) {
            (bool feeSuccess,) = commissionWallet.call{value: processingFee}("");
            require(feeSuccess, "ETH fee transfer failed");

            (bool customerSuccess,) = payable(customer).call{value: refundAmount}("");
            require(customerSuccess, "Failed to refund ETH to customer");

        } else {
            IERC20 token = IERC20(primaryAsset.assetAddress);

            bool feeSuccess = token.transfer(commissionWallet, processingFee);
            require(feeSuccess, "Token fee transfer failed");
            bool refundSuccess = token.transfer(customer, refundAmount);
            require(refundSuccess, "Failed to refund tokens to customer");
        }

        for (uint256 i = 0; i < additionalAssets.length; i++) {
            IERC20 token = IERC20(additionalAssets[i].assetAddress);
            processingFee = additionalAssets[i].amount * processingFeePercent / 1000;
            refundAmount = additionalAssets[i].amount - processingFee;

            bool refundSuccess = token.transfer(customer, refundAmount);
            require(refundSuccess, "Failed to refund additional tokens to customer");

            bool commissionFeeTransferSuccess = token.transfer(commissionTokenWallet, processingFee);
            require(commissionFeeTransferSuccess, "Failed to transfer primary token commission fees");
        }

        MoontuberEscrow(mainEscrow).emitRefundProcessedEvent(address(this), customer);
    }

    /**
     * @dev Fallback function to receive ETH when remaining ETH is transferred back
     */
    receive() external payable {}
}