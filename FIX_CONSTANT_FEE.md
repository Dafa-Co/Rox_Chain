# Fix for Constant Fee Issue

## Problem
Even after building with the constant fee code, transactions are still charging more than 0.00001 ROX because:
1. The `run.sh` script doesn't set fee parameters when building genesis
2. Prioritization fees from compute budget instructions are still being added

## Solution

### 1. Update `run.sh` - Add Fee Parameters to Genesis

In your `run.sh` script, find the section where `solana-genesis` is called (around line 120-140). Add these three lines to the `GEN_ARGS` array:

```bash
  # Constant fee configuration
  # To change the fee, update CONSTANT_TRANSACTION_FEE_LAMPORTS in:
  # sdk/program/src/fee_calculator.rs
  # Current: 0.00001 ROX = 10,000 lamports
  --target-lamports-per-signature 10000
  --target-signatures-per-slot 0
  --fee-burn-percentage 0
```

The `GEN_ARGS` section should look like this:

```bash
GEN_ARGS=(
  --cluster-type development
  --hashes-per-tick auto
  --bootstrap-validator "$($SOLANA_BIN/solana-keygen pubkey "$IDENTITY")" \
                        "$($SOLANA_BIN/solana-keygen pubkey "$VOTE")" \
                        "$($SOLANA_BIN/solana-keygen pubkey "$STAKE")"
  --bootstrap-validator-lamports "$BOOTSTRAP_LAMPORTS"
  --bootstrap-validator-stake-lamports "$BOOTSTRAP_STAKE_LAMPORTS"
  --faucet-pubkey "$($SOLANA_BIN/solana-keygen pubkey "$FAUCET")"
  --faucet-lamports "$FAUCET_LAMPORTS"
  --ledger "$LEDGER"

  # Constant fee configuration
  --target-lamports-per-signature 10000
  --target-signatures-per-slot 0
  --fee-burn-percentage 0

  # === [ADDED] programs at genesis ===
  --bpf-program "$SPL_TOKEN_PID" "$BPF_LOADER2" "$SPL_TOKEN_SO"
  --bpf-program "$SPL_ATA_PID"   "$BPF_LOADER2" "$SPL_ATA_SO"
  --upgradeable-program "$MPL_METADATA_PID" "$BPF_UPGRADEABLE_LOADER" "$MPL_METADATA_SO" "$UPGRADE_AUTHORITY"
)
```

### 2. Rebuild After Code Changes

The code has been updated to force prioritization fees to 0. You need to:

1. **Rebuild the code:**
   ```bash
   ./cargo build --release
   ```

2. **Rebuild genesis with WIPE_LEDGER=1:**
   ```bash
   WIPE_LEDGER=1 ./run.sh
   ```

   This is critical! The old genesis block has the old fee settings. You MUST wipe the ledger and rebuild genesis with the new fee parameters.

### 3. Verify the Fix

After rebuilding and restarting, check the fee rate governor:

```bash
curl -s http://127.0.0.1:8899 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getFeeRateGovernor"}' | \
  grep -o '"targetLamportsPerSignature":[0-9]*'
```

Should show: `"targetLamportsPerSignature":10000`

## Summary of Code Changes Made

1. **`sdk/src/fee.rs`**: Modified `calculate_fee_details()` to always return `CONSTANT_TRANSACTION_FEE_LAMPORTS` (10,000 lamports)

2. **`sdk/program/src/fee_calculator.rs`**: Added global constant `CONSTANT_TRANSACTION_FEE_LAMPORTS` and updated `FeeRateGovernor` to always use it

3. **`program-runtime/src/compute_budget_processor.rs`**: Modified `From<ComputeBudgetLimits> for FeeBudgetLimits` to always return `prioritization_fee: 0`

## Important Notes

- **You MUST rebuild genesis** with `WIPE_LEDGER=1` after updating the code. The old genesis block has the old fee settings baked in.
- All transactions (including mint, burn, transfers, etc.) will now pay exactly 0.00001 ROX (10,000 lamports)
- Prioritization fees are completely disabled
- To change the fee amount, edit `CONSTANT_TRANSACTION_FEE_LAMPORTS` in `sdk/program/src/fee_calculator.rs`
