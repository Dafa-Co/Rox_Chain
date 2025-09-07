#!/usr/bin/env bash
# run-localhost.sh
set -euo pipefail

# ------------------------------ Paths ---------------------------------
LEDGER="./rox-ledger"
SECRETS="./secrets"
IDENTITY="$SECRETS/validator-identity.json"
VOTE="$SECRETS/validator-vote-account.json"
STAKE="$SECRETS/validator-stake-account.json"
FAUCET="$SECRETS/faucet.json"
PRIMORDIAL="$SECRETS/accounts.yaml"        # optional

PROGRAMS_DIR="./programs"
SPL_TOKEN_SO="$PROGRAMS_DIR/spl_token.so"
SPL_ATA_SO="$PROGRAMS_DIR/spl_ata.so"
MPL_METADATA_SO="$PROGRAMS_DIR/mpl_token_metadata.so"

# Upgrade authority for Metaplex (create once with: ./bin/solana-keygen new -o ./secrets/upgrade-authority.json -f --no-bip39-passphrase)
UPGRADE_AUTHORITY="$SECRETS/upgrade-authority.json"

# Use your patched ROX/Solana binaries (not system ones)
SOLANA_BIN="$(pwd)/bin"

# ------------------------------ IDs -----------------------------------
# Canonical program IDs (match wallet/SDK defaults)
SPL_TOKEN_PID="TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
SPL_ATA_PID="ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
MPL_METADATA_PID="metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"

# Loaders (owners)
BPF_LOADER2="BPFLoader2111111111111111111111111111111111"
BPF_UPGRADEABLE_LOADER="BPFLoaderUpgradeab1e11111111111111111111111"

# ----------------------------- Network --------------------------------
RPC_HOST="127.0.0.1"
RPC_PORT="8899"
GOSSIP_PORT="8001"
RPC_URL="http://${RPC_HOST}:${RPC_PORT}"

# Faucet defaults to 9900. We won't pass --faucet-port since that fixed airdrop for you.
FAUCET_ADDR="${RPC_HOST}:9900"

# ----------------------- Bootstrap balances ---------------------------
LAMPORTS_PER_SOL=1000000000
BOOTSTRAP_LAMPORTS=$((5000 * LAMPORTS_PER_SOL))        # 5,000 SOL
BOOTSTRAP_STAKE_LAMPORTS=$((2000 * LAMPORTS_PER_SOL))  # 2,000 SOL
FAUCET_LAMPORTS=$((10000 * LAMPORTS_PER_SOL))          # 10,000 SOL

# --------------------------- Sanity checks ----------------------------
for b in solana solana-genesis solana-validator solana-faucet solana-keygen; do
  [[ -x "$SOLANA_BIN/$b" ]] || { echo "Missing $SOLANA_BIN/$b"; exit 1; }
done

for f in "$IDENTITY" "$VOTE" "$STAKE" "$FAUCET"; do
  [[ -f "$f" ]] || { echo "Missing keypair: $f"; exit 1; }
done

[[ -f "$SPL_TOKEN_SO" ]]     || { echo "Missing $SPL_TOKEN_SO"; exit 1; }
[[ -f "$SPL_ATA_SO" ]]       || { echo "Missing $SPL_ATA_SO"; exit 1; }
[[ -f "$MPL_METADATA_SO" ]]  || { echo "Missing $MPL_METADATA_SO"; exit 1; }

# Upgrade authority needed for upgradeable Metaplex
if [[ ! -f "$UPGRADE_AUTHORITY" ]]; then
  echo "Upgrade authority not found at $UPGRADE_AUTHORITY"
  echo "Creating one now (no passphrase)..."
  "$SOLANA_BIN/solana-keygen" new -o "$UPGRADE_AUTHORITY" -f --no-bip39-passphrase
fi

# --------------------------- Stop old procs ---------------------------
pkill -f "[s]olana-validator" 2>/dev/null || true
pkill -f "[s]olana-faucet" 2>/dev/null || true
sleep 0.5

# ---------------------------- Fresh ledger ----------------------------
rm -rf "$LEDGER"
mkdir -p "$LEDGER"

# ---------------------------- Build genesis ---------------------------
echo "==> Building genesis..."
GEN_ARGS=(
  --cluster-type development
  --hashes-per-tick auto
  --bootstrap-validator "$("$SOLANA_BIN/solana-keygen" pubkey "$IDENTITY")" \
                        "$("$SOLANA_BIN/solana-keygen" pubkey "$VOTE")" \
                        "$("$SOLANA_BIN/solana-keygen" pubkey "$STAKE")"
  --bootstrap-validator-lamports "$BOOTSTRAP_LAMPORTS"
  --bootstrap-validator-stake-lamports "$BOOTSTRAP_STAKE_LAMPORTS"
  --faucet-pubkey "$("$SOLANA_BIN/solana-keygen" pubkey "$FAUCET")"
  --faucet-lamports "$FAUCET_LAMPORTS"
  --ledger "$LEDGER"

  # ---- Programs at genesis ----
  # Immutable programs via BPF Loader 2:
  --bpf-program "$SPL_TOKEN_PID" "$BPF_LOADER2" "$SPL_TOKEN_SO"
  --bpf-program "$SPL_ATA_PID"   "$BPF_LOADER2" "$SPL_ATA_SO"

  # Upgradeable Metaplex Token Metadata (owner: Upgradeable Loader, authority: $UPGRADE_AUTHORITY)
  --upgradeable-program "$MPL_METADATA_PID" "$BPF_UPGRADEABLE_LOADER" "$MPL_METADATA_SO" "$UPGRADE_AUTHORITY"
)

if [[ -f "$PRIMORDIAL" ]]; then
  echo "   including primordial accounts: $PRIMORDIAL"
  GEN_ARGS+=( --primordial-accounts-file "$PRIMORDIAL" )
fi

"$SOLANA_BIN/solana-genesis" "${GEN_ARGS[@]}"

# ----------------------------- Start faucet ---------------------------
echo "==> Starting faucet..."
nohup "$SOLANA_BIN/solana-faucet" \
  --keypair "$FAUCET" \
  > faucet.log 2>&1 &

# --------------------------- Start validator --------------------------
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

# --------------------------- Wait for health --------------------------
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

# --------------------------- Set CLI RPC URL --------------------------
"$SOLANA_BIN/solana" config set --url "$RPC_URL" >/dev/null

# -------------------------- Program sanity ---------------------------
echo "==> Program sanity:"
"$SOLANA_BIN/solana" program show "$SPL_TOKEN_PID" || true
"$SOLANA_BIN/solana" program show "$SPL_ATA_PID"   || true
"$SOLANA_BIN/solana" program show "$MPL_METADATA_PID" || true

# ------------------------------ Usage --------------------------------
cat <<'USAGE'

✅ Localnet is up.

Quick helpers:
  # airdrop <AMOUNT_SOL> <PUBKEY>
  airdrop() { ./bin/solana airdrop "$1" "$2" --url http://127.0.0.1:8899; }

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

Notes:
  - Programs baked into genesis:
      SPL Token           => Tokenkeg... (owner: BPF Loader 2)
      ATA                 => ATokenG...  (owner: BPF Loader 2)
      Metaplex Metadata   => metaqbxx... (owner: Upgradeable Loader; upgrade authority: ./secrets/upgrade-authority.json)
  - If you change program binaries or authorities, re-run this script (it wipes the ledger).

USAGE
