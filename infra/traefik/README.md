# Traefik reverse proxy stack

This directory contains a Docker Compose project that runs Traefik v2 with a test `whoami` service. Traefik is configured to obtain Let's Encrypt certificates for the provided domain and to expose the `whoami` service over HTTPS.

## Usage

1. Copy `.env.example` to `.env` and adjust the values:

   ```bash
   cp .env.example .env
   sed -i 's/meteor.crabdance.com/<your-domain>/' .env
   sed -i 's/admin@example.com/<your-email>/' .env
   ```

2. Create the volume directory that stores ACME data and ensure it has the correct permissions:

   ```bash
   mkdir -p letsencrypt
   install -m 600 /dev/null letsencrypt/acme.json
   ```

3. Start the stack:

   ```bash
   docker compose --env-file .env up -d
   ```

   Traefik will listen on ports 80 and 443. The `whoami` service will be available at `https://<your-domain>/`.

4. Check the status:

   ```bash
   docker compose ps
   docker compose logs -f traefik
   ```

Certificates are stored in `letsencrypt/acme.json`. Keep this file secure; it contains the private key for your certificates.
