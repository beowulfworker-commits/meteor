# Meteor infrastructure

This repository contains infrastructure automation for deploying the Meteor playground services.

## Traefik reverse proxy stack

A Docker Compose project that exposes Traefik with a test `whoami` service lives in [`infra/traefik`](infra/traefik/README.md). The stack provisions Let's Encrypt certificates for `https://${DOMAIN}` and is intended to run on a host reachable at `${HOST_IP}`.

To roll it out automatically from CI, use the helper script [`scripts/deploy_traefik_stack.sh`](scripts/deploy_traefik_stack.sh). The script expects the following environment variables to be provided by the pipeline:

- `GIT_REPO` – Git repository URL (e.g. `https://github.com/beowulfworker-commits/meteor.git`)
- `SSH_USER` – SSH user for the target server (`root`)
- `HOST_IP` – public IP of the server (`37.221.125.161`)
- `DOMAIN` – domain name pointing to the server (`meteor.crabdance.com`)
- `LETSENCRYPT_EMAIL` – e-mail used for the Let's Encrypt account (`beo.wulf.worker@gmail.com`)

The script installs Docker when necessary, clones the repository into `/opt/meteor`, prepares the Traefik environment file, starts the stack, and waits for a successful HTTPS response with a valid certificate.
