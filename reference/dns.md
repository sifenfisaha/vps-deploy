# DNS

Getting a certificate depends entirely on this, and it is where most first
deployments stall. Do it before Caddy ever tries.

## What has to be true

One `A` record, for the exact hostname being served, pointing at the VPS's
public IPv4 address, **not proxied**, and actually resolving.

```
Type   Name   Value            Proxy
A      api    203.0.113.10     OFF  (DNS only / grey cloud)
```

Verify from your own machine, not from the dashboard:

```bash
dig +short api.example.com A      # must print exactly the VPS IP
```

If `dig` is unavailable: `getent hosts api.example.com` or
`nslookup api.example.com`.

## The Cloudflare trap

**A proxied record makes every ACME challenge fail.** This is the single most
common reason a deployment gets to "the app is running" and stops there.

With the orange cloud on, `api.example.com` resolves to Cloudflare's edge, not
to the VPS. Let's Encrypt then talks to Cloudflare:

- `http-01` — Cloudflare answers `/.well-known/acme-challenge/…` itself, or
  forwards to an origin it cannot reach over plain HTTP. Result: **404**.
- `tls-alpn-01` — Cloudflare will not negotiate the `acme-tls/1` ALPN protocol.
  Result: **"Cannot negotiate ALPN protocol"**.

How it looks in the logs, and the tell is the IP that answered:

```
"msg":"validating authorization","identifier":"api.example.com",
"problem":{"detail":"2606:4700:3031::6815:47e8: Invalid response from
http://api.example.com/.well-known/acme-challenge/…: 404"}
```

`2606:4700:*`, `104.21.*`, `172.67.*` are Cloudflare. If you see them, the
record is proxied. Turn the proxy off.

**Recognising proxied IPs without the dashboard:**

```bash
dig +short api.example.com A
# 104.21.71.232 / 172.67.172.19  -> proxied, ACME will fail
# 203.0.113.10                   -> DNS only, correct
```

**After the certificate exists** you can turn the proxy back on, but set the
Cloudflare SSL/TLS mode to **Full (strict)**. In "Flexible" Cloudflare talks to
your origin over plain HTTP, which produces redirect loops against a Caddy that
redirects HTTP to HTTPS. Renewals also need to work, so leaving the proxy off is
the simpler life.

## Automating it with the Cloudflare API

Needs a token with **Zone:DNS:Edit** on the zone. Create it at
*My Profile → API Tokens → Create Token → Edit zone DNS*. It is a secret: pass
it in the environment, never write it into a file in the repo.

```bash
export CF_API_TOKEN=...            # Zone:DNS:Edit
ZONE=example.com
NAME=api.example.com
IP=203.0.113.10

# 1. Find the zone id
ZONE_ID=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=$ZONE" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["id"])')

# 2. Does the record already exist?
REC_ID=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$NAME" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r[0]["id"] if r else "")')

BODY="{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$IP\",\"ttl\":60,\"proxied\":false}"

# 3. Create or update it. proxied:false is the part that matters.
if [ -n "$REC_ID" ]; then
  curl -s -X PUT -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$REC_ID" -d "$BODY"
else
  curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" -d "$BODY"
fi
```

Then confirm it took effect, rather than trusting the API response:

```bash
dig +short @1.1.1.1 $NAME A
```

**Edit the existing record rather than adding a second one.** Two `A` records
for the same name round-robin, and half the requests — including ACME's — go to
the wrong place. Intermittent failures are much harder to diagnose than total
ones.

## Other providers

The requirement is identical everywhere: an `A` record at the host's IP, no
proxy or CDN in front of it during issuance.

- **Route 53** — `aws route53 change-resource-record-sets`, `UPSERT`, TTL 60.
- **DigitalOcean** — `doctl compute domain records create --record-type A`.
- **Namecheap / GoDaddy / Porkbun** — dashboard. Watch for an existing parked
  `A` record or a wildcard `*` that shadows the name.
- **Anything with a CDN toggle** — same trap as Cloudflare. Off until the
  certificate exists.

## Propagation

New records are usually live in seconds to a couple of minutes. A record that is
being *changed* can be cached for its old TTL — lower the TTL to 60 before
changing it if you can plan ahead.

Caddy retries a failed issuance for up to 30 days with backoff, so **a record
fixed after the fact needs no intervention** — the certificate typically appears
within a minute or two. Watch it happen:

```bash
ssh <target> 'sudo journalctl -u caddy -f | grep -i acme'
```

Look for `certificate obtained successfully`. Do not conclude it failed because
one `curl` immediately after the DNS change returned a TLS error — check the log
before deciding.

## IPv6

If the host has a public IPv6 address, either add a matching `AAAA` record or
add none at all. An `AAAA` pointing somewhere stale is worse than its absence:
clients and ACME prefer IPv6, so it will be tried first and fail while the
working `A` record sits unused.
