//! Definitions for the native ROX token and its fractional lamports.

#![allow(clippy::arithmetic_side_effects)]

/// There are 10^9 lamports in one ROX
pub const LAMPORTS_PER_ROX: u64 = 1_000_000_000;

/// Approximately convert fractional native tokens (lamports) into native tokens (ROX)
pub fn lamports_to_rox(lamports: u64) -> f64 {
    lamports as f64 / LAMPORTS_PER_ROX as f64
}

/// Approximately convert native tokens (ROX) into fractional native tokens (lamports)
pub fn rox_to_lamports(rox: f64) -> u64 {
    (rox * LAMPORTS_PER_ROX as f64) as u64
}

use std::fmt::{Debug, Display, Formatter, Result};
pub struct Rox(pub u64);

impl Rox {
    fn write_in_rox(&self, f: &mut Formatter) -> Result {
        write!(
            f,
            "◎{}.{:09}",
            self.0 / LAMPORTS_PER_ROX,
            self.0 % LAMPORTS_PER_ROX
        )
    }
}

impl Display for Rox {
    fn fmt(&self, f: &mut Formatter) -> Result {
        self.write_in_rox(f)
    }
}

impl Debug for Rox {
    fn fmt(&self, f: &mut Formatter) -> Result {
        self.write_in_rox(f)
    }
}
