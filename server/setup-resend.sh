#!/usr/bin/env bash
#
# setup-resend.sh
#
# One-shot installer for the RESEND_API_KEY secret on RAVEN's Cloud Run
# backend. Reads the key INTERACTIVELY (never echoed, never on the
# command line, never logged) and wires it into:
#   1. Google Secret Manager (creates secret OR adds new version)
#   2. The Cloud Run service account's IAM
#   3. The raven-server Cloud Run service env (RESEND_API_KEY +
#      RESEND_FROM_EMAIL)
#
# Then triggers a redeploy and prints the tail of logs so you can
# confirm Resend is sending mail.
#
# Usage:
#   bash /Users/ahmd/hybrid_messenger/server/setup-resend.sh
#
# Safety: the script unsets RESEND_KEY at exit (trap) so it never
# lingers in shell history or env.

set -e

PROJECT_ID="hybrid-messenger-backend"
REGION="europe-west1"
SERVICE_NAME="raven-server"
SECRET_NAME="RESEND_API_KEY"
FROM_EMAIL="${RESEND_FROM_EMAIL:-no-reply@raven-messager.com}"

# Trap to scrub the key from env on ANY exit path.
cleanup() {
  unset RESEND_KEY
}
trap cleanup EXIT INT TERM

echo "🔧 RAVEN Resend setup"
echo "    Project: $PROJECT_ID"
echo "    Region:  $REGION"
echo "    Service: $SERVICE_NAME"
echo "    Secret:  $SECRET_NAME"
echo "    From:    $FROM_EMAIL"
echo ""

# Sanity: gcloud is installed and authenticated.
if ! command -v gcloud >/dev/null 2>&1; then
  echo "❌ gcloud not found on PATH. Install Cloud SDK first."
  exit 1
fi
if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q '@'; then
  echo "❌ gcloud is not authenticated. Run 'gcloud auth login' first."
  exit 1
fi

# 1) Prompt for the API key — SILENT input (no echo, no history).
echo ""
echo "📋 Paste your Resend API key (input HIDDEN — nothing will appear on screen):"
read -r -s RESEND_KEY
echo ""

# Basic format check — Resend keys start with "re_".
if [[ -z "$RESEND_KEY" ]]; then
  echo "❌ Empty input. Aborting."
  exit 1
fi
if [[ "$RESEND_KEY" != re_* ]]; then
  echo "❌ Key doesn't look like a Resend key (expected prefix 're_'). Aborting."
  exit 1
fi
echo "✅ Got key (${#RESEND_KEY} chars, prefix re_)"

# 2) Create OR add-new-version of the secret.
echo ""
echo "🔐 Provisioning Secret Manager entry..."
if gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "   Secret '$SECRET_NAME' already exists — adding a new version."
  printf '%s' "$RESEND_KEY" | gcloud secrets versions add "$SECRET_NAME" \
    --data-file=- \
    --project="$PROJECT_ID" >/dev/null
  echo "   ✅ New version added."
else
  echo "   Secret '$SECRET_NAME' not found — creating."
  printf '%s' "$RESEND_KEY" | gcloud secrets create "$SECRET_NAME" \
    --data-file=- \
    --project="$PROJECT_ID" \
    --replication-policy=automatic >/dev/null
  echo "   ✅ Secret created."
fi

# Wipe the key from shell var as soon as the Secret Manager write is done.
# (The trap will repeat this on exit; doing it now closes the window.)
unset RESEND_KEY

# 3) Grant the Cloud Run runtime service account read access.
echo ""
echo "🔑 Granting Cloud Run service account access to the secret..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SA_EMAIL="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$PROJECT_ID" >/dev/null
echo "   ✅ Binding ensured for ${SA_EMAIL}"

# 4) Update Cloud Run service: mount the secret as env var + set FROM_EMAIL.
echo ""
echo "🚀 Updating Cloud Run service '$SERVICE_NAME'..."
gcloud run services update "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --update-secrets="${SECRET_NAME}=${SECRET_NAME}:latest" \
  --update-env-vars="RESEND_FROM_EMAIL=${FROM_EMAIL}" \
  --quiet >/dev/null
echo "   ✅ Service updated. A new revision is rolling out."

# 5) Verify the revision is serving and Resend is configured.
echo ""
echo "⏳ Waiting ~30s for the revision to receive traffic..."
sleep 30

REVISION=$(gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format='value(status.latestReadyRevisionName)')
echo "   Latest ready revision: $REVISION"

echo ""
echo "📜 Tailing recent logs for Resend activity..."
gcloud run services logs read "$SERVICE_NAME" \
  --limit=80 \
  --project="$PROJECT_ID" \
  --region="$REGION" 2>&1 \
  | grep -iE "resend|email otp|password reset|notification_service" \
  | tail -20 \
  || true

echo ""
echo "✅ DONE."
echo ""
echo "Next steps to verify end-to-end:"
echo "  1. Trigger a forgot-password from the iOS app."
echo "  2. Re-run the log tail:"
echo "       gcloud run services logs read $SERVICE_NAME \\"
echo "         --limit=30 --project=$PROJECT_ID --region=$REGION \\"
echo "         | grep -iE 'resend|email'"
echo "  3. Expected success lines:"
echo "       ✅ Using Resend for emails"
echo "       ✅ [Resend] Email sent to xxx*** | message_id=..."
echo "  4. Check your inbox (and spam folder)."
