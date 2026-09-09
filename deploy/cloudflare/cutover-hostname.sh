#!/bin/bash
# Move a PseudoCo Assistant named tunnel from one public hostname to another.
#
#   ./deploy/cloudflare/cutover-hostname.sh --check     # preflight only, changes nothing
#   ./deploy/cloudflare/cutover-hostname.sh --apply     # route DNS, rewrite ingress, restart, verify
#   ./deploy/cloudflare/cutover-hostname.sh --rollback  # restore the previous ingress config
#
#   --hostname H   public hostname to serve   (default: pseudocoassistant.com)
#   --tunnel   T   named tunnel to re-point   (default: medadvice)
#   --service  U   local origin               (default: http://localhost:8001)
#
# WHY THIS EXISTS: the 4.10.0 product rename deliberately did NOT touch
# medadvice.yeackbot.com. CLAUDE.md lists the tunnel hostnames as addresses of
# state that lives outside the repo — Cloudflare DNS, the Cisco AI Defense
# connection, Agent Observability environment names, and browser localStorage —
# so a blanket sed over them orphans the thing they point at. Moving the
# hostname is therefore a deliberate, scripted migration with a preflight and a
# rollback, in the same spirit as the rename script: check the outside state
# first, change one thing at a time, and print what only a human can finish.
#
# WHAT THIS CANNOT DO, BY DESIGN:
#   - register a domain (a purchase)
#   - delete the old DNS record (destructive and irreversible from here)
#   - re-point AI Defense / Agent Observability (external consoles)
# Each is printed as a follow-up at the end instead.
#
# The config is REGENERATED from the live tunnel's own values, never sed-patched
# in place, so a malformed ingress list cannot survive a run. Every apply backs
# up the previous config first.
set -euo pipefail

HOSTNAME_="pseudocoassistant.com"
TUNNEL="medadvice"
SERVICE="http://localhost:8001"
MODE=""

CF_DIR="$HOME/.cloudflared"
CONFIG="$CF_DIR/config.yml"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check)    MODE=check ;;
    --apply)    MODE=apply ;;
    --rollback) MODE=rollback ;;
    --hostname) HOSTNAME_="${2:?--hostname needs a value}"; shift ;;
    --tunnel)   TUNNEL="${2:?--tunnel needs a value}"; shift ;;
    --service)  SERVICE="${2:?--service needs a value}"; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
[ -n "$MODE" ] || die "pick one of --check, --apply, --rollback (try --help)"

# The launchd label is pre-rename and stays that way: it is the address of a
# service already registered with launchd. See CLAUDE.md, medadvice* exclusions.
PLIST_LABEL="com.yeack.medadvice-tunnel"

# ---------------------------------------------------------------- preflight --
# Every check is read-only. --check runs these and stops; --apply runs these and
# refuses to continue unless all of them pass, because each failure mode below
# produces a tunnel that resolves but serves a Cloudflare error page.
preflight() {
  local fails=0

  log "Preflight for $HOSTNAME_ (tunnel: $TUNNEL)"

  if command -v cloudflared >/dev/null 2>&1; then
    ok "cloudflared present ($(command -v cloudflared))"
  else
    bad "cloudflared not on PATH"; fails=$((fails + 1))
  fi

  if [ -f "$CF_DIR/cert.pem" ]; then
    ok "cert.pem present (account is logged in)"
  else
    bad "no $CF_DIR/cert.pem — run 'cloudflared tunnel login'"; fails=$((fails + 1))
  fi

  local uuid=""
  uuid=$(cloudflared tunnel list 2>/dev/null | awk -v t="$TUNNEL" '$2 == t {print $1}' | head -1)
  if [ -n "$uuid" ]; then
    ok "tunnel '$TUNNEL' exists ($uuid)"
  else
    bad "no named tunnel '$TUNNEL' in this account"; fails=$((fails + 1))
  fi

  # The registration gate. A .com that nobody has bought returns no NS at all;
  # a domain registered but not delegated to Cloudflare returns someone else's.
  # Both cases make 'tunnel route dns' fail later with a much vaguer message,
  # so they are named explicitly here.
  # The registrable domain is the last two labels. Stripping only the FIRST
  # label is wrong for an apex hostname: it turns pseudocoassistant.com into
  # "com" and then reports the gTLD's own nameservers as a misdelegation.
  # (Two labels is right for .com and every TLD in play here; a multi-part
  # suffix like .co.uk would need a public-suffix list.)
  local zone ns
  zone=$(printf '%s' "$HOSTNAME_" | awk -F. 'NF>=2 {print $(NF-1)"."$NF; next} {print}')
  ns=$(dig +short NS "$zone" 2>/dev/null | tr -d ' ' | sort | paste -sd, -)
  if [ -z "$ns" ]; then
    bad "$zone has no nameservers — the domain is not registered yet"
    fails=$((fails + 1))
  elif printf '%s' "$ns" | grep -q "ns.cloudflare.com"; then
    ok "zone $zone delegated to Cloudflare ($ns)"
  else
    bad "zone $zone is delegated elsewhere ($ns) — add it to Cloudflare first"
    fails=$((fails + 1))
  fi

  # An ingress rule pointing at a dead origin yields a 502 through the tunnel,
  # which reads exactly like a DNS problem. Rule it out before cutting over.
  if curl -fsS -o /dev/null --max-time 5 "$SERVICE/health" 2>/dev/null; then
    ok "origin $SERVICE answers /health"
  else
    bad "origin $SERVICE is not answering /health — start the app first"; fails=$((fails + 1))
  fi

  if [ "$fails" -gt 0 ]; then
    printf '\n\033[31m%s preflight check(s) failed — nothing was changed.\033[0m\n' "$fails"
    return 1
  fi
  printf '\n\033[32mAll preflight checks passed.\033[0m\n'
  return 0
}

# ------------------------------------------------------------------- apply --
apply() {
  preflight || die "preflight failed; refusing to cut over"

  local uuid creds proto backup
  uuid=$(cloudflared tunnel list | awk -v t="$TUNNEL" '$2 == t {print $1}' | head -1)
  # Carry the live values forward rather than assuming the defaults, so a tunnel
  # whose credentials moved is not silently re-pointed at a path that is gone.
  creds=$(awk '/^credentials-file:/ {print $2}' "$CONFIG" 2>/dev/null || true)
  proto=$(awk '/^protocol:/ {print $2}' "$CONFIG" 2>/dev/null || true)
  [ -n "$creds" ] || creds="$CF_DIR/$uuid.json"
  [ -n "$proto" ] || proto="http2"
  [ -f "$creds" ] || die "credentials file $creds is missing"

  log "Routing $HOSTNAME_ to tunnel $TUNNEL"
  # Idempotent in practice: a second run against the same tunnel is a no-op,
  # but a hostname already claimed by a DIFFERENT record is a real conflict and
  # must stop the run rather than be forced.
  if cloudflared tunnel route dns "$TUNNEL" "$HOSTNAME_" 2>&1 | tee /tmp/cf-route.$$; then
    ok "DNS route created (CNAME $HOSTNAME_ -> $uuid.cfargotunnel.com)"
  else
    if grep -qi "already exists" /tmp/cf-route.$$; then
      warn "a DNS record for $HOSTNAME_ already exists"
      warn "check it points at $uuid.cfargotunnel.com, then re-run"
    fi
    rm -f /tmp/cf-route.$$
    die "could not route $HOSTNAME_"
  fi
  rm -f /tmp/cf-route.$$

  log "Rewriting ingress"
  backup="$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG" "$backup"
  ok "previous config saved to $backup"

  # Regenerated wholesale — see the header note on not sed-patching YAML.
  cat > "$CONFIG" <<EOF
tunnel: $uuid
credentials-file: $creds
protocol: $proto

ingress:
  - hostname: $HOSTNAME_
    service: $SERVICE
  - service: http_status:404
EOF

  if cloudflared tunnel ingress validate --config "$CONFIG" >/dev/null 2>&1; then
    ok "ingress config validates"
  else
    cp "$backup" "$CONFIG"
    die "ingress validation failed — config restored from $backup"
  fi

  log "Restarting the tunnel"
  launchctl kickstart -k "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null \
    && ok "$PLIST_LABEL restarted" \
    || warn "could not kickstart $PLIST_LABEL — restart cloudflared by hand"

  log "Verifying $HOSTNAME_"
  # Cloudflare needs a moment to publish the record and re-register the
  # connectors; a single immediate curl reports a false failure.
  local i code=""
  for i in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://$HOSTNAME_/health" 2>/dev/null || true)
    [ "$code" = "200" ] && break
    sleep 3
  done
  if [ "$code" = "200" ]; then
    ok "https://$HOSTNAME_/health -> 200"
  else
    bad "https://$HOSTNAME_/health -> ${code:-no response} after 60s"
    warn "DNS may still be propagating; re-check before rolling back"
  fi

  follow_ups
}

# ---------------------------------------------------------------- rollback --
rollback() {
  local backup
  backup=$(ls -t "$CONFIG".bak.* 2>/dev/null | head -1 || true)
  [ -n "$backup" ] || die "no $CONFIG.bak.* to roll back to"
  log "Restoring $backup"
  cp "$backup" "$CONFIG"
  cloudflared tunnel ingress validate --config "$CONFIG" >/dev/null 2>&1 \
    || die "restored config does not validate — inspect $CONFIG by hand"
  ok "config restored and validates"
  launchctl kickstart -k "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null \
    && ok "$PLIST_LABEL restarted" \
    || warn "restart cloudflared by hand"
  warn "the DNS record for the new hostname was NOT removed; delete it in the Cloudflare dashboard if you are abandoning the cutover"
}

# --------------------------------------------------------------- follow-ups --
# Deliberately printed, not automated: each one is either destructive or lives
# in a console this script has no credentials for.
follow_ups() {
  cat <<EOF

$(printf '\033[1m')Manual follow-ups — this script cannot do these$(printf '\033[0m')

  1. Delete the old DNS record
     Cloudflare dashboard -> yeackbot.com -> DNS -> remove the 'medadvice'
     CNAME. Leaving it up serves a 1033 error page once the ingress rule for
     it is gone, which looks like an outage to anyone holding an old link.

  2. Re-point Cisco AI Defense
     SCC -> Yeack Industries -> app YeackBot -> Connections. The API
     connection is keyed to the old hostname. See .claude/skills/connect-ai-defense.

  3. Re-point Agent Observability
     Environment names are derived from the hostname's first label, so
     existing dashboards and detectors key on 'medadvice'. New turns land
     under the new label and old ones do not move.
     See .claude/skills/fan-tunnel-to-agent-observability.

  4. Warn anyone holding a saved link
     Browser localStorage keys are per-origin, so a new hostname starts with
     an empty session history and needs the access key entered again.

  5. The EC2 fleet still serves medadviceN.yeackbot.com
     deploy/ec2/fleet.sh keeps FLEET_HOSTNAME=medadvice.yeackbot.com. Move it
     separately and only with the boxes running, so their per-box tunnels can
     be re-routed one at a time.
EOF
}

case "$MODE" in
  check)    preflight ;;
  apply)    apply ;;
  rollback) rollback ;;
esac
