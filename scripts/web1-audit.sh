#!/usr/bin/env bash
# /usr/local/libexec/web1-audit.sh
#
# Boot-time audit script for the w3dev.tech VPS stack.
# Checks that all components are running correctly and that hardening
# settings are in effect.
#
# Invoked by: web1-audit.service (Type=oneshot, User=root)
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed (logged to stderr → journald)
#
# Configuration — update these values to match your deployment:
set -euo pipefail

CONTAINER_NAME="web1"
CONTAINER_IP="<CONTAINER_IP>"       # e.g. 10.200.1.2
CONTAINER_PORT="8080"
VARNISH_ADDR="127.0.0.1"
VARNISH_PORT="6081"

# ── Helpers ───────────────────────────────────────────────────────────────────

PASS=0
FAIL=0

pass() { echo "[PASS] $*"; PASS=$(( PASS + 1 )); }
fail() { echo "[FAIL] $*" >&2; FAIL=$(( FAIL + 1 )); }

section() { echo ""; echo "── $* ──────────────────────────────────────────────"; }

# ── 1. Systemd service checks ─────────────────────────────────────────────────

section "Systemd services"

if systemctl is-active --quiet "systemd-nspawn@${CONTAINER_NAME}.service"; then
    pass "systemd-nspawn@${CONTAINER_NAME} is active"
else
    fail "systemd-nspawn@${CONTAINER_NAME} is NOT active"
fi

if systemctl is-active --quiet varnish.service; then
    pass "varnish is active"
else
    fail "varnish is NOT active"
fi

if systemctl is-active --quiet caddy.service; then
    pass "caddy is active"
else
    fail "caddy is NOT active"
fi

# ── 2. Network reachability ───────────────────────────────────────────────────

section "Network reachability"

if curl -fsS --max-time 5 "http://${CONTAINER_IP}:${CONTAINER_PORT}/" >/dev/null 2>&1; then
    pass "Apache is reachable at ${CONTAINER_IP}:${CONTAINER_PORT}"
else
    fail "Apache is NOT reachable at ${CONTAINER_IP}:${CONTAINER_PORT}"
fi

if curl -fsS --max-time 5 "http://${VARNISH_ADDR}:${VARNISH_PORT}/" >/dev/null 2>&1; then
    pass "Varnish is reachable at ${VARNISH_ADDR}:${VARNISH_PORT}"
else
    fail "Varnish is NOT reachable at ${VARNISH_ADDR}:${VARNISH_PORT} (may be normal if no cache-able content)"
fi

# ── 3. Port exposure checks ───────────────────────────────────────────────────
# Verify that Apache's port is NOT exposed on any public/host interface.
# If you see a FAIL here, Apache has escaped the container network boundary.

section "Port exposure"

HOST_IFACES_LISTENING_ON_CONTAINER_PORT=$(
    ss -lntp 2>/dev/null \
    | grep ":${CONTAINER_PORT}" \
    | grep -v "127\\.0\\.0\\.1" \
    | grep -v "${CONTAINER_IP}" \
    | grep -v "\\[::1\\]" \
    || true
)

if [[ -z "${HOST_IFACES_LISTENING_ON_CONTAINER_PORT}" ]]; then
    pass "Port ${CONTAINER_PORT} is NOT exposed on any host public interface"
else
    fail "Port ${CONTAINER_PORT} is EXPOSED on a host public interface — Apache may be reachable from internet:"
    echo "${HOST_IFACES_LISTENING_ON_CONTAINER_PORT}" >&2
fi

# Varnish should only listen on loopback
VARNISH_PUBLIC_EXPOSURE=$(
    ss -lntp 2>/dev/null \
    | grep ":${VARNISH_PORT}" \
    | grep -v "127\\.0\\.0\\.1" \
    | grep -v "\\[::1\\]" \
    || true
)

if [[ -z "${VARNISH_PUBLIC_EXPOSURE}" ]]; then
    pass "Varnish port ${VARNISH_PORT} is NOT exposed on any public interface"
else
    fail "Varnish port ${VARNISH_PORT} is EXPOSED on a public interface:"
    echo "${VARNISH_PUBLIC_EXPOSURE}" >&2
fi

# ── 4. Firewall check ─────────────────────────────────────────────────────────

section "nftables firewall"

if systemctl is-active --quiet nftables.service; then
    pass "nftables.service is active"
else
    fail "nftables.service is NOT active — host may be unprotected"
fi

# Verify at least one inet filter table is loaded
if nft list tables 2>/dev/null | grep -q "inet filter"; then
    pass "nftables inet filter table is loaded"
else
    fail "nftables inet filter table is NOT loaded — check /etc/nftables.conf"
fi

# ── 5. Container hardening spot-check ─────────────────────────────────────────

section "Systemd hardening (spot-check)"

# Read current unit properties
NO_NEW_PRIVS=$(systemctl show "systemd-nspawn@${CONTAINER_NAME}.service" \
    -p NoNewPrivileges --value 2>/dev/null || echo "unknown")
PROTECT_SYS=$(systemctl show "systemd-nspawn@${CONTAINER_NAME}.service" \
    -p ProtectSystem --value 2>/dev/null || echo "unknown")
PROTECT_HOME=$(systemctl show "systemd-nspawn@${CONTAINER_NAME}.service" \
    -p ProtectHome --value 2>/dev/null || echo "unknown")
RESTRICT_SUID=$(systemctl show "systemd-nspawn@${CONTAINER_NAME}.service" \
    -p RestrictSUIDSGID --value 2>/dev/null || echo "unknown")

check_flag() {
    local name="$1" actual="$2" expected="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        pass "${name}=${actual}"
    else
        fail "${name}=${actual} (expected ${expected}) — check override.conf"
    fi
}

check_flag "NoNewPrivileges"  "${NO_NEW_PRIVS}"   "yes"
check_flag "ProtectSystem"    "${PROTECT_SYS}"    "strict"
check_flag "ProtectHome"      "${PROTECT_HOME}"   "yes"
check_flag "RestrictSUIDSGID" "${RESTRICT_SUID}"  "yes"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════"
echo "Audit complete — PASS: ${PASS}  FAIL: ${FAIL}"
echo "════════════════════════════════════════════════════"

if [[ "${FAIL}" -gt 0 ]]; then
    echo "One or more checks FAILED. Review the output above." >&2
    exit 1
fi

exit 0
