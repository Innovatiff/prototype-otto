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
gcloud run deploy "${SERVICE}" \
  --project="${PROJECT_ID}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --allow-unauthenticated \
  --set-env-vars=NODE_ENV=production

echo "Done. Service URL:"
gcloud run services describe "${SERVICE}" --project="${PROJECT_ID}" --region="${REGION}" --format='value(status.url)'
