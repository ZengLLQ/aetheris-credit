pub mod flash;
pub mod interest;
pub mod liquidations;
pub mod market;
pub mod math;
pub mod oracle;
pub mod reserves;
pub mod risk;
pub mod types;

#[cfg(test)]
mod tests {
    use super::flash::{calculate_flash_amount_due, calculate_flash_loan_fee};
    use super::interest::{calculate_interest_rates, calculate_utilization_rate};
    use super::liquidations::calculate_liquidation_amounts;
    use super::math::{
        RAY, WAD, calculate_compounded_interest, calculate_linear_interest, percent_div,
        percent_mul, ray_div, ray_mul, ray_to_wad, wad_div, wad_mul, wad_to_ray,
    };
    use super::oracle::{convert_token_to_usd, convert_usd_to_token, validate_price_bounds};
    use super::reserves::{to_real_balance, to_scaled_balance, update_reserve_state};
    use super::risk::{
        calculate_health_factor, calculate_ltv_borrow_capacity, calculate_weighted_collateral,
        is_account_solvent, validate_borrow_capacity,
    };
    use super::types::{InterestRateConfig, ReserveConfig, ReserveData};

    #[test]
    fn test_wad_math_operations() {
        let a = 2 * WAD;
        let b = 3 * WAD;
        let c = wad_mul(a, b);
        assert!(c == 6 * WAD, "2 * 3 wad_mul must equal 6 WAD");

        let d = wad_div(c, a);
        assert!(d == b, "6 / 2 wad_div must equal 3 WAD");
    }

    #[test]
    fn test_ray_math_operations() {
        let a = 5 * RAY;
        let b = 4 * RAY;
        let c = ray_mul(a, b);
        assert!(c == 20 * RAY, "5 * 4 ray_mul must equal 20 RAY");

        let d = ray_div(c, a);
        assert!(d == b, "20 / 5 ray_div must equal 4 RAY");
    }

    #[test]
    fn test_wad_ray_conversions() {
        let w = 42 * WAD;
        let r = wad_to_ray(w);
        assert!(r == 42 * RAY, "wad_to_ray failed");

        let w_back = ray_to_wad(r);
        assert!(w_back == w, "ray_to_wad round-trip failed");
    }

    #[test]
    fn test_percent_mul_div() {
        let val = 1_000 * WAD;
        // 50% = 5000 bps
        let half = percent_mul(val, 5_000);
        assert!(half == 500 * WAD, "50% percent_mul must be 500 WAD");

        let full = percent_div(half, 5_000);
        assert!(full == val, "percent_div round-trip failed");
    }

    #[test]
    fn test_interest_compounding() {
        // 10% annual rate in RAY = 0.1 * 10^27
        let rate_10_percent = 100_000_000_000_000_000_000_000_000;
        let one_year_seconds: u256 = 31_536_000;

        let linear_factor = calculate_linear_interest(rate_10_percent, one_year_seconds);
        // Linear factor should be 1.0 + 0.1 = 1.10 RAY
        let expected_linear = RAY + rate_10_percent;
        assert!(linear_factor == expected_linear, "Linear interest factor mismatch");

        let compounded_factor = calculate_compounded_interest(rate_10_percent, one_year_seconds);
        // Compounded factor includes 2nd order term x^2 / 2: 1 + 0.1 + 0.005 = 1.105 RAY
        assert!(compounded_factor > linear_factor, "Compounded rate must exceed linear");
    }

    #[test]
    fn test_kinked_interest_rate_model() {
        let ir_config = InterestRateConfig {
            base_rate_ray: 20_000_000_000_000_000_000_000_000, // 2% base
            optimal_utilization_ray: 800_000_000_000_000_000_000_000_000, // 80% optimal
            slope_1_ray: 40_000_000_000_000_000_000_000_000, // 4% slope 1
            slope_2_ray: 600_000_000_000_000_000_000_000_000 // 60% jump slope
        };
        let reserve_factor_bps = 1_000; // 10%

        // 1. Zero borrow: Utilization = 0%
        let u0 = calculate_utilization_rate(100_000 * WAD, 0);
        assert!(u0 == 0, "U must be 0 for 0 borrows");
        let (borrow_r0, supply_r0) = calculate_interest_rates(
            ir_config, reserve_factor_bps, 100_000 * WAD, 0,
        );
        assert!(borrow_r0 == ir_config.base_rate_ray, "Borrow rate at 0% must equal base rate");
        assert!(supply_r0 == 0, "Supply rate at 0% must be zero");

        // 2. Exactly at optimal utilization: U = 80%
        let cash = 20_000 * WAD;
        let borrows = 80_000 * WAD;
        let (borrow_r_opt, _) = calculate_interest_rates(
            ir_config, reserve_factor_bps, cash, borrows,
        );
        // At kink: Base + Slope 1 = 2% + 4% = 6%
        let expected_opt = ir_config.base_rate_ray + ir_config.slope_1_ray;
        assert!(borrow_r_opt == expected_opt, "Borrow rate at kink must equal base + slope1");

        // 3. Above optimal: U = 90% (Halfway through 80%..100% excess zone)
        let cash_high = 10_000 * WAD;
        let borrows_high = 90_000 * WAD;
        let (borrow_r_high, _) = calculate_interest_rates(
            ir_config, reserve_factor_bps, cash_high, borrows_high,
        );
        // Should trigger jump slope: Base + Slope1 + 0.5 * Slope2 = 2% + 4% + 30% = 36%
        assert!(borrow_r_high > expected_opt, "Jump slope must activate above kink");
    }

    #[test]
    fn test_scaled_balance_transformations() {
        let index = 1_250_000_000_000_000_000_000_000_000; // 1.25 RAY
        let real_amount = 250 * WAD;

        let scaled = to_scaled_balance(real_amount, index);
        // 250 / 1.25 = 200
        assert!(scaled == 200 * WAD, "Scaled shares calculation mismatch");

        let nominal_back = to_real_balance(scaled, index);
        assert!(nominal_back == real_amount, "Scaled to real round-trip failed");
    }

    #[test]
    fn test_health_factor_and_solvency() {
        // Collateral = 10 ETH @ $2,000 = $20,000. Liquidation Threshold = 80% => Weighted = $16,000
        let col_val_usd = 20_000 * WAD;
        let weighted_col = calculate_weighted_collateral(col_val_usd, 8_000);
        assert!(weighted_col == 16_000 * WAD, "Weighted collateral must be $16,000");

        // Debt = $10,000
        let debt_usd = 10_000 * WAD;
        let hf = calculate_health_factor(weighted_col, debt_usd);
        // HF = 16,000 / 10,000 = 1.60 WAD
        let expected_hf = (16 * WAD) / 10;
        assert!(hf == expected_hf, "Health factor must be 1.6 WAD");
        assert!(is_account_solvent(hf), "Account with HF 1.6 must be solvent");

        // Underwater position: Debt = $20,000
        let debt_underwater = 20_000 * WAD;
        let hf_underwater = calculate_health_factor(weighted_col, debt_underwater);
        // HF = 16,000 / 20,000 = 0.80 WAD
        assert!(!is_account_solvent(hf_underwater), "Account with HF 0.8 must be insolvent");
    }

    #[test]
    fn test_liquidation_calculation() {
        // Borrower debt: $10,000 in USDC (Price = $1.00)
        let user_debt = 10_000 * WAD;
        // Borrower collateral: 5 ETH (Price = $2,000 => $10,000)
        let user_col = 5 * WAD;
        let debt_price = 1 * WAD;
        let col_price = 2_000 * WAD;
        let bonus_bps = 500; // 5% bonus

        // Liquidator covers 50% max close factor: $5,000
        let res = calculate_liquidation_amounts(
            user_debt, user_col, debt_price, col_price, bonus_bps, 5_000 * WAD,
        );

        assert!(res.debt_repaid == 5_000 * WAD, "Debt repaid must be 5000 WAD");
        // Collateral value to seize: $5,000 * 1.05 = $5,250 => in ETH: 5,250 / 2,000 = 2.625 ETH
        let expected_col_tokens = (5_250 * WAD) / 2_000;
        assert!(
            res.collateral_seized == expected_col_tokens, "Collateral seized must match 2.625 ETH"
        );
        assert!(res.liquidator_reward > 0, "Liquidator reward must be > 0");
        assert!(res.protocol_collateral_fee > 0, "Protocol fee must be > 0");
    }

    #[test]
    fn test_flash_loan_fee_split() {
        let flash_amount = 100_000 * WAD;
        let fee_bps = 9; // 9 bps (0.09%)

        let (total_fee, protocol_share, lp_share) = calculate_flash_loan_fee(flash_amount, fee_bps);
        // 100,000 * 0.0009 = 90 WAD
        assert!(total_fee == 90 * WAD, "Flash loan fee must be 90 WAD");
        // Protocol share = 20% of 90 = 18 WAD
        assert!(protocol_share == 18 * WAD, "Protocol share must be 18 WAD");
        // LP share = 80% of 90 = 72 WAD
        assert!(lp_share == 72 * WAD, "LP share must be 72 WAD");

        let amount_due = calculate_flash_amount_due(flash_amount, fee_bps);
        assert!(amount_due == 100_090 * WAD, "Amount due must be 100,090 WAD");
    }

    #[test]
    fn test_oracle_conversions_and_bounds() {
        let eth_amount = 4 * WAD;
        let eth_price = 2_500 * WAD;
        let usd_val = convert_token_to_usd(eth_amount, eth_price);
        assert!(usd_val == 10_000 * WAD, "4 ETH @ $2,500 must equal $10,000");

        let tokens_back = convert_usd_to_token(usd_val, eth_price);
        assert!(tokens_back == eth_amount, "convert_usd_to_token round-trip failed");

        let is_valid = validate_price_bounds(eth_price, 100 * WAD, 100_000 * WAD);
        assert!(is_valid, "Price $2,500 must be within bounds");

        let is_out_of_bounds = validate_price_bounds(eth_price, 5_000 * WAD, 10_000 * WAD);
        assert!(!is_out_of_bounds, "Price $2,500 must be flagged out of bounds");
    }

    #[test]
    fn test_reserve_accrual_cycle() {
        let config = ReserveConfig {
            ltv: 7500,
            liquidation_threshold: 8000,
            liquidation_bonus: 500,
            reserve_factor: 1000, // 10%
            borrow_cap: 1_000_000 * WAD,
            supply_cap: 2_000_000 * WAD,
            is_active: true,
            is_frozen: false,
            borrowing_enabled: true,
        };

        let ir_config = InterestRateConfig {
            base_rate_ray: 20_000_000_000_000_000_000_000_000, // 2%
            optimal_utilization_ray: 800_000_000_000_000_000_000_000_000, // 80%
            slope_1_ray: 40_000_000_000_000_000_000_000_000, // 4%
            slope_2_ray: 600_000_000_000_000_000_000_000_000 // 60%
        };

        let mut data = ReserveData {
            liquidity_index_ray: RAY,
            borrow_index_ray: RAY,
            current_liquidity_rate_ray: 0,
            current_borrow_rate_ray: 60_000_000_000_000_000_000_000_000, // 6% initial borrow APY
            last_update_timestamp: 1_000_000,
            total_liquidity_scaled: 100_000 * WAD,
            total_borrow_scaled: 50_000 * WAD,
            accrued_protocol_fees: 0,
        };

        let cash = 50_000 * WAD;
        // Advance time by 180 days = 15,552,000 seconds
        let current_time = 1_000_000 + 15_552_000;

        update_reserve_state(ref data, config, ir_config, cash, current_time);

        assert!(data.borrow_index_ray > RAY, "Borrow index must compound upwards");
        assert!(data.last_update_timestamp == current_time, "Timestamp not updated");
        assert!(data.accrued_protocol_fees > 0, "Protocol fees must accrue from interest");
    }

    #[test]
    fn test_borrow_capacity_bounds() {
        // Collateral = $10,000. LTV = 75% => Max borrow capacity = $7,500
        let col_usd = 10_000 * WAD;
        let ltv_bps = 7_500;
        let max_borrow = calculate_ltv_borrow_capacity(col_usd, ltv_bps);
        assert!(max_borrow == 7_500 * WAD, "LTV capacity must be 7,500 WAD");

        // Existing borrow = $5,000. New borrow = $2,000 => Total $7,000 <= $7,500 (Allowed)
        let allowed = validate_borrow_capacity(max_borrow, 5_000 * WAD, 2_000 * WAD);
        assert!(allowed, "Borrowing up to $7,000 should be allowed");

        // Existing borrow = $5,000. New borrow = $3,000 => Total $8,000 > $7,500 (Denied)
        let denied = validate_borrow_capacity(max_borrow, 5_000 * WAD, 3_000 * WAD);
        assert!(!denied, "Borrowing beyond capacity must be rejected");
    }

    #[test]
    fn test_underwater_debt_cascade() {
        // Severe crash: User has 1 ETH ($1,000) but borrowed $3,000 USDC
        let user_debt = 3_000 * WAD;
        let user_col = 1 * WAD;
        let debt_price = 1 * WAD;
        let col_price = 1_000 * WAD;
        let bonus_bps = 500; // 5%

        // Liquidator tries to repay $1,500
        let res = calculate_liquidation_amounts(
            user_debt, user_col, debt_price, col_price, bonus_bps, 1_500 * WAD,
        );

        // Seizure is capped at user's total available collateral (1 ETH)
        assert!(res.collateral_seized <= user_col, "Seized collateral cannot exceed available");
        assert!(res.debt_repaid > 0, "Debt repaid must be non-zero");
    }

    #[test]
    fn test_extreme_utilization_near_hundred() {
        let ir_config = InterestRateConfig {
            base_rate_ray: 10_000_000_000_000_000_000_000_000, // 1%
            optimal_utilization_ray: 800_000_000_000_000_000_000_000_000, // 80%
            slope_1_ray: 30_000_000_000_000_000_000_000_000, // 3%
            slope_2_ray: 1_000_000_000_000_000_000_000_000_000 // 100% jump slope
        };
        let reserve_factor_bps = 1_000;

        // 98% utilization: Cash = 2,000, Borrows = 98,000
        let (borrow_rate, _) = calculate_interest_rates(
            ir_config, reserve_factor_bps, 2_000 * WAD, 98_000 * WAD,
        );

        // Borrow rate should reflect massive jump rate above 80%: Base + Slope1 + ~90% of Slope2
        assert!(
            borrow_rate > 800_000_000_000_000_000_000_000_000, "Borrow rate must spike past 80%"
        );
    }

    #[test]
    fn test_zero_amount_safeguards() {
        let res = calculate_liquidation_amounts(0, 0, 1 * WAD, 1 * WAD, 500, 100 * WAD);
        assert!(res.debt_repaid == 0, "Repaid debt on 0 position must be 0");
        assert!(res.collateral_seized == 0, "Seized collateral on 0 position must be 0");
    }
}
