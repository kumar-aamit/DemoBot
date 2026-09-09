# =============================================================================
# NemoClaw sandbox image for the PseudoCo Assistant agentic-risk demo
# =============================================================================
# NVIDIA NemoClaw runs OpenClaw inside an OpenShell sandbox. Custom OpenClaw
# plugins are baked into a custom sandbox image and the sandbox is created from
# it with `nemoclaw onboard --from nemoclaw/Dockerfile` (the Dockerfile's parent
# directory is the build context). This image = NemoClaw's pinned OpenClaw
# sandbox + PseudoCo Assistant's governance seat (the pseudoco-assistant-toolguard plugin), so every
# tool call the sandboxed agent makes is inspected by /api/toolguard/inspect
# and every OpenShell denial is reported back (after_tool_call + OCSF tail).
#
# Build context: run-nemoclaw.sh materialises the plugin from git
# (`git archive HEAD:openclaw/plugins/pseudoco-assistant-toolguard`) into
# nemoclaw/plugins/pseudoco-assistant-toolguard/ for the duration of the build and removes
# it afterwards — openclaw/ is sparse-excluded on the Mac (EDR).
#
# Pin: the digest NemoClaw's blueprint.yaml pins (OpenShell 0.0.106, OpenClaw
# 2026.3.11+). Bump deliberately together with NEMOCLAW_INSTALL_REF in
# run-nemoclaw.sh; the plugin's peer range is checked at install time.
# =============================================================================
ARG NEMOCLAW_SANDBOX_IMAGE=ghcr.io/nvidia/openshell-community/sandboxes/openclaw:latest
FROM ${NEMOCLAW_SANDBOX_IMAGE}

# Plugin config (guardUrl / accessKey / agentSurface) is written at onboarding
# by run-nemoclaw.sh through build args, so the image itself holds no secret
# when built without them.
ARG PSEUDOCO_ASSISTANT_GUARD_URL=http://127.0.0.1:8001
ARG PSEUDOCO_ASSISTANT_ACCESS_KEY=
ARG PSEUDOCO_ASSISTANT_FAIL_OPEN=false

USER root
COPY plugins/pseudoco-assistant-toolguard/ /opt/pseudoco-assistant-toolguard/
RUN test ! -e /opt/pseudoco-assistant-toolguard/node_modules/openclaw \
 && chown -R sandbox:sandbox /opt/pseudoco-assistant-toolguard || true

# Install + enable the plugin the way NemoClaw documents for custom images
# (docs/deployment/install-openclaw-plugins.mdx): the local install copies the
# staged plugin into OpenClaw's extensions tree, `enable` updates openclaw.json,
# and the managed runtime's config hash is refreshed afterwards.
USER sandbox
RUN HOME=/sandbox openclaw plugins install /opt/pseudoco-assistant-toolguard \
 && HOME=/sandbox openclaw plugins enable pseudoco-assistant-toolguard \
 && HOME=/sandbox node -e ' \
      const fs=require("fs"); const p="/sandbox/.openclaw/openclaw.json"; \
      const c=JSON.parse(fs.readFileSync(p,"utf8")); \
      c.plugins=c.plugins||{}; c.plugins.entries=c.plugins.entries||{}; \
      c.plugins.entries["pseudoco-assistant-toolguard"]={enabled:true,config:{ \
        guardUrl:process.env.PSEUDOCO_ASSISTANT_GUARD_URL, accessKey:process.env.PSEUDOCO_ASSISTANT_ACCESS_KEY, \
        failOpen:process.env.PSEUDOCO_ASSISTANT_FAIL_OPEN==="true", timeoutMs:8000, agentSurface:"nemoclaw"}}; \
      fs.writeFileSync(p, JSON.stringify(c,null,2));' \
 && sha256sum /sandbox/.openclaw/openclaw.json > /sandbox/.openclaw/.config-hash
ENV PSEUDOCO_ASSISTANT_GUARD_URL=${PSEUDOCO_ASSISTANT_GUARD_URL} \
    PSEUDOCO_ASSISTANT_ACCESS_KEY=${PSEUDOCO_ASSISTANT_ACCESS_KEY} \
    PSEUDOCO_ASSISTANT_FAIL_OPEN=${PSEUDOCO_ASSISTANT_FAIL_OPEN}
