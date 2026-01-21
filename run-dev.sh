#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Paths
# -------------------------------------------------------------------
LEDGER="./rox-ledger"
SECRETS="./secrets"
IDENTITY="$SECRETS/validator-identity.json"
VOTE="$SECRETS/validator-vote.json"
STAKE="$SECRETS/validator-stake.json"
FAUCET="$SECRETS/faucet.json"
PRIMORDIAL="$SECRETS/accounts.yaml"     # optional

# === [ADDED] program binaries and upgrade authority ===
PROGRAMS_DIR="./programs"
SPL_TOKEN_SO="$PROGRAMS_DIR/spl_token.so"
SPL_ATA_SO="$PROGRAMS_DIR/spl_ata.so"
MPL_METADATA_SO="$PROGRAMS_DIR/mpl_token_metadata.so"
UPGRADE_AUTHORITY="$SECRETS/upgrade-authority.json"   # created if missing

# Binaries
SOLANA_BIN="$(pwd)/bin"
for b in solana solana-genesis solana-validator solana-faucet solana-keygen; do
  [[ -x "$SOLANA_BIN/$b" ]] || { echo "Missing $SOLANA_BIN/$b"; exit 1; }
done

# -------------------------------------------------------------------
# Network
# -------------------------------------------------------------------
PUBLIC_IP="91.99.236.35"
RPC_HOST="0.0.0.0"
RPC_PORT="8899"
FAUCET_HOST="127.0.0.1"
FAUCET_PORT="9900"
GOSSIP_HOST="$PUBLIC_IP"
GOSSIP_PORT="8001"
RPC_URL="http://127.0.0.1:${RPC_PORT}"
FAUCET_ADDR="${FAUCET_HOST}:${FAUCET_PORT}"

# -------------------------------------------------------------------
# Limits & disk guard
# -------------------------------------------------------------------
MIN_FREE_GB=10
LEDGER_SHREDS_LIMIT=5000000
MAX_LOG_MB=200
MAX_LOG_BACKUPS=5

# -------------------------------------------------------------------
# === [ADDED] canonical program IDs + loaders ===
# -------------------------------------------------------------------
SPL_TOKEN_PID="TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
SPL_ATA_PID="ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
MPL_METADATA_PID="metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"

BPF_LOADER2="BPFLoader2111111111111111111111111111111111"
BPF_UPGRADEABLE_LOADER="BPFLoaderUpgradeab1e11111111111111111111111"

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
bytes_to_mb() { awk '{printf "%.0f", $1/1024/1024}'; }
file_mb() { [[ -f "$1" ]] && stat -c%s "$1" | bytes_to_mb || echo 0; }
rotate_log_if_big() {
  local f="$1"; local sz_mb
  sz_mb=$(file_mb "$f")
  if (( sz_mb > MAX_LOG_MB )); then
    local ts; ts=$(date +%F_%H%M%S)
    mv "$f" "${f}.${ts}"
    gzip -9 "${f}.${ts}" || true
    ls -1t "${f}."* 2>/dev/null | tail -n +"$((MAX_LOG_BACKUPS+1))" | xargs -r rm -f
  fi
}
free_gb() { df --output=avail -BG / | tail -1 | tr -dc '0-9'; }
ensure_space_or_cleanup() {
  local free=$(free_gb)
  if (( free < MIN_FREE_GB )); then
    echo "Low disk: ${free}GB free < ${MIN_FREE_GB}GB."
    if [[ "${ALLOW_LEDGER_PURGE:-0}" == "1" ]]; then
      echo "ALLOW_LEDGER_PURGE=1 → purging ledger to reclaim space..."
      rm -rf "$LEDGER" || true
      mkdir -p "$LEDGER"
    else
      echo "Refusing to purge ledger automatically. Free up space or rerun with ALLOW_LEDGER_PURGE=1."
      exit 1
    fi
  fi
}

# -------------------------------------------------------------------
# Stop previous runs
# -------------------------------------------------------------------
pkill -f solana-validator 2>/dev/null || true
pkill -f solana-faucet 2>/dev/null || true
sleep 0.5

# -------------------------------------------------------------------
# Disk-space guard
# -------------------------------------------------------------------
ensure_space_or_cleanup

# -------------------------------------------------------------------
# Fresh ledger (optional wipe)
# -------------------------------------------------------------------
mkdir -p "$LEDGER"
echo "WIPE_LEDGER=${WIPE_LEDGER:-0}"
if [[ "${WIPE_LEDGER:-0}" == "1" ]]; then
  echo "WIPE_LEDGER=1 → wiping $LEDGER"
  rm -rf "$LEDGER"
  mkdir -p "$LEDGER"
else
  echo "Keeping existing ledger (no wipe)"
fi

# -------------------------------------------------------------------
# Bootstrap balances
# -------------------------------------------------------------------
LAMPORTS_PER_SOL=1000000000
BOOTSTRAP_LAMPORTS=$((5000 * LAMPORTS_PER_SOL))
BOOTSTRAP_STAKE_LAMPORTS=$((2000 * LAMPORTS_PER_SOL))
FAUCET_LAMPORTS=$((10000 * LAMPORTS_PER_SOL))

# Sanity: keys exist
for k in "$IDENTITY" "$VOTE" "$STAKE" "$FAUCET"; do
  [[ -f "$k" ]] || { echo "Missing keypair: $k"; exit 1; }
done

# === [ADDED] ensure program .so exist & have an upgrade authority ===
[[ -f "$SPL_TOKEN_SO" ]]    || { echo "Missing $SPL_TOKEN_SO"; exit 1; }
[[ -f "$SPL_ATA_SO" ]]      || { echo "Missing $SPL_ATA_SO"; exit 1; }
[[ -f "$MPL_METADATA_SO" ]] || { echo "Missing $MPL_METADATA_SO"; exit 1; }
if [[ ! -f "$UPGRADE_AUTHORITY" ]]; then
  echo "Upgrade authority not found at $UPGRADE_AUTHORITY; creating one..."
  "$SOLANA_BIN/solana-keygen" new -o "$UPGRADE_AUTHORITY" -f --no-bip39-passphrase
fi

# -------------------------------------------------------------------
# Build genesis only if needed
# -------------------------------------------------------------------
if [[ ! -f "$LEDGER/genesis.bin" ]]; then
  echo "==> Building genesis..."
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

    # ===================================================================
    # CONSTANT FEE CONFIGURATION
    # ===================================================================
    # All transactions pay exactly 0.00001 ROX (10,000 lamports)
    # regardless of:
    #   - Number of signatures
    #   - Number of write locks
    #   - Compute units consumed
    #   - Network traffic/load
    #   - Prioritization fees (disabled)
    #
    # To change the fee amount, update CONSTANT_TRANSACTION_FEE_LAMPORTS in:
    #   sdk/program/src/fee_calculator.rs
    # ===================================================================
    --target-lamports-per-signature 10000
    --target-signatures-per-slot 0
    --fee-burn-percentage 0

    # === [ADDED] programs at genesis ===
    # Immutable via BPF Loader 2:
    --bpf-program "$SPL_TOKEN_PID" "$BPF_LOADER2" "$SPL_TOKEN_SO"
    --bpf-program "$SPL_ATA_PID"   "$BPF_LOADER2" "$SPL_ATA_SO"

    # Upgradeable Metaplex Token Metadata:
    --upgradeable-program "$MPL_METADATA_PID" "$BPF_UPGRADEABLE_LOADER" "$MPL_METADATA_SO" "$UPGRADE_AUTHORITY"
  )
  if [[ -f "$PRIMORDIAL" ]]; then
    echo "   including primordial accounts: $PRIMORDIAL"
    GEN_ARGS+=( --primordial-accounts-file "$PRIMORDIAL" )
  fi
  "$SOLANA_BIN/solana-genesis" "${GEN_ARGS[@]}"
else
  echo "==> Reusing existing genesis at $LEDGER/genesis.bin"
  echo "NOTE: If you previously built genesis without programs or with different fee settings,"
  echo "      set WIPE_LEDGER=1 to rebuild with them."
fi

# -------------------------------------------------------------------
# Start faucet
# -------------------------------------------------------------------
echo "==> Starting faucet..."
rotate_log_if_big faucet.log || true
nohup "$SOLANA_BIN/solana-faucet" \
  --keypair "$FAUCET" \
  --host "$FAUCET_HOST" \
  --port "$FAUCET_PORT" \
  --url "$RPC_URL" \
  > faucet.log 2>&1 &

rm -f ./solana-validator-*.log

# -------------------------------------------------------------------
# Start validator
# -------------------------------------------------------------------
echo "==> Starting validator..."
rotate_log_if_big validator.log || true
RUST_LOG=warn nohup "$SOLANA_BIN/solana-validator" \
  --identity "$IDENTITY" \
  --vote-account "$VOTE" \
  --ledger "$LEDGER" \
  --gossip-host "$GOSSIP_HOST" \
  --gossip-port "$GOSSIP_PORT" \
  --rpc-bind-address "$RPC_HOST" \
  --rpc-port "$RPC_PORT" \
  --public-rpc-address "$PUBLIC_IP:$RPC_PORT" \
  --full-rpc-api \
  --enable-rpc-transaction-history \
  --rpc-faucet-address "$FAUCET_ADDR" \
  --no-wait-for-vote-to-start-leader \
  --limit-ledger-size "$LEDGER_SHREDS_LIMIT" \
  --full-snapshot-interval-slots 2000 \
  --incremental-snapshot-interval-slots 1000 \
  --log validator.log &

# -------------------------------------------------------------------
# Wait for health
# -------------------------------------------------------------------
echo -n "==> Waiting for RPC health "
for i in {1..120}; do
  if curl -s "${RPC_URL}" -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
      | grep -q '"ok"'; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 0.5
  if [[ $i -eq 120 ]]; then
    echo
    echo "Validator failed to become healthy. See validator.log"
    exit 1
  fi
done

# -------------------------------------------------------------------
# Set CLI default URL
# -------------------------------------------------------------------
"$SOLANA_BIN/solana" config set --url "$RPC_URL" >/dev/null
GENESIS=$("$SOLANA_BIN/solana" genesis-hash)
echo "Genesis Hash: $GENESIS"

# === [ADDED] quick program sanity ===
echo "==> Program sanity:"
"$SOLANA_BIN/solana" program show "$SPL_TOKEN_PID"   || true
"$SOLANA_BIN/solana" program show "$SPL_ATA_PID"     || true
"$SOLANA_BIN/solana" program show "$MPL_METADATA_PID"|| true

# -------------------------------------------------------------------
# Usage message
# -------------------------------------------------------------------
cat <<'USAGE'
✅ Validator1 (bootstrap) is up.
Quick commands:
  airdrop() { ./bin/solana airdrop "$1" "$2" --url http://127.0.0.1:8899; }
  tail -f validator.log
  tail -f faucet.log
  curl -s http://127.0.0.1:8899 -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}'
  ./bin/solana cluster-version
  ./bin/solana leader-schedule | head
  # stop
  pkill -f solana-validator; pkill -f solana-faucet

Notes:
  - Programs baked into genesis:
      SPL Token         => Tokenkeg... (owner: BPF Loader 2)
      ATA               => ATokenG...  (owner: BPF Loader 2)
      Metaplex Metadata => metaqbxx... (owner: Upgradeable Loader; authority: ./secrets/upgrade-authority.json)
  - If you change any .so or want to add/remove programs, re-run with WIPE_LEDGER=1 (this rebuilds genesis).
  - Constant transaction fee: 0.00001 ROX (10,000 lamports) for ALL transactions
  - To change the fee, edit CONSTANT_TRANSACTION_FEE_LAMPORTS in sdk/program/src/fee_calculator.rs
USAGE
