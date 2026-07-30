# Build context is the REPO ROOT (the server depends on the shared workspace):
#   docker build -f server/Dockerfile .
# server/deploy.sh and cloudbuild.yaml both do this.

# ── Build stage ──────────────────────────────────────────────────────
FROM node:22-slim AS build
WORKDIR /app

# Manifests first so dependency layers cache across source-only changes.
COPY package.json package-lock.json ./
COPY shared/package.json shared/
COPY server/package.json server/
RUN npm ci

COPY shared/ shared/
COPY server/ server/
RUN npm run build -w @otto/shared \
 && npm run build -w @otto/server \
 && npm prune --omit=dev

# ── Runtime stage ────────────────────────────────────────────────────
FROM node:22-slim
ENV NODE_ENV=production
WORKDIR /app

# node_modules keeps the @otto/shared workspace symlink, so shared/ must land
# at the same relative path with its package.json (exports map) and dist/.
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/shared/package.json ./shared/package.json
COPY --from=build /app/shared/dist ./shared/dist
COPY --from=build /app/server/package.json ./server/package.json
COPY --from=build /app/server/dist ./server/dist

# node:22-slim ships an unprivileged `node` user — never run as root.
USER node

# Cloud Run injects PORT; 8080 is the conventional default.
ENV PORT=8080
EXPOSE 8080

CMD ["node", "server/dist/index.js"]
