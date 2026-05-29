FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install system dependencies (curl for APNs HTTP/2 push)
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# 🔴 hacker-audit 2026-05-19: run as a non-root user.
# Previously the container ran the uvicorn process as UID 0. If the
# app (or any dependency) were to ever hit RCE, the attacker would
# have full container privileges — read every secret mounted into
# the container (encryption.key, APNs .p8, Secret Manager
# materializations), exec arbitrary binaries, and pivot off the
# pod. Cloud Run blocks most outbound but in-container attacks
# (memory dump, /proc/self/environ for env-var secrets) stay open.
# Standard hardening: create a dedicated low-priv user, chown the
# app dir, drop to it for the CMD.
RUN groupadd -r raven && useradd -r -g raven -d /app -s /bin/false raven \
    && chown -R raven:raven /app
USER raven

# Cloud Run uses PORT environment variable
ENV PORT=8080

# Expose port
EXPOSE 8080

# Run uvicorn
CMD exec uvicorn main:app --host 0.0.0.0 --port $PORT --workers 1
