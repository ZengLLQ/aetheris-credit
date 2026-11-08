//! High-Precision Fixed-Point Numerical Engine for AetherisCredit.
//! Implements Wad (10^18) and Ray (10^27) arithmetic with half-up rounding.

pub const WAD: u256 = 1_000_000_000_000_000_000;
pub const HALF_WAD: u256 = 500_000_000_000_000_000;

pub const RAY: u256 = 1_000_000_000_000_000_000_000_000_000;
pub const HALF_RAY: u256 = 500_000_000_000_000_000_000_000_000;

pub const WAD_RAY_RATIO: u256 = 1_000_000_000;
pub const HALF_WAD_RAY_RATIO: u256 = 500_000_000;

pub const PERCENTAGE_FACTOR: u256 = 10_000;
pub const HALF_PERCENTAGE_FACTOR: u256 = 5_000;

pub const SECONDS_PER_YEAR: u256 = 31_536_000;

/// Multiplies two WAD numbers with standard half-up rounding.
pub fn wad_mul(a: u256, b: u256) -> u256 {
    if a == 0 || b == 0 {
        return 0;
    }
    (a * b + HALF_WAD) / WAD
}

/// Divides two WAD numbers with standard half-up rounding.
pub fn wad_div(a: u256, b: u256) -> u256 {
    assert!(b != 0, "Division by zero in wad_div");
    (a * WAD + b / 2) / b
}

/// Multiplies two RAY numbers with standard half-up rounding.
pub fn ray_mul(a: u256, b: u256) -> u256 {
    if a == 0 || b == 0 {
        return 0;
    }
    (a * b + HALF_RAY) / RAY
}

/// Divides two RAY numbers with standard half-up rounding.
pub fn ray_div(a: u256, b: u256) -> u256 {
    assert!(b != 0, "Division by zero in ray_div");
    (a * RAY + b / 2) / b
}

/// Converts a RAY value (10^27) down to a WAD value (10^18) with rounding.
pub fn ray_to_wad(a: u256) -> u256 {
    (a + HALF_WAD_RAY_RATIO) / WAD_RAY_RATIO
}

/// Converts a WAD value (10^18) up to a RAY value (10^27).
pub fn wad_to_ray(a: u256) -> u256 {
    a * WAD_RAY_RATIO
}

/// Multiplies a value by basis points percentage (10,000 = 100.00%).
pub fn percent_mul(value: u256, percentage: u256) -> u256 {
    if value == 0 || percentage == 0 {
        return 0;
    }
    (value * percentage + HALF_PERCENTAGE_FACTOR) / PERCENTAGE_FACTOR
}

/// Divides a value by basis points percentage (10,000 = 100.00%).
pub fn percent_div(value: u256, percentage: u256) -> u256 {
    assert!(percentage != 0, "Division by zero in percent_div");
    (value * PERCENTAGE_FACTOR + percentage / 2) / percentage
}

/// Computes linear interest accrual factor over delta_t seconds:
/// Factor = 1.0 + (rate_ray * delta_t) / SECONDS_PER_YEAR
pub fn calculate_linear_interest(rate_per_year_ray: u256, delta_t: u256) -> u256 {
    if rate_per_year_ray == 0 || delta_t == 0 {
        return RAY;
    }
    let interest = (rate_per_year_ray * delta_t) / SECONDS_PER_YEAR;
    RAY + interest
}

/// Computes continuously compounded interest factor via 2nd-order Taylor expansion:
/// Factor = 1 + x + x^2 / 2! where x = (rate_ray * delta_t) / SECONDS_PER_YEAR
pub fn calculate_compounded_interest(rate_per_year_ray: u256, delta_t: u256) -> u256 {
    if rate_per_year_ray == 0 || delta_t == 0 {
        return RAY;
    }
    let x = (rate_per_year_ray * delta_t) / SECONDS_PER_YEAR;
    let x_squared = ray_mul(x, x);
    let second_term = x_squared / 2;
    RAY + x + second_term
}
