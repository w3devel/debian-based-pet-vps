# Ingress, VPN & Security Patterns

This directory documents the recommended patterns for exposing services on a
**Debian 12 (bookworm)** pet VPS where:

- Services are primarily **systemd units** bound to `127.0.0.1`.
- HTTP(S) ingress is handled by **Cloudflare Tunnel** (no inbound 80/443 required).
- **SSH** is kept open with strong hardening (non-default port recommended).
- **Traefik** is an optional routing layer for multi-app cases.
- **WireGuard** provides secure full-tunnel remote admin access.

## Ingress & Service Exposure

| File | Purpose |
|------|---------|
| [ingress.md](ingress.md) | Architecture overview, port policy, and decision matrix — when to route directly vs via Traefik. |
| [cloudflare-tunnel.md](cloudflare-tunnel.md) | Step-by-step setup of a named Cloudflare Tunnel with systemd, including ingress rule examples. |
| [traefik.md](traefik.md) | Optional Traefik layer — as a systemd service binary or via Podman/Docker. |
| [ssh.md](ssh.md) | SSH hardening baseline: sshd_config settings, firewall rate-limiting, and Fail2ban (port 22 / Cloudflare Tunnel context). |

## VPN — Remote Access

| File | Purpose |
|------|---------|
| [vpn/wireguard-full-tunnel-nftables.md](vpn/wireguard-full-tunnel-nftables.md) | **Primary:** WireGuard full-tunnel setup (IPv4 + IPv6) with nftables rules, address plan, and admin service binding. [...]|
| [vpn/openvpn-fallback-remote-access.md](vpn/openvpn-fallback-remote-access.md) | **Fallback:** OpenVPN for networks that block UDP or require legacy client support. |

## Security

| File | Purpose |
|------|---------|
| [security/ssh-hardening.md](security/ssh-hardening.md) | SSH hardening with a non-standard port (`${SSH_PORT}` placeholder), key-only auth, Fail2ban, and nftables integration. |
| [security/crowdsec-nftables.md](security/crowdsec-nftables.md) | CrowdSec installation + nftables bouncer integration for SSH-only ingress (Cloudflare Tunnel + optional WireGuard). |
| [security/audit-over-vpn.md](security/audit-over-vpn.md) | nmap audit workflow and script — verify open ports (including Docker/Podman published ports) from a connected VPN peer. |

## Quick-start decision

```
Do you have more than one hostname to expose?
├── No  → cloudflared routes directly to each service (see cloudflare-tunnel.md)
└── Yes → add Traefik as a local router (see traefik.md) and point cloudflared at it

Do you need remote admin access to the VPS?
└── Yes → set up WireGuard (see vpn/wireguard-full-tunnel-nftables.md)
          then harden SSH (see security/ssh-hardening.md)
          and verify exposure (see security/audit-over-vpn.md)
```

See [ingress.md](ingress.md) for the full decision matrix.

For QEMU, see [qemu.md](qemu.md) if using image files.
