//! Normalized 18-decimal price routing and bounds verification for AetherisCredit.

use starknet::ContractAddress;
use crate::math::{wad_div, wad_mul};

#[starknet::interface]
pub trait IPriceOracle<TContractState> {
    fn get_asset_price(self: @TContractState, asset: ContractAddress) -> u256;
    fn get_asset_price_with_staleness(
        self: @TContractState, asset: ContractAddress, max_age_seconds: u64, current_timestamp: u64,
    ) -> u256;
}

/// Converts a nominal token amount to its USD valuation in WAD (10^18):
/// usd_val = (amount * price_wad) / WAD
pub fn convert_token_to_usd(amount: u256, price_usd_wad: u256) -> u256 {
    if amount == 0 || price_usd_wad == 0 {
        return 0;
    }
    wad_mul(amount, price_usd_wad)
}

/// Converts a USD valuation in WAD to nominal token units:
/// token_amount = (usd_val * WAD) / price_wad
pub fn convert_usd_to_token(usd_amount_wad: u256, price_usd_wad: u256) -> u256 {
    assert!(price_usd_wad > 0, "Price cannot be zero in convert_usd_to_token");
    wad_div(usd_amount_wad, price_usd_wad)
}

/// Validates whether an oracle price falls within circuit-breaker sanity bounds.
pub fn validate_price_bounds(price_usd_wad: u256, min_bound: u256, max_bound: u256) -> bool {
    price_usd_wad >= min_bound && price_usd_wad <= max_bound
}
