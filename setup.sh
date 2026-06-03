#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  setup.sh — Mostro Regtest
#
#  Spins up a bitcoind regtest node + 3 LND nodes using Docker (host
#  networking), creates wallets, funds them, opens channels (triangle
#  topology), launches RTL (Ride The Lightning) to manage all nodes,
#  starts Mostro (P2P Lightning exchange over Nostr) connected to lnd1,
#  and builds MostriX (TUI client for Mostro).
#
#  Zero local dependencies beyond Docker and Rust (for MostriX).
#  Optional: copy .env.example to .env to override defaults.
#  Run ./setup.sh --help for usage information.
###############################################################################

# ── Usage ─────────────────────────────────────────────────────────────────────

show_usage() {
  cat <<'USAGE'
Usage: ./setup.sh [--help] [--from <step>]

Mostro Regtest — sets up 3 LND regtest nodes + RTL + Mostro + MostriX with Docker.

Steps:
  1. Verifies prerequisites (docker)
  2. Installs dependencies (jq, curl)
  3. Cleans previous environment
  4. Prompts for a wallet password
  5. Builds + starts bitcoind Docker container, writes LND/RTL configs, starts LND
  6. Creates wallets, enables auto-unlock, starts RTL
  7. Loads/prompts/generates Nostr key, configures Mostro on lnd1, builds MostriX TUI
  8. Funds wallets and opens a balanced channel
  9. Domains + HTTPS via nginx (only if RTL_DOMAIN or LNURL_DOMAIN is set)

Configuration:
  All settings have sensible defaults — no .env required for basic usage.
  Copy .env.example to .env to override defaults. See .env.example for options.

Options:
  --help, -h        Show this help message
  --from <step>     Start from a specific step (1-9), skipping earlier ones
                    Example: ./setup.sh --from 7
USAGE
}

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/setup-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Handle flags before loading config
START_FROM=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_usage; exit 0 ;;
    --from)
      if [[ -z "${2:-}" || ! "$2" =~ ^[1-9]$ ]]; then
        echo "Error: --from requires a step number (1-9)" >&2; exit 1
      fi
      START_FROM="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; show_usage; exit 1 ;;
  esac
done

# ── Config ────────────────────────────────────────────────────────────────────
# Load user settings from .env and apply defaults for anything unset.
# Only BITCOIND_RPC_USER and BITCOIND_RPC_PASS are required — everything else
# has sensible defaults so the script works out of the box.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}"

# Load optional .env overrides (no error if missing — all values have defaults)
if [[ -f "${BASE_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${BASE_DIR}/.env"
fi

BITCOIND_HOST="${BITCOIND_HOST:-127.0.0.1}"
BITCOIND_RPC_PORT="${BITCOIND_RPC_PORT:-18443}"
BITCOIND_RPC_USER="${BITCOIND_RPC_USER:-regtest}"
BITCOIND_RPC_PASS="${BITCOIND_RPC_PASS:-regtest}"
BITCOIN_VERSION="${BITCOIN_VERSION:-28.0}"
MINER_WALLET="${MINER_WALLET:-miner}"
LND_IMAGE="${LND_IMAGE:-lightninglabs/lnd:v0.20.1-beta}"
FUND_LND1_BTC="${FUND_LND1_BTC:-8}"
FUND_LND2_BTC="${FUND_LND2_BTC:-3}"
FUND_LND3_BTC="${FUND_LND3_BTC:-6}"
CHANNEL_SATS="${CHANNEL_SATS:-500000000}"
REBALANCE_SATS="${REBALANCE_SATS:-250000000}"
LND3_CHANNEL_SATS="${LND3_CHANNEL_SATS:-250000000}"

RTL_IMAGE="${RTL_IMAGE:-shahanafarooqui/rtl:v0.15.8}"
RTL_PORT="${RTL_PORT:-3000}"
RTL_DOMAIN="${RTL_DOMAIN:-}"

MOSTRO_REF="${MOSTRO_REF:-main}"
MOSTRO_RELAYS="${MOSTRO_RELAYS:-wss://nos.lol,wss://relay.mostro.network}"

MOSTRIX_REF="${MOSTRIX_REF:-main}"

ZMQ_BLOCK="tcp://${BITCOIND_HOST}:28332"
ZMQ_TX="tcp://${BITCOIND_HOST}:28333"

NODES=(lnd1 lnd2 lnd3)
declare -A PORTS=(
  [lnd1_listen]=9735  [lnd1_rpc]=10009  [lnd1_rest]=8080
  [lnd2_listen]=9736  [lnd2_rpc]=10010  [lnd2_rest]=8081
  [lnd3_listen]=9737  [lnd3_rpc]=10011  [lnd3_rest]=8082
)
declare -A FUND_BTC=(
  [lnd1]="${FUND_LND1_BTC}"
  [lnd2]="${FUND_LND2_BTC}"
  [lnd3]="${FUND_LND3_BTC}"
)

LNURL_DOMAIN="${LNURL_DOMAIN:-}"
LNURL_USERNAMES="${LNURL_USERNAMES:-admin}"
SATDRESS_PORT="${SATDRESS_PORT:-17422}"

WALLET_PASS="${WALLET_PASS:-}"
MOSTRO_NSEC=""
MOSTRO_NPUB_ENV="${MOSTRO_NPUB:-}"
MOSTRO_NPUB=""
MOSTRO_HEX=""

# ── Helpers ───────────────────────────────────────────────────────────────────
# log/ok/fail — consistent coloured output for step progress.
# lncli/bcli  — wrappers that hide repetitive flags.
# mine_blocks — generates regtest blocks via the miner wallet.
# wait_ready / wait_wallet_unlocker — poll loops for LND startup stages.

log()  { echo -e "\n\033[1;34m[$1]\033[0m $2"; }
ok()   { echo -e "  \033[1;32m✔\033[0m $1"; }
warn() { echo -e "  \033[1;33m⚠\033[0m $1"; }
fail() { echo -e "  \033[1;31m✘\033[0m $1"; exit 1; }

lncli() {
  local node="$1"; shift
  docker exec "$node" lncli --network=regtest \
    --rpcserver="127.0.0.1:${PORTS[${node}_rpc]}" "$@" 2>/dev/null | tr -d '\r'
}

bcli() {
  docker exec bitcoind bitcoin-cli \
    -regtest \
    -rpcport="${BITCOIND_RPC_PORT}" \
    -rpcuser="${BITCOIND_RPC_USER}" \
    -rpcpassword="${BITCOIND_RPC_PASS}" \
    "$@"
}

mine_blocks() {
  local addr
  addr="$(bcli -rpcwallet="${MINER_WALLET}" getnewaddress)"
  bcli -rpcwallet="${MINER_WALLET}" generatetoaddress "$1" "$addr" >/dev/null
}

wait_ready() {
  local node="$1" i=0
  echo "  Waiting for ${node}..."
  while (( i < 120 )); do
    if docker exec "$node" lncli --network=regtest \
         --rpcserver="127.0.0.1:${PORTS[${node}_rpc]}" getinfo >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    (( i++ ))
  done
  return 1
}

wait_wallet_unlocker() {
  local port="$1" i=0
  while (( i < 60 )); do
    local resp
    resp="$(curl -sk "https://127.0.0.1:${port}/v1/genseed" 2>/dev/null)" || true
    if echo "$resp" | jq -e '.cipher_seed_mnemonic' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    (( i++ ))
  done
  return 1
}

# Write bitcoin.conf for the dockerised bitcoind node.
write_bitcoin_conf() {
  mkdir -p "${BASE_DIR}/bitcoind"
  cat > "${BASE_DIR}/bitcoind/bitcoin.conf" <<EOF
regtest=1
server=1
txindex=1

[regtest]
rpcport=${BITCOIND_RPC_PORT}
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcuser=${BITCOIND_RPC_USER}
rpcpassword=${BITCOIND_RPC_PASS}
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
fallbackfee=0.0002
EOF
}

wait_bitcoind() {
  local i=0
  echo "  Waiting for bitcoind RPC..."
  while (( i < 60 )); do
    if bcli getblockchaininfo >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    (( i++ ))
  done
  return 1
}

# Generate lnd.conf for a node. All listeners bind to 127.0.0.1 because we use
# host networking — without this, LND would listen on 0.0.0.0 and be reachable
# from the internet. The optional $extra arg adds wallet-unlock-password-file
# after the first run so LND auto-unlocks on restart.
write_lnd_conf() {
  local node="$1" extra="${2:-}"
  cat > "${BASE_DIR}/${node}/lnd.conf" <<EOF
[Application Options]
alias=${node}
debuglevel=info
listen=127.0.0.1:${PORTS[${node}_listen]}
rpclisten=127.0.0.1:${PORTS[${node}_rpc]}
restlisten=127.0.0.1:${PORTS[${node}_rest]}
${extra}

[Bitcoin]
bitcoin.regtest=1
bitcoin.node=bitcoind

[Bitcoind]
bitcoind.rpchost=${BITCOIND_HOST}:${BITCOIND_RPC_PORT}
bitcoind.rpcuser=${BITCOIND_RPC_USER}
bitcoind.rpcpass=${BITCOIND_RPC_PASS}
bitcoind.zmqpubrawblock=${ZMQ_BLOCK}
bitcoind.zmqpubrawtx=${ZMQ_TX}

[protocol]
protocol.wumbo-channels=1
EOF
}

# Generate RTL-Config.json with both LND nodes. RTL also binds to 127.0.0.1
# for the same host-networking reason. Each node gets its own macaroon path
# so RTL can switch between them via the UI dropdown.
write_rtl_config() {
  local rtl_pass="${RTL_PASSWORD:-${WALLET_PASS}}"
  mkdir -p "${BASE_DIR}/rtl/database"
  cat > "${BASE_DIR}/rtl/RTL-Config.json" <<EOF
{
  "multiPass": "${rtl_pass}",
  "port": "${RTL_PORT}",
  "host": "127.0.0.1",
  "defaultNodeIndex": 1,
  "dbDirectoryPath": "/RTL/database",
  "SSO": {
    "rtlSSO": 0,
    "rtlCookiePath": "",
    "logoutRedirectLink": ""
  },
  "nodes": [
    {
      "index": 1,
      "lnNode": "lnd1",
      "lnImplementation": "LND",
      "authentication": {
        "macaroonPath": "/macaroons/lnd1"
      },
      "settings": {
        "userPersona": "OPERATOR",
        "themeMode": "NIGHT",
        "themeColor": "TEAL",
        "channelBackupPath": "",
        "logLevel": "ERROR",
        "lnServerUrl": "https://127.0.0.1:${PORTS[lnd1_rest]}",
        "fiatConversion": false,
        "unannouncedChannels": false
      }
    },
    {
      "index": 2,
      "lnNode": "lnd2",
      "lnImplementation": "LND",
      "authentication": {
        "macaroonPath": "/macaroons/lnd2"
      },
      "settings": {
        "userPersona": "OPERATOR",
        "themeMode": "NIGHT",
        "themeColor": "PURPLE",
        "channelBackupPath": "",
        "logLevel": "ERROR",
        "lnServerUrl": "https://127.0.0.1:${PORTS[lnd2_rest]}",
        "fiatConversion": false,
        "unannouncedChannels": false
      }
    },
    {
      "index": 3,
      "lnNode": "lnd3",
      "lnImplementation": "LND",
      "authentication": {
        "macaroonPath": "/macaroons/lnd3"
      },
      "settings": {
        "userPersona": "OPERATOR",
        "themeMode": "NIGHT",
        "themeColor": "INDIGO",
        "channelBackupPath": "",
        "logLevel": "ERROR",
        "lnServerUrl": "https://127.0.0.1:${PORTS[lnd3_rest]}",
        "fiatConversion": false,
        "unannouncedChannels": false
      }
    }
  ]
}
EOF
}


# Generate Mostro settings.toml. Points at lnd1's gRPC and external relays.
# TLS cert and admin macaroon are copied from lnd1 in step 7.
write_mostro_config() {
  mkdir -p "${BASE_DIR}/mostro/lnd"

  # Build TOML relays array from MOSTRO_RELAYS
  local relays_toml=""
  if [[ -n "${MOSTRO_RELAYS}" ]]; then
    IFS=',' read -ra relay_list <<< "${MOSTRO_RELAYS}"
    for r in "${relay_list[@]}"; do
      r="$(echo "$r" | xargs)"  # trim whitespace
      [[ -z "$r" ]] && continue
      [[ -n "$relays_toml" ]] && relays_toml+=", "
      relays_toml+="'${r}'"
    done
  fi

  cat > "${BASE_DIR}/mostro/settings.toml" <<EOF
[lightning]
lnd_cert_file = '/config/lnd/tls.cert'
lnd_macaroon_file = '/config/lnd/admin.macaroon'
lnd_grpc_host = 'https://127.0.0.1:${PORTS[lnd1_rpc]}'
invoice_expiration_window = 3600
hold_invoice_cltv_delta = 144
hold_invoice_expiration_window = 300
payment_attempts = 3
payment_retries_interval = 60

[nostr]
nsec_privkey = '${MOSTRO_NSEC}'
relays = [${relays_toml}]

[mostro]
fee = 0
max_routing_fee = 0.001
max_order_amount = 1000000
min_payment_amount = 100
expiration_hours = 24
max_expiration_days = 15
expiration_seconds = 900
user_rates_sent_interval_seconds = 3600
publish_relays_interval = 60
pow = 0
publish_mostro_info_interval = 300
bitcoin_price_api_url = "https://api.yadio.io"
fiat_currencies_accepted = ['USD', 'EUR', 'ARS', 'CUP']
max_orders_per_response = 10
dev_fee_percentage = 0.30

[database]
url = "sqlite:///config/mostro.db"

[expiration]
order_days = 30
dispute_days = 90
fee_audit_days = 365

[rpc]
enabled = false
listen_address = "127.0.0.1"
port = 50051
EOF
}


# Generate satdress .env file. satdress reads its config from environment
# variables. The SECRET is randomly generated for HMAC signing.
write_satdress_env() {
  mkdir -p "${BASE_DIR}/satdress/data"
  local secret
  secret="$(openssl rand -hex 32)"
  cat > "${BASE_DIR}/satdress/.env" <<EOF
PORT=${SATDRESS_PORT}
DOMAIN=${LNURL_DOMAIN}
HOST=127.0.0.1
SECRET=${secret}
SITE_NAME=Mostro Regtest
SITE_OWNER_NAME=${LNURL_USERNAMES%%,*}
SITE_OWNER_URL=https://${LNURL_DOMAIN}
EOF
  chmod 600 "${BASE_DIR}/satdress/.env"
}

generate_nostr_keys() {
  echo "  Building rana (Nostr key generator)... this may take a few minutes on first run"
  local build_dir
  build_dir="$(mktemp -d)"
  cat > "${build_dir}/Dockerfile" <<'DOCKERFILE'
FROM rust:1.84-slim AS builder
RUN apt-get update && apt-get install -y cmake build-essential pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
RUN cargo install rana --locked
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y libssl3 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/cargo/bin/rana /usr/local/bin/rana
ENTRYPOINT ["rana"]
DOCKERFILE

  if ! docker build -t rana -f "${build_dir}/Dockerfile" "${build_dir}" -q >/dev/null; then
    rm -rf "${build_dir}"
    fail "Failed to build rana Docker image — check Docker daemon and internet connectivity"
  fi
  rm -rf "${build_dir}"
  ok "rana image ready"

  echo "  Generating Nostr keypair..."
  docker rm -f rana-gen >/dev/null 2>&1 || true
  docker run -d --name rana-gen rana --difficulty 1 >/dev/null
  sleep 8

  local output
  output="$(docker logs rana-gen 2>&1)"
  docker rm -f rana-gen >/dev/null 2>&1

  MOSTRO_NSEC="$(echo "$output" | grep -oP 'nsec1[a-z0-9]+' | head -1)"
  MOSTRO_NPUB="$(echo "$output" | grep -oP 'npub1[a-z0-9]+' | head -1)"
  MOSTRO_HEX="$(echo "$output" | grep -oP '(?<=Hex public key:\s{3})[0-9a-f]+' | head -1)"

  if [[ -z "$MOSTRO_NSEC" || -z "$MOSTRO_NPUB" ]]; then
    fail "Could not generate Nostr keys — rana output: ${output}"
  fi
}

# Derives npub from an nsec using a throwaway python:3-slim container (zero host deps).
derive_npub() {
  local nsec="$1"
  local script
  script="$(mktemp /tmp/npub.XXXXXX.py)"
  cat > "$script" <<'PYEOF'
import sys

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
P  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

def convertbits(data, frombits, tobits, pad=True):
    acc = 0; bits = 0; ret = []; maxv = (1 << tobits) - 1
    for v in data:
        acc = (acc << frombits) | v; bits += frombits
        while bits >= tobits:
            bits -= tobits; ret.append((acc >> bits) & maxv)
    if pad and bits: ret.append((acc << (tobits - bits)) & maxv)
    return ret

def bech32_polymod(values):
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]; chk = 1
    for v in values:
        b = chk >> 25; chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5): chk ^= GEN[i] if (b >> i) & 1 else 0
    return chk

def bech32_encode(hrp, data):
    d = list(data)
    exp = [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]
    poly = bech32_polymod(exp + d + [0]*6) ^ 1
    cs = [(poly >> 5*(5-i)) & 31 for i in range(6)]
    return hrp + '1' + ''.join(CHARSET[x] for x in d + cs)

def bech32_decode(bech):
    bech = bech.lower(); pos = bech.rfind('1')
    data = [CHARSET.find(x) for x in bech[pos+1:]]
    return bytes(convertbits(data[:-6], 5, 8, False))

def point_add(A, B):
    if A is None: return B
    if B is None: return A
    if A[0] == B[0]:
        if A[1] != B[1]: return None
        m = 3 * A[0]**2 * pow(2 * A[1], P-2, P) % P
    else:
        m = (B[1] - A[1]) * pow(B[0] - A[0], P-2, P) % P
    x = (m*m - A[0] - B[0]) % P
    return (x, (m * (A[0] - x) - A[1]) % P)

def point_mul(k, pt):
    r = None; a = pt
    while k:
        if k & 1: r = point_add(r, a)
        a = point_add(a, a); k >>= 1
    return r

privkey = int.from_bytes(bech32_decode(sys.argv[1]), 'big')
pub = point_mul(privkey, (Gx, Gy))
print(bech32_encode("npub", convertbits(list(pub[0].to_bytes(32, 'big')), 8, 5)))
PYEOF
  MOSTRO_NPUB="$(docker run --rm -v "${script}:/derive.py:ro" python:3-slim python3 /derive.py "$nsec" 2>/dev/null)"
  rm -f "$script"
  if [[ -z "$MOSTRO_NPUB" ]]; then
    fail "Could not derive npub from provided nsec"
  fi
}

create_wallet_rest() {
  local node="$1"
  local rest_port="${PORTS[${node}_rest]}"
  local data_dir="${BASE_DIR}/${node}/data"

  echo "  Waiting for WalletUnlocker on ${node}..."
  wait_wallet_unlocker "$rest_port" || fail "${node} WalletUnlocker not responding"

  local seed_response
  if ! seed_response="$(curl -sk --connect-timeout 10 --max-time 30 "https://127.0.0.1:${rest_port}/v1/genseed")"; then
    fail "${node}: curl failed reaching LND REST API on port ${rest_port} — is lnd running?"
  fi
  local mnemonic
  mnemonic="$(echo "$seed_response" | jq -c '.cipher_seed_mnemonic')"

  if [[ "$mnemonic" == "null" || -z "$mnemonic" ]]; then
    fail "${node}: could not generate seed — ${seed_response}"
  fi

  echo "$seed_response" | jq -r '.cipher_seed_mnemonic[]' > "${data_dir}/seed.txt"
  chmod 600 "${data_dir}/seed.txt"

  local pass_b64
  pass_b64="$(echo -n "$WALLET_PASS" | base64)"

  local init_response
  if ! init_response="$(curl -sk --connect-timeout 10 --max-time 30 -X POST "https://127.0.0.1:${rest_port}/v1/initwallet" \
    -d "{\"wallet_password\":\"${pass_b64}\",\"cipher_seed_mnemonic\":${mnemonic}}")"; then
    fail "${node}: curl failed during wallet init on port ${rest_port}"
  fi

  if echo "$init_response" | jq -e '.admin_macaroon' >/dev/null 2>&1; then
    ok "${node} wallet created — seed at ${node}/data/seed.txt"
  else
    fail "${node}: error creating wallet — ${init_response}"
  fi
}

# Write MostriX settings.toml so it connects to the local Mostro instance.
write_mostrix_settings() {
  local mostrix_dir="${HOME}/.mostrix"
  mkdir -p "${mostrix_dir}"
  cat > "${mostrix_dir}/settings.toml" <<EOF
mostro_pubkey = "${MOSTRO_HEX}"
nsec_privkey = "${MOSTRO_NSEC}"
admin_privkey = "${MOSTRO_NSEC}"
relays = [
$(IFS=',' ; for r in ${MOSTRO_RELAYS}; do echo "  \"${r}\","; done)
]
log_level = "info"
currencies_filter = ["USD"]
user_mode = "admin"
pow = 0
EOF
  chmod 600 "${mostrix_dir}/settings.toml"
}

# ── Steps ─────────────────────────────────────────────────────────────────────

###############################################################################
#  STEP 1 — Preflight checks
#  Fail fast if Docker isn't available. bitcoind runs in Docker — no local
#  Bitcoin Core installation required.
###############################################################################
step_preflight() {
  log "1/9" "Preflight checks"

  if ! command -v docker &>/dev/null; then
    fail "docker is not installed (sudo apt install docker.io)"
  fi
  if ! docker info &>/dev/null; then
    fail "Docker daemon is not running (sudo systemctl start docker)"
  fi
  ok "Docker available"

}

###############################################################################
#  STEP 2 — Dependencies
#  jq is needed to parse LND REST API JSON responses; curl to call them.
#  Both are lightweight and safe to auto-install.
###############################################################################
step_deps() {
  log "2/9" "Checking dependencies (jq, curl)"

  local missing=()
  for cmd in jq curl; do
    if command -v "$cmd" &>/dev/null; then
      ok "${cmd} already installed"
    else
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "  Installing ${missing[*]} (requires sudo to apt-get install)"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${missing[@]}" >/dev/null
    ok "${missing[*]} installed"
  fi
}

###############################################################################
#  STEP 3 — Clean environment
#  Stop and remove all containers (including bitcoind) and wipe generated
#  configs and data dirs so we start completely fresh.
#  LND data dirs may be owned by root (Docker), so we use an alpine container
#  to delete them reliably.
###############################################################################
step_clean() {
  log "3/9" "Cleaning environment"

  docker compose -f "${BASE_DIR}/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
  docker rm -f "${NODES[@]}" rtl mostro satdress bitcoind 2>/dev/null || true

  for node in "${NODES[@]}"; do
    if [[ -d "${BASE_DIR}/${node}" ]]; then
      docker run --rm -v "${BASE_DIR}/${node}:/cleanup" alpine \
        rm -rf /cleanup/data /cleanup/lnd.conf 2>/dev/null || true
      rm -rf "${BASE_DIR:?}/${node}" 2>/dev/null || true
    fi
  done
  rm -rf "${BASE_DIR}/rtl" "${BASE_DIR}/mostro" "${BASE_DIR}/satdress" "${BASE_DIR}/mostro-cli-bin" 2>/dev/null || true
  if [[ -d "${BASE_DIR}/bitcoind" ]]; then
    docker run --rm -v "${BASE_DIR}/bitcoind:/cleanup" alpine rm -rf /cleanup 2>/dev/null || true
    rm -rf "${BASE_DIR}/bitcoind" 2>/dev/null || true
  fi
  rm -rf "${HOME}/.mostrix" 2>/dev/null || true
  rm -f "${BASE_DIR}/docker-compose.yml" 2>/dev/null || true

  for node in "${NODES[@]}"; do
    mkdir -p "${BASE_DIR}/${node}/data"
  done
  ok "Directories clean"
}

###############################################################################
#  STEP 4 — Ask wallet password
#  The same password is used for both LND wallets and (by default) RTL login.
#  If WALLET_PASS is already set in .env, skip the interactive prompt so the
#  script can run unattended.
###############################################################################
step_password() {
  log "4/9" "Wallet password for LND"

  if [[ -n "${WALLET_PASS:-}" ]] && (( ${#WALLET_PASS} >= 8 )); then
    ok "Password loaded from .env"
    return
  fi

  while true; do
    echo
    read -s -p "  Enter password (min 8 chars): " WALLET_PASS
    echo
    read -s -p "  Confirm password: " pass_confirm
    echo

    if (( ${#WALLET_PASS} < 8 )); then
      echo -e "  \033[1;31m✘\033[0m Minimum 8 characters — try again"
      continue
    fi
    if [[ "$WALLET_PASS" != "$pass_confirm" ]]; then
      echo -e "  \033[1;31m✘\033[0m Passwords do not match — try again"
      continue
    fi

    ok "Password accepted"
    break
  done
}

###############################################################################
#  STEP 5 — Build + start bitcoind, write configs, start LND containers
#  Build the bitcoind Docker image from docker/bitcoind/Dockerfile (based on
#  Polar's approach), generate bitcoin.conf, start bitcoind and wait for its
#  RPC to be ready. Then generate LND/RTL configs and docker-compose.yml and
#  start the three LND containers.
#  RTL starts later (step 6) because it needs macaroons created by LND wallets.
###############################################################################
step_configs_and_start() {
  log "5/9" "Building bitcoind image, writing configs, starting containers"

  # ── bitcoind ──
  write_bitcoin_conf
  ok "bitcoin.conf written"

  echo "  Building bitcoind Docker image (Bitcoin Core ${BITCOIN_VERSION})..."
  docker build \
    --build-arg BITCOIN_VERSION="${BITCOIN_VERSION}" \
    -t mostro-bitcoind:local \
    "${BASE_DIR}/docker/bitcoind" -q
  ok "bitcoind image built"

  # ── LND configs ──
  for node in "${NODES[@]}"; do
    write_lnd_conf "$node"
  done
  ok "LND configs written"

  write_rtl_config
  ok "RTL config written"

  # ── docker-compose.yml ──
  cat > "${BASE_DIR}/docker-compose.yml" <<EOF
services:
  bitcoind:
    image: mostro-bitcoind:local
    container_name: bitcoind
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./bitcoind:/home/bitcoin/.bitcoin
    environment:
      USERID: "1000"
      GROUPID: "1000"

  lnd1:
    image: ${LND_IMAGE}
    container_name: lnd1
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./lnd1/data:/root/.lnd
      - ./lnd1/lnd.conf:/root/.lnd/lnd.conf:ro

  lnd2:
    image: ${LND_IMAGE}
    container_name: lnd2
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./lnd2/data:/root/.lnd
      - ./lnd2/lnd.conf:/root/.lnd/lnd.conf:ro

  lnd3:
    image: ${LND_IMAGE}
    container_name: lnd3
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./lnd3/data:/root/.lnd
      - ./lnd3/lnd.conf:/root/.lnd/lnd.conf:ro

  rtl:
    image: ${RTL_IMAGE}
    container_name: rtl
    restart: unless-stopped
    network_mode: host
    environment:
      RTL_CONFIG_PATH: /RTL
    volumes:
      - ./rtl/RTL-Config.json:/RTL/RTL-Config.json
      - ./rtl/database:/RTL/database
      - ./lnd1/data/data/chain/bitcoin/regtest:/macaroons/lnd1:ro
      - ./lnd2/data/data/chain/bitcoin/regtest:/macaroons/lnd2:ro
      - ./lnd3/data/data/chain/bitcoin/regtest:/macaroons/lnd3:ro

  mostro:
    image: mostro:local
    container_name: mostro
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./mostro:/config
EOF

  if [[ -n "${LNURL_DOMAIN}" ]]; then
    cat >> "${BASE_DIR}/docker-compose.yml" <<EOF

  satdress:
    image: satdress:local
    container_name: satdress
    restart: unless-stopped
    network_mode: host
    env_file:
      - ./satdress/.env
    volumes:
      - ./satdress/data:/data
EOF
  fi

  ok "docker-compose.yml written"

  # ── Start bitcoind and wait for RPC ──
  docker compose -f "${BASE_DIR}/docker-compose.yml" up -d bitcoind
  wait_bitcoind || fail "bitcoind RPC not responding after 60s — check: docker logs bitcoind"
  ok "bitcoind ready (regtest)"

  # Create miner wallet on first run; on re-runs just load it if needed
  if ! bcli listwallets | jq -e ".[] | select(.==\"${MINER_WALLET}\")" >/dev/null 2>&1; then
    if bcli listwalletdir | jq -e ".wallets[].name | select(.==\"${MINER_WALLET}\")" >/dev/null 2>&1; then
      bcli loadwallet "${MINER_WALLET}" >/dev/null
      ok "Miner wallet loaded"
    else
      bcli createwallet "${MINER_WALLET}" >/dev/null
      # Mine past the initial coinbase maturity threshold so coins are spendable
      mine_blocks 101
      ok "Miner wallet created and 101 blocks mined"
    fi
  else
    ok "Miner wallet already loaded"
  fi

  # ── Start LND containers ──
  docker compose -f "${BASE_DIR}/docker-compose.yml" up -d lnd1 lnd2 lnd3
  sleep 3
  ok "lnd1, lnd2, and lnd3 running"
}

###############################################################################
#  STEP 6 — Create wallets + enable auto-unlock + start RTL & relay
#  Create wallets via REST API, then rewrite lnd.conf with the auto-unlock
#  password file and restart. This two-phase approach is needed because LND
#  only exposes the WalletUnlocker gRPC before a wallet exists. After restart,
#  macaroons are available and RTL + relay can start.
###############################################################################
step_wallets_and_unlock() {
  log "6/9" "Creating wallets, enabling auto-unlock, starting RTL"

  for node in "${NODES[@]}"; do
    create_wallet_rest "$node"
  done

  for node in "${NODES[@]}"; do
    echo -n "${WALLET_PASS}" > "${BASE_DIR}/${node}/data/wallet-password.txt"
    chmod 600 "${BASE_DIR}/${node}/data/wallet-password.txt"
    write_lnd_conf "$node" "wallet-unlock-password-file=/root/.lnd/wallet-password.txt"
  done

  docker compose -f "${BASE_DIR}/docker-compose.yml" restart lnd1 lnd2 lnd3
  sleep 5

  for node in "${NODES[@]}"; do
    wait_ready "$node" || fail "${node} not responding after restart"
  done
  ok "All nodes unlocked and ready"

  docker compose -f "${BASE_DIR}/docker-compose.yml" up -d rtl
  ok "RTL started on http://127.0.0.1:${RTL_PORT}"
}

###############################################################################
#  STEP 7 — Build Mostro image, configure Nostr key, start container
#  Build the Mostro Docker image from docker/mostro/Dockerfile (clones and
#  compiles Mostro inside Docker — no local source tree required).
#  Mostro needs a Nostr identity: key from .env, interactive paste, or
#  auto-generation with rana. Then copy lnd1's credentials and start.
###############################################################################
step_mostro() {
  log "7/9" "Building Mostro image and starting P2P exchange (lnd1)"

  mkdir -p "${BASE_DIR}/mostro"

  echo "  Building Mostro Docker image (ref: ${MOSTRO_REF}) — this may take a few minutes..."
  docker build \
    --build-arg MOSTRO_REF="${MOSTRO_REF}" \
    -t mostro:local \
    "${BASE_DIR}/docker/mostro"
  ok "Mostro Docker image built"

  if [[ -n "${MOSTRO_NSEC_PRIVKEY:-}" ]]; then
    # Option 1: key from .env
    MOSTRO_NSEC="${MOSTRO_NSEC_PRIVKEY}"
    if [[ -n "${MOSTRO_NPUB_ENV}" ]]; then
      MOSTRO_NPUB="${MOSTRO_NPUB_ENV}"
      ok "Nostr public key loaded from .env"
    fi
    ok "Nostr private key loaded from .env"
  else
    # Option 2: ask the user
    echo
    read -p "  Enter your Nostr private key (nsec1...) or press Enter to generate one: " user_nsec
    if [[ -n "$user_nsec" ]]; then
      MOSTRO_NSEC="${user_nsec}"
      ok "Nostr private key provided"
    else
      # Option 3: generate with rana
      generate_nostr_keys
    fi
  fi

  # Derive npub if not already set (rana sets it; manual/env entry does not)
  if [[ -z "${MOSTRO_NPUB:-}" ]]; then
    echo "  Deriving public key from nsec..."
    derive_npub "$MOSTRO_NSEC"
  fi

  echo "${MOSTRO_NSEC}" > "${BASE_DIR}/mostro/nostr-private.txt"
  chmod 600 "${BASE_DIR}/mostro/nostr-private.txt"
  ok "Private key saved → mostro/nostr-private.txt"

  echo "${MOSTRO_NPUB}" > "${BASE_DIR}/mostro/nostr-public.txt"
  chmod 644 "${BASE_DIR}/mostro/nostr-public.txt"
  ok "Public key  saved → mostro/nostr-public.txt  (${MOSTRO_NPUB})"

  write_mostro_config
  ok "Mostro settings.toml written"

  if ! docker cp lnd1:/root/.lnd/tls.cert "${BASE_DIR}/mostro/lnd/tls.cert"; then
    fail "Could not copy tls.cert from lnd1 — is the container running? (docker ps)"
  fi
  if ! docker cp lnd1:/root/.lnd/data/chain/bitcoin/regtest/admin.macaroon "${BASE_DIR}/mostro/lnd/admin.macaroon"; then
    fail "Could not copy admin.macaroon from lnd1 — wallet may not have been created"
  fi
  chmod -R a+r "${BASE_DIR}/mostro/lnd"
  chmod a+rwx "${BASE_DIR}/mostro"
  ok "LND credentials copied for Mostro"

  docker compose -f "${BASE_DIR}/docker-compose.yml" up -d mostro
  sleep 3
  ok "Mostro started (connected to lnd1)"

  if [[ -n "${MOSTRO_NPUB}" ]]; then
    echo
    echo -e "  \033[1;33mMostro public key (npub):\033[0m"
    echo -e "  \033[1;32m${MOSTRO_NPUB}\033[0m"
    if [[ -n "${MOSTRO_HEX}" ]]; then
      echo -e "  \033[1;33mMostro public key (hex):\033[0m"
      echo -e "  \033[1;32m${MOSTRO_HEX}\033[0m"
    fi
    echo
  fi

  # ── Build MostriX Docker image ──
  echo "  Building MostriX Docker image (ref: ${MOSTRIX_REF}) — this may take a few minutes..."
  docker build \
    --build-arg MOSTRIX_REF="${MOSTRIX_REF}" \
    -t mostrix:local \
    "${BASE_DIR}/docker/mostrix"
  ok "MostriX Docker image built"

  if [[ -n "${MOSTRO_HEX}" && -n "${MOSTRO_NSEC}" ]]; then
    write_mostrix_settings
    ok "MostriX configured (~/.mostrix/settings.toml)"
  else
    echo -e "  \033[1;33m⚠\033[0m  MostriX built but not configured — Mostro keys not available"
  fi
}

###############################################################################
#  STEP 8 — Fund wallets + open channels (triangle topology)
#  Send on-chain BTC from bitcoind's miner wallet to all LND nodes, open a
#  balanced channel lnd1↔lnd2, then open channels from lnd3→lnd1 and lnd3→lnd2.
#  This creates a triangle topology for richer routing.
###############################################################################
step_fund_and_channel() {
  log "8/9" "Funding wallets and opening channels"

  # Ensure miner wallet is loaded (it was created in step 5; may need reload after restart)
  if ! bcli listwallets | jq -e ".[] | select(.==\"${MINER_WALLET}\")" >/dev/null 2>&1; then
    bcli loadwallet "${MINER_WALLET}" >/dev/null
  fi

  for node in "${NODES[@]}"; do
    local addr
    addr="$(lncli "$node" newaddress p2wkh | jq -r '.address')"
    bcli -rpcwallet="${MINER_WALLET}" sendtoaddress "$addr" "${FUND_BTC[$node]}" >/dev/null
  done

  mine_blocks 6
  sleep 3
  ok "lnd1 received ${FUND_BTC[lnd1]} BTC, lnd2 received ${FUND_BTC[lnd2]} BTC, lnd3 received ${FUND_BTC[lnd3]} BTC"

  # ── lnd1↔lnd2 balanced channel ──
  local pub2
  pub2="$(lncli lnd2 getinfo | jq -r '.identity_pubkey')"
  lncli lnd1 connect "${pub2}@127.0.0.1:${PORTS[lnd2_listen]}" >/dev/null 2>&1 || true
  sleep 2

  lncli lnd1 openchannel --node_key="${pub2}" --local_amt="${CHANNEL_SATS}" >/dev/null
  ok "lnd1↔lnd2 channel opened (pending confirmation)"

  mine_blocks 6
  sleep 5

  local invoice
  invoice="$(lncli lnd2 addinvoice --amt="${REBALANCE_SATS}" --memo="rebalance" | jq -r '.payment_request')"
  lncli lnd1 payinvoice --force "${invoice}" >/dev/null
  ok "lnd1↔lnd2 channel balanced ~2.5 BTC each side"

  # ── lnd3 channels (2.5 BTC to lnd1, 2.5 BTC to lnd2) ──
  local pub1
  pub1="$(lncli lnd1 getinfo | jq -r '.identity_pubkey')"

  lncli lnd3 connect "${pub1}@127.0.0.1:${PORTS[lnd1_listen]}" >/dev/null 2>&1 || true
  lncli lnd3 connect "${pub2}@127.0.0.1:${PORTS[lnd2_listen]}" >/dev/null 2>&1 || true
  sleep 2

  lncli lnd3 openchannel --node_key="${pub1}" --local_amt="${LND3_CHANNEL_SATS}" >/dev/null
  ok "lnd3→lnd1 channel opened (pending confirmation)"

  echo "  Mining blocks to confirm change before second channel..."
  mine_blocks 6
  sleep 3

  lncli lnd3 openchannel --node_key="${pub2}" --local_amt="${LND3_CHANNEL_SATS}" >/dev/null
  ok "lnd3→lnd2 channel opened (pending confirmation)"

  mine_blocks 6
  sleep 5

  # Balance lnd3 channels (~1.25 BTC each side)
  local lnd3_rebalance=$(( LND3_CHANNEL_SATS / 2 ))

  local inv_lnd1
  inv_lnd1="$(lncli lnd1 addinvoice --amt="${lnd3_rebalance}" --memo="rebalance lnd3-lnd1" | jq -r '.payment_request')"
  lncli lnd3 payinvoice --force "${inv_lnd1}" >/dev/null
  ok "lnd3↔lnd1 channel balanced ~1.25 BTC each side"

  local inv_lnd2
  inv_lnd2="$(lncli lnd2 addinvoice --amt="${lnd3_rebalance}" --memo="rebalance lnd3-lnd2" | jq -r '.payment_request')"
  lncli lnd3 payinvoice --force "${inv_lnd2}" >/dev/null
  ok "lnd3↔lnd2 channel balanced ~1.25 BTC each side"
}

###############################################################################
#  STEP 9 — Proxy checks + Lightning Address (conditional)
#  nginx and SSL certs are managed externally (~/Server/). This step only:
#    1. Verifies the nginx proxy container is running and ports 80/443 are up.
#    2. Starts satdress and registers Lightning Address usernames (LNURL_DOMAIN).
#  Skipped entirely if neither RTL_DOMAIN nor LNURL_DOMAIN is set in .env.
###############################################################################
step_domains() {
  log "9/9" "Proxy checks + Lightning Address setup"

  if [[ -z "${RTL_DOMAIN}" && -z "${LNURL_DOMAIN}" ]]; then
    ok "Skipped — neither RTL_DOMAIN nor LNURL_DOMAIN set in .env"
    return
  fi

  # ── Verify external nginx proxy is running (optional — warn, do not fail) ──
  if ! docker inspect nginx --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
    warn "nginx container is not running — HTTPS domains will not be reachable until you start your reverse proxy"
  else
    ok "nginx proxy container is running"
  fi

  if [[ -n "${RTL_DOMAIN}" ]]; then
    if curl -sf --max-time 5 "https://${RTL_DOMAIN}" -o /dev/null 2>/dev/null; then
      ok "${RTL_DOMAIN} reachable via HTTPS"
    else
      ok "${RTL_DOMAIN} HTTPS proxy active (RTL will be live once this step completes)"
    fi
  fi

  # ── Lightning Address via satdress ──
  if [[ -n "${LNURL_DOMAIN}" ]]; then
    write_satdress_env
    ok "satdress .env written"

    echo "  Building satdress Docker image..."
    docker build -t satdress:local "${BASE_DIR}/docker/satdress"
    ok "satdress image built"

    docker compose -f "${BASE_DIR}/docker-compose.yml" up -d satdress

    local i=0
    while (( i < 30 )); do
      if curl -s "http://127.0.0.1:${SATDRESS_PORT}" >/dev/null 2>&1; then
        break
      fi
      sleep 1
      (( i++ ))
    done
    if (( i >= 30 )); then
      fail "satdress not responding on 127.0.0.1:${SATDRESS_PORT}"
    fi
    ok "satdress running on 127.0.0.1:${SATDRESS_PORT}"

    local mac_hex
    mac_hex="$(docker exec lnd1 xxd -p -c 9999 /root/.lnd/data/chain/bitcoin/regtest/admin.macaroon 2>/dev/null)" \
      || fail "Could not read admin macaroon from lnd1"

    IFS=',' read -ra lnurl_users <<< "${LNURL_USERNAMES}"
    for uname in "${lnurl_users[@]}"; do
      uname="$(echo "$uname" | xargs)"
      [[ -z "$uname" ]] && continue

      local reg_resp
      reg_resp="$(curl -s -X POST "http://127.0.0.1:${SATDRESS_PORT}/grab" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "name=${uname}&kind=lnd&host=https://127.0.0.1:${PORTS[lnd1_rest]}&key=${mac_hex}&nossl=true" \
        2>/dev/null)" || true

      if echo "$reg_resp" | grep -q '"name":"'"${uname}"'"'; then
        ok "Lightning Address registered: ${uname}@${LNURL_DOMAIN}"
      else
        echo "  Warning: ${uname} registration may have failed"
        echo "  Register manually at http://127.0.0.1:${SATDRESS_PORT}"
      fi
    done
  fi
}

# ── Shell aliases ─────────────────────────────────────────────────────────────
# Install mostro-logs as a permanent bash function so the user can check
# Mostro output from any directory without remembering the full docker command.

install_shell_commands() {
  local bashrc="${HOME}/.bashrc"
  local marker="# --- mostro-regtest-aliases ---"

  # Remove previous version if it exists, then append fresh
  if grep -qF "${marker}" "${bashrc}" 2>/dev/null; then
    sed -i "/${marker}/,/${marker}/d" "${bashrc}"
  fi

  local alias_block
  alias_block="mostro-logs() { docker compose -f \"${BASE_DIR}/docker-compose.yml\" logs --tail 100 -f mostro; }"
  alias_block+=$'\n'"bcli() { docker exec bitcoind bitcoin-cli -regtest -rpcuser=${BITCOIND_RPC_USER} -rpcpassword=${BITCOIND_RPC_PASS} \"\$@\"; }"
  if docker image inspect mostrix:local >/dev/null 2>&1; then
    alias_block+=$'\n'"alias mostrix='docker run -it --rm --network host -v \$HOME/.mostrix:/root/.mostrix mostrix:local'"
  fi

  cat >> "${bashrc}" <<EOF
${marker}
${alias_block}
${marker}
EOF

  ok "Shell commands installed (run: source ~/.bashrc or open a new terminal)"
}

# ── Summary ───────────────────────────────────────────────────────────────────

show_summary() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  SETUP COMPLETE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  echo "  Seeds saved at:"
  echo "    ${BASE_DIR}/lnd1/data/seed.txt"
  echo "    ${BASE_DIR}/lnd2/data/seed.txt"
  echo "    ${BASE_DIR}/lnd3/data/seed.txt"
  echo
  echo "  RTL web UI:"
  if [[ -n "${RTL_DOMAIN}" ]]; then
    echo "    https://${RTL_DOMAIN}"
  else
    echo "    http://127.0.0.1:${RTL_PORT}"
    echo "    SSH tunnel: ssh -L ${RTL_PORT}:127.0.0.1:${RTL_PORT} user@your-vps"
  fi
  echo
  echo "  Mostro (P2P exchange on lnd1):"
  echo "    Relays: ${MOSTRO_RELAYS}"
  echo "    Public key (npub): ${MOSTRO_NPUB}"
  echo "    Public key (hex):  ${MOSTRO_HEX}"
  echo "    Private key:  ${BASE_DIR}/mostro/nostr-private.txt"
  echo "    Public key:   ${BASE_DIR}/mostro/nostr-public.txt"
  echo

  if [[ -n "${LNURL_DOMAIN}" ]]; then
    echo "  Lightning Addresses:"
    IFS=',' read -ra summary_users <<< "${LNURL_USERNAMES}"
    for uname in "${summary_users[@]}"; do
      uname="$(echo "$uname" | xargs)"
      [[ -z "$uname" ]] && continue
      echo "    ${uname}@${LNURL_DOMAIN}"
      echo "      https://${LNURL_DOMAIN}/.well-known/lnurlp/${uname}"
    done
    echo
  fi

  echo "  Channel balances:"
  for node in "${NODES[@]}"; do
    echo "  ── ${node} ──"
    lncli "$node" listchannels | jq '.channels[] | {capacity, local_balance, remote_balance}'
  done

  if docker image inspect mostrix:local >/dev/null 2>&1; then
    echo "  MostriX (TUI client):"
    echo "    mostrix               Launch MostriX terminal interface"
    echo "    Config: ~/.mostrix/settings.toml"
    echo
  fi

  echo
  echo "  Useful commands:"
  echo "    mostro-logs  Shows last 100 lines + follows in real time"
  if docker image inspect mostrix:local >/dev/null 2>&1; then
    echo "    mostrix      MostriX TUI (orders, trades, admin disputes)"
  fi
  echo "    bitcoin-cli: docker exec bitcoind bitcoin-cli -regtest -rpcuser=${BITCOIND_RPC_USER} -rpcpassword=${BITCOIND_RPC_PASS} <cmd>"
  echo "    lncli1:      docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd1_rpc]} <cmd>"
  echo "    lncli2:      docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd2_rpc]} <cmd>"
  echo "    lncli3:      docker exec lnd3 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd3_rpc]} <cmd>"
  echo "    logs:        cd ${BASE_DIR} && docker compose logs -f"
  echo
}

# ── Summary file ──────────────────────────────────────────────────────────────
# Write a plain-text summary of everything created during setup so the user
# can reference it later without scrolling through terminal output.

write_summary_file() {
  local f="${BASE_DIR}/summary.txt"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"

  cat > "$f" <<EOF
===============================================
  MOSTRO REGTEST — SETUP SUMMARY
  Generated: ${ts}
===============================================

SEEDS
  lnd1: ${BASE_DIR}/lnd1/data/seed.txt
  lnd2: ${BASE_DIR}/lnd2/data/seed.txt
  lnd3: ${BASE_DIR}/lnd3/data/seed.txt

RTL WEB UI
EOF

  if [[ -n "${RTL_DOMAIN}" ]]; then
    echo "  URL: https://${RTL_DOMAIN}" >> "$f"
  else
    echo "  URL: http://127.0.0.1:${RTL_PORT}" >> "$f"
    echo "  SSH tunnel: ssh -L ${RTL_PORT}:127.0.0.1:${RTL_PORT} user@your-vps" >> "$f"
  fi

  cat >> "$f" <<EOF

MOSTRO (P2P exchange on lnd1)
  Relays: ${MOSTRO_RELAYS}
  Private key: ${BASE_DIR}/mostro/nostr-private.txt
EOF

  if [[ -n "${MOSTRO_NPUB}" ]]; then
    echo "  Public key (npub): ${MOSTRO_NPUB}" >> "$f"
  fi
  if [[ -n "${MOSTRO_HEX}" ]]; then
    echo "  Public key (hex):  ${MOSTRO_HEX}" >> "$f"
  fi

  if [[ -n "${LNURL_DOMAIN}" ]]; then
    echo "" >> "$f"
    echo "LIGHTNING ADDRESSES" >> "$f"
    IFS=',' read -ra file_users <<< "${LNURL_USERNAMES}"
    for uname in "${file_users[@]}"; do
      uname="$(echo "$uname" | xargs)"
      [[ -z "$uname" ]] && continue
      echo "  ${uname}@${LNURL_DOMAIN}" >> "$f"
      echo "    https://${LNURL_DOMAIN}/.well-known/lnurlp/${uname}" >> "$f"
    done
  fi

  if docker image inspect mostrix:local >/dev/null 2>&1; then
    cat >> "$f" <<EOF

MOSTRIX (TUI client)
  mostrix                         Launch MostriX terminal interface
  Config: ~/.mostrix/settings.toml
  Keys: Left/Right=tabs, Up/Down=navigate, Enter=select, Q=quit
EOF
  fi

  cat >> "$f" <<EOF

USEFUL COMMANDS
  mostro-logs                     Last 100 lines + follow
EOF
  if docker image inspect mostrix:local >/dev/null 2>&1; then
    echo "  mostrix                       MostriX TUI (orders, trades, admin)" >> "$f"
  fi
  cat >> "$f" <<EOF
  docker exec bitcoind bitcoin-cli -regtest -rpcuser=${BITCOIND_RPC_USER} -rpcpassword=${BITCOIND_RPC_PASS} <cmd>
  docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd1_rpc]} <cmd>
  docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd2_rpc]} <cmd>
  docker exec lnd3 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd3_rpc]} <cmd>
  cd ${BASE_DIR} && docker compose logs -f
EOF

  chmod 600 "$f"
  ok "Summary written to ${f}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  [[ "$START_FROM" -le 1 ]] && step_preflight
  [[ "$START_FROM" -le 2 ]] && step_deps
  [[ "$START_FROM" -le 3 ]] && step_clean
  [[ "$START_FROM" -le 4 ]] && step_password
  [[ "$START_FROM" -le 5 ]] && step_configs_and_start
  [[ "$START_FROM" -le 6 ]] && step_wallets_and_unlock
  [[ "$START_FROM" -le 7 ]] && step_mostro
  [[ "$START_FROM" -le 8 ]] && step_fund_and_channel
  [[ "$START_FROM" -le 9 ]] && step_domains
  install_shell_commands
  write_summary_file
  show_summary
}

main "$@"
