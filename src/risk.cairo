//! Risk modeling, collateral valuation, and account solvency engine for AetherisCredit.

use crate::math::{WAD, percent_mul, wad_div};

/// High constant representing infinite health factor when user has 0 debt.
pub const INFINITE_HEALTH_FACTOR: u256 = 1_000_000_000_000_000_000_000_000_000_000; // 10^30

/// Computes account health factor H in WAD:
/// H = (Total Collateral in USD * Weighted Liquidation Threshold) / Total Borrow in USD
pub fn calculate_health_factor(
    total_collateral_weighted_usd_wad: u256, total_borrow_usd_wad: u256,
) -> u256 {
    if total_borrow_usd_wad == 0 {
        return INFINITE_HEALTH_FACTOR;
    }
    wad_div(total_collateral_weighted_usd_wad, total_borrow_usd_wad)
}

/// Evaluates whether an account is solvent (H >= 1.0 WAD).
pub fn is_account_solvent(health_factor_wad: u256) -> bool {
    health_factor_wad >= WAD
}

/// Computes the collateral value weighted by its liquidation threshold:
/// WeightedValue = ValueUSD * (LiquidationThreshold / 10000)
pub fn calculate_weighted_collateral(
    amount_usd_wad: u256, liquidation_threshold_bps: u256,
) -> u256 {
    percent_mul(amount_usd_wad, liquidation_threshold_bps)
}

/// Computes the maximum borrowable capacity based on Loan-To-Value (LTV):
/// Capacity = ValueUSD * (LTV / 10000)
pub fn calculate_ltv_borrow_capacity(amount_usd_wad: u256, ltv_bps: u256) -> u256 {
    percent_mul(amount_usd_wad, ltv_bps)
}

/// Validates whether a requested borrow amount can be safely issued without violating LTV.
pub fn validate_borrow_capacity(
    total_ltv_capacity_usd_wad: u256, current_borrow_usd_wad: u256, new_borrow_usd_wad: u256,
) -> bool {
    let projected_borrow = current_borrow_usd_wad + new_borrow_usd_wad;
    projected_borrow <= total_ltv_capacity_usd_wad
}
