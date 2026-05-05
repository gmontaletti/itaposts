#!/usr/bin/env bash
# Wrapper host invocato dal cron. Lancia un container one-shot itaposts che
# esegue oja_sync() e termina. Lo stato persistente (DuckDB, snapshot scaricati,
# lock file) vive sul host sotto $ITAPOSTS_STATE_ROOT e viene bind-montato.
#
# La concorrenza fra run e' protetta in due modi:
#   1. --name itaposts-sync: un secondo invocazione mentre la prima e' viva
#      esce subito con "container name already in use".
#   2. Lock file in $ITAPOSTS_STATE_ROOT/run/sync_oja.lock gestito dal pacchetto.

set -euo pipefail

IMAGE="${ITAPOSTS_IMAGE:-ghcr.io/gmontaletti/itaposts:latest}"
ENV_FILE="${ITAPOSTS_ENV_FILE:-/etc/itaposts/itaposts.env}"
STATE_ROOT="${ITAPOSTS_STATE_ROOT:-/var/itaposts}"

if [ ! -r "$ENV_FILE" ]; then
  echo "ERRORE: $ENV_FILE non esiste o non leggibile da $(id -un)." >&2
  exit 1
fi

mkdir -p "$STATE_ROOT/shared" "$STATE_ROOT/incoming" "$STATE_ROOT/run"

exec docker run --rm \
  --name itaposts-sync \
  --user "$(id -u):$(id -g)" \
  --env-file "$ENV_FILE" \
  -v "$STATE_ROOT/shared":/var/itaposts/shared \
  -v "$STATE_ROOT/incoming":/var/itaposts/incoming \
  -v "$STATE_ROOT/run":/var/itaposts/run \
  "$IMAGE"
