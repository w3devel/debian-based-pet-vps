# WireGuard — Full-Tunnel Remote Access (nftables)

This guide configures a **WireGuard** server on a Debian 12 (bookworm) VPS so
that connected clients route **all** traffic (IPv4 and IPv6) through the VPS.
Firewalling examples use **nftables**.

Use this as your primary remote-admin path: once connected, you reach the VPS
over the WireGuard interface, and all admin dashboards (e.g. Traefik) are bound
to that interface only.

---

## Address Plan

| Role | IPv4 | IPv6 (ULA) |
|------|------|------------|
| VPS (`wg0`) | `10.8.0.1/24` | `fd42:42:42::1/64` |
| Client 1 | `10.8.0.2/32` | `fd42:42:42::2/128` |
| Client 2 | `10.8.0.3/32` | `fd42:42:42::3/128` |

- **IPv4 subnet:** `10.8.0.0/24`
- **IPv6 prefix:** `fd42:42:42::/64` (ULA — not globally routable, used only
  inside the tunnel; see [IPv6 note](#ipv6-note) below)
- **WireGuard listen port:** `51820/udp`

---

## 1. Install WireGuard

```bash
sudo apt update
sudo apt install wireguard wireguard-tools
```

---

## 2. Generate Keys

```bash
# On the VPS
cd /etc/wireguard
umask 077
wg genkey | tee server_private.key | wg pubkey > server_public.key

# On each client (run locally, not on the VPS)
wg genkey | tee client_private.key | wg pubkey > client_public.key
```

Store `client_public.key` on the VPS; keep `client_private.key` only on the
client.

---

## 3. Server Configuration — `/etc/wireguard/wg0.conf`

```ini
# /etc/wireguard/wg0.conf
# WireGuard server — full-tunnel, IPv4 + IPv6

[Interface]
Address    = 10.8.0.1/24, fd42:42:42::1/64
ListenPort = 51820
PrivateKey = <SERVER_PRIVATE_KEY>

# Enable IP forwarding for both address families when the interface comes up
PostUp   = sysctl -w net.ipv4.ip_forward=1
PostUp   = sysctl -w net.ipv6.conf.all.forwarding=1
PostDown = sysctl -w net.ipv4.ip_forward=0
PostDown = sysctl -w net.ipv6.conf.all.forwarding=0

# ── Peer: Client 1 ─────────────────────────────────────────────────────────
[Peer]
PublicKey  = <CLIENT_1_PUBLIC_KEY>
AllowedIPs = 10.8.0.2/32, fd42:42:42::2/128
```

> **Note:** `PostUp`/`PostDown` keep forwarding scoped to when the tunnel is
> active. You can also set `net.ipv4.ip_forward=1` persistently in
> `/etc/sysctl.d/99-wireguard.conf` if preferred.

---

## 4. Client Configuration

```ini
# client.conf — full-tunnel (all traffic via VPS)

[Interface]
Address    = 10.8.0.2/32, fd42:42:42::2/128
PrivateKey = <CLIENT_PRIVATE_KEY>
DNS        = 10.8.0.1          # Use VPS resolver, or a trusted upstream

[Peer]
PublicKey  = <SERVER_PUBLIC_KEY>
Endpoint   = <VPS_PUBLIC_IP>:51820
AllowedIPs = 0.0.0.0/0, ::/0  # Full tunnel — all traffic via VPS
PersistentKeepalive = 25
```

Import `client.conf` into your WireGuard app (desktop, mobile, or
`wg-quick up client`).

---

## 5. Systemd — Enable and Start

```bash
sudo systemctl enable --now wg-quick@wg0
sudo systemctl status wg-quick@wg0
```

Check the tunnel is up:

```bash
sudo wg show wg0
```

---

## 6. nftables — Firewall Rules

Add or merge these rules into `/etc/nftables.conf`.  Replace `eth0` with your
VPS's actual WAN interface name (check with `ip link`).

```nftables
#!/usr/sbin/nft -f
# /etc/nftables.conf — WireGuard full-tunnel + NAT

flush ruleset

define WAN_IF = "eth0"
define WG_IF  = "wg0"
define WG_NET4 = 10.8.0.0/24
define WG_NET6 = fd42:42:42::/64

table inet filter {

    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        iif lo accept

        ip  protocol icmp   accept
        ip6 nexthdr  icmpv6 accept

        # ── WireGuard ────────────────────────────────────────────────────────
        # Allow WireGuard handshakes on the WAN interface
        iif $WAN_IF udp dport 51820 accept

        # Allow all traffic arriving on the wg0 interface (from VPN peers)
        iif $WG_IF accept

        # ── SSH (public interface) ────────────────────────────────────────────
        # Uncomment to allow SSH from the public internet (use your SSH port):
        # tcp dport <SSH_PORT> accept
        # Or restrict to the WireGuard subnet only and keep SSH off the internet:
        # iif $WG_IF tcp dport <SSH_PORT> accept

        log prefix "[nft-drop] " level warn drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        ct state established,related accept

        # Allow forwarding from WireGuard clients to the internet (full tunnel)
        iif $WG_IF oif $WAN_IF accept

        # Allow return traffic for forwarded connections
        iif $WAN_IF oif $WG_IF ct state established,related accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

# ── IPv4 NAT — masquerade WireGuard client traffic ───────────────────────────
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # Masquerade all WireGuard IPv4 client traffic leaving via WAN
        oif $WAN_IF ip saddr $WG_NET4 masquerade
    }
}
```

Apply and persist:

```bash
sudo nft -f /etc/nftables.conf
sudo systemctl enable --now nftables
```

### IPv6 Note

For the **ULA prefix** (`fd42:42:42::/64`) used above, packets leaving the VPS
toward the internet carry a non-routable source address — you have two options:

| Option | How | Notes |
|--------|-----|-------|
| **Route ULA, NAT66** | Add `masquerade` in an `ip6 nat postrouting` chain | NAT66 is generally **not recommended** — breaks end-to-end transparency and some protocols; only use if your provider does not delegate a public IPv6 prefix |
| **Route a delegated public prefix** | Ask your VPS provider for a routed `/64`; assign it to `wg0` | Preferred — no NAT, true end-to-end IPv6; clients get globally routable addresses |
| **Tunnel IPv6-in-IPv4 only** | Use `AllowedIPs = 0.0.0.0/0` only on the client | Simplest if you don't need IPv6 on clients |

The config above uses ULA for simplicity. If your provider gives you a routed
`/64`, replace `fd42:42:42::/64` with that prefix and omit NAT66.

---

## 7. Admin Service Exposure — Bind to `wg0` Only

Services like the **Traefik dashboard** should bind to the WireGuard interface
IP (`10.8.0.1`) rather than `0.0.0.0` so they are unreachable from the public
internet.

**Traefik dashboard** (`/etc/traefik/traefik.yml`):

```yaml
api:
  dashboard: true
  insecure: true          # Safe — only reachable from 10.8.0.1 (wg0)

entryPoints:
  traefik:
    address: "10.8.0.1:8080"  # Bind to WireGuard interface only
```

**General principle:**

- Admin dashboards and management APIs → bind to `10.8.0.1` (wg0) or
  `127.0.0.1`; never `0.0.0.0`.
- SSH → allow from `wg0` subnet; optionally close from the public internet
  entirely (see [ssh-hardening.md](../security/ssh-hardening.md)).
- Docker/Podman published ports → verify with `nmap` after connecting
  (see [audit-over-vpn.md](../security/audit-over-vpn.md)).

---

## 8. Troubleshooting

| Symptom | Check |
|---------|-------|
| Handshake never completes | `sudo wg show` — verify endpoint, public key, and that UDP/51820 is allowed in nftables |
| Traffic not forwarding | `sysctl net.ipv4.ip_forward` — must be `1`; check `forward` chain in nftables |
| IPv6 not working | Check `net.ipv6.conf.all.forwarding`; verify client `AllowedIPs` includes `::/0` |
| High latency / packet loss | Try lowering MTU in `[Interface]` to `1380`; WireGuard overhead on some links requires it |
| DNS leaks | Set client `DNS = 10.8.0.1` and run a DNS leak test after connecting |

---

## Related Documents

- [openvpn-fallback-remote-access.md](openvpn-fallback-remote-access.md) — OpenVPN as a UDP/TCP fallback
- [../security/ssh-hardening.md](../security/ssh-hardening.md) — SSH port change and key-only auth
- [../security/audit-over-vpn.md](../security/audit-over-vpn.md) — nmap audit workflow over the VPN
- [../nftables/nftables.conf](../../nftables/nftables.conf) — base nftables config
