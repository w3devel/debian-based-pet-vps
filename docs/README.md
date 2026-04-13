# Audit Over VPN — Scanning Ports with nmap

Once connected over WireGuard (or OpenVPN), you can run an **nmap** scan
against the VPS from your workstation to verify exactly what is exposed — from
the perspective of a connected peer.

This is the recommended way to confirm your firewall rules are correct and to
check that Docker/Podman published ports are (or are not) reachable.

---

## Prerequisites

- Connected to the VPS via WireGuard (see
  [wireguard-full-tunnel-nftables.md](../vpn/wireguard-full-tunnel-nftables.md))
  or OpenVPN.
- `nmap` installed on your workstation:
  ```bash
  # Debian/Ubuntu
  sudo apt install nmap
  # macOS
  brew install nmap
  ```
- VPS WireGuard IP: `10.8.0.1` (default from this repo's address plan).

---

## 1. Quick Single-Host Scan

From your workstation (while connected over WireGuard):

```bash
# SYN scan of the top 1000 ports on the VPS WireGuard address
sudo nmap -sS -T4 10.8.0.1

# Full TCP port range — slower but thorough
sudo nmap -sS -T4 -p- 10.8.0.1

# TCP + UDP top ports (UDP is slow; use -F for faster/fewer ports)
sudo nmap -sS -sU -T4 -F 10.8.0.1

# Service/version detection
sudo nmap -sS -sV -T4 -p- 10.8.0.1
```

> **Why use the WireGuard IP?** Scanning `10.8.0.1` tests what is reachable
> _from a connected VPN peer_ — the same view an attacker who has compromised
> a peer key would have. Scanning the public IP from outside tests the nftables
> `input` chain instead.

---

## 2. Audit Script

Save this script on your **workstation** and run it while connected over VPN.

```bash
#!/usr/bin/env bash
# vpn-audit.sh — scan VPS ports from a connected WireGuard peer
#
# Usage:
#   chmod +x vpn-audit.sh
#   sudo ./vpn-audit.sh [WG_IP] [PUBLIC_IP]
#
# Arguments (both optional, defaults shown):
#   WG_IP      — WireGuard IP of the VPS          (default: 10.8.0.1)
#   PUBLIC_IP  — Public IP/hostname of the VPS    (default: skip public scan)
#
# Requirements: nmap must be installed and script must run as root (for -sS).

set -euo pipefail

WG_IP="${1:-10.8.0.1}"
PUBLIC_IP="${2:-}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
OUTDIR="/tmp/vpn-audit-${TIMESTAMP}"
mkdir -p "${OUTDIR}"

# ── Helpers ───────────────────────────────────────────────────────────────────
section() { echo ""; echo "── $* ──────────────────────────────────────────────"; }
log()     { echo "[INFO] $*"; }
warn()    { echo "[WARN] $*" >&2; }

# ── 1. Connectivity check ─────────────────────────────────────────────────────
section "Connectivity"
if ping -c 1 -W 2 "${WG_IP}" >/dev/null 2>&1; then
    log "VPS WireGuard IP ${WG_IP} is reachable"
else
    warn "Cannot reach ${WG_IP} — are you connected to WireGuard?"
    exit 1
fi

# ── 2. Full TCP scan over WireGuard ───────────────────────────────────────────
section "TCP scan — via WireGuard (${WG_IP})"
log "Scanning all TCP ports on ${WG_IP} (this may take a minute)..."
nmap -sS -T4 -p- -oN "${OUTDIR}/tcp-wg.txt" "${WG_IP}"
log "Results saved to ${OUTDIR}/tcp-wg.txt"

# ── 3. UDP top-ports scan over WireGuard ─────────────────────────────────────
section "UDP scan — via WireGuard (${WG_IP})"
log "Scanning top UDP ports on ${WG_IP}..."
nmap -sU -T4 -F -oN "${OUTDIR}/udp-wg.txt" "${WG_IP}"
log "Results saved to ${OUTDIR}/udp-wg.txt"

# ── 4. Service/version detection ─────────────────────────────────────────────
section "Service detection — via WireGuard"
log "Running service/version detection on ${WG_IP}..."
nmap -sS -sV -T4 -p- -oN "${OUTDIR}/services-wg.txt" "${WG_IP}"
log "Results saved to ${OUTDIR}/services-wg.txt"

# ── 5. Optional: public IP scan (from your external perspective) ──────────────
if [[ -n "${PUBLIC_IP}" ]]; then
    section "TCP scan — public IP (${PUBLIC_IP})"
    log "Scanning top 1000 TCP ports on public IP ${PUBLIC_IP}..."
    nmap -sS -T4 -oN "${OUTDIR}/tcp-public.txt" "${PUBLIC_IP}"
    log "Results saved to ${OUTDIR}/tcp-public.txt"
fi

# ── 6. Summary ────────────────────────────────────────────────────────────────
section "Summary"
log "All scan results saved to: ${OUTDIR}/"
echo ""
echo "Open ports found via WireGuard (${WG_IP}):"
grep -E "^[0-9]+/tcp.*open|^[0-9]+/udp.*open" \
    "${OUTDIR}/tcp-wg.txt" "${OUTDIR}/udp-wg.txt" 2>/dev/null || true

if [[ -f "${OUTDIR}/tcp-public.txt" ]]; then
    echo ""
    echo "Open ports found on public IP (${PUBLIC_IP}):"
    grep -E "^[0-9]+/tcp.*open" "${OUTDIR}/tcp-public.txt" 2>/dev/null || true
fi

echo ""
log "Audit complete."
```

Run the script:

```bash
chmod +x vpn-audit.sh

# Scan only via WireGuard:
sudo ./vpn-audit.sh

# Scan via WireGuard AND check the public IP:
sudo ./vpn-audit.sh 10.8.0.1 <VPS_PUBLIC_IP>
```

---

## 3. What to Expect

After running the script, review the open ports against your intended policy:

| Port | Expected | Notes |
|------|----------|-------|
| `${SSH_PORT}/tcp` | Open (on wg0) | Your SSH port — should be reachable from WG |
| `51820/udp` | Open (public) | WireGuard listen port — must be open |
| `8080/tcp` | Open (on wg0) | Traefik dashboard — only if bound to `10.8.0.1` |
| Any Docker/Podman published port | May be open | See note below |
| `22/tcp` | Closed or restricted | Should not be open on public interface if you moved SSH |
| `80/tcp`, `443/tcp` | Closed (public) | Not needed with Cloudflare Tunnel |

---

## 4. Localhost-Bound Services

Services bound to `127.0.0.1` (loopback only) are **not** reachable over the
WireGuard tunnel — nmap will show them as filtered or closed.

To audit loopback-only services, either:

**A — Run nmap on the VPS itself:**

```bash
ssh -p ${SSH_PORT} <YOUR_ADMIN_USER>@10.8.0.1 \
    "sudo nmap -sS -T4 -p- 127.0.0.1"
```

**B — Use an SSH local port-forward and scan locally:**

```bash
# Forward VPS loopback port 8080 to your local port 18080
ssh -p ${SSH_PORT} -L 18080:127.0.0.1:8080 <YOUR_ADMIN_USER>@10.8.0.1 -N &
curl http://localhost:18080/
kill %1
```

---

## 5. Docker / Podman Published Ports

Docker and Podman add their own `iptables`/`nftables` rules when you publish a
port (`-p 8080:8080`). These rules may **bypass your nftables `input` chain**
because Docker inserts rules in the `DOCKER` chain at a lower priority.

This means a port published with Docker/Podman may be reachable from the
internet even if your nftables config does not explicitly allow it.

**Verify after any container change:**

```bash
# On the VPS — list all published ports from running containers
sudo docker ps --format "table {{.Names}}\t{{.Ports}}"
# or
sudo podman ps --format "table {{.Names}}\t{{.Ports}}"

# Then re-run the audit script from your workstation to confirm actual exposure
sudo ./vpn-audit.sh 10.8.0.1 <VPS_PUBLIC_IP>
```

**Mitigation — bind published ports to the WireGuard IP:**

```bash
# Publish only on the WireGuard interface, not 0.0.0.0
docker run -p 10.8.0.1:8080:8080 myimage
```

This ensures the port is only reachable from VPN peers, not the public internet.

---

## 6. Ongoing Audit Cadence

- Run the audit script after **any change** to running containers, systemd
  services, or nftables rules.
- Consider running the script from a scheduled job (e.g. weekly) and
  diffing the output to detect unexpected port changes.
- Check `sudo ss -lntp` on the VPS to see which process is listening on each
  port.

---
  
# Security

| File | Description |
| --- | --- |
| [security/ssh-hardening.md](security/ssh-hardening.md) | Enhancements to SSH security. |
| [security/crowdsec-nftables.md](security/crowdsec-nftables.md) | CrowdSec installation + nftables bouncer integration for SSH-only ingress (Cloudflare Tunnel + optional WireGuard). |

---

## Related Documents

- [../vpn/wireguard-full-tunnel-nftables.md](../vpn/wireguard-full-tunnel-nftables.md) — WireGuard setup
- [ssh-hardening.md](ssh-hardening.md) — SSH port and auth hardening
- [../../scripts/web1-audit.sh](../../scripts/web1-audit.sh) — server-side service audit script
