# Mostro Regtest

Fully Dockerized setup for a Bitcoin regtest node, 3 LND nodes (triangle topology), RTL web UI, and [Mostro](https://github.com/MostroP2P/mostro) P2P exchange.

**Zero local dependencies** — only Docker is required. Minimum: 2 CPU cores, 4 GB RAM, 20 GB disk. bitcoind, LND, Mostro, MostriX, and RTL all run as Docker containers. Nothing is installed on the host.

## Quick start

```bash
git clone https://github.com/BraCR10/Mostro-regtest ~/Mostro
cd ~/Mostro
cp .env.example .env
nano .env          # set WALLET_PASS at minimum (everything else has defaults)
chmod +x setup.sh
./setup.sh
```

Re-run from a specific step (skips earlier steps):

```bash
./setup.sh --from 7
```

## What the script does

| Step | What happens |
|------|-------------|
| **1/9** | Verifies Docker is available and running |
| **2/9** | Installs `jq` and `curl` if missing |
| **3/9** | Stops and removes all containers, wipes generated data dirs |
| **4/9** | Loads `WALLET_PASS` from `.env` or prompts interactively |
| **5/9** | Builds bitcoind Docker image, generates `bitcoin.conf`, starts bitcoind, creates miner wallet, mines 101 initial blocks, writes LND + RTL configs, starts lnd1/lnd2/lnd3 |
| **6/9** | Creates LND wallets via REST API, enables auto-unlock on restart, starts RTL |
| **7/9** | Builds Mostro Docker image from source, handles Nostr key (`.env` / prompt / auto-generate), builds MostriX Docker image, starts Mostro on lnd1 |
| **8/9** | Funds all nodes from the miner wallet, opens and balances channels in triangle topology (lnd1↔lnd2, lnd3↔lnd1, lnd3↔lnd2) |
| **9/9** | Verifies nginx proxy is running, starts satdress, registers Lightning Address usernames (skipped if no domains set) |

## Architecture

All services use Docker host networking and bind to `127.0.0.1`. Nothing is exposed to the internet directly — nginx (managed separately in `~/Server/`) is the only public-facing component.

```
                        Internet
                           │
                    nginx (~/Server/)
                    ports 80 / 443
                    ┌──────┴──────┐
              btcpanel.website   lndpanel.site
                    │                  │
              RTL :3000         satdress :17422
                                       │
  bitcoind ──── lnd1 ──── lnd2        lnd1
   :18443        │          │
                lnd3 ──────┘
```

## Channel topology

```
    lnd1 (8 BTC)
   /    \
lnd3 ── lnd2
(6 BTC) (3 BTC)
```

Each channel is opened and balanced so both sides have roughly equal liquidity.

## Shell shortcuts

After setup and `source ~/.bashrc`:

| Command | Description |
|---------|-------------|
| `mostro-logs` | Last 100 lines of Mostro logs, follows in real time |
| `mostrix` | Launch MostriX TUI (orders, trades, admin) |
| `bcli <cmd>` | Run `bitcoin-cli` against the regtest node |

## Documentation

- [Prerequisites](docs/prerequisites.md) — what you need before running setup
- [Configuration](docs/configuration.md) — `.env` variables, directory structure, ports
- [Setup steps](docs/setup-steps.md) — detailed breakdown of each step
- [Commands](docs/commands.md) — day-to-day commands for lncli, logs, mining
- [Mostro + MostriX](docs/mostro.md) — P2P exchange, Nostr keys, MostriX TUI
- [RTL](docs/rtl.md) — web UI access
- [LNURL and Lightning Address](docs/lnurl.md) — Lightning Address via satdress
- [Security](docs/security.md) — firewall, nginx proxy, port model
