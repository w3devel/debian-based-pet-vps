# Ingress Architecture — Cloudflare Tunnel + SSH

This document describes the recommended ingress model for a **Debian 12 (bookworm)**
pet VPS running services as **systemd units**.

## Recommended Architecture

```
Internet
   │
   ▼
Cloudflare (DNS / WAF / CDN)
   │  QUIC / HTTP2 outbound tunnel
   ▼
cloudflared (systemd service, outbound-only)
   │
   ├── hostname A → http://127.0.0.1:3000   (direct-to-service)
   ├── hostname B → http://127.0.0.1:4000   (direct-to-service)
   └── hostname C → http://127.0.0.1:8080      (Traefik, multi-app)
                          │
                          ├── app1.example.com → 127.0.0.1:<port1>
                          └── app2.example.com → 127.0.0.1:<port2>

SSH (port 22) ←─ direct, key-only, hardened (see ssh.md)
```

Key properties:

- **No inbound ports 80 or 443** are needed on the VPS.
- **cloudflared** makes an outbound connection to Cloudflare's edge; Cloudflare
  forwards inbound HTTPS traffic back through that tunnel.
- All services bind to `127.0.0.1`; only `cloudflared` (and optionally Traefik)
  can reach them locally.
- SSH is kept open but hardened (keys only, rate-limited).

## Port Policy

| Port | State | Notes |
|------|-------|-------|
| 22/tcp | **Open** | SSH, key-only, hardened. Optionally restrict by source IP. |
| 80/tcp | Closed | HTTP ingress is not needed; Cloudflare Tunnel handles it. |
| 443/tcp | Closed | HTTPS ingress is not needed; Cloudflare Tunnel handles it. |
| Others | Closed | All service ports are on `127.0.0.1` only. |

> **Firewall:** Use `nftables` (see [the repo's nftables config](../nftables/nftables.conf))
> to enforce this. Drop 80/443 in the `input` chain and keep only 22 open.

## Decision Matrix — Route Directly or via Traefik?

| Scenario | Recommended approach |
|----------|---------------------|
| One or two independent services, each on its own hostname | **Direct**: cloudflared ingress rule → `http://127.0.0.1:<port>` |
| Many apps sharing a domain prefix (e.g. `app1.example.com`, `app2.example.com`) | **Via Traefik**: cloudflared → `http://127.0.0.1:8080`, Traefik routes by hostname |
| Service needs middleware (auth, rate-limit, header rewrite) | **Via Traefik** |
| Simplest possible setup — minimal moving parts | **Direct** |
| Containerised apps alongside systemd services | **Via Traefik** (Docker/Podman provider + file provider) |

## Design Principles

1. **Outbound-only tunnel.** `cloudflared` never listens on a public port. The
   VPS does not need to accept inbound HTTP/HTTPS connections from the internet.

2. **Localhost-only origins.** Every service (whether a systemd unit or a
   container) binds to `127.0.0.1:<port>`. Nothing is reachable except through
   `cloudflared` or Traefik.

3. **SSH as the break-glass path.** Keep SSH (port 22) open with hard key-only
   authentication so you can always reach the server even if the tunnel fails.
   See [ssh.md](ssh.md).

4. **TLS is Cloudflare's job.** Public TLS termination happens at Cloudflare's
   edge. Traffic between `cloudflared` and your local services travels over
   localhost (no TLS needed). Do _not_ use `noTLSVerify` unless you have a
   genuine need — prefer HTTP to localhost origins.

5. **Optional Traefik layer.** Add Traefik only when you outgrow direct routing.
   See [traefik.md](traefik.md).

## Related Documents

- [cloudflare-tunnel.md](cloudflare-tunnel.md) — tunnel setup and config examples
- [traefik.md](traefik.md) — optional Traefik routing layer
- [ssh.md](ssh.md) — SSH hardening
