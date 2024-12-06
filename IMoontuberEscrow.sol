// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Interface for MoontuberEscrow functions needed by EscrowIndividual
interface IMoontuberEscrow {
    /// @dev Get moontuber commission rate
    function moontuberCommissionRates(address moontuber) external view returns (uint256);

    /// @dev Get default commission rate
    function defaultCommissionRate() external view returns (uint256);

    /// @dev Get processing fee percent
    function defaultProcessingFeePercent() external view returns (uint256);
}