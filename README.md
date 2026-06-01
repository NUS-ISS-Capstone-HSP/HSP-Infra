# HSP-Infra

HSP-Infra is an assembly-only repository for running the full system together:

- api-gateway
- user-service
- order-service
- worker-schedule-service
- dispatch-service
- execution-record-service
- payment-settlement-service
- frontend
- mysql
- nginx

## Quick Start (Dev)

```bash
cp env/image-tags.env.example env/image-tags.env
./scripts/dev-up.sh
./scripts/integration/smoke-tests.sh
./scripts/dev-down.sh --volumes
```

## Frontend Smoke Test

```bash
npm ci
npx playwright install chromium firefox webkit chrome
npm run test:smoke
```

## Bruno API Interface Test

```bash
BRUNO_API_BASE_URL="http://127.0.0.1:8080" \
./scripts/integration/bruno-api-tests.sh
```

Optional variables:

- `BRUNO_API_BASE_URL`: API gateway base URL, defaults to local nginx from `env/dev.env`
- `BRUNO_HEALTH_PATH`: health endpoint path, defaults to `/api/healthz` for nginx and `/healthz` for direct `:8081` gateway URLs
- `BRUNO_API_TESTS_ENABLED`: set to `false` to skip the CD API interface test
- `BRUNO_CLI_PACKAGE`: Bruno CLI package spec, defaults to `@usebruno/cli@2.10.1`
- `API_TEST_REPORT_DIR`: report output directory, defaults to `reports/api-interface`

The Bruno collection lives in `bruno/hsp-core-flow` and follows the core flow in `API_DOCUMENTATION.md`: register/login test users, prepare an available worker, create an order, assign a worker, accept and execute service, confirm payment, close the order, then verify order detail, dispatch history, service record, and payment records.

## Gateway Health Check

```bash
GATEWAY_HEALTH_BASE_URL="http://127.0.0.1:8080" \
./scripts/integration/gateway-health-check.sh
```

Optional variables:

- `GATEWAY_HEALTH_BASE_URL`: API gateway base URL, defaults to `PROD_API_BASE_URL`, `BRUNO_API_BASE_URL`, or local nginx from `env/dev.env`
- `GATEWAY_HEALTH_PATH`: health endpoint path, defaults to `/api/healthz` for nginx and `/healthz` for direct `:8081` gateway URLs
- `GATEWAY_HEALTH_TIMEOUT_SECONDS`: total wait time, defaults to `180`
- `GATEWAY_HEALTH_INTERVAL_SECONDS`: retry interval, defaults to `5`
- `GATEWAY_HEALTH_REPORT_DIR`: report output directory, defaults to `reports/gateway-health`

## Start DB Only (Local Backend Dev)

```bash
./scripts/db-up.sh
```

This starts only `mysql` from compose so you can run one backend service locally.

## Start DB in Debug Mode (Expose 3306 to Host)

```bash
./scripts/db-debug-up.sh
```

This starts only `mysql` and maps container MySQL port to host:

- host: `localhost:${MYSQL_HOST_PORT}`
- container: `${MYSQL_PORT}`

Default from `env/dev.env` is `localhost:3306`.

## Environment Files

- `env/dev.env`: local compose variables and host port mapping
- `env/prod.env`: production compose variables
- `env/image-tags.env`: per-service image and tag (tracked by infra)

## Gateway Routes

- `/api/*` -> `api-gateway`
- `/docs` -> `api-gateway:/docs`
- `/redoc` -> `api-gateway:/redoc`
- `/openapi.json` -> `api-gateway:/openapi.json`
- `api-gateway` calls backend services over gRPC:
  - `user-service:50051`
  - `order-service:50052`
  - `payment-settlement-service:50053`
  - `dispatch-service:50054`
  - `worker-schedule-service:50055`
- `/api/healthz` -> `api-gateway:/healthz`

## CI/CD Workflows

- `CI Integration`: starts compose, waits health, runs smoke + order flow checks
- `Update Image Tag`: updates one service tag from `repository_dispatch` payload
- `Deploy Production`: manual-approved deploy to production via SSH, then runs gateway health check, Bruno API tests, frontend smoke tests, and publishes a deployment verification summary with image manifest

### repository_dispatch Example

```bash
curl -X POST \
  -H "Authorization: Bearer <GITHUB_TOKEN>" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/NUS-ISS-Capstone-HSP/HSP-Infra/dispatches \
  -d '{
    "event_type": "image-published",
    "client_payload": {
      "service": "api-gateway",
      "image": "ghcr.io/nus-iss-capstone-hsp/api-gateway",
      "tag": "v1.2.3"
    }
  }'
```

## Production Secrets (GitHub Actions)

Set these Organization secrets and grant this repository access before enabling production deployment:

- `PROD_SSH_HOST`
- `PROD_SSH_USER`
- `PROD_SSH_KEY`
- `PROD_SSH_PORT` (optional, default 22)
- `PROD_INFRA_PATH` (absolute path of infra repo on target host)
- `PROD_GATEWAY_JWT_SECRET` (shared by api-gateway and user-service JWT signing)
- `PROD_API_BASE_URL`
- `PROD_WEB_BASE_URL` (optional, defaults frontend smoke tests to `PROD_API_BASE_URL`)
- `ALIYUN_REGISTRY`
- `ALIYUN_USERNAME`
- `ALIYUN_PASSWORD`
- `ALIYUN_NAMESPACE`
