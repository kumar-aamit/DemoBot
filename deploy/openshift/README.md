# OpenShift deployment

Runs the app on an OpenShift cluster from an in-cluster image build, with the LLM served
by a **remote Nemotron** behind an OpenAI-compatible endpoint and prompt/response inspection
by an **on-prem Cisco AI Defense gateway**. Everything in this directory is applied with `oc`;
the two objects that carry secrets or environment-specific material are created by hand first.

| File | What it is |
|---|---|
| `buildconfig.yaml` | ImageStream + BuildConfig: builds the top-level `Containerfile` from this repo's `main` |
| `configmap.yaml` | Non-secret settings (provider, model, AI Defense gateway, rules, telemetry identity) |
| `deployment.yaml` | PVC, Deployment (with the `ca-bundle` init container), Service, edge-TLS Route |
| `secret.example.env` | Template for the `pseudoco-assistant-secrets` Secret (copy to `secret.env`, git-ignored) |
| `certs/aid-ingress-chain.pem` | The AI Defense gateway's ingress chain (2 certs), source of the `aid-ca` ConfigMap |

## 1. Prerequisites

- `oc` logged in with rights to create builds, image streams and routes in the project.
- Network reach from the cluster to the Ray Serve endpoint (`OPENAI_BASE_URL`) and the
  AI Defense gateway (`AI_DEFENSE_ENDPOINT`) named in `configmap.yaml`; edit both if yours differ.
- Outbound TLS to the public internet for the Anthropic / Splunk paths if you enable them.

```bash
oc new-project pseudoco-assistant      # or: oc project <existing>
```

## 2. Secrets and the CA bundle (created out-of-band)

```bash
cd deploy/openshift
cp secret.example.env secret.env && $EDITOR secret.env        # ACCESS_KEY: openssl rand -hex 24
oc create secret generic pseudoco-assistant-secrets --from-env-file=secret.env
oc create configmap aid-ca --from-file=certs/aid-ingress-chain.pem
```

Why a chain and not a full bundle: `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` **replace** the
trust store rather than extend it, so a bundle holding only the gateway's chain would break
every public TLS call. The `ca-bundle` init container in `deployment.yaml` builds the real
bundle at pod start — the image's `certifi` roots plus this chain — into an `emptyDir` the app
mounts at `/app/certs`. Nothing environment-specific is baked into the image. If the gateway's
certificate is re-issued, replace `certs/aid-ingress-chain.pem`, re-create the ConfigMap
(`oc delete configmap aid-ca && oc create configmap aid-ca --from-file=…`) and restart the
Deployment.

## 3. Build and deploy

```bash
oc apply -f buildconfig.yaml
oc start-build pseudoco-assistant --follow      # the only way a build starts (no triggers)
oc apply -f configmap.yaml -f deployment.yaml
oc rollout status deployment/pseudoco-assistant
echo "https://$(oc get route pseudoco-assistant -o jsonpath='{.spec.host}')"
```

Verify:

```bash
URL="https://$(oc get route pseudoco-assistant -o jsonpath='{.spec.host}')"
KEY=$(grep '^ACCESS_KEY=' secret.env | cut -d= -f2)
curl -s "$URL/health"                                                   # {"status":"healthy", ...}
curl -s -u "x:$KEY" "$URL/api/settings/ai-provider" | python3 -m json.tool | grep -E '"provider"|base_url'
curl -s -u "x:$KEY" -X POST "$URL/api/chat/session" -H 'Content-Type: application/json' -d '{}'
oc logs deployment/pseudoco-assistant --tail=50 | grep -i 'ai defense\|inspect'
```

A chat turn from the UI (`$URL/app`, access key = `ACCESS_KEY`) must return the JSON-shaped
answer, not a `<think>` trace (that is `OPENAI_REASONING=False` working), and the governance
event must show `provider_name=openai` and the Nemotron model id.

## 4. Update, restart, scale

- New code: `oc start-build pseudoco-assistant --follow` then
  `oc rollout restart deployment/pseudoco-assistant` (`imagePullPolicy: Always`).
- Settings changed through the UI (`/settings-ui`, provider, keys, reasoning) live in the SQLite
  file on the PVC and win over the ConfigMap's boot defaults on the next start.
- **Do not scale past 1 replica**: the database is SQLite on a ReadWriteOnce PVC.
- `AI_DEFENSE_FAIL_OPEN` is `True` in `configmap.yaml` so the app answers while the gateway
  connection is being verified. Flip it to `False` once inspection is confirmed
  (`oc apply -f configmap.yaml && oc rollout restart deployment/pseudoco-assistant`).

## 5. Why the LLM goes through `provider=openai`

`provider=nvidia` is **local inference only**: `backend/nvidia_nim.py` rejects any base URL that
is not loopback, because that provider means "a NIM container on this host's GPU" and the UI
gates it on a detected GPU (`GET /api/server-info` → `gated.provider_nvidia`). A Nemotron served
elsewhere in the cluster (Ray Serve, vLLM, a remote NIM) is an OpenAI-compatible endpoint, so it
is configured as `AI_PROVIDER=openai` with `OPENAI_BASE_URL` pointing at it. Nemotron 3 defaults
"thinking" **on**, which wraps the JSON answer contract in a reasoning trace, so
`OPENAI_REASONING=False` sends `chat_template_kwargs.enable_thinking=false` — only to
self-hosted endpoints, never to `api.openai.com`. Any non-empty `OPENAI_API_KEY` satisfies the
Ray Serve endpoint; it does not gate on it.

## 6. Telemetry

There is no OpenTelemetry collector in the pod, so `OTEL_ENABLED` keeps its default (off).
To send traces, run a collector the pod can reach and add `OTEL_ENABLED: "True"` and
`OTEL_EXPORTER_OTLP_ENDPOINT` to `configmap.yaml`; the APM service name stays the code default
and `OTEL_RESOURCE_ATTRIBUTES` (`deployment.environment=pseudoco-assistant-openshift`) is what
separates this cluster from a laptop or an EC2 box in Splunk Observability Cloud. Governance
logs go to the local `logs/` directory and the SQLite database unless an HEC destination is
configured on the Settings page.

## 7. Cleanup

```bash
oc delete -f deployment.yaml -f configmap.yaml -f buildconfig.yaml
oc delete secret pseudoco-assistant-secrets configmap aid-ca
```
