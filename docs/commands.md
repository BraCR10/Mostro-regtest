# Commands

Shell aliases installed by `setup.sh` (active after `source ~/.bashrc`):

```bash
mostro-logs     # last 100 lines of Mostro logs + follow
mostrix         # launch MostriX TUI
bcli <cmd>      # bitcoin-cli against the regtest node
```

---

## bitcoin-cli

The `bcli` alias wraps `docker exec bitcoind bitcoin-cli -regtest` with the configured RPC credentials.

```bash
# Node info
bcli getblockchaininfo
bcli getblockcount

# Mine a block
bcli -rpcwallet=miner generatetoaddress 1 $(bcli -rpcwallet=miner getnewaddress)

# Mine 6 blocks (confirm transactions)
bcli -rpcwallet=miner generatetoaddress 6 $(bcli -rpcwallet=miner getnewaddress)

# Check miner balance
bcli -rpcwallet=miner getbalance

# Send to address
bcli -rpcwallet=miner sendtoaddress <address> <amount>
```

---

## lncli

Each LND node has its own gRPC port.

```bash
# lnd1 — gRPC port 10009
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo

# lnd2 — gRPC port 10010
docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:10010 getinfo

# lnd3 — gRPC port 10011
docker exec lnd3 lncli --network=regtest --rpcserver=127.0.0.1:10011 getinfo
```

Common lncli commands (replace `lnd1` / `10009` as needed):

```bash
# Balances
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 walletbalance
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 channelbalance

# Channels
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels

# Peers
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listpeers

# Create invoice
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 addinvoice --amt=10000

# Pay invoice
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 payinvoice --force <bolt11>
```

---

## Logs

```bash
# Mostro — last 100 lines + follow
mostro-logs

# All services
cd ~/Mostro && docker compose logs -f

# Specific service
cd ~/Mostro && docker compose logs -f lnd1
cd ~/Mostro && docker compose logs -f rtl
cd ~/Mostro && docker compose logs -f bitcoind

# Setup run logs (saved automatically)
ls ~/Mostro/logs/
cat ~/Mostro/logs/setup-<timestamp>.log
```

---

## Docker management

```bash
# Status of all containers
docker ps

# Restart everything
cd ~/Mostro && docker compose restart

# Stop everything (keeps data)
cd ~/Mostro && docker compose down

# Stop + wipe all data (full reset)
./setup.sh

# Re-run from a specific step
./setup.sh --from 5    # rebuild bitcoind + LND
./setup.sh --from 6    # recreate wallets
./setup.sh --from 7    # rebuild Mostro + MostriX
./setup.sh --from 8    # re-fund + re-open channels
./setup.sh --from 9    # redo satdress + Lightning Address
```

---

## MostriX

```bash
# Launch the TUI
mostrix

# Key bindings
# Left/Right — switch tabs
# Up/Down    — navigate lists
# Enter      — select/confirm
# Q          — quit
# M          — toggle User/Admin mode
# C          — copy invoice to clipboard
# Esc        — cancel/close popup

# Config location
cat ~/.mostrix/settings.toml
```

---

## Seeds and keys

```bash
# LND wallet seeds (back these up)
cat ~/Mostro/lnd1/data/seed.txt
cat ~/Mostro/lnd2/data/seed.txt
cat ~/Mostro/lnd3/data/seed.txt

# Mostro Nostr private key
cat ~/Mostro/mostro/nostr-private.txt

# Setup summary (ports, keys, addresses)
cat ~/Mostro/summary.txt
```
