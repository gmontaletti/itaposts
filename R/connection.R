# 1. Risoluzione percorso ----------------------------------------------------

#' Percorso del database OJA condiviso
#'
#' Restituisce il percorso del database che ospita gli OJA normalizzati. Se
#' la variabile d'ambiente `ITAPOSTS_DB` è valorizzata, la funzione ne
#' restituisce il valore: un file DuckDB oppure un catalogo DuckLake con
#' prefisso `ducklake:` (es.
#' `ducklake:sqlite:~/Documents/funzioni/datalake/catalog/lake.sqlite`).
#' Altrimenti il percorso è radicato nella variabile d'ambiente
#' `SHARED_DATA_DIR` (con fallback `~/Documents/funzioni/shared_data`), la
#' stessa convenzione usata dagli altri moduli dell'ecosistema (cfr.
#' `data_pipeline/R/person_employer_links.R`).
#'
#' @param create_dir Logico. Se `TRUE` (default) crea la cartella che
#'   contiene il file DuckDB se non esiste. Non ha effetto sui percorsi
#'   `ducklake:`. La creazione del file DuckDB stesso è delegata a
#'   [oja_init_db()] o alla prima `dbConnect()`.
#'
#' @return Stringa con il percorso assoluto del file DuckDB (per default
#'   `<SHARED_DATA_DIR>/oja/itposts.duckdb`) oppure con il percorso
#'   `ducklake:` letto da `ITAPOSTS_DB`.
#' @export
#' @examples
#' oja_db_path(create_dir = FALSE)
oja_db_path <- function(create_dir = TRUE) {
  db <- .strip_outer_quotes(Sys.getenv("ITAPOSTS_DB", unset = ""))
  if (nzchar(db)) {
    if (.is_ducklake_path(db)) {
      return(db)
    }
    db <- path.expand(db)
    if (create_dir && !dir.exists(dirname(db))) {
      dir.create(dirname(db), recursive = TRUE, showWarnings = FALSE)
    }
    return(db)
  }
  base <- Sys.getenv(
    "SHARED_DATA_DIR",
    unset = "~/Documents/funzioni/shared_data"
  )
  base <- path.expand(base)
  oja_dir <- file.path(base, "oja")
  if (create_dir && !dir.exists(oja_dir)) {
    dir.create(oja_dir, recursive = TRUE, showWarnings = FALSE)
  }
  file.path(oja_dir, "itposts.duckdb")
}

# 2. Apertura/chiusura connessione -------------------------------------------

#' Apre una connessione al database OJA
#'
#' Wrapper su [DBI::dbConnect()] con il driver `duckdb::duckdb()`. Per default
#' apre in sola lettura (i consumatori a valle). Le funzioni di ingestione
#' richiedono `read_only = FALSE`.
#'
#' @details
#' Con un percorso di file la funzione apre il database DuckDB indicato.
#'
#' Con un percorso che inizia con `ducklake:` la funzione apre un database
#' DuckDB in memoria, carica l'estensione `ducklake` (più `sqlite` per i
#' cataloghi `ducklake:sqlite:`), collega il catalogo con
#' `ATTACH '<path>' AS lake` (`READ_ONLY` se `read_only = TRUE`) ed esegue
#' `USE lake.<schema>`, con lo schema indicato dall'opzione
#' `itaposts.schema` (default `"oja"`). Le query con nomi di tabella non
#' qualificati (`FROM fact_postings`) risolvono quindi sullo schema del
#' lago: le funzioni di lettura e di ingestione del pacchetto, e il codice
#' dei consumatori a valle, restano invariati. Il database in memoria resta
#' scrivibile anche in sola lettura, così viste e tabelle temporanee (es.
#' `duckdb::duckdb_register()`) restano disponibili.
#'
#' Il catalogo DuckLake e lo schema devono esistere. La creazione del
#' catalogo richiede l'opzione `DATA_PATH` ed è compito di chi inizializza
#' il lago; nei collegamenti successivi il percorso dei dati è letto dal
#' catalogo. Le estensioni si installano una volta con
#' `INSTALL ducklake; INSTALL sqlite;` (richiede la rete).
#'
#' Il chiamante è responsabile della chiusura via [oja_disconnect()]. Il
#' pattern raccomandato:
#'
#' ```r
#' con <- oja_connect()
#' on.exit(oja_disconnect(con), add = TRUE)
#' ```
#'
#' @param path Percorso del file DuckDB oppure catalogo DuckLake con prefisso
#'   `ducklake:` (es. `"ducklake:sqlite:/percorso/lake.sqlite"`). Default:
#'   [oja_db_path()].
#' @param read_only Logico. `TRUE` (default) per consumatori; `FALSE` per
#'   ingestione.
#' @param ... Argomenti aggiuntivi passati a [DBI::dbConnect()].
#'
#' @return Oggetto `DBIConnection`.
#' @export
#' @examples
#' con <- oja_connect(path = ":memory:", read_only = FALSE)
#' DBI::dbGetQuery(con, "SELECT current_database() AS db")
#' oja_disconnect(con)
#'
#' \dontrun{
#'   con <- oja_connect()
#'   on.exit(oja_disconnect(con), add = TRUE)
#'   DBI::dbListTables(con)
#'
#'   # Catalogo DuckLake: le query non qualificate usano lo schema lake.oja
#'   con <- oja_connect("ducklake:sqlite:~/Documents/funzioni/datalake/catalog/lake.sqlite")
#' }
oja_connect <- function(path = oja_db_path(), read_only = TRUE, ...) {
  if (
    !is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)
  ) {
    cli::cli_abort("{.arg path} deve essere una stringa non vuota.")
  }
  if (!isTRUE(read_only) && !isFALSE(read_only)) {
    cli::cli_abort("{.arg read_only} deve essere {.code TRUE} o {.code FALSE}.")
  }
  if (.is_ducklake_path(path)) {
    return(.oja_connect_ducklake(path, read_only = read_only, ...))
  }
  DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = path,
    read_only = read_only,
    ...
  )
}

#' Chiude una connessione OJA
#'
#' Chiude la connessione aperta da [oja_connect()]. Per le connessioni a un
#' catalogo DuckLake scollega prima il catalogo (`DETACH lake`), così il
#' catalogo viene rilasciato subito e non alla garbage collection.
#' Restituisce invisibilmente `TRUE`.
#'
#' @param con Connessione restituita da [oja_connect()].
#' @return Invisibilmente `TRUE`.
#' @export
#' @examples
#' con <- oja_connect(path = ":memory:", read_only = FALSE)
#' oja_disconnect(con)
oja_disconnect <- function(con) {
  if (DBI::dbIsValid(con) && .oja_has_lake(con)) {
    try(
      {
        DBI::dbExecute(con, "USE memory;")
        DBI::dbExecute(con, "DETACH lake;")
      },
      silent = TRUE
    )
  }
  DBI::dbDisconnect(con, shutdown = TRUE)
  invisible(TRUE)
}

# 3. Backend DuckLake ---------------------------------------------------------

# TRUE se `path` indica un catalogo DuckLake.
.is_ducklake_path <- function(path) {
  is.character(path) &&
    length(path) == 1L &&
    !is.na(path) &&
    startsWith(path, "ducklake:")
}

# Espande `~` nella parte di file del catalogo. Le stringhe di connessione
# (es. `ducklake:postgres:dbname=...`) non iniziano con `~` e restano
# invariate.
.expand_ducklake_path <- function(path) {
  prefix <- regmatches(path, regexpr("^ducklake:(sqlite:)?", path))
  paste0(prefix, path.expand(substring(path, nchar(prefix) + 1L)))
}

# Apre DuckDB in memoria, collega il catalogo DuckLake come `lake` e rende
# corrente lo schema `getOption("itaposts.schema", "oja")`.
.oja_connect_ducklake <- function(path, read_only = TRUE, ...) {
  schema <- getOption("itaposts.schema", "oja")
  if (
    !is.character(schema) ||
      length(schema) != 1L ||
      is.na(schema) ||
      !nzchar(schema)
  ) {
    cli::cli_abort(
      "L'opzione {.code itaposts.schema} deve essere una stringa non vuota."
    )
  }
  target <- .expand_ducklake_path(path)
  is_sqlite <- startsWith(target, "ducklake:sqlite:")
  # Un ATTACH in scrittura su un catalogo SQLite inesistente fallisce per
  # l'assenza di DATA_PATH ma lascia un file vuoto: il controllo precede.
  if (is_sqlite) {
    catalog <- sub("^ducklake:sqlite:", "", target)
    if (!file.exists(catalog)) {
      cli::cli_abort(c(
        "Catalogo DuckLake inesistente: {.path {catalog}}.",
        "i" = "Il catalogo va creato all'inizializzazione del lago, con l'opzione {.code DATA_PATH}."
      ))
    }
  }

  con <- DBI::dbConnect(duckdb::duckdb(), ...)
  ok <- FALSE
  on.exit(
    {
      if (!ok) DBI::dbDisconnect(con, shutdown = TRUE)
    },
    add = TRUE
  )

  extensions <- if (is_sqlite) c("ducklake", "sqlite") else "ducklake"
  for (ext in extensions) {
    tryCatch(
      DBI::dbExecute(con, sprintf("LOAD %s;", ext)),
      error = function(e) {
        cli::cli_abort(
          c(
            "Impossibile caricare l'estensione DuckDB {.val {ext}}.",
            "i" = "Installarla una volta con {.code INSTALL {ext};} (richiede la rete)."
          ),
          parent = e
        )
      }
    )
  }

  attach_sql <- sprintf(
    "ATTACH %s AS lake%s;",
    DBI::dbQuoteString(con, target),
    if (read_only) " (READ_ONLY)" else ""
  )
  tryCatch(
    DBI::dbExecute(con, attach_sql),
    error = function(e) {
      cli::cli_abort(
        "Impossibile collegare il catalogo DuckLake {.val {path}}.",
        parent = e
      )
    }
  )
  tryCatch(
    DBI::dbExecute(
      con,
      sprintf("USE lake.%s;", DBI::dbQuoteIdentifier(con, schema))
    ),
    error = function(e) {
      cli::cli_abort(
        c(
          "Schema {.val {schema}} assente nel catalogo DuckLake {.val {path}}.",
          "i" = "Lo schema va creato all'inizializzazione del lago; l'opzione {.code itaposts.schema} ne indica il nome."
        ),
        parent = e
      )
    }
  )
  ok <- TRUE
  con
}

# TRUE se la connessione ha un catalogo DuckLake collegato come `lake`.
.oja_has_lake <- function(con) {
  tryCatch(
    nrow(DBI::dbGetQuery(
      con,
      "SELECT 1 FROM duckdb_databases()
        WHERE database_name = 'lake' AND type = 'ducklake'"
    )) >
      0L,
    error = function(e) FALSE
  )
}

# TRUE se il database corrente della connessione è un catalogo DuckLake. La
# colonna `type` di duckdb_databases() vale `ducklake` per il catalogo,
# `duckdb` per i file DuckDB e per il database in memoria.
.oja_is_ducklake <- function(con) {
  type <- DBI::dbGetQuery(
    con,
    "SELECT type FROM duckdb_databases()
      WHERE database_name = current_database()"
  )$type
  identical(type, "ducklake")
}

# TRUE se `table` esiste nello schema corrente della connessione.
.oja_table_exists <- function(con, table) {
  n <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS n FROM duckdb_tables()
      WHERE database_name = current_database()
        AND schema_name = current_schema()
        AND table_name = ?",
    params = list(table)
  )$n
  n > 0
}

# 4. Transazioni -------------------------------------------------------------

# TRUE se la connessione ha una transazione esplicita aperta. In autocommit
# ogni istruzione ha un proprio identificativo di transazione, dentro BEGIN
# le istruzioni lo condividono: due letture consecutive distinguono i due
# casi senza effetti collaterali (un BEGIN di prova abortirebbe la
# transazione esterna). Una transazione già abortita rende impossibile la
# lettura e viene trattata come aperta.
.oja_in_transaction <- function(con) {
  sql <- "SELECT current_transaction_id() AS id"
  tryCatch(
    identical(DBI::dbGetQuery(con, sql)$id, DBI::dbGetQuery(con, sql)$id),
    error = function(e) TRUE
  )
}

# Valuta `code` in una transazione e ne restituisce il valore. Se `con` ha
# già una transazione aperta vi partecipa senza COMMIT né ROLLBACK: la
# conclusione spetta al chiamante, che riceve l'eventuale errore.
.oja_with_transaction <- function(con, code) {
  if (.oja_in_transaction(con)) {
    return(code)
  }
  DBI::dbExecute(con, "BEGIN TRANSACTION;")
  ok <- FALSE
  on.exit(
    {
      if (!ok) try(DBI::dbExecute(con, "ROLLBACK;"), silent = TRUE)
    },
    add = TRUE
  )
  res <- code
  DBI::dbExecute(con, "COMMIT;")
  ok <- TRUE
  res
}
