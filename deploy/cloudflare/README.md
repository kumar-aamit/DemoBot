# Public tunnel hostname migration

Moving the public tunnel from `medadvice.yeackbot.com` to `pseudocoassistant.com`.

The 4.10.0 product rename deliberately left the tunnel hostnames alone. CLAUDE.md
lists `medadviceN.yeackbot.com` among the addresses of state that lives outside
the repo, alongside the checkout paths and the EC2 tags. That is why this is a
scripted migration with a preflight and a rollback rather than a search and
replace: the hostname is not a string in the codebase, it is the name of a record
in Cloudflare that four other systems point at.

## Status

**Done.** `pseudocoassistant.com` was registered through Cloudflare Registrar on
2026-09-09, delegated to `julio`/`ziggy.ns.cloudflare.com`, and the tunnel cut
over the same day.

Verified through the new hostname: `/health` 200, `/app` 401 without the access
key and 200 with it, edge certificate issued by Let's Encrypt.
`medadvice.yeackbot.com` now returns 404, its ingress rule having been removed by
the cutover.

The steps below are kept because the same script moves the EC2 fleet later, and
because the follow-ups in step 3 are still outstanding.

## The origin cert is scoped to one zone

`~/.cloudflared/cert.pem` is a base64 JSON blob carrying exactly one `zoneID`
and a token scoped to it. That zone is `yeackbot.com`. An account-wide cert is
not what `cloudflared tunnel login` produces.

This matters more than it looks, because **`cloudflared tunnel route dns` does
not reject a hostname outside the cert's zone.** It treats the hostname as a
label and appends its own zone. Asking it for `pseudocoassistant.com` against
the `yeackbot.com` cert creates `pseudocoassistant.com.yeackbot.com` and reports
success.

That is exactly what happened on the first cutover attempt on 2026-09-09.
`cloudflared` reported `Added CNAME pseudocoassistant.com.yeackbot.com`, the
ingress was rewritten to a hostname with no DNS record, and the old rule was
gone, so the public tunnel served nothing for about three minutes until
`--rollback`. The preflight now checks the cert's zone against the target
hostname, and `--apply` additionally refuses if the record `cloudflared` reports
creating is not the one that was asked for.

A later audit of the zone found no `pseudocoassistant.com.yeackbot.com` record —
the name is NXDOMAIN and the API lists it nowhere — so whatever `cloudflared`
logged, nothing durable was left behind. The guards stand regardless: the failure
mode they prevent is the ingress rewrite, not the record.

## Step 1 — create the DNS record (manual, one time)

Cloudflare dashboard → **pseudocoassistant.com** → **DNS** → **Add record**:

| Field | Value |
| --- | --- |
| Type | `CNAME` |
| Name | `@` |
| Target | `52a942e8-dddf-4a19-81fe-7865fc94c41b.cfargotunnel.com` |
| Proxy status | **Proxied** (orange cloud) — a grey cloud will not serve the tunnel |

Confirm it before going further:

```bash
dig +short pseudocoassistant.com
```

The alternative is `cloudflared tunnel login`, selecting `pseudocoassistant.com`.
That is a browser flow, and it **overwrites** `cert.pem` with one scoped to the
new zone, which breaks `route dns` for `yeackbot.com` and the fleet. If you take
that route, save the result to its own path and pass `--origincert`.

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
| cert's zone covers the hostname | `route dns` silently creating `host.certzone` |
| origin answers `/health` | 502 through the tunnel, reads like a DNS fault |

When all five pass:

```bash
./deploy/cloudflare/cutover-hostname.sh --apply --skip-dns
```

`--skip-dns` is right whenever the record was made in the dashboard: it skips
the `route dns` call and instead refuses to continue unless the hostname already
resolves. Drop it only for a hostname inside the cert's own zone.

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
| ~~Cloudflare DNS~~ | **Done.** The old `medadvice` CNAME was deleted; the name is now NXDOMAIN and `yeackbot.com` holds no records. | — |
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
