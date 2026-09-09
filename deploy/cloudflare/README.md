# Public tunnel hostname migration

Moving the public tunnel from `medadvice.yeackbot.com` to `pseudocoassistant.com`.

The 4.10.0 product rename deliberately left the tunnel hostnames alone. CLAUDE.md
lists `medadviceN.yeackbot.com` among the addresses of state that lives outside
the repo, alongside the checkout paths and the EC2 tags. That is why this is a
scripted migration with a preflight and a rollback rather than a search and
replace: the hostname is not a string in the codebase, it is the name of a record
in Cloudflare that four other systems point at.

## Status

`pseudocoassistant.com` is **not registered**. Verisign, authoritative for `.com`,
returns `No match for domain "PSEUDOCOASSISTANT.COM"` and the name has no NS or
SOA records. Nothing can be wired up until someone buys it.

## Step 1 — register the domain (manual)

This is a purchase and has to be done by a person.

1. Register `pseudocoassistant.com` at any registrar, or directly through
   Cloudflare Registrar, which skips step 2.
2. Add the zone to the same Cloudflare account that holds `yeackbot.com`. The
   account is already authorized for tunnel routing; `~/.cloudflared/cert.pem`
   covers every zone in it, so no new credential is needed.
3. Point the registrar at the Cloudflare nameservers and wait for delegation.

Delegation is the gate. Confirm it before going further:

```bash
dig +short NS pseudocoassistant.com
```

Two `*.ns.cloudflare.com` names means the zone is live.

## Step 2 — cut over

```bash
./deploy/cloudflare/cutover-hostname.sh --check
```

Read-only. It verifies five things, each of which otherwise produces a tunnel
that resolves but serves an error page:

| Check | Failure it prevents |
| --- | --- |
| `cloudflared` on PATH | nothing to run |
| `cert.pem` present | routing rejected, account not logged in |
| named tunnel exists | routing a hostname at nothing |
| zone delegated to Cloudflare | domain unregistered or pointed elsewhere |
| origin answers `/health` | 502 through the tunnel, reads like a DNS fault |

When all five pass:

```bash
./deploy/cloudflare/cutover-hostname.sh --apply
```

That routes the DNS record, backs up `~/.cloudflared/config.yml`, regenerates the
ingress from the live tunnel's own values, validates it, restarts the launchd
service, and polls the new hostname for a healthy response for up to a minute.

The config is regenerated rather than patched in place, so a malformed ingress
list cannot survive a run. If validation fails the backup is restored
automatically.

## Step 3 — re-point what keys on the old hostname

The script prints these and does not attempt any of them. Each is either
destructive or lives in a console the script has no credentials for.

| System | What to do | Reference |
| --- | --- | --- |
| Cloudflare DNS | Delete the old `medadvice` CNAME on `yeackbot.com`. Left up, it serves a 1033 error page, which looks like an outage to anyone holding an old link. | dashboard |
| Cisco AI Defense | Re-point the API connection on app **YeackBot**. | `.claude/skills/connect-ai-defense` |
| Agent Observability | Environment names derive from the hostname's first label. New turns land under the new label; historical data stays under `medadvice` and does not move. | `.claude/skills/fan-tunnel-to-agent-observability` |
| Browser sessions | localStorage is per-origin, so the new hostname starts with empty session history and needs the access key entered again. | — |

## The EC2 fleet is a separate migration

`deploy/ec2/fleet.sh` still defaults to `FLEET_HOSTNAME=medadvice.yeackbot.com`,
and each box serves its own `medadviceN.yeackbot.com` through its own
`demobot-N` tunnel. Those are untouched by this cutover.

Move them only with the boxes running, one at a time, so each per-box tunnel can
be re-routed and verified before the next. A replica whose DNS moves while it is
stopped cannot be checked, and the failure surfaces later as a 1033 page.

## Rollback

```bash
./deploy/cloudflare/cutover-hostname.sh --rollback
```

Restores the most recent `config.yml` backup, validates it, and restarts the
tunnel. It does **not** delete the new DNS record; remove that by hand if the
cutover is being abandoned.
