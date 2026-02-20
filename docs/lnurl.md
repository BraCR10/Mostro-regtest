# LNURL and Lightning Address

## What is LNURL

[LNURL](https://github.com/lnurl/luds) is a UX protocol on top of Lightning Network that replaces single-use invoices with reusable interactions: pay, receive, authenticate — all from a static QR code or a fixed URL.

Main sub-protocols:

| Protocol | What it does |
|----------|-------------|
| **lnurl-pay** (LUD-06) | Sender scans a QR/link and the server generates a BOLT11 invoice on the spot |
| **lnurl-withdraw** | Receiver scans a QR and "withdraws" sats from a service |
| **lnurl-auth** | Passwordless login — signs with the node key |
| **lightning address** (LUD-16) | Human-readable address like `user@domain.com` that internally resolves to lnurl-pay |

## What is a Lightning Address

A Lightning Address works like an email address but for receiving Bitcoin. Instead of sharing a 200-character invoice, you share something like:

```
satoshi@yourdomain.com
```

When someone pays that address, their wallet internally:

1. Takes `satoshi@yourdomain.com` and makes a GET to `https://yourdomain.com/.well-known/lnurlp/satoshi`
2. Your server responds with JSON (callback URL, min/max amounts, metadata)
3. The wallet calls the callback with the chosen amount
4. Your server generates a BOLT11 invoice from your LND node and returns it
5. The wallet pays the invoice

```
Payer's wallet                        Your server + LND
       |                                      |
       |  GET /.well-known/lnurlp/satoshi      |
       |  -----------------------------------> |
       |                                      |
       |  { callback, minSendable, ... }       |
       |  <----------------------------------- |
       |                                      |
       |  GET callback?amount=50000            |
       |  -----------------------------------> |
       |                                      |
       |  { pr: "lnbc500n1..." }               |
       |  <----------------------------------- |
       |                                      |
       |  Pays the BOLT11 invoice              |
       |  -----------------------------------> |
```

## What you need

### 1. A domain

You need to buy a domain (can be from [Namecheap](https://www.namecheap.com/), Porkbun, Cloudflare, etc.). The domain is what goes after the `@` in your Lightning Address.

**All you do with the domain is point the DNS to your server** — no complex configuration, just an A record:

```
Type: A
Host: @    (or the subdomain you want)
Value: YOUR_VPS_IP
TTL: Automatic
```

If you want to use a subdomain (e.g. `ln.yourdomain.com`):

```
Type: A
Host: ln
Value: YOUR_VPS_IP
TTL: Automatic
```

### 2. HTTPS (SSL certificate)

LNURL requires HTTPS. The simplest option is [Caddy](https://caddyserver.com/) as a reverse proxy — it obtains Let's Encrypt certificates automatically:

```
yourdomain.com {
    reverse_proxy 127.0.0.1:8080
}
```

Alternatively you can use nginx + certbot.

### 3. An LNURL server

The server receives HTTP requests at `/.well-known/lnurlp/<username>` and generates invoices from your LND node. The [lnurl-rs](https://github.com/benthecarman/lnurl-rs) library implements the full protocol in Rust.

## Endpoint response

The endpoint `GET https://yourdomain.com/.well-known/lnurlp/username` must return:

```json
{
  "status": "OK",
  "tag": "payRequest",
  "callback": "https://yourdomain.com/lnurl/pay/username",
  "minSendable": 1000,
  "maxSendable": 100000000,
  "metadata": "[[\"text/plain\",\"Payment to username\"]]",
  "commentAllowed": 140
}
```

- `minSendable` / `maxSendable` in **millisatoshis** (1000 msat = 1 sat)
- `callback` is the URL the wallet calls with `?amount=<msat>` to get the BOLT11 invoice
- `metadata` is a JSON-string with at least `text/plain`

## Flow summary

```
[Buy domain] --> [DNS: A record pointing to your VPS]
                            |
                            v
                  [Reverse proxy with HTTPS]
                     (Caddy or nginx)
                            |
                            v
                  [LNURL server on your VPS]
                   /.well-known/lnurlp/*
                            |
                            v
                     [Your LND node]
                  (generates BOLT11 invoices)
```

The heavy part (LND node, channels, liquidity) is already in place with this setup. The LNURL server is just the HTTP bridge that converts web requests into invoices from your node.
