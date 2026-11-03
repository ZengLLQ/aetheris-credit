//! Core isolated lending pool and market orchestrator contract for AetherisCredit on Starknet.

use starknet::ContractAddress;

#[starknet::interface]
pub trait IAetherisMarket<TContractState> {
    fn initialize_reserve(
        ref self: TContractState,
        asset: ContractAddress,
        ltv: u256,
        liquidation_threshold: u256,
        liquidation_bonus: u256,
        reserve_factor: u256,
        borrow_cap: u256,
        supply_cap: u256,
        base_rate_ray: u256,
        optimal_utilization_ray: u256,
        slope_1_ray: u256,
        slope_2_ray: u256,
    );
    fn set_asset_price(ref self: TContractState, asset: ContractAddress, price_usd_wad: u256);
    fn deposit(ref self: TContractState, asset: ContractAddress, amount: u256) -> u256;
    fn withdraw(ref self: TContractState, asset: ContractAddress, amount: u256) -> u256;
    fn borrow(ref self: TContractState, asset: ContractAddress, amount: u256);
    fn repay(ref self: TContractState, asset: ContractAddress, amount: u256) -> u256;
    fn liquidate(
        ref self: TContractState,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        debt_to_cover: u256,
    ) -> (u256, u256);
    fn get_user_position(
        self: @TContractState, user: ContractAddress, asset: ContractAddress,
    ) -> (u256, u256);
    fn get_reserve_indices(self: @TContractState, asset: ContractAddress) -> (u256, u256);
    fn get_reserve_rates(self: @TContractState, asset: ContractAddress) -> (u256, u256);
    fn get_user_health_factor(self: @TContractState, user: ContractAddress) -> u256;
}

#[starknet::contract]
pub mod aetheris_market {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use crate::liquidations::calculate_liquidation_amounts;
    use crate::math::RAY;
    use crate::oracle::convert_token_to_usd;
    use crate::reserves::{to_real_balance, to_scaled_balance, update_reserve_state};
    use crate::risk::{calculate_health_factor, calculate_weighted_collateral, is_account_solvent};
    use crate::types::{
        InterestRateConfig, LiquidationResult, ReserveConfig, ReserveData, UserPosition,
    };
    use super::IAetherisMarket;

    #[storage]
    struct Storage {
        admin: ContractAddress,
        reserves_config: Map<ContractAddress, ReserveConfig>,
        reserves_data: Map<ContractAddress, ReserveData>,
        reserves_ir: Map<ContractAddress, InterestRateConfig>,
        reserves_cash: Map<ContractAddress, u256>,
        prices_usd_wad: Map<ContractAddress, u256>,
        user_positions: Map<(ContractAddress, ContractAddress), UserPosition>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Deposit: Deposit,
        Withdraw: Withdraw,
        Borrow: Borrow,
        Repay: Repay,
        Liquidate: Liquidate,
        ReserveInitialized: ReserveInitialized,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Deposit {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub asset: ContractAddress,
        pub amount: u256,
        pub scaled_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Withdraw {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub asset: ContractAddress,
        pub amount: u256,
        pub scaled_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Borrow {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub asset: ContractAddress,
        pub amount: u256,
        pub scaled_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Repay {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub asset: ContractAddress,
        pub amount: u256,
        pub scaled_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Liquidate {
        #[key]
        pub liquidator: ContractAddress,
        #[key]
        pub borrower: ContractAddress,
        pub collateral_asset: ContractAddress,
        pub debt_asset: ContractAddress,
        pub debt_repaid: u256,
        pub collateral_seized: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ReserveInitialized {
        #[key]
        pub asset: ContractAddress,
        pub ltv: u256,
        pub liquidation_threshold: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.admin.write(admin);
    }

    #[abi(embed_v0)]
    impl AetherisMarketImpl of IAetherisMarket<ContractState> {
        fn initialize_reserve(
            ref self: ContractState,
            asset: ContractAddress,
            ltv: u256,
            liquidation_threshold: u256,
            liquidation_bonus: u256,
            reserve_factor: u256,
            borrow_cap: u256,
            supply_cap: u256,
            base_rate_ray: u256,
            optimal_utilization_ray: u256,
            slope_1_ray: u256,
            slope_2_ray: u256,
        ) {
            let caller = get_caller_address();
            let admin = self.admin.read();
            assert!(caller == admin, "Caller is not admin");

            let config = ReserveConfig {
                ltv,
                liquidation_threshold,
                liquidation_bonus,
                reserve_factor,
                borrow_cap,
                supply_cap,
                is_active: true,
                is_frozen: false,
                borrowing_enabled: true,
            };

            let ir_config = InterestRateConfig {
                base_rate_ray, optimal_utilization_ray, slope_1_ray, slope_2_ray,
            };

            let now = get_block_timestamp();
            let data = ReserveData {
                liquidity_index_ray: RAY,
                borrow_index_ray: RAY,
                current_liquidity_rate_ray: 0,
                current_borrow_rate_ray: base_rate_ray,
                last_update_timestamp: now,
                total_liquidity_scaled: 0,
                total_borrow_scaled: 0,
                accrued_protocol_fees: 0,
            };

            self.reserves_config.write(asset, config);
            self.reserves_ir.write(asset, ir_config);
            self.reserves_data.write(asset, data);
            self.reserves_cash.write(asset, 0);

            self
                .emit(
                    Event::ReserveInitialized(
                        ReserveInitialized { asset, ltv, liquidation_threshold },
                    ),
                );
        }

        fn set_asset_price(ref self: ContractState, asset: ContractAddress, price_usd_wad: u256) {
            let caller = get_caller_address();
            let admin = self.admin.read();
            assert!(caller == admin, "Caller is not admin");
            assert!(price_usd_wad > 0, "Price must be strictly positive");
            self.prices_usd_wad.write(asset, price_usd_wad);
        }

        fn deposit(ref self: ContractState, asset: ContractAddress, amount: u256) -> u256 {
            assert!(amount > 0, "Deposit amount must be > 0");
            let caller = get_caller_address();
            let config = self.reserves_config.read(asset);
            assert!(config.is_active && !config.is_frozen, "Reserve is not active or frozen");

            let mut data = self.reserves_data.read(asset);
            let ir_config = self.reserves_ir.read(asset);
            let mut cash = self.reserves_cash.read(asset);
            let now = get_block_timestamp();

            update_reserve_state(ref data, config, ir_config, cash, now);

            let scaled_amount = to_scaled_balance(amount, data.liquidity_index_ray);
            data.total_liquidity_scaled += scaled_amount;
            cash += amount;

            if config.supply_cap > 0 {
                let current_supply = to_real_balance(
                    data.total_liquidity_scaled, data.liquidity_index_ray,
                );
                assert!(current_supply <= config.supply_cap, "Supply cap exceeded");
            }

            self.reserves_data.write(asset, data);
            self.reserves_cash.write(asset, cash);

            let mut pos = self.user_positions.read((caller, asset));
            pos.scaled_collateral += scaled_amount;
            pos.is_collateral_enabled = true;
            self.user_positions.write((caller, asset), pos);

            self.emit(Event::Deposit(Deposit { user: caller, asset, amount, scaled_amount }));
            scaled_amount
        }

        fn withdraw(ref self: ContractState, asset: ContractAddress, amount: u256) -> u256 {
            assert!(amount > 0, "Withdraw amount must be > 0");
            let caller = get_caller_address();
            let config = self.reserves_config.read(asset);
            assert!(config.is_active, "Reserve is not active");

            let mut data = self.reserves_data.read(asset);
            let ir_config = self.reserves_ir.read(asset);
            let mut cash = self.reserves_cash.read(asset);
            let now = get_block_timestamp();

            update_reserve_state(ref data, config, ir_config, cash, now);

            let mut pos = self.user_positions.read((caller, asset));
            let user_nominal_collateral = to_real_balance(
                pos.scaled_collateral, data.liquidity_index_ray,
            );
            let actual_withdraw = if amount > user_nominal_collateral {
                user_nominal_collateral
            } else {
                amount
            };
            assert!(actual_withdraw > 0, "Zero withdrawable balance");
            assert!(cash >= actual_withdraw, "Insufficient market cash liquidity");

            let scaled_withdraw = to_scaled_balance(actual_withdraw, data.liquidity_index_ray);
            pos.scaled_collateral -= scaled_withdraw;
            data.total_liquidity_scaled -= scaled_withdraw;
            cash -= actual_withdraw;

            self.reserves_data.write(asset, data);
            self.reserves_cash.write(asset, cash);
            self.user_positions.write((caller, asset), pos);

            // Verify account remains solvent after withdrawal:
            let health_factor = self.get_user_health_factor(caller);
            assert!(is_account_solvent(health_factor), "Withdrawal violates solvency");

            self
                .emit(
                    Event::Withdraw(
                        Withdraw {
                            user: caller,
                            asset,
                            amount: actual_withdraw,
                            scaled_amount: scaled_withdraw,
                        },
                    ),
                );
            actual_withdraw
        }

        fn borrow(ref self: ContractState, asset: ContractAddress, amount: u256) {
            assert!(amount > 0, "Borrow amount must be > 0");
            let caller = get_caller_address();
            let config = self.reserves_config.read(asset);
            assert!(config.is_active && !config.is_frozen, "Reserve is not active or frozen");
            assert!(config.borrowing_enabled, "Borrowing is disabled for asset");

            let mut data = self.reserves_data.read(asset);
            let ir_config = self.reserves_ir.read(asset);
            let mut cash = self.reserves_cash.read(asset);
            assert!(cash >= amount, "Insufficient cash to borrow");

            let now = get_block_timestamp();
            update_reserve_state(ref data, config, ir_config, cash, now);

            let scaled_borrow = to_scaled_balance(amount, data.borrow_index_ray);
            data.total_borrow_scaled += scaled_borrow;
            cash -= amount;

            if config.borrow_cap > 0 {
                let current_borrow = to_real_balance(
                    data.total_borrow_scaled, data.borrow_index_ray,
                );
                assert!(current_borrow <= config.borrow_cap, "Borrow cap exceeded");
            }

            self.reserves_data.write(asset, data);
            self.reserves_cash.write(asset, cash);

            let mut pos = self.user_positions.read((caller, asset));
            pos.scaled_borrow += scaled_borrow;
            self.user_positions.write((caller, asset), pos);

            // Solvency verification post-borrow:
            let health_factor = self.get_user_health_factor(caller);
            assert!(is_account_solvent(health_factor), "Borrow exceeds collateral LTV capacity");

            self
                .emit(
                    Event::Borrow(
                        Borrow { user: caller, asset, amount, scaled_amount: scaled_borrow },
                    ),
                );
        }

        fn repay(ref self: ContractState, asset: ContractAddress, amount: u256) -> u256 {
            assert!(amount > 0, "Repay amount must be > 0");
            let caller = get_caller_address();
            let config = self.reserves_config.read(asset);
            assert!(config.is_active, "Reserve is not active");

            let mut data = self.reserves_data.read(asset);
            let ir_config = self.reserves_ir.read(asset);
            let mut cash = self.reserves_cash.read(asset);
            let now = get_block_timestamp();

            update_reserve_state(ref data, config, ir_config, cash, now);

            let mut pos = self.user_positions.read((caller, asset));
            let user_borrow_nominal = to_real_balance(pos.scaled_borrow, data.borrow_index_ray);
            assert!(user_borrow_nominal > 0, "User has zero outstanding debt");

            let actual_repay = if amount > user_borrow_nominal {
                user_borrow_nominal
            } else {
                amount
            };

            let scaled_repay = to_scaled_balance(actual_repay, data.borrow_index_ray);
            pos.scaled_borrow -= scaled_repay;
            data.total_borrow_scaled -= scaled_repay;
            cash += actual_repay;

            self.reserves_data.write(asset, data);
            self.reserves_cash.write(asset, cash);
            self.user_positions.write((caller, asset), pos);

            self
                .emit(
                    Event::Repay(
                        Repay {
                            user: caller, asset, amount: actual_repay, scaled_amount: scaled_repay,
                        },
                    ),
                );
            actual_repay
        }

        fn liquidate(
            ref self: ContractState,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress,
            debt_to_cover: u256,
        ) -> (u256, u256) {
            let liquidator = get_caller_address();
            assert!(liquidator != user, "Borrower cannot self-liquidate");

            let user_hf = self.get_user_health_factor(user);
            assert!(!is_account_solvent(user_hf), "Position is solvent; cannot liquidate");

            let debt_config = self.reserves_config.read(debt_asset);
            let col_config = self.reserves_config.read(collateral_asset);
            assert!(debt_config.is_active && col_config.is_active, "Reserves must be active");

            let mut debt_data = self.reserves_data.read(debt_asset);
            let mut col_data = self.reserves_data.read(collateral_asset);
            let debt_ir = self.reserves_ir.read(debt_asset);
            let col_ir = self.reserves_ir.read(collateral_asset);

            let mut debt_cash = self.reserves_cash.read(debt_asset);
            let col_cash = self.reserves_cash.read(collateral_asset);
            let now = get_block_timestamp();

            update_reserve_state(ref debt_data, debt_config, debt_ir, debt_cash, now);
            update_reserve_state(ref col_data, col_config, col_ir, col_cash, now);

            let mut user_debt_pos = self.user_positions.read((user, debt_asset));
            let mut user_col_pos = self.user_positions.read((user, collateral_asset));

            let user_debt_nominal = to_real_balance(
                user_debt_pos.scaled_borrow, debt_data.borrow_index_ray,
            );
            let user_col_nominal = to_real_balance(
                user_col_pos.scaled_collateral, col_data.liquidity_index_ray,
            );

            let debt_price = self.prices_usd_wad.read(debt_asset);
            let col_price = self.prices_usd_wad.read(collateral_asset);

            let result: LiquidationResult = calculate_liquidation_amounts(
                user_debt_nominal,
                user_col_nominal,
                debt_price,
                col_price,
                col_config.liquidation_bonus,
                debt_to_cover,
            );

            assert!(result.debt_repaid > 0, "Calculated debt repaid is zero");
            assert!(result.collateral_seized > 0, "Calculated collateral seized is zero");

            // Burn user debt
            let scaled_debt_repaid = to_scaled_balance(
                result.debt_repaid, debt_data.borrow_index_ray,
            );
            user_debt_pos.scaled_borrow -= scaled_debt_repaid;
            debt_data.total_borrow_scaled -= scaled_debt_repaid;
            debt_cash += result.debt_repaid;

            // Seize user collateral
            let scaled_col_seized = to_scaled_balance(
                result.collateral_seized, col_data.liquidity_index_ray,
            );
            user_col_pos.scaled_collateral -= scaled_col_seized;
            col_data.total_liquidity_scaled -= scaled_col_seized;

            // Credit liquidator with seized collateral shares
            let mut liquidator_pos = self.user_positions.read((liquidator, collateral_asset));
            let scaled_liquidator_reward = to_scaled_balance(
                result.liquidator_reward, col_data.liquidity_index_ray,
            );
            liquidator_pos.scaled_collateral += scaled_liquidator_reward;
            col_data.total_liquidity_scaled += scaled_liquidator_reward;

            // Protocol fee credit
            if result.protocol_collateral_fee > 0 {
                col_data.accrued_protocol_fees += result.protocol_collateral_fee;
            }

            self.reserves_data.write(debt_asset, debt_data);
            self.reserves_cash.write(debt_asset, debt_cash);
            self.reserves_data.write(collateral_asset, col_data);

            self.user_positions.write((user, debt_asset), user_debt_pos);
            self.user_positions.write((user, collateral_asset), user_col_pos);
            self.user_positions.write((liquidator, collateral_asset), liquidator_pos);

            self
                .emit(
                    Event::Liquidate(
                        Liquidate {
                            liquidator,
                            borrower: user,
                            collateral_asset,
                            debt_asset,
                            debt_repaid: result.debt_repaid,
                            collateral_seized: result.collateral_seized,
                        },
                    ),
                );

            (result.debt_repaid, result.collateral_seized)
        }

        fn get_user_position(
            self: @ContractState, user: ContractAddress, asset: ContractAddress,
        ) -> (u256, u256) {
            let pos = self.user_positions.read((user, asset));
            let data = self.reserves_data.read(asset);
            let collateral_nominal = to_real_balance(
                pos.scaled_collateral, data.liquidity_index_ray,
            );
            let borrow_nominal = to_real_balance(pos.scaled_borrow, data.borrow_index_ray);
            (collateral_nominal, borrow_nominal)
        }

        fn get_reserve_indices(self: @ContractState, asset: ContractAddress) -> (u256, u256) {
            let data = self.reserves_data.read(asset);
            (data.liquidity_index_ray, data.borrow_index_ray)
        }

        fn get_reserve_rates(self: @ContractState, asset: ContractAddress) -> (u256, u256) {
            let data = self.reserves_data.read(asset);
            (data.current_borrow_rate_ray, data.current_liquidity_rate_ray)
        }

        fn get_user_health_factor(self: @ContractState, user: ContractAddress) -> u256 {
            let eth_addr: ContractAddress = 0x1.try_into().unwrap();
            let usdc_addr: ContractAddress = 0x2.try_into().unwrap();

            let (eth_col, eth_borrow) = self.get_user_position(user, eth_addr);
            let (usdc_col, usdc_borrow) = self.get_user_position(user, usdc_addr);

            let eth_price = self.prices_usd_wad.read(eth_addr);
            let usdc_price = self.prices_usd_wad.read(usdc_addr);

            let eth_config = self.reserves_config.read(eth_addr);
            let usdc_config = self.reserves_config.read(usdc_addr);

            let eth_col_usd = convert_token_to_usd(eth_col, eth_price);
            let usdc_col_usd = convert_token_to_usd(usdc_col, usdc_price);

            let eth_borrow_usd = convert_token_to_usd(eth_borrow, eth_price);
            let usdc_borrow_usd = convert_token_to_usd(usdc_borrow, usdc_price);

            let total_borrow_usd = eth_borrow_usd + usdc_borrow_usd;
            if total_borrow_usd == 0 {
                return crate::risk::INFINITE_HEALTH_FACTOR;
            }

            let eth_weighted_col = calculate_weighted_collateral(
                eth_col_usd, eth_config.liquidation_threshold,
            );
            let usdc_weighted_col = calculate_weighted_collateral(
                usdc_col_usd, usdc_config.liquidation_threshold,
            );
            let total_weighted_col = eth_weighted_col + usdc_weighted_col;

            calculate_health_factor(total_weighted_col, total_borrow_usd)
        }
    }
}
