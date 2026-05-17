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

## Dispatch API Interface Test

```bash
DISPATCH_TEST_EMAIL="<email>" \
DISPATCH_TEST_PASSWORD="<password>" \
DISPATCH_TEST_ORDER_ID="<order_id>" \
./scripts/integration/dispatch-api-tests.sh
```

Optional variables:

- `DISPATCH_API_BASE_URL`: API gateway base URL, defaults to local nginx from `env/dev.env`
- `DISPATCH_API_TESTS_ENABLED`: set to `false` to skip the CD API interface test
- `DISPATCH_TEST_WORKER_ID`: fixed worker id; otherwise the script picks the first available worker
- `DISPATCH_TEST_SERVICE_TYPE`, `DISPATCH_TEST_REGION`, `DISPATCH_TEST_AT_TIME`, `DISPATCH_TEST_LIMIT`: filters for `/api/dispatch/v1/workers/available`

Use a disposable or dedicated test order for `DISPATCH_TEST_ORDER_ID`; the manual assignment endpoint changes dispatch state.

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
- `Deploy Production`: manual-approved deploy to production via SSH

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
- `PROD_GATEWAY_JWT_SECRET`
- `PROD_API_BASE_URL`
- `DISPATCH_TEST_EMAIL`
- `DISPATCH_TEST_PASSWORD`
- `DISPATCH_TEST_ORDER_ID`
- `ALIYUN_REGISTRY`
- `ALIYUN_USERNAME`
- `ALIYUN_PASSWORD`
- `ALIYUN_NAMESPACE`
