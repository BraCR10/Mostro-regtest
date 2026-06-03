# Setup steps

Detailed breakdown of each step in `setup.sh`. Re-run from any step with `--from N`.

---

## Step 1 — Preflight checks

Verifies Docker is installed and the daemon is running. Fails fast so you don't waste time on a broken environment.

```
Checks: docker, docker info
```

---

## Step 2 — Dependencies

Installs `jq` (JSON parser) and `curl` via `apt-get` if not already present. Both are used to call LND's REST API during wallet creation.

---

## Step 3 — Clean environment

Stops and removes all containers managed by this setup (`bitcoind`, `lnd1`, `lnd2`, `lnd3`, `rtl`, `mostro`, `satdress`, `nginx`). Wipes all generated data directories:

```
lnd1/   lnd2/   lnd3/   bitcoind/
rtl/    mostro/ satdress/
docker-compose.yml
~/.mostrix/
```

LND data dirs may be owned by root (Docker wrote them), so a temporary Alpine container is used to delete them safely.

**Tip:** Use `--from 5` or later to skip this step and keep existing containers running.

---

## Step 4 — Wallet password

Loads `WALLET_PASS` from `.env`. If not set, prompts interactively (minimum 8 characters, confirmed twice). The same password is used for all three LND wallets and for wallet auto-unlock on container restart.

---

## Step 5 — bitcoind + LND configs + start

The most complex step. Does five things in sequence:

### 5a. Build bitcoind Docker image

Builds `mostro-bitcoind:local` from `docker/bitcoind/Dockerfile`. Downloads Bitcoin Core `${BITCOIN_VERSION}` (default `28.0`) from `bitcoincore.org` during the build. Detects architecture automatically (`x86_64` / `aarch64`).

### 5b. Generate `bitcoin.conf`

Writes `bitcoind/bitcoin.conf` with regtest settings, RPC credentials, ZMQ endpoints, and `fallbackfee`. All RPC settings go inside the `[regtest]` section.

### 5c. Generate `docker-compose.yml`

Creates the full `docker-compose.yml` with services for `bitcoind`, `lnd1`, `lnd2`, `lnd3`, `rtl`, `mostro`, and optionally `satdress` (if `LNURL_DOMAIN` is set). All services use `network_mode: host` so they communicate over `127.0.0.1`.

### 5d. Start bitcoind, create miner wallet

Starts the `bitcoind` container and waits up to 60s for the RPC to respond. On first run, creates the `miner` wallet and mines 101 blocks so coinbase outputs are mature and spendable.

### 5e. Start LND containers

Starts `lnd1`, `lnd2`, `lnd3`. At this point wallets don't exist yet — LND exposes the `WalletUnlocker` gRPC until wallets are created in step 6.

---

## Step 6 — Wallets + auto-unlock + RTL

### 6a. Create wallets

For each node, calls LND's REST API:

1. `GET /v1/genseed` — generates a 24-word mnemonic
2. `POST /v1/initwallet` — initializes the wallet with the mnemonic and password

The seed is saved to `lndN/data/seed.txt` (chmod 600). **Back this up** — it's the only way to recover funds.

### 6b. Enable auto-unlock

Writes the wallet password to `lndN/data/wallet-password.txt` and adds `wallet-unlock-password-file` to each `lnd.conf`. Restarts all three LND containers. After restart, LND reads the password file and unlocks the wallet automatically.

### 6c. Start RTL

Starts the RTL container. RTL reads macaroons from the LND data directories (mounted read-only) and exposes a web UI at `http://127.0.0.1:3000`. All three nodes are available in the UI via a dropdown.

---

## Step 7 — Mostro + MostriX

### 7a. Build Mostro Docker image

Builds `mostro:local` from `docker/mostro/Dockerfile`. The build clones the Mostro repo at `MOSTRO_REF` (default: `main`) inside Docker and compiles with `cargo build --release`. **This takes ~10 minutes on first run** due to Rust compilation.

### 7b. Nostr key

Mostro needs a Nostr identity. Three options in priority order:

| Option | How |
|--------|-----|
| From `.env` | Set `MOSTRO_NSEC_PRIVKEY=nsec1...` to skip all prompts |
| Interactive paste | Enter your existing `nsec1...` key when prompted |
| Auto-generate | Press Enter — builds [rana](https://github.com/grunch/rana) in Docker and generates a new keypair |

The private key is saved to `mostro/nostr-private.txt` (chmod 600).

### 7c. Start Mostro

Copies lnd1's TLS cert and admin macaroon to `mostro/lnd/`, writes `mostro/settings.toml`, and starts the Mostro container. Mostro connects to lnd1 over gRPC and to Nostr relays over WebSocket.

### 7d. Build MostriX Docker image

Builds `mostrix:local` from `docker/mostrix/Dockerfile`. Same process as Mostro — clones at `MOSTRIX_REF` and compiles inside Docker. Writes `~/.mostrix/settings.toml` with the Mostro pubkey, relays, and admin key.

The `mostrix` shell alias runs: `docker run -it --rm --network host -v ~/.mostrix:/root/.mostrix mostrix:local`

---

## Step 8 — Fund wallets + open channels

### 8a. Fund nodes

Sends regtest BTC from the miner wallet to each LND node's on-chain address:

| Node | Amount |
|------|--------|
| lnd1 | 8 BTC |
| lnd2 | 3 BTC |
| lnd3 | 6 BTC |

Mines 6 blocks to confirm.

### 8b. Open and balance channels

Opens three channels to form a triangle topology:

| Channel | Capacity | After balance |
|---------|----------|---------------|
| lnd1 → lnd2 | 5 BTC | ~2.5 BTC each side |
| lnd3 → lnd1 | 2.5 BTC | ~1.25 BTC each side |
| lnd3 → lnd2 | 2.5 BTC | ~1.25 BTC each side |

Balancing is done by paying invoices across the channel so both sides have equal liquidity — enabling routing in both directions.

---

## Step 9 — Proxy check + Lightning Address

Skipped entirely if neither `RTL_DOMAIN` nor `LNURL_DOMAIN` is set.

### 9a. Verify nginx proxy

Checks that the `nginx` Docker container (managed in `~/Server/`) is running. If not, fails with instructions. nginx and SSL certs are **not managed by this script** — they live in `~/Server/` independently.

### 9b. Start satdress + register Lightning Address

If `LNURL_DOMAIN` is set:

1. Writes `satdress/.env` with the domain, port, and a randomly generated HMAC secret
2. Starts the `satdress` Docker container on `127.0.0.1:17422`
3. Reads lnd1's admin macaroon and registers each username in `LNURL_USERNAMES` via the satdress API

After this, `bracr10@lndpanel.site` is a working Lightning Address backed by lnd1.
