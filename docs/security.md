# Security

Defense in depth — only what's necessary is exposed to the internet:

| Layer | What it does |
|-------|--------------|
| **ufw** | Blocks all incoming traffic except SSH (22) and, if any domain is enabled, HTTP/HTTPS (80/443) |
| **bind 127.0.0.1** | bitcoind, LND, RTL, Mostro, and satdress only listen on localhost |
| **nginx** | The only service on 0.0.0.0 — reverse proxies HTTPS to configured domains only |
| **SSH tunnel** | The way to reach internal services remotely (unless `RTL_DOMAIN` exposes RTL via HTTPS) |

## What's exposed to the internet

| Port | Service | When |
|------|---------|------|
| 22 | SSH | Always |
| 80 | nginx (HTTP → HTTPS redirect) | Only if `RTL_DOMAIN` or `LNURL_DOMAIN` is set |
| 443 | nginx (HTTPS → configured services) | Only if `RTL_DOMAIN` or `LNURL_DOMAIN` is set |

nginx only proxies to explicitly configured domains:
- **`RTL_DOMAIN`** → RTL web UI (`127.0.0.1:3000`). RTL is password-protected. Use a strong `RTL_PASSWORD`.
- **`LNURL_DOMAIN`** → satdress (`127.0.0.1:17422`), which serves Lightning Address endpoints.

Each domain gets its own nginx server block and TLS certificate. Your LND nodes, Mostro, bitcoind, and macaroons are **not** reachable through nginx.

## Without any domains

If neither `RTL_DOMAIN` nor `LNURL_DOMAIN` is set, nothing changes — only port 22 is open. No nginx, no ports 80/443.

## Verifying

```bash
# Check what's listening on public interfaces (not 127.0.0.1)
ss -tlnp | grep -v 127.0.0

# Without domains: should only show port 22
# With RTL_DOMAIN or LNURL_DOMAIN: also ports 22, 80, 443 (nginx)

# Verify nginx doesn't leak internal services
curl -s https://yourdomain.com/v1/getinfo                  # should NOT return LND data
```

All Docker containers use `network_mode: host` and bind to `127.0.0.1`, so even without ufw, services are only reachable locally. The firewall adds a second layer of protection.
