# LNURL and Lightning Address

## What is a Lightning Address

A Lightning Address looks like an email address (`bracr10@lndpanel.site`) but resolves to a BOLT11 invoice. When someone pays your Lightning Address:

1. Their wallet fetches `https://lndpanel.site/.well-known/lnurlp/bracr10`
2. satdress responds with LNURL-pay metadata
3. The wallet requests an invoice for the chosen amount
4. satdress asks lnd1 to generate a BOLT11 invoice and returns it
5. The wallet pays the invoice

```
Payer's wallet                         satdress + lnd1
      │                                      │
      │  GET /.well-known/lnurlp/bracr10     │
      │ ────────────────────────────────────►│
      │  { callback, minSendable, ... }      │
      │ ◄────────────────────────────────────│
      │  GET callback?amount=50000           │
      │ ────────────────────────────────────►│
      │  { pr: "lnbc500n1..." }              │
      │ ◄────────────────────────────────────│
      │  Pays invoice                        │
      │ ────────────────────────────────────►│
```

## Setup

Set in `.env`:

```bash
LNURL_DOMAIN=lndpanel.site
LNURL_USERNAMES=bracr10        # comma-separated for multiple: bracr10,alice
```

Step 9 of `setup.sh` handles the rest: starts satdress and registers the Lightning Address.

The nginx proxy in `~/Server/` must be configured separately to forward `https://lndpanel.site` → `127.0.0.1:17422`. See [security.md](security.md).

## satdress

[satdress](https://github.com/nbd-wtf/satdress) is the Lightning Address server. It runs as a Docker container on `127.0.0.1:17422` and connects to lnd1 via its REST API and admin macaroon.

Config at `satdress/.env` (generated, chmod 600):

```
PORT=17422
DOMAIN=lndpanel.site
HOST=127.0.0.1
SECRET=<random hex>
```

## Manual registration

If auto-registration fails during setup, register manually:

```bash
MAC_HEX=$(docker exec lnd1 xxd -p -c 9999 /root/.lnd/data/chain/bitcoin/regtest/admin.macaroon)

curl -X POST http://127.0.0.1:17422/grab \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "name=bracr10&kind=lnd&host=https://127.0.0.1:8080&key=${MAC_HEX}"
```

## Verification

```bash
# Check satdress is running
docker ps | grep satdress

# Test the endpoint
curl -s https://lndpanel.site/.well-known/lnurlp/bracr10
# Expected: {"callback":"...","maxSendable":...,"tag":"payRequest"}
```
