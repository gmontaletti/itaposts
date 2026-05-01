#!/usr/bin/env Rscript

# 1. Ambiente -----------------------------------------------------------------
# Entry point unattended invocato da run_sync.sh. La cwd e' la cartella che
# contiene questo file (impostata dal wrapper) e l'eventuale .Renviron locale.

options(warn = 1, itaposts.cron = TRUE)

# 2. Logger -------------------------------------------------------------------

.log <- function(level, ...) {
  msg <- paste0(..., collapse = "")
  ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S%z")
  cat(
    sprintf("[%s] %-5s %s\n", ts, level, msg),
    file = if (level == "ERROR") stderr() else stdout()
  )
  flush.console()
}

.log("INFO", "Avvio sync_oja.R (PID ", Sys.getpid(), ")")
.log(
  "INFO",
  "R ",
  paste(R.version$major, R.version$minor, sep = "."),
  " su ",
  R.version$platform
)

# 3. Caricamento .Renviron ----------------------------------------------------
# Rscript --vanilla salta .Renviron: lo carichiamo a mano. Ordine HOME -> cwd
# in modo che la copia locale (cron/.Renviron) abbia la precedenza.

for (f in c(path.expand("~/.Renviron"), file.path(getwd(), ".Renviron"))) {
  if (file.exists(f)) {
    .log("INFO", "Carico ", f)
    readRenviron(f)
  }
}

# 4. Pacchetto ----------------------------------------------------------------

if (!requireNamespace("itaposts", quietly = TRUE)) {
  .log(
    "ERROR",
    "Pacchetto 'itaposts' non installato. Eseguire prima install.sh."
  )
  quit(status = 2, save = "no")
}
.log(
  "INFO",
  "itaposts versione ",
  as.character(utils::packageVersion("itaposts"))
)

# 5. Lock file ----------------------------------------------------------------
# DuckDB rifiuta una seconda connessione in scrittura sullo stesso file.
# Evitiamo che cron lanci una seconda istanza prima che la precedente chiuda.

lock_dir <- Sys.getenv(
  "ITAPOSTS_LOCK_DIR",
  unset = file.path(tempdir(), "itaposts_lock")
)
dir.create(lock_dir, recursive = TRUE, showWarnings = FALSE)
lock_file <- file.path(lock_dir, "sync_oja.lock")

if (file.exists(lock_file)) {
  prev <- suppressWarnings(as.integer(readLines(lock_file, warn = FALSE)[1]))
  alive <- !is.na(prev) &&
    length(suppressWarnings(system2(
      "ps",
      c("-p", prev),
      stdout = TRUE,
      stderr = FALSE
    ))) >=
      2
  if (isTRUE(alive)) {
    .log(
      "ERROR",
      "Lock attivo: run precedente (PID ",
      prev,
      ") ancora in corso. Esco."
    )
    quit(status = 3, save = "no")
  }
  .log("WARN", "Lock stale (PID ", prev, "), lo rimuovo.")
  file.remove(lock_file)
}
writeLines(as.character(Sys.getpid()), lock_file)
on.exit(try(file.remove(lock_file), silent = TRUE), add = TRUE)

# 6. Sync ---------------------------------------------------------------------

t0 <- Sys.time()
status <- tryCatch(
  withCallingHandlers(
    list(ok = TRUE, summary = itaposts::oja_sync()),
    warning = function(w) {
      .log("WARN", conditionMessage(w))
      invokeRestart("muffleWarning")
    },
    message = function(m) {
      .log("INFO", trimws(conditionMessage(m)))
      invokeRestart("muffleMessage")
    }
  ),
  error = function(e) {
    .log("ERROR", "oja_sync() fallita: ", conditionMessage(e))
    list(ok = FALSE)
  }
)

dt <- format(round(difftime(Sys.time(), t0, units = "secs"), 1))

if (!isTRUE(status$ok)) {
  .log("ERROR", "Sync interrotta dopo ", dt, ".")
  quit(status = 1, save = "no")
}

s <- status$summary
zero_if_null <- function(x) if (is.null(x)) 0L else sum(x, na.rm = TRUE)
.log(
  "INFO",
  "Sync ok in ",
  dt,
  ": righe=",
  nrow(s),
  ", download=",
  zero_if_null(s$downloaded),
  ", ingest=",
  zero_if_null(s$ingested)
)
quit(status = 0, save = "no")
