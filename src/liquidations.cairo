//! Liquidation engine with dynamic bonus and bad-debt resolution for AetherisCredit.

use crate::math::{PERCENTAGE_FACTOR, percent_mul, wad_div, wad_mul};
use crate::types::LiquidationResult;

pub const DEFAULT_CLOSE_FACTOR_BPS: u256 = 5_000; // 50% max close factor per liquidation
pub const PROTOCOL_SEIZURE_SHARE_BPS: u256 = 1_000; // 10% of liquidation bonus routed to protocol

/// Calculates liquidation repayment and collateral seizure amounts.
/// Ensures liquidator receives fair market value + liquidation bonus.
pub fn calculate_liquidation_amounts(
    user_debt_nominal: u256,
    user_collateral_nominal: u256,
    debt_price_usd_wad: u256,
    collateral_price_usd_wad: u256,
    liquidation_bonus_bps: u256,
    requested_repay_amount: u256,
) -> LiquidationResult {
    assert!(debt_price_usd_wad > 0, "Debt price cannot be zero");
    assert!(collateral_price_usd_wad > 0, "Collateral price cannot be zero");

    // 1. Calculate max closeable debt (Close Factor = 50%)
    let max_repayable = percent_mul(user_debt_nominal, DEFAULT_CLOSE_FACTOR_BPS);
    let mut debt_to_repay = if requested_repay_amount > max_repayable {
        max_repayable
    } else {
        requested_repay_amount
    };

    if debt_to_repay == 0 {
        return LiquidationResult {
            debt_repaid: 0, collateral_seized: 0, protocol_collateral_fee: 0, liquidator_reward: 0,
        };
    }

    // 2. Value of debt repaid in USD:
    let debt_repaid_usd = wad_mul(debt_to_repay, debt_price_usd_wad);

    // 3. Gross collateral value in USD including liquidation bonus:
    // Bonus multiplier = 10000 + bonus_bps
    let bonus_multiplier = PERCENTAGE_FACTOR + liquidation_bonus_bps;
    let gross_collateral_usd = percent_mul(debt_repaid_usd, bonus_multiplier);

    // 4. Convert USD value into collateral token units:
    let mut gross_collateral_tokens = wad_div(gross_collateral_usd, collateral_price_usd_wad);

    // 5. Cap by available user collateral if underwater position exceeds collateral:
    if gross_collateral_tokens > user_collateral_nominal {
        gross_collateral_tokens = user_collateral_nominal;
        // Recalculate debt repaid matching max available collateral:
        let max_collateral_usd = wad_mul(gross_collateral_tokens, collateral_price_usd_wad);
        let adjusted_debt_usd = (max_collateral_usd * PERCENTAGE_FACTOR) / bonus_multiplier;
        debt_to_repay = wad_div(adjusted_debt_usd, debt_price_usd_wad);
    }

    // 6. Split bonus between liquidator and protocol insurance fund:
    let base_collateral_usd = wad_mul(debt_to_repay, debt_price_usd_wad);
    let base_collateral_tokens = wad_div(base_collateral_usd, collateral_price_usd_wad);
    let total_bonus_tokens = if gross_collateral_tokens > base_collateral_tokens {
        gross_collateral_tokens - base_collateral_tokens
    } else {
        0
    };

    let protocol_fee = percent_mul(total_bonus_tokens, PROTOCOL_SEIZURE_SHARE_BPS);
    let liquidator_reward = gross_collateral_tokens - protocol_fee;

    LiquidationResult {
        debt_repaid: debt_to_repay,
        collateral_seized: gross_collateral_tokens,
        protocol_collateral_fee: protocol_fee,
        liquidator_reward: liquidator_reward,
    }
}
