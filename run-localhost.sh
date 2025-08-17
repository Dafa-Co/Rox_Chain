#!/usr/bin/env bash
set -euo pipefail

# --- paths (edit if your files live elsewhere) ---
LEDGER="./rox-ledger"
SECRETS="./secrets"
IDENTITY="$SECRETS/validator-identity.json"
VOTE="$SECRETS/validator-vote-account.json"
STAKE="$SECRETS/validator-stake-account.json"
FAUCET="$SECRETS/faucet.json"
PRIMORDIAL="$SECRETS/accounts.yaml"     # optional

# --- network (Phantom expects localhost:8899) ---
RPC_HOST="127.0.0.1"
RPC_PORT="8899"
FAUCET_PORT="9900"
GOSSIP_PORT="8001"
RPC_URL="http://${RPC_HOST}:${RPC_PORT}"
FAUCET_ADDR="${RPC_HOST}:${FAUCET_PORT}"

# 1 SOL = 1_000_000_000 lamports
LAMPORTS_PER_SOL=1000000000

BOOTSTRAP_LAMPORTS=$((5000 * LAMPORTS_PER_SOL))        # 5,000 SOL
BOOTSTRAP_STAKE_LAMPORTS=$((2000 * LAMPORTS_PER_SOL))  # 2,000 SOL
FAUCET_LAMPORTS=$((10000 * LAMPORTS_PER_SOL))          # 10,000 SOL

# --- helpers ---------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

need_bins=(solana-genesis solana-validator solana-faucet solana-keygen solana)
for b in "${need_bins[@]}"; do have "$b" || die "missing $b in PATH"; done

# stop any previous runs
pkill -f solana-validator 2>/dev/null || true
pkill -f solana-faucet 2>/dev/null || true
sleep 0.5

# fresh ledger
rm -rf "$LEDGER"
mkdir -p "$LEDGER"

# sanity: keys exist
for k in "$IDENTITY" "$VOTE" "$STAKE" "$FAUCET"; do
  [[ -f "$k" ]] || die "missing keypair: $k"
done

echo "==> Building genesis..."
GEN_ARGS=(
  --cluster-type development
  --hashes-per-tick auto
  --bootstrap-validator "$(solana-keygen pubkey "$IDENTITY")" \
                        "$(solana-keygen pubkey "$VOTE")" \
                        "$(solana-keygen pubkey "$STAKE")"
  --bootstrap-validator-lamports "$BOOTSTRAP_LAMPORTS"
  --bootstrap-validator-stake-lamports "$BOOTSTRAP_STAKE_LAMPORTS"
  --faucet-pubkey "$(solana-keygen pubkey "$FAUCET")"
  --faucet-lamports "$FAUCET_LAMPORTS"
  --ledger "$LEDGER"
)

if [[ -f "$PRIMORDIAL" ]]; then
  echo "   including primordial accounts: $PRIMORDIAL"
  GEN_ARGS+=( --primordial-accounts-file "$PRIMORDIAL" )
fi

solana-genesis "${GEN_ARGS[@]}"

# start faucet (bound to localhost; matches validator’s RPC)
echo "==> Starting faucet..."
nohup solana-faucet \
  --keypair "$FAUCET" \
  --bind-address "$FAUCET_ADDR" \
  --rpc-port "$RPC_PORT" \
  > faucet.log 2>&1 &

# start validator
echo "==> Starting validator..."
nohup solana-validator \
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

# wait for health
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

# set CLI default URL to localnet (nice QOL)
solana config set --url "$RPC_URL" >/dev/null

cat <<'USAGE'

✅ Localnet is up.

Useful commands:
  # airdrop <AMOUNT_SOL> <PUBKEY>
  airdrop() { solana airdrop "$1" "$2" --url http://127.0.0.1:8899; }

  # example (Phantom address):
  # airdrop 100 B4YxRJKiVFhD9LTZzq8nqiXFZg1D2X2MsLX92nANA6qR

  # follow logs
  tail -f validator.log
  tail -f faucet.log

  # quick status checks
  curl -s http://127.0.0.1:8899 -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}'
  solana cluster-version
  solana leader-schedule | head

  # stop everything
  pkill -f solana-validator; pkill -f solana-faucet

Phantom setup:
  - Settings → Developer Settings → enable “Testnet Mode”
  - Test Networks → select “Solana Localnet”
  - That view hardcodes http://localhost:8899 — which we’re using here.
  - If balance doesn’t refresh: toggle networks or restart the extension.

USAGE
