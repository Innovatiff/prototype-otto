#!/usr/bin/env bash
# Deploys the Otto API to Cloud Run in northamerica-northeast1 (same region as
# Firestore). Run as `npm run deploy` from the repo root; requires gcloud auth.
#
# Overrides:
#   OTTO_PROJECT_ID  GCP project (default: current gcloud config)
#   OTTO_SERVICE     Cloud Run service name (default: otto-api)
set -euo pipefail

REGION="northamerica-northeast1"
SERVICE="${OTTO_SERVICE:-otto-api}"
REPOSITORY="otto"

PROJECT_ID="${OTTO_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "No GCP project configured. Run 'gcloud config set project <id>' or set OTTO_PROJECT_ID." >&2
  exit 1
fi

GIT_SHA="$(git rev-parse --short HEAD)"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${SERVICE}:${GIT_SHA}"

# One-time (idempotent, and cheap once they're on): every API this script and
# the running service touch. Without these the first deploy fails deep inside
# a gcloud call with an "API not enabled" link instead of a usable message.
echo "Ensuring required APIs are enabled..."
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  cloudscheduler.googleapis.com \
  secretmanager.googleapis.com \
  --project="${PROJECT_ID}" --quiet

# One-time: the Artifact Registry repository.
if ! gcloud artifacts repositories describe "${REPOSITORY}" \
    --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Creating Artifact Registry repository '${REPOSITORY}' in ${REGION}..."
  gcloud artifacts repositories create "${REPOSITORY}" \
    --repository-format=docker --location="${REGION}" --project="${PROJECT_ID}"
fi

echo "Building ${IMAGE} with Cloud Build..."
gcloud builds submit \
  --project="${PROJECT_ID}" \
  --config=server/cloudbuild.yaml \
  --substitutions=_IMAGE="${IMAGE}" \
  .

# Auth happens at the app layer (Firebase ID tokens verified on every request),
# so the Cloud Run service itself allows unauthenticated invocations.
echo "Deploying ${SERVICE} to Cloud Run (${REGION})..."
# --update-env-vars, never --set-env-vars: --set REPLACES the whole environment,
# which would wipe SCHEDULER_INVOKER/SCHEDULER_AUDIENCE (and anything set by
# hand) on every redeploy and leave the tick route failing closed until the
# update below landed.
gcloud run deploy "${SERVICE}" \
  --project="${PROJECT_ID}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --allow-unauthenticated \
  --update-env-vars=NODE_ENV=production

SERVICE_URL="$(gcloud run services describe "${SERVICE}" --project="${PROJECT_ID}" --region="${REGION}" --format='value(status.url)')"

# ── Secrets ──────────────────────────────────────────────────────────
# The service reads secrets from Secret Manager at cold start (see
# src/secrets/index.ts), under the identity Cloud Run runs it as. Grant that
# identity read access to the secrets that exist, and name the ones that
# don't — an absent ANTHROPIC_API_KEY means every model call 500s, and an
# absent REVENUECAT_WEBHOOK_SECRET means the webhook refuses every event.
RUNTIME_SA="$(gcloud run services describe "${SERVICE}" --project="${PROJECT_ID}" --region="${REGION}" --format='value(spec.template.spec.serviceAccountName)')"
if [[ -z "${RUNTIME_SA}" ]]; then
  PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
  RUNTIME_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
fi

MISSING_SECRETS=()
for SECRET_NAME in ANTHROPIC_API_KEY REVENUECAT_WEBHOOK_SECRET VOYAGE_API_KEY; do
  if gcloud secrets describe "${SECRET_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
      --project="${PROJECT_ID}" \
      --member="serviceAccount:${RUNTIME_SA}" \
      --role="roles/secretmanager.secretAccessor" \
      --quiet >/dev/null
  else
    MISSING_SECRETS+=("${SECRET_NAME}")
  fi
done
if (( ${#MISSING_SECRETS[@]} > 0 )); then
  echo
  echo "NOT CONFIGURED: ${MISSING_SECRETS[*]}"
  echo "Create each one, then re-run this script so it can grant access:"
  for SECRET_NAME in "${MISSING_SECRETS[@]}"; do
    echo "  printf %s 'THE_VALUE' | gcloud secrets create ${SECRET_NAME} --project=${PROJECT_ID} --data-file=-"
  done
  echo
fi

# ── Automations scheduler ────────────────────────────────────────────
# Cloud Scheduler fires POST /automations/tick every 5 minutes with an OIDC
# token minted for a dedicated invoker service account. The service is
# publicly reachable, so the route verifies the token at the app layer:
# SCHEDULER_INVOKER (who may call) and SCHEDULER_AUDIENCE (what the token
# must be minted for) arm that check — without them the route fails closed.
INVOKER_SA="otto-scheduler-invoker"
INVOKER_EMAIL="${INVOKER_SA}@${PROJECT_ID}.iam.gserviceaccount.com"
TICK_URL="${SERVICE_URL}/automations/tick"

if ! gcloud iam service-accounts describe "${INVOKER_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Creating scheduler invoker service account ${INVOKER_EMAIL}..."
  gcloud iam service-accounts create "${INVOKER_SA}" \
    --project="${PROJECT_ID}" \
    --display-name="Otto automations tick invoker"
fi

echo "Arming the tick guard (SCHEDULER_INVOKER, SCHEDULER_AUDIENCE)..."
gcloud run services update "${SERVICE}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --update-env-vars="SCHEDULER_INVOKER=${INVOKER_EMAIL},SCHEDULER_AUDIENCE=${TICK_URL}" \
  --quiet >/dev/null

SCHEDULER_ARGS=(
  --project="${PROJECT_ID}"
  --location="${REGION}"
  --schedule="*/5 * * * *"
  --uri="${TICK_URL}"
  --http-method=POST
  --oidc-service-account-email="${INVOKER_EMAIL}"
  --oidc-token-audience="${TICK_URL}"
  --attempt-deadline=600s
)
if gcloud scheduler jobs describe otto-automations-tick \
    --project="${PROJECT_ID}" --location="${REGION}" >/dev/null 2>&1; then
  echo "Updating Cloud Scheduler job otto-automations-tick..."
  gcloud scheduler jobs update http otto-automations-tick "${SCHEDULER_ARGS[@]}" --quiet >/dev/null
else
  echo "Creating Cloud Scheduler job otto-automations-tick (every 5 minutes)..."
  gcloud scheduler jobs create http otto-automations-tick "${SCHEDULER_ARGS[@]}" --quiet >/dev/null
fi

echo "Done. Service URL:"
echo "${SERVICE_URL}"
