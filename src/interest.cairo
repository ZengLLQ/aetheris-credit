//! Dynamic Kinked Jump-Rate Interest Rate Model for AetherisCredit.
//! Implements a two-slope piecewise linear curve with a steep penalty slope past U_optimal.

use crate::math::{RAY, percent_mul, ray_div, ray_mul};
use crate::types::InterestRateConfig;

/// Computes the reserve utilization rate U in RAY (10^27):
/// U = total_borrows / (total_cash + total_borrows)
pub fn calculate_utilization_rate(total_cash: u256, total_borrows: u256) -> u256 {
    if total_borrows == 0 {
        return 0;
    }
    let total_liquidity = total_cash + total_borrows;
    if total_liquidity == 0 {
        return 0;
    }
    // (total_borrows * RAY) / total_liquidity
    ray_div(total_borrows, total_liquidity)
}

/// Computes both the borrow rate and liquidity (deposit) supply rate in RAY.
/// Returns (borrow_rate_ray, liquidity_rate_ray).
pub fn calculate_interest_rates(
    config: InterestRateConfig, reserve_factor_bps: u256, total_cash: u256, total_borrows: u256,
) -> (u256, u256) {
    let utilization = calculate_utilization_rate(total_cash, total_borrows);

    let borrow_rate = if utilization <= config.optimal_utilization_ray {
        if config.optimal_utilization_ray == 0 {
            config.base_rate_ray
        } else {
            // R = Base + (U / U_opt) * Slope1
            let scaled_slope = ray_div(
                ray_mul(utilization, config.slope_1_ray), config.optimal_utilization_ray,
            );
            config.base_rate_ray + scaled_slope
        }
    } else {
        // R = Base + Slope1 + ((U - U_opt) / (1 - U_opt)) * Slope2
        let excess_utilization = utilization - config.optimal_utilization_ray;
        let excess_capacity = RAY - config.optimal_utilization_ray;
        assert!(excess_capacity > 0, "Optimal utilization cannot be 100%");
        let jump = ray_div(ray_mul(excess_utilization, config.slope_2_ray), excess_capacity);
        config.base_rate_ray + config.slope_1_ray + jump
    };

    // Liquidity Rate = BorrowRate * Utilization * (1 - ReserveFactor)
    let gross_rate = ray_mul(borrow_rate, utilization);
    let retained_percentage = if reserve_factor_bps >= 10_000 {
        0
    } else {
        10_000 - reserve_factor_bps
    };
    let liquidity_rate = percent_mul(gross_rate, retained_percentage);

    (borrow_rate, liquidity_rate)
}
