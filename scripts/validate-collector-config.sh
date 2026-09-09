#!/bin/bash
# Validate the collector config(s) exactly as run-collector.sh would launch them:
# read the same .env keys, then run `otelcol-contrib validate` on the base config
# and on base + the Agent Observability overlay when SPLUNK_AO_O11Y_TOKEN is
# present. Exits non-zero on invalid config.
set -euo pipefail
cd "$(dirname "$0")/.."

export SPLUNK_REALM=$(grep '^SPLUNK_REALM=' .env 2>/dev/null | cut -d= -f2- || true)
export O11Y_INGEST=$(grep '^O11Y_INGEST=' .env 2>/dev/null | cut -d= -f2- || true)
export SPLUNK_AO_REALM=$(grep '^SPLUNK_AO_REALM=' .env 2>/dev/null | cut -d= -f2- || true)
export SPLUNK_AO_O11Y_TOKEN=$(grep '^SPLUNK_AO_O11Y_TOKEN=' .env 2>/dev/null | cut -d= -f2- || true)
export SPLUNK_AO_PROJECT=$(grep '^SPLUNK_AO_PROJECT=' .env 2>/dev/null | cut -d= -f2- || true)
export SPLUNK_AO_AGENT_STREAM=$(grep '^SPLUNK_AO_AGENT_STREAM=' .env 2>/dev/null | cut -d= -f2- || true)
export SPLUNK_AO_PROJECT="${SPLUNK_AO_PROJECT:-PseudoCo Assistant}"
export SPLUNK_AO_AGENT_STREAM="${SPLUNK_AO_AGENT_STREAM:-PseudoCo Assistant}"

./bin/otelcol-contrib validate --config otel-collector-config.yaml
echo "base config: OK"
if [ -n "${SPLUNK_AO_O11Y_TOKEN:-}" ]; then
  ./bin/otelcol-contrib validate --config otel-collector-config.yaml --config otel-collector-agent-obs.yaml
  echo "base + agent-obs overlay: OK"
fi
