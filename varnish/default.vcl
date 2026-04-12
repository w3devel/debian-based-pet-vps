vcl 4.1;
#
# /etc/varnish/default.vcl
#
# Varnish configuration for the w3dev.tech VPS stack.
# Varnish listens on 127.0.0.1:6081 (configured in /etc/default/varnish or the
# systemd unit override — see systemd/system/varnish-override.conf if present).
#
# Backend: Apache inside the systemd-nspawn container.
# Replace <CONTAINER_IP> with the actual container veth address (e.g. 10.200.1.2).

import std;

# ── Backend definition ────────────────────────────────────────────────────────
# Apache listens only on the private container veth IP — never on a public address.

backend web1 {
    .host = "<CONTAINER_IP>";   # e.g. 10.200.1.2
    .port = "8080";

    # Basic health probe — adjust .url to a lightweight endpoint
    .probe = {
        .url       = "/";
        .timeout   = 5s;
        .interval  = 10s;
        .window    = 5;
        .threshold = 3;
    }
}

# ── vcl_recv: request handling ────────────────────────────────────────────────

sub vcl_recv {
    set req.backend_hint = web1;

    # Normalise the Host header (strip port if present)
    set req.http.Host = regsub(req.http.Host, ":[0-9]+$", "");

    # Do not cache requests with a Cookie or Authorization header
    if (req.http.Cookie || req.http.Authorization) {
        return (pass);
    }

    # Pass non-cacheable HTTP methods
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    return (hash);
}

# ── vcl_backend_response: cache control ───────────────────────────────────────

sub vcl_backend_response {
    # Serve stale content for up to 30s while re-fetching from backend
    set beresp.grace = 30s;

    # Do not cache responses with Set-Cookie
    if (beresp.http.Set-Cookie) {
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }

    # Default TTL if the backend doesn't set Cache-Control
    if (!beresp.http.Cache-Control) {
        set beresp.ttl = 60s;
    }
}

# ── vcl_deliver: response headers ─────────────────────────────────────────────

sub vcl_deliver {
    # X-Cache header — useful for debugging cache behaviour but leaks internal
    # stack details to clients.  Remove or comment out these lines in production.
    #
    # To enable for debugging only, uncomment:
    # if (obj.hits > 0) {
    #     set resp.http.X-Cache = "HIT";
    # } else {
    #     set resp.http.X-Cache = "MISS";
    # }

    # Remove headers that expose internal stack details.
    unset resp.http.Via;
    unset resp.http.X-Varnish;
    unset resp.http.Server;
}
