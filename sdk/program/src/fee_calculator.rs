//! Calculation of transaction fees.

#![allow(clippy::arithmetic_side_effects)]
use {
    crate::{ed25519_program, message::Message, secp256k1_program},
    log::*,
};

#[repr(C)]
#[derive(Serialize, Deserialize, Default, PartialEq, Eq, Clone, Copy, Debug, AbiExample)]
#[serde(rename_all = "camelCase")]
pub struct FeeCalculator {
    /// The current cost of a signature.
    ///
    /// This amount may increase/decrease over time based on cluster processing
    /// load.
    pub lamports_per_signature: u64,
}

impl FeeCalculator {
    pub fn new(lamports_per_signature: u64) -> Self {
        Self {
            lamports_per_signature,
        }
    }

    #[deprecated(
        since = "1.9.0",
        note = "Please do not use, will no longer be available in the future"
    )]
    pub fn calculate_fee(&self, message: &Message) -> u64 {
        DEFAULT_TARGET_LAMPORTS_PER_SIGNATURE
    }
}

#[derive(Serialize, Deserialize, PartialEq, Eq, Clone, Debug, AbiExample)]
#[serde(rename_all = "camelCase")]
pub struct FeeRateGovernor {
    // The current cost of a signature  This amount may increase/decrease over time based on
    // cluster processing load.
    #[serde(skip)]
    pub lamports_per_signature: u64,

    // The target cost of a signature when the cluster is operating around target_signatures_per_slot
    // signatures
    pub target_lamports_per_signature: u64,

    // Used to estimate the desired processing capacity of the cluster.  As the signatures for
    // recent slots are fewer/greater than this value, lamports_per_signature will decrease/increase
    // for the next slot.  A value of 0 disables lamports_per_signature fee adjustments
    pub target_signatures_per_slot: u64,

    pub min_lamports_per_signature: u64,
    pub max_lamports_per_signature: u64,

    // What portion of collected fees are to be destroyed, as a fraction of std::u8::MAX
    pub burn_percent: u8,
}

// ============================================================================
// CONSTANT TRANSACTION FEE CONFIGURATION
// ============================================================================
// Change this value to modify the constant transaction fee for all transactions
// Current: 0.00001 ROX = 10,000 lamports
// To change: Update CONSTANT_TRANSACTION_FEE_LAMPORTS below
// ============================================================================
pub const CONSTANT_TRANSACTION_FEE_LAMPORTS: u64 = 10_000;

// Legacy constant - now uses the constant fee
pub const DEFAULT_TARGET_LAMPORTS_PER_SIGNATURE: u64 = CONSTANT_TRANSACTION_FEE_LAMPORTS;
pub const DEFAULT_TARGET_SIGNATURES_PER_SLOT: u64 = 0;

// Percentage of tx fees to burn
pub const DEFAULT_BURN_PERCENT: u8 = 0;

impl Default for FeeRateGovernor {
    fn default() -> Self {
        // Use global constant fee
        Self {
            lamports_per_signature: CONSTANT_TRANSACTION_FEE_LAMPORTS,
            target_lamports_per_signature: CONSTANT_TRANSACTION_FEE_LAMPORTS,
            target_signatures_per_slot: 0, // Disable dynamic adjustment
            min_lamports_per_signature: CONSTANT_TRANSACTION_FEE_LAMPORTS,
            max_lamports_per_signature: CONSTANT_TRANSACTION_FEE_LAMPORTS,
            burn_percent: DEFAULT_BURN_PERCENT,
        }
    }
}

impl FeeRateGovernor {
    pub fn new(target_lamports_per_signature: u64, target_signatures_per_slot: u64) -> Self {
        // Always use constant fee from global constant
        // Ignore parameters to ensure fees never change
        let base_fee_rate_governor = Self {
            target_lamports_per_signature: CONSTANT_TRANSACTION_FEE_LAMPORTS,
            lamports_per_signature: CONSTANT_TRANSACTION_FEE_LAMPORTS,
            target_signatures_per_slot: 0, // Disable dynamic adjustment
            min_lamports_per_signature: CONSTANT_TRANSACTION_FEE_LAMPORTS,
            max_lamports_per_signature: CONSTANT_TRANSACTION_FEE_LAMPORTS,
            ..FeeRateGovernor::default()
        };

        Self::new_derived(&base_fee_rate_governor, 0)
    }

    pub fn new_derived(
        base_fee_rate_governor: &FeeRateGovernor,
        latest_signatures_per_slot: u64,
    ) -> Self {
        let mut me = base_fee_rate_governor.clone();

        // Always use constant fee from global constant
        // Disable dynamic fee adjustment regardless of traffic
        me.lamports_per_signature = CONSTANT_TRANSACTION_FEE_LAMPORTS;
        me.target_lamports_per_signature = CONSTANT_TRANSACTION_FEE_LAMPORTS;
        me.min_lamports_per_signature = CONSTANT_TRANSACTION_FEE_LAMPORTS;
        me.max_lamports_per_signature = CONSTANT_TRANSACTION_FEE_LAMPORTS;
        me.target_signatures_per_slot = 0; // Disable dynamic adjustment
        
        debug!(
            "new_derived(): lamports_per_signature: {} (constant fee)",
            me.lamports_per_signature
        );
        me
    }

    pub fn clone_with_lamports_per_signature(&self, lamports_per_signature: u64) -> Self {
        Self {
            lamports_per_signature,
            ..*self
        }
    }

    /// calculate unburned fee from a fee total, returns (unburned, burned)
    pub fn burn(&self, fees: u64) -> (u64, u64) {
        let burned = fees * u64::from(self.burn_percent) / 100;
        (fees - burned, burned)
    }

    /// create a FeeCalculator based on current cluster signature throughput
    pub fn create_fee_calculator(&self) -> FeeCalculator {
        FeeCalculator::new(self.lamports_per_signature)
    }
}

#[cfg(test)]
mod tests {
    use {
        super::*,
        crate::{pubkey::Pubkey, system_instruction},
    };

    #[test]
    fn test_fee_rate_governor_burn() {
        let mut fee_rate_governor = FeeRateGovernor::default();
        assert_eq!(fee_rate_governor.burn(2), (1, 1));

        fee_rate_governor.burn_percent = 0;
        assert_eq!(fee_rate_governor.burn(2), (2, 0));

        fee_rate_governor.burn_percent = 100;
        assert_eq!(fee_rate_governor.burn(2), (0, 2));
    }

    #[test]
    #[allow(deprecated)]
    fn test_fee_calculator_calculate_fee() {
        // Default: no fee.
        let message = Message::default();
        assert_eq!(FeeCalculator::default().calculate_fee(&message), 0);

        // No signature, no fee.
        assert_eq!(FeeCalculator::new(1).calculate_fee(&message), 0);

        // One signature, a fee.
        let pubkey0 = Pubkey::from([0; 32]);
        let pubkey1 = Pubkey::from([1; 32]);
        let ix0 = system_instruction::transfer(&pubkey0, &pubkey1, 1);
        let message = Message::new(&[ix0], Some(&pubkey0));
        assert_eq!(FeeCalculator::new(2).calculate_fee(&message), 2);

        // Two signatures, double the fee.
        let ix0 = system_instruction::transfer(&pubkey0, &pubkey1, 1);
        let ix1 = system_instruction::transfer(&pubkey1, &pubkey0, 1);
        let message = Message::new(&[ix0, ix1], Some(&pubkey0));
        assert_eq!(FeeCalculator::new(2).calculate_fee(&message), 4);
    }

    #[test]
    #[allow(deprecated)]
    fn test_fee_calculator_calculate_fee_secp256k1() {
        use crate::instruction::Instruction;
        let pubkey0 = Pubkey::from([0; 32]);
        let pubkey1 = Pubkey::from([1; 32]);
        let ix0 = system_instruction::transfer(&pubkey0, &pubkey1, 1);
        let mut secp_instruction = Instruction {
            program_id: crate::secp256k1_program::id(),
            accounts: vec![],
            data: vec![],
        };
        let mut secp_instruction2 = Instruction {
            program_id: crate::secp256k1_program::id(),
            accounts: vec![],
            data: vec![1],
        };

        let message = Message::new(
            &[
                ix0.clone(),
                secp_instruction.clone(),
                secp_instruction2.clone(),
            ],
            Some(&pubkey0),
        );
        assert_eq!(FeeCalculator::new(1).calculate_fee(&message), 2);

        secp_instruction.data = vec![0];
        secp_instruction2.data = vec![10];
        let message = Message::new(&[ix0, secp_instruction, secp_instruction2], Some(&pubkey0));
        assert_eq!(FeeCalculator::new(1).calculate_fee(&message), 11);
    }

    #[test]
    fn test_fee_rate_governor_derived_default() {
        solana_logger::setup();

        let f0 = FeeRateGovernor::default();
        assert_eq!(
            f0.target_signatures_per_slot,
            DEFAULT_TARGET_SIGNATURES_PER_SLOT
        );
        assert_eq!(
            f0.target_lamports_per_signature,
            DEFAULT_TARGET_LAMPORTS_PER_SIGNATURE
        );
        assert_eq!(f0.lamports_per_signature, 0);

        let f1 = FeeRateGovernor::new_derived(&f0, DEFAULT_TARGET_SIGNATURES_PER_SLOT);
        assert_eq!(
            f1.target_signatures_per_slot,
            DEFAULT_TARGET_SIGNATURES_PER_SLOT
        );
        assert_eq!(
            f1.target_lamports_per_signature,
            DEFAULT_TARGET_LAMPORTS_PER_SIGNATURE
        );
        assert_eq!(
            f1.lamports_per_signature,
            DEFAULT_TARGET_LAMPORTS_PER_SIGNATURE / 2
        ); // min
    }

    #[test]
    fn test_fee_rate_governor_derived_adjust() {
        solana_logger::setup();

        let mut f = FeeRateGovernor {
            target_lamports_per_signature: 100,
            target_signatures_per_slot: 100,
            ..FeeRateGovernor::default()
        };
        f = FeeRateGovernor::new_derived(&f, 0);

        // Ramp fees up
        let mut count = 0;
        loop {
            let last_lamports_per_signature = f.lamports_per_signature;

            f = FeeRateGovernor::new_derived(&f, std::u64::MAX);
            info!("[up] f.lamports_per_signature={}", f.lamports_per_signature);

            // some maximum target reached
            if f.lamports_per_signature == last_lamports_per_signature {
                break;
            }
            // shouldn't take more than 1000 steps to get to minimum
            assert!(count < 1000);
            count += 1;
        }

        // Ramp fees down
        let mut count = 0;
        loop {
            let last_lamports_per_signature = f.lamports_per_signature;
            f = FeeRateGovernor::new_derived(&f, 0);

            info!(
                "[down] f.lamports_per_signature={}",
                f.lamports_per_signature
            );

            // some minimum target reached
            if f.lamports_per_signature == last_lamports_per_signature {
                break;
            }

            // shouldn't take more than 1000 steps to get to minimum
            assert!(count < 1000);
            count += 1;
        }

        // Arrive at target rate
        let mut count = 0;
        while f.lamports_per_signature != f.target_lamports_per_signature {
            f = FeeRateGovernor::new_derived(&f, f.target_signatures_per_slot);
            info!(
                "[target] f.lamports_per_signature={}",
                f.lamports_per_signature
            );
            // shouldn't take more than 100 steps to get to target
            assert!(count < 100);
            count += 1;
        }
    }
}
