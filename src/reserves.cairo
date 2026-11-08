//! Reserve accounting and compounded index updates for AetherisCredit.

use crate::interest::calculate_interest_rates;
use crate::math::{
    calculate_compounded_interest, calculate_linear_interest, percent_mul, ray_div, ray_mul,
};
use crate::types::{InterestRateConfig, ReserveConfig, ReserveData};

/// Converts a nominal token amount to scaled balance shares using the current index:
/// scaled = (amount * RAY) / index
pub fn to_scaled_balance(amount: u256, index_ray: u256) -> u256 {
    if amount == 0 {
        return 0;
    }
    ray_div(amount, index_ray)
}

/// Converts scaled balance shares to nominal real token balance:
/// nominal = (scaled * index) / RAY
pub fn to_real_balance(scaled_amount: u256, index_ray: u256) -> u256 {
    if scaled_amount == 0 {
        return 0;
    }
    ray_mul(scaled_amount, index_ray)
}

/// Computes the current updated borrow index given elapsed time.
pub fn get_updated_borrow_index(
    borrow_index_ray: u256,
    current_borrow_rate_ray: u256,
    last_update_timestamp: u64,
    current_timestamp: u64,
) -> u256 {
    if current_timestamp <= last_update_timestamp {
        return borrow_index_ray;
    }
    let delta_t: u256 = (current_timestamp - last_update_timestamp).into();
    let interest_factor = calculate_compounded_interest(current_borrow_rate_ray, delta_t);
    ray_mul(borrow_index_ray, interest_factor)
}

/// Computes the current updated liquidity (supply) index given elapsed time.
pub fn get_updated_liquidity_index(
    liquidity_index_ray: u256,
    current_liquidity_rate_ray: u256,
    last_update_timestamp: u64,
    current_timestamp: u64,
) -> u256 {
    if current_timestamp <= last_update_timestamp {
        return liquidity_index_ray;
    }
    let delta_t: u256 = (current_timestamp - last_update_timestamp).into();
    let interest_factor = calculate_linear_interest(current_liquidity_rate_ray, delta_t);
    ray_mul(liquidity_index_ray, interest_factor)
}

/// Updates cumulative borrow & liquidity indices, distributes reserve fees,
/// and re-evaluates instantaneous interest rates.
pub fn update_reserve_state(
    ref reserve: ReserveData,
    config: ReserveConfig,
    ir_config: InterestRateConfig,
    total_cash: u256,
    current_timestamp: u64,
) {
    if current_timestamp <= reserve.last_update_timestamp {
        return;
    }

    let old_borrow_index = reserve.borrow_index_ray;
    let new_borrow_index = get_updated_borrow_index(
        old_borrow_index,
        reserve.current_borrow_rate_ray,
        reserve.last_update_timestamp,
        current_timestamp,
    );
    reserve.borrow_index_ray = new_borrow_index;

    // Calculate accrued borrow interest:
    let total_borrow_prev = to_real_balance(reserve.total_borrow_scaled, old_borrow_index);
    let total_borrow_new = to_real_balance(reserve.total_borrow_scaled, new_borrow_index);

    if total_borrow_new > total_borrow_prev {
        let interest_accrued = total_borrow_new - total_borrow_prev;
        // Protocol treasury fee portion
        let protocol_fee = percent_mul(interest_accrued, config.reserve_factor);
        reserve.accrued_protocol_fees += protocol_fee;
    }

    // Update liquidity index
    let new_liquidity_index = get_updated_liquidity_index(
        reserve.liquidity_index_ray,
        reserve.current_liquidity_rate_ray,
        reserve.last_update_timestamp,
        current_timestamp,
    );
    reserve.liquidity_index_ray = new_liquidity_index;

    // Re-evaluate dynamic interest rates based on current utilization
    let total_borrow_current = to_real_balance(reserve.total_borrow_scaled, new_borrow_index);
    let (new_borrow_rate, new_liquidity_rate) = calculate_interest_rates(
        ir_config, config.reserve_factor, total_cash, total_borrow_current,
    );

    reserve.current_borrow_rate_ray = new_borrow_rate;
    reserve.current_liquidity_rate_ray = new_liquidity_rate;
    reserve.last_update_timestamp = current_timestamp;
}
