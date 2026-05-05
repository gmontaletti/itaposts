#!/usr/bin/env bash
# Costruisce dist/itaposts-cron-<versione>.zip — bundle monolitico
# auto-contenuto per installazione su una macchina Linux/macOS pulita.
#
# Contenuto del bundle:
#   - itaposts_<versione>.tar.gz       sorgente del pacchetto R
#   - vendor/                          mirror CRAN locale dei deps (source)
#   - vendor/PACKAGES                  metadata generato da tools::write_PACKAGES
#   - install.sh                       installer idempotente, offline-first
#   - cron/sync_oja.R, run_sync.sh,    runtime cron + template .Renviron
#     crontab.example, .Renviron.template
#   - README.md
#
# Esclusioni garantite per costruzione: lo stage si popola solo con copie
# esplicite e R CMD build rispetta .Rbuildignore (no .Renviron reale,
# no ITC4_*.zip, no .Rproj.user, no .claude, no .git, no DuckDB).
#
# Cache: i tarball CRAN vengono scaricati una volta in tools/vendor-cache/
# (gitignored) e riutilizzati nei build successivi se la versione coincide.

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
CACHE="$PKG_ROOT/tools/vendor-cache"

# Skip vendoring quando esplicitamente richiesto (build più rapido per test).
WITH_VENDOR="${WITH_VENDOR:-1}"

rm -rf "$STAGE" "$DIST/${NAME}.zip"
mkdir -p "$STAGE/cron" "$CACHE"

echo "==> R CMD build (può richiedere alcuni secondi)"
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

if [ "$WITH_VENDOR" = "1" ]; then
  echo "==> Vendoring CRAN deps (closure su Imports/Depends/LinkingTo)"
  mkdir -p "$STAGE/vendor"
  CACHE_DIR="$CACHE" STAGE_DIR="$STAGE/vendor" Rscript --vanilla - <<'RSCRIPT'
cache <- Sys.getenv("CACHE_DIR")
out   <- Sys.getenv("STAGE_DIR")
deps_top <- c("cli","data.table","DBI","dplyr","dbplyr","duckdb","processx","rlang")
ap <- available.packages(repos = "https://cloud.r-project.org")
closure <- unique(c(
  deps_top,
  unlist(tools::package_dependencies(
    deps_top, db = ap,
    which = c("Depends","Imports","LinkingTo"),
    recursive = TRUE
  ))
))
# Escludi i pacchetti base/recommended (forniti con R).
base_pkgs <- rownames(installed.packages(priority = c("base","recommended")))
closure <- setdiff(closure, base_pkgs)
closure <- intersect(closure, rownames(ap))
message("Closure: ", length(closure), " pacchetti")

# Per ogni dep: usa la copia in cache se la versione coincide, altrimenti
# scarica il tarball sorgente in cache; poi copia in stage.
for (pkg in closure) {
  ver <- ap[pkg, "Version"]
  fname <- sprintf("%s_%s.tar.gz", pkg, ver)
  cached <- file.path(cache, fname)
  if (!file.exists(cached)) {
    message("  download ", fname)
    download.packages(pkg, destdir = cache, repos = "https://cloud.r-project.org",
                      type = "source", quiet = TRUE)
  } else {
    message("  cache hit ", fname)
  }
  file.copy(cached, file.path(out, fname), overwrite = TRUE)
}
tools::write_PACKAGES(out, type = "source")
message("Vendor pronto: ", length(list.files(out, pattern = "\\.tar\\.gz$")),
        " tarball + PACKAGES")
RSCRIPT
  echo "==> Vendor:"
  du -sh "$STAGE/vendor" | sed 's/^/    /'
else
  echo "==> Vendoring saltato (WITH_VENDOR=0)"
fi

echo "==> Zip finale"
( cd "$DIST" && zip -rq "${NAME}.zip" "$NAME" )

echo "==> $DIST/${NAME}.zip"
ls -lh "$DIST/${NAME}.zip"
