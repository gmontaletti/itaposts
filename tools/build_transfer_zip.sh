#!/usr/bin/env bash
# Costruisce dist/itaposts-cron-<versione>.zip dalla root del repo.
# Le esclusioni (.Renviron reale, ITC4_*.zip, .Rproj.user, .claude, .git,
# DuckDB esistente) sono garantite per costruzione: lo stage si popola solo
# con copie esplicite e R CMD build rispetta .Rbuildignore.

set -euo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG_ROOT"

if ! command -v R       >/dev/null; then echo "ERRORE: R non in PATH"       >&2; exit 1; fi
if ! command -v Rscript >/dev/null; then echo "ERRORE: Rscript non in PATH" >&2; exit 1; fi
if ! command -v zip     >/dev/null; then echo "ERRORE: zip non in PATH"     >&2; exit 1; fi

VERSION="$(awk -F': *' '/^Version:/ {print $2; exit}' DESCRIPTION)"
if [ -z "$VERSION" ]; then
  echo "ERRORE: impossibile estrarre Version dal DESCRIPTION." >&2
  exit 1
fi

NAME="itaposts-cron-${VERSION}"
DIST="$PKG_ROOT/dist"
STAGE="$DIST/$NAME"

rm -rf "$STAGE" "$DIST/${NAME}.zip"
mkdir -p "$STAGE/cron"

echo "==> R CMD build (puo' richiedere alcuni secondi)"
( cd "$DIST" && R CMD build "$PKG_ROOT" >/dev/null )
mv "$DIST"/itaposts_*.tar.gz "$STAGE/"

echo "==> Copia script cron"
cp "$PKG_ROOT/inst/cron/sync_oja.R"         "$STAGE/cron/"
cp "$PKG_ROOT/inst/cron/run_sync.sh"        "$STAGE/cron/"
cp "$PKG_ROOT/inst/cron/crontab.example"    "$STAGE/cron/"
cp "$PKG_ROOT/inst/cron/.Renviron.template" "$STAGE/cron/"

echo "==> Copia README e installer"
cp "$PKG_ROOT/inst/cron/README.md"       "$STAGE/README.md"
cp "$PKG_ROOT/tools/install.sh.template" "$STAGE/install.sh"

chmod +x "$STAGE/cron/run_sync.sh" "$STAGE/install.sh"

echo "==> Zip finale"
( cd "$DIST" && zip -rq "${NAME}.zip" "$NAME" )

echo "==> $DIST/${NAME}.zip"
ls -lh "$DIST/${NAME}.zip"
