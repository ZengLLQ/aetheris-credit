//! Atomic uncollateralized flash loan calculation engine for AetherisCredit.

use crate::math::percent_mul;

pub const DEFAULT_FLASH_LOAN_FEE_BPS: u256 = 9; // 9 bps (0.09%)
pub const PROTOCOL_FLASH_SHARE_BPS: u256 = 2_000; // 20% to protocol treasury, 80% to LPs

/// Computes flash loan fee and splits between liquidity providers and protocol treasury.
/// Returns (total_fee, protocol_share, lp_share).
pub fn calculate_flash_loan_fee(amount: u256, fee_bps: u256) -> (u256, u256, u256) {
    if amount == 0 {
        return (0, 0, 0);
    }
    let total_fee = percent_mul(amount, fee_bps);
    let protocol_share = percent_mul(total_fee, PROTOCOL_FLASH_SHARE_BPS);
    let lp_share = total_fee - protocol_share;
    (total_fee, protocol_share, lp_share)
}

/// Computes the total amount due to be repaid by the flash borrower.
pub fn calculate_flash_amount_due(amount: u256, fee_bps: u256) -> u256 {
    let (total_fee, _, _) = calculate_flash_loan_fee(amount, fee_bps);
    amount + total_fee
}
