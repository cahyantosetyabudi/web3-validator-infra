#!/usr/bin/env bash
# Generate the shared JWT secret for the Engine API (geth <-> lighthouse auth).
# Run once before first `docker compose up`. The file is gitignored.
set -euo pipefail
mkdir -p secrets
if [ -f secrets/jwt.hex ]; then
  echo "secrets/jwt.hex already exists, refusing to overwrite."
  exit 1
fi
openssl rand -hex 32 > secrets/jwt.hex
chmod 600 secrets/jwt.hex
echo "wrote secrets/jwt.hex"
