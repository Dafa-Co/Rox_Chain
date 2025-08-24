#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Paths (edit if your files live elsewhere)
# -------------------------------------------------------------------
LEDGER="./rox-ledger"
SECRETS="./secrets"
IDENTITY="$SECRETS/validator-identity.json"
VOTE="$SECRETS/validator-vote-account.json"
STAKE="$SECRETS/validator-stake-account.json"
FAUCET="$SECRETS/faucet.json"
PRIMORDIAL="$SECRETS/accounts.yaml"     # optional

# Use our patched ROX binaries, not /usr/local/bin ones
SOLANA_BIN="$(pwd)/bin"

# sanity check
for b in solana solana-genesis solana-validator solana-faucet solana-keygen; do
  [[ -x "$SOLANA_BIN/$b" ]] || { echo "Missing $SOLANA_BIN/$b"; exit 1; }
done

# -------------------------------------------------------------------
# Network (Phantom expects localhost:8899)
# -------------------------------------------------------------------
RPC_HOST="127.0.0.1"
RPC_PORT="8899"
FAUCET_PORT="9900"
GOSSIP_PORT="8001"
RPC_URL="http://${RPC_HOST}:${RPC_PORT}"
FAUCET_ADDR="${RPC_HOST}:${FAUCET_PORT}"

# -------------------------------------------------------------------
# Bootstrap balances
# -------------------------------------------------------------------
LAMPORTS_PER_SOL=1000000000

BOOTSTRAP_LAMPORTS=$((5000 * LAMPORTS_PER_SOL))        # 5,000 SOL
BOOTSTRAP_STAKE_LAMPORTS=$((2000 * LAMPORTS_PER_SOL))  # 2,000 SOL
FAUCET_LAMPORTS=$((10000 * LAMPORTS_PER_SOL))          # 10,000 SOL

# -------------------------------------------------------------------
# Stop any previous runs
# -------------------------------------------------------------------
pkill -f solana-validator 2>/dev/null || true
pkill -f solana-faucet 2>/dev/null || true
sleep 0.5

# -------------------------------------------------------------------
# Fresh ledger
# -------------------------------------------------------------------
rm -rf "$LEDGER"
mkdir -p "$LEDGER"

# Sanity: keys exist
for k in "$IDENTITY" "$VOTE" "$STAKE" "$FAUCET"; do
  [[ -f "$k" ]] || { echo "Missing keypair: $k"; exit 1; }
done

# -------------------------------------------------------------------
# Build genesis
# -------------------------------------------------------------------
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
)

if [[ -f "$PRIMORDIAL" ]]; then
  echo "   including primordial accounts: $PRIMORDIAL"
  GEN_ARGS+=( --primordial-accounts-file "$PRIMORDIAL" )
fi

"$SOLANA_BIN/solana-genesis" "${GEN_ARGS[@]}"

# -------------------------------------------------------------------
# Start faucet
# -------------------------------------------------------------------
echo "==> Starting faucet..."
nohup "$SOLANA_BIN/solana-faucet" \
  --keypair "$FAUCET" \
  > faucet.log 2>&1 &

# -------------------------------------------------------------------
# Start validator
# -------------------------------------------------------------------
echo "==> Starting validator..."
nohup "$SOLANA_BIN/solana-validator" \
  --identity "$IDENTITY" \
  --vote-account "$VOTE" \
  --ledger "$LEDGER" \
  --rpc-bind-address "$RPC_HOST" \
  --rpc-port "$RPC_PORT" \
  --gossip-port "$GOSSIP_PORT" \
  --full-rpc-api \
  --enable-rpc-transaction-history \
  --rpc-faucet-address "$FAUCET_ADDR" \
  --no-wait-for-vote-to-start-leader \
  > validator.log 2>&1 &

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

# -------------------------------------------------------------------
# Usage message
# -------------------------------------------------------------------
cat <<'USAGE'

✅ Localnet is up.

Useful commands:
  # airdrop <AMOUNT_SOL> <PUBKEY>
  airdrop() { ./bin/solana airdrop "$1" "$2" --url http://127.0.0.1:8899; }

  # example (Phantom address):
  # airdrop 100 B4YxRJKiVFhD9LTZzq8nqiXFZg1D2X2MsLX92nANA6qR

  # follow logs
  tail -f validator.log
  tail -f faucet.log

  # quick status checks
  curl -s http://127.0.0.1:8899 -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}'
  ./bin/solana cluster-version
  ./bin/solana leader-schedule | head

  # stop everything
  pkill -f solana-validator; pkill -f solana-faucet

Phantom setup:
  - Settings → Developer Settings → enable “Testnet Mode”
  - Test Networks → select “Solana Localnet”
  - That view hardcodes http://localhost:8899 — which we’re using here.
  - If balance doesn’t refresh: toggle networks or restart the extension.

USAGE
