# 1. Lettura lazy delle tabelle ----------------------------------------------

# Helper: applica filtri opzionali a un dplyr::tbl_lazy.
.filter_postings <- function(tbl, snapshots = NULL, region_code = NULL) {
  if (!is.null(snapshots)) {
    tbl <- dplyr::filter(tbl, .data$snapshot_id %in% !!snapshots)
  }
  if (!is.null(region_code)) {
    tbl <- dplyr::filter(tbl, .data$region_code %in% !!region_code)
  }
  tbl
}

# Risolve years/months in una lista di snapshot_id da intersecare poi con
# l'eventuale `snapshots` fornito dall'utente.
.resolve_year_month_snapshots <- function(con, snapshots, years, months) {
  if (is.null(years) && is.null(months)) {
    return(snapshots)
  }
  q <- "SELECT snapshot_id FROM dim_snapshot WHERE 1=1"
  params <- list()
  if (!is.null(years)) {
    q <- paste0(
      q,
      " AND year IN (",
      paste(rep("?", length(years)), collapse = ","),
      ")"
    )
    params <- c(params, as.list(as.integer(years)))
  }
  if (!is.null(months)) {
    q <- paste0(
      q,
      " AND month IN (",
      paste(rep("?", length(months)), collapse = ","),
      ")"
    )
    params <- c(params, as.list(as.integer(months)))
  }
  ids <- DBI::dbGetQuery(con, q, params = params)$snapshot_id
  if (!is.null(snapshots)) {
    ids <- intersect(ids, snapshots)
  }
  ids
}

#' Vista lazy su `fact_postings`
#'
#' Restituisce un `dbplyr` lazy table su `fact_postings`. Filtri opzionali su
#' snapshot, regione, anno e mese. Per materializzare, applicare
#' [dplyr::collect()] o [data.table::as.data.table()].
#'
#' @param con Connessione restituita da [oja_connect()].
#' @param snapshots Vettore opzionale di `snapshot_id` da includere.
#' @param region_code Vettore opzionale di codici regione (es. `"ITC4"`).
#' @param years,months Vettori opzionali di anni / mesi (interi) calcolati da
#'   `grab_date`.
#'
#' @return Un `tbl_lazy` di `dbplyr`.
#' @export
oja_postings <- function(
  con,
  snapshots = NULL,
  region_code = NULL,
  years = NULL,
  months = NULL
) {
  effective <- .resolve_year_month_snapshots(con, snapshots, years, months)
  if (!is.null(effective) && length(effective) == 0L) {
    effective <- "__no_match__"
  }
  tbl <- dplyr::tbl(con, "fact_postings")
  .filter_postings(tbl, effective, region_code)
}

#' Vista lazy su `fact_skills`
#'
#' Restituisce un `dbplyr` lazy table su `fact_skills`. Per le proprieta'
#' delle singole skill, fare `dplyr::left_join(oja_skill_dim(con))`. I filtri
#' su anno/mese richiedono un join con `fact_postings` perche' la data e'
#' attaccata al posting, non alla skill.
#'
#' @inheritParams oja_postings
#' @param join_postings Logico. Se `TRUE` esegue il join con `fact_postings`
#'   per esporre `grab_date`, `region_code`, ecc.
#'
#' @return Un `tbl_lazy` di `dbplyr`.
#' @export
oja_skills <- function(
  con,
  snapshots = NULL,
  region_code = NULL,
  years = NULL,
  months = NULL,
  join_postings = FALSE
) {
  tbl <- dplyr::tbl(con, "fact_skills")
  if (!is.null(snapshots)) {
    tbl <- dplyr::filter(tbl, .data$snapshot_id %in% !!snapshots)
  }
  if (
    join_postings ||
      !is.null(region_code) ||
      !is.null(years) ||
      !is.null(months)
  ) {
    p <- oja_postings(
      con,
      snapshots = snapshots,
      region_code = region_code,
      years = years,
      months = months
    ) |>
      dplyr::select("snapshot_id", "general_id", "region_code", "grab_date")
    tbl <- dplyr::inner_join(tbl, p, by = c("snapshot_id", "general_id"))
  }
  tbl
}

#' Tabella degli snapshot ingeriti
#'
#' @param con Connessione restituita da [oja_connect()].
#' @return Un `data.frame` con `snapshot_id`, `region_code`, `year`, `month`,
#'   `n_postings`, `n_skills`, `ingested_at`.
#' @export
oja_snapshots <- function(con) {
  DBI::dbGetQuery(
    con,
    "SELECT snapshot_id, region_code, year, month,
            n_postings, n_skills, ingested_at,
            source_zip_postings, source_zip_skills, itaposts_version
       FROM dim_snapshot
      ORDER BY year, month, region_code"
  )
}

#' Vista lazy su `dim_esco_skill`
#'
#' @param con Connessione restituita da [oja_connect()].
#' @return Un `tbl_lazy` di `dbplyr`.
#' @export
oja_skill_dim <- function(con) {
  dplyr::tbl(con, "dim_esco_skill")
}
