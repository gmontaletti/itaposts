#!/usr/bin/env bash
# Wrapper invocato dal cron. Cron parte con PATH minimale e senza profilo
# utente: qui forziamo PATH, cwd, HOME e logging su file.

set -u

# Risolvi la cartella dello script (segue link simbolici).
SCRIPT_DIR="$(cd "$(dirname "$(readlink "$0" 2>/dev/null || echo "$0")")" && pwd)"
cd "$SCRIPT_DIR"

# PATH ragionevole su macOS (Apple Silicon e Intel) e Linux.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# HOME deve esistere: alcune launchd/cron non la impostano.
if [ -z "${HOME:-}" ]; then
  HOME_FALLBACK="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || true)"
  export HOME="${HOME_FALLBACK:-/tmp}"
fi

LOG_DIR="${ITAPOSTS_LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/sync_$(date +%Y%m%d).log"

RSCRIPT="$(command -v Rscript || true)"
if [ -z "$RSCRIPT" ]; then
  echo "[$(date -Iseconds 2>/dev/null || date)] ERROR Rscript non trovato in PATH=$PATH" >&2
  exit 127
fi

{
  echo "[$(date -Iseconds 2>/dev/null || date)] INFO  cwd=$SCRIPT_DIR Rscript=$RSCRIPT"
} >> "$LOG_FILE"

"$RSCRIPT" --vanilla "$SCRIPT_DIR/sync_oja.R" >> "$LOG_FILE" 2>&1
rc=$?

echo "[$(date -Iseconds 2>/dev/null || date)] INFO  exit=$rc" >> "$LOG_FILE"
exit "$rc"
