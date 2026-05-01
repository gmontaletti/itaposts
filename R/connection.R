# 1. Risoluzione percorso ----------------------------------------------------

#' Percorso del database DuckDB OJA condiviso
#'
#' Restituisce il percorso del file DuckDB centralizzato che ospita gli OJA
#' normalizzati. Il percorso e' radicato nella variabile d'ambiente
#' `SHARED_DATA_DIR` (con fallback `~/Documents/funzioni/shared_data`) — la
#' stessa convenzione usata dagli altri moduli dell'ecosistema (cfr.
#' `data_pipeline/R/person_employer_links.R`).
#'
#' @param create_dir Logico. Se `TRUE` (default) crea la cartella `oja/` se non
#'   esiste. La creazione del file DuckDB stesso e' delegata a
#'   [oja_init_db()] o alla prima `dbConnect()`.
#'
#' @return Stringa con il percorso assoluto del file `itposts.duckdb`.
#' @export
#' @examples
#' \dontrun{
#'   oja_db_path()
#' }
oja_db_path <- function(create_dir = TRUE) {
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

#' Apre una connessione al database DuckDB OJA
#'
#' Wrapper su [DBI::dbConnect()] con il driver `duckdb::duckdb()`. Per default
#' apre in sola lettura (i consumatori a valle). Le funzioni di ingestione
#' richiedono `read_only = FALSE`.
#'
#' Il chiamante e' responsabile della chiusura via [oja_disconnect()] o
#' `DBI::dbDisconnect(con, shutdown = TRUE)`. Il pattern raccomandato:
#'
#' ```r
#' con <- oja_connect()
#' on.exit(oja_disconnect(con), add = TRUE)
#' ```
#'
#' @param path Percorso del file DuckDB. Default: [oja_db_path()].
#' @param read_only Logico. `TRUE` (default) per consumatori; `FALSE` per
#'   ingestione.
#' @param ... Argomenti aggiuntivi passati a [DBI::dbConnect()].
#'
#' @return Oggetto `DBIConnection`.
#' @export
#' @examples
#' \dontrun{
#'   con <- oja_connect()
#'   on.exit(oja_disconnect(con), add = TRUE)
#'   DBI::dbListTables(con)
#' }
oja_connect <- function(path = oja_db_path(), read_only = TRUE, ...) {
  DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = path,
    read_only = read_only,
    ...
  )
}

#' Chiude una connessione DuckDB OJA
#'
#' Equivalente a `DBI::dbDisconnect(con, shutdown = TRUE)`. Restituisce
#' invisibilmente `TRUE`.
#'
#' @param con Connessione restituita da [oja_connect()].
#' @return Invisibilmente `TRUE`.
#' @export
oja_disconnect <- function(con) {
  DBI::dbDisconnect(con, shutdown = TRUE)
  invisible(TRUE)
}
