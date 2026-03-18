# HSP-Infra

HSP-Infra is an assembly-only repository for running the full system together:

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

## Start DB Only (Local Backend Dev)

```bash
./scripts/db-up.sh
```

This starts only `mysql` from compose so you can run one backend service locally.

## Environment Files

- `env/dev.env`: local compose variables and host port mapping
- `env/prod.env`: production compose variables
- `env/image-tags.env`: per-service image and tag (tracked by infra)

## Gateway Routes

- `/api/users/*` -> `user-service`
- `/api/orders/*` -> `order-service`
- `/api/dispatch/*` -> `dispatch-service`
- `/api/payment/*` -> `payment-settlement-service`
- `/api/execution/*` -> `execution-record-service`
- `/api/schedule/*` -> `worker-schedule-service`
- `/` -> `frontend`

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
      "service": "user-service",
      "image": "ghcr.io/nus-iss-capstone-hsp/user-service",
      "tag": "v1.2.3"
    }
  }'
```

## Production Secrets (GitHub Actions)

Set these repository/environment secrets before enabling production deployment:

- `PROD_SSH_HOST`
- `PROD_SSH_USER`
- `PROD_SSH_KEY`
- `PROD_SSH_PORT` (optional, default 22)
- `PROD_INFRA_PATH` (absolute path of infra repo on target host)
