# =============================================================================
# PseudoCo Assistant v4 Container Image
# =============================================================================
# Supports dual-environment deployment:
# - AI_PROVIDER=anthropic: Local development with Anthropic API
# - AI_PROVIDER=bedrock: AWS production with Amazon Bedrock
# =============================================================================

FROM python:3.11-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY backend/ ./backend/
COPY frontend/ ./frontend/

# Non-root user, built for arbitrary UIDs. OpenShift ignores USER at runtime and
# runs the container as a random UID that is always a member of group 0
# ("Support Arbitrary User IDs", deploy/openshift/README.md), so /app is handed
# to group 0 with the owner's rights (chmod g=u) instead of being chown'ed to
# appuser. appuser's primary group is 0 as well, so podman/docker (which do
# honour USER) get the same permissions locally. HOME=/app because
# /home/appuser is not group-writable and some libraries (boto3, pip) fall back
# to $HOME for cache/config.
RUN useradd --create-home --shell /bin/bash --gid 0 appuser && \
    mkdir -p logs data && \
    chgrp -R 0 /app && \
    chmod -R g=u /app
ENV HOME=/app
USER appuser

# Expose the application port
EXPOSE 8001

# Health check (docker/podman only — Kubernetes/OpenShift ignore this and use
# the probes in deploy/openshift/deployment.yaml instead).
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8001/health')" || exit 1

# umask 0002 so files the app creates at runtime (the SQLite db, log files) are
# group-writable: on a PVC a pod restart lands a new arbitrary UID that only
# shares the volume's group, not the previous UID.
CMD ["sh", "-c", "umask 0002 && exec python -m backend.main"]
