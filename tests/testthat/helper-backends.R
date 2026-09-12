# Backend di archiviazione per i test parametrizzati: file DuckDB temporaneo
# e lago DuckLake temporaneo (catalogo SQLite e dati in una cartella
# temporanea). I test DuckLake vengono saltati se le estensioni `ducklake` e
# `sqlite` non si caricano: i test non installano estensioni.

# 1. Disponibilità delle estensioni -------------------------------------------

.ducklake_available <- local({
  cache <- NULL
  function() {
    if (is.null(cache)) {
      con <- DBI::dbConnect(duckdb::duckdb())
      on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
      cache <<- tryCatch(
        {
          DBI::dbExecute(con, "LOAD ducklake;")
          DBI::dbExecute(con, "LOAD sqlite;")
          TRUE
        },
        error = function(e) FALSE
      )
    }
    cache
  }
})

skip_if_no_ducklake <- function() {
  if (!.ducklake_available()) {
    testthat::skip("Estensioni DuckDB ducklake e sqlite non caricabili.")
  }
}

# 2. Store temporanei ----------------------------------------------------------

.oja_backends <- c("duckdb", "ducklake")

# Crea un catalogo DuckLake temporaneo con gli schemi `schema` e restituisce
# il percorso `ducklake:sqlite:`. La cartella viene rimossa all'uscita da
# `env`.
local_temp_lake <- function(schema = "oja", env = parent.frame()) {
  skip_if_no_ducklake()
  dir <- withr::local_tempdir("itaposts_lake_", .local_envir = env)
  lake <- paste0("ducklake:sqlite:", file.path(dir, "catalog.sqlite"))
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "LOAD ducklake;")
  DBI::dbExecute(con, "LOAD sqlite;")
  DBI::dbExecute(
    con,
    sprintf(
      "ATTACH %s AS lake (DATA_PATH %s);",
      DBI::dbQuoteString(con, lake),
      DBI::dbQuoteString(con, file.path(dir, "data"))
    )
  )
  for (s in schema) {
    DBI::dbExecute(
      con,
      sprintf("CREATE SCHEMA lake.%s;", DBI::dbQuoteIdentifier(con, s))
    )
  }
  DBI::dbExecute(con, "DETACH lake;")
  lake
}

# Percorso di uno store temporaneo per `backend`.
local_temp_store <- function(
  backend = c("duckdb", "ducklake"),
  env = parent.frame()
) {
  backend <- match.arg(backend)
  if (identical(backend, "ducklake")) {
    return(local_temp_lake(env = env))
  }
  db <- tempfile("itaposts_", fileext = ".duckdb")
  withr::defer(unlink(c(db, paste0(db, ".wal"))), envir = env)
  db
}

# Numero di snapshot DuckLake del catalogo collegato come `lake`.
lake_snapshot_count <- function(con) {
  DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM lake.snapshots()")$n
}
