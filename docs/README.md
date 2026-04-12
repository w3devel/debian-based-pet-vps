# /docs — Ingress & Service Exposure Patterns

This directory documents the recommended patterns for exposing services on a
**Debian 12 (bookworm)** pet VPS where:

- Services are primarily **systemd units** bound to `127.0.0.1`.
- HTTP(S) ingress is handled by **Cloudflare Tunnel** (no inbound 80/443 required).
- **SSH (port 22)** is kept open with strong hardening.
- **Traefik** is an optional routing layer for multi-app cases.

## Documents

| File | Purpose |
|------|---------|
| [ingress.md](ingress.md) | Architecture overview, port policy, and decision matrix — when to route directly vs via Traefik. |
| [cloudflare-tunnel.md](cloudflare-tunnel.md) | Step-by-step setup of a named Cloudflare Tunnel with systemd, including ingress rule examples. |
| [traefik.md](traefik.md) | Optional Traefik layer — as a systemd service binary or via Podman/Docker. |
| [ssh.md](ssh.md) | SSH hardening: sshd_config settings, firewall rate-limiting, and Fail2ban. |

## Quick-start decision

```
Do you have more than one hostname to expose?
├── No  → cloudflared routes directly to each service (see cloudflare-tunnel.md)
└── Yes → add Traefik as a local router (see traefik.md) and point cloudflared at it
```

See [ingress.md](ingress.md) for the full decision matrix.
