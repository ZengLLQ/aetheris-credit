//! Core data structures, configurations, and structs for AetherisCredit.

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct ReserveConfig {
    pub ltv: u256, // Loan to value in bps (e.g., 7500 = 75%)
    pub liquidation_threshold: u256, // Liquidation threshold in bps (e.g., 8000 = 80%)
    pub liquidation_bonus: u256, // Bonus for liquidator in bps (e.g., 500 = 5%)
    pub reserve_factor: u256, // Protocol share of borrow interest in bps (e.g., 1000 = 10%)
    pub borrow_cap: u256, // Max allowed total borrow amount
    pub supply_cap: u256, // Max allowed total supply amount
    pub is_active: bool,
    pub is_frozen: bool,
    pub borrowing_enabled: bool,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct InterestRateConfig {
    pub base_rate_ray: u256, // R_0 in RAY
    pub optimal_utilization_ray: u256, // U_optimal in RAY (e.g., 0.8 * 10^27 = 80%)
    pub slope_1_ray: u256, // Slope 1 in RAY below optimal utilization
    pub slope_2_ray: u256 // Slope 2 (jump slope) in RAY above optimal
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct ReserveData {
    pub liquidity_index_ray: u256, // Compounded liquidity index in RAY
    pub borrow_index_ray: u256, // Compounded borrow index in RAY
    pub current_liquidity_rate_ray: u256, // Annual supply APY in RAY
    pub current_borrow_rate_ray: u256, // Annual borrow APY in RAY
    pub last_update_timestamp: u64,
    pub total_liquidity_scaled: u256, // Total scaled deposit shares
    pub total_borrow_scaled: u256, // Total scaled borrow shares
    pub accrued_protocol_fees: u256 // Accumulated protocol treasury fees
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct UserPosition {
    pub scaled_collateral: u256,
    pub scaled_borrow: u256,
    pub is_collateral_enabled: bool,
}

#[derive(Copy, Drop, Serde)]
pub struct AccountHealth {
    pub total_collateral_usd_wad: u256,
    pub total_borrow_usd_wad: u256,
    pub weighted_liquidation_usd_wad: u256,
    pub health_factor_wad: u256,
    pub is_solvent: bool,
}

#[derive(Copy, Drop, Serde)]
pub struct LiquidationResult {
    pub debt_repaid: u256,
    pub collateral_seized: u256,
    pub protocol_collateral_fee: u256,
    pub liquidator_reward: u256,
}
