# OpenVPN — Fallback Remote Access

OpenVPN is provided as a **fallback** for situations where WireGuard is not
usable. Use [WireGuard](wireguard-full-tunnel-nftables.md) by default.

---

## When to Use OpenVPN Instead of WireGuard

| Situation | Recommendation |
|-----------|---------------|
| Normal remote admin access | **WireGuard** — simpler, faster, lower overhead |
| Network blocks UDP entirely (captive portals, some corporate firewalls) | **OpenVPN over TCP 443** — harder to block |
| Client device only supports OpenVPN (legacy hardware/OS) | **OpenVPN** |
| Need certificate-based PKI with revocation lists | **OpenVPN** (has built-in PKI tooling via Easy-RSA) |
| Performance-sensitive bulk transfer | **WireGuard** — significantly lower CPU overhead |

---

## 1. Install OpenVPN and Easy-RSA

```bash
sudo apt update
sudo apt install openvpn easy-rsa
```

---

## 2. Set Up the PKI (Easy-RSA)

```bash
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa

./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa gen-req server nopass
./easyrsa sign-req server server
./easyrsa gen-dh
openvpn --genkey secret /etc/openvpn/server/ta.key
```

Copy the generated files into place:

```bash
cp pki/ca.crt                /etc/openvpn/server/
cp pki/issued/server.crt     /etc/openvpn/server/
cp pki/private/server.key    /etc/openvpn/server/
cp pki/dh.pem                /etc/openvpn/server/
```

---

## 3. Server Configuration — `/etc/openvpn/server/server.conf`

```ini
# /etc/openvpn/server/server.conf
# OpenVPN server — full-tunnel, IPv4 + IPv6 (fallback mode)

port   1194
proto  udp       # Change to tcp and port 443 if UDP is blocked

dev tun

ca   /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key  /etc/openvpn/server/server.key
dh   /etc/openvpn/server/dh.pem
tls-auth /etc/openvpn/server/ta.key 0

# IPv4 tunnel network
server 10.9.0.0 255.255.255.0

# Push full-tunnel routes to clients
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 10.9.0.1"

# IPv6 — assign a ULA /64 to the tunnel
server-ipv6 fd42:43:43::/64
push "route-ipv6 ::/0"
tun-ipv6

keepalive 10 120
cipher AES-256-GCM
auth   SHA256

user  nobody
group nogroup
persist-key
persist-tun

status      /var/log/openvpn/status.log
log-append  /var/log/openvpn/openvpn.log
verb 3
```

> For **TCP fallback on port 443**, change `proto udp` → `proto tcp` and
> `port 1194` → `port 443`. Make sure to open port 443/tcp in nftables (see
> [Section 5](#5-nftables--firewall-rules)) and note that your HTTP/HTTPS
> traffic (Cloudflare Tunnel) does not require port 443 to be open inbound,
> so this only conflicts if you were already using port 443 for something else.

---

## 4. Enable IP Forwarding

```bash
# Persist across reboots
cat << 'EOF' | sudo tee /etc/sysctl.d/99-openvpn.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sudo sysctl --system
```

---

## 5. nftables — Firewall Rules

Add or merge these rules into `/etc/nftables.conf`. Replace `eth0` with your
VPS WAN interface.

```nftables
define WAN_IF  = "eth0"
define OVP_IF  = "tun0"
define OVP_NET4 = 10.9.0.0/24
define OVP_NET6 = fd42:43:43::/64

table inet filter {

    chain input {
        # ... (existing rules) ...

        # Allow OpenVPN — UDP 1194 (or TCP 443 if using TCP fallback)
        iif $WAN_IF udp dport 1194 accept
        # iif $WAN_IF tcp dport 443 accept   # Uncomment for TCP fallback

        # Allow traffic arriving on the tun0 interface
        iif $OVP_IF accept
    }

    chain forward {
        # ... (existing rules) ...

        ct state established,related accept

        # Forward OpenVPN client traffic to the internet
        iif $OVP_IF oif $WAN_IF accept
        iif $WAN_IF oif $OVP_IF ct state established,related accept
    }
}

# IPv4 masquerade for OpenVPN clients
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oif $WAN_IF ip saddr $OVP_NET4 masquerade
    }
}
```

### IPv6 Considerations

OpenVPN's IPv6 support (`server-ipv6` / `tun-ipv6`) is functional but less
integrated than WireGuard's dual-stack handling. The same options apply:

- **ULA prefix** (`fd42:43:43::/64`): non-routable externally; use NAT66 or
  skip IPv6 egress.
- **Delegated public /64**: assign to `tun0`; no NAT needed; true end-to-end
  IPv6 egress.
- **IPv4-only tunnel**: omit `server-ipv6` and `push "route-ipv6 ::/0"` and
  remove `::/0` from the client profile.

NAT66 is generally not recommended — prefer a routed public prefix if your
provider offers one (same guidance as in the
[WireGuard doc](wireguard-full-tunnel-nftables.md#ipv6-note)).

---

## 6. Systemd — Enable and Start

```bash
sudo systemctl enable --now openvpn-server@server
sudo systemctl status  openvpn-server@server
```

View logs:

```bash
sudo journalctl -u openvpn-server@server -f
# or
sudo tail -f /var/log/openvpn/openvpn.log
```

---

## 7. Client Profile — `.ovpn`

Generate a client certificate first:

```bash
cd /etc/openvpn/easy-rsa
./easyrsa gen-req client1 nopass
./easyrsa sign-req client client1
```

Then build the `.ovpn` file (inline format):

```bash
cat << 'EOF' > client1.ovpn
client
dev tun
proto udp
remote <VPS_PUBLIC_IP> 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
key-direction 1
verb 3
<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/easy-rsa/pki/issued/client1.crt)
</cert>
<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client1.key)
</key>
<tls-auth>
$(cat /etc/openvpn/server/ta.key)
</tls-auth>
EOF
```

Distribute `client1.ovpn` securely (e.g., via SCP over SSH, then delete from
the server). Import into the OpenVPN client application.

---

## 8. Admin Service Exposure

The same principles as WireGuard apply: bind admin dashboards to the tunnel
interface IP (`10.9.0.1`) or `127.0.0.1`, not `0.0.0.0`.

SSH access follows the same SSH hardening recommendations — see
[ssh-hardening.md](../security/ssh-hardening.md).

---

## Related Documents

- [wireguard-full-tunnel-nftables.md](wireguard-full-tunnel-nftables.md) — preferred WireGuard setup
- [../security/ssh-hardening.md](../security/ssh-hardening.md) — SSH hardening with non-standard port
- [../security/audit-over-vpn.md](../security/audit-over-vpn.md) — nmap audit workflow over the VPN
