# RTL (Ride The Lightning)

RTL is a web UI for managing Lightning nodes. All three nodes (lnd1, lnd2, lnd3) are available via a dropdown selector. Default URL: `http://127.0.0.1:3000`.

Password: `RTL_PASSWORD` from `.env`, or `WALLET_PASS` if not set.

## Accessing RTL

RTL binds to `127.0.0.1` — not directly reachable from the internet.

### Local machine

Open `http://localhost:3000` directly. No extra steps.

### VPS — SSH tunnel

Safest option. Nothing exposed to the internet.

```bash
# From your local machine
ssh -L 3000:127.0.0.1:3000 user@your-vps-ip
```

Then open `http://localhost:3000` in your local browser.

### VPS — Custom domain with HTTPS

Set `RTL_DOMAIN` in `.env` and configure the nginx proxy in `~/Server/`. The proxy handles TLS termination and proxies to RTL on `127.0.0.1:3000` with WebSocket support.

```bash
# .env
RTL_DOMAIN=btcpanel.website
RTL_PASSWORD=yourpassword
```

See [security.md](security.md) for the nginx proxy setup.
