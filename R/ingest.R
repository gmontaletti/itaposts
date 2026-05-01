# 1. Helper interni -----------------------------------------------------------

# Parsing dello snapshot_id "ITC4_2026_2" in regione/anno/mese.
.parse_snapshot_id <- function(snapshot_id) {
  m <- regmatches(
    snapshot_id,
    regexec("^([A-Z0-9]+)_([0-9]{4})_([0-9]{1,2})$", snapshot_id)
  )[[1]]
  if (length(m) != 4L) {
    cli::cli_abort(c(
      "{.arg snapshot_id} non valido: {.val {snapshot_id}}.",
      "i" = "Formato atteso: {.code <REGION>_<YEAR>_<MONTH>} (es. ITC4_2026_2)."
    ))
  }
  list(
    snapshot_id = snapshot_id,
    region_code = m[2],
    year = as.integer(m[3]),
    month = as.integer(m[4])
  )
}

# Risolve i tre file zip attesi nello snapshot.
.resolve_zip_paths <- function(zip_dir, snapshot_id) {
  base <- file.path(zip_dir, snapshot_id)
  paths <- list(
    postings = paste0(base, "_postings.zip"),
    postings_raw = paste0(base, "_postings_raw.zip"),
    skills = paste0(base, "_skills.zip")
  )
  missing <- vapply(paths, function(p) !file.exists(p), logical(1))
  if (any(missing)) {
    cli::cli_abort(c(
      "Archivi mancanti per snapshot {.val {snapshot_id}}.",
      "x" = "Non trovati: {.path {unlist(paths[missing])}}"
    ))
  }
  paths
}

# Estrae l'unica entry CSV dentro un .zip in un tempfile e lo restituisce.
.unzip_to_temp <- function(zip_path) {
  entries <- utils::unzip(zip_path, list = TRUE)
  if (nrow(entries) != 1L) {
    cli::cli_abort(
      "L'archivio {.path {zip_path}} contiene {nrow(entries)} entry; ne attendo 1."
    )
  }
  tdir <- tempfile("itaposts_unzip_")
  dir.create(tdir)
  utils::unzip(zip_path, exdir = tdir)
  file.path(tdir, entries$Name)
}

# Costruisce una data.table con date derivate e dedup keeping latest grab.
.read_postings <- function(zip_path) {
  dt <- data.table::fread(zip_path, showProgress = FALSE)
  required <- c(
    "general_id",
    "year_grab_date",
    "month_grab_date",
    "day_grab_date",
    "year_expire_date",
    "month_expire_date",
    "day_expire_date"
  )
  miss <- setdiff(required, names(dt))
  if (length(miss)) {
    cli::cli_abort("Colonne mancanti in {.path {zip_path}}: {.val {miss}}.")
  }
  # Tutti gli identificatori sono trattati come VARCHAR: alcuni codici
  # sorgenti (idmacro_sector='C', idcategory_sector='D', ...) sono alfabetici.
  id_cols <- c(
    "idcity",
    "idprovince",
    "idregion",
    "idmacro_region",
    "idcountry",
    "idcontract",
    "ideducational_level",
    "idsector",
    "idmacro_sector",
    "idcategory_sector",
    "idexperience",
    "idworking_hours",
    "idsalary",
    "cp2021_id_level_5",
    "cp2021_id_level_4",
    "cp2021_id_level_3",
    "cp2021_id_level_2",
    "cp2021_id_level_1",
    "idesco_level_4",
    "idesco_level_5",
    "general_id"
  )
  for (col in intersect(id_cols, names(dt))) {
    if (!is.character(dt[[col]])) {
      data.table::set(dt, j = col, value = as.character(dt[[col]]))
    }
  }
  data.table::setorderv(
    dt,
    cols = c("year_grab_date", "month_grab_date", "day_grab_date"),
    order = -1L
  )
  dt <- unique(dt, by = "general_id")
  dt[,
    grab_date := tryCatch(
      as.Date(sprintf(
        "%04d-%02d-%02d",
        year_grab_date,
        month_grab_date,
        day_grab_date
      )),
      error = function(e) as.Date(NA)
    )
  ]
  dt[,
    expire_date := suppressWarnings(as.Date(
      sprintf(
        "%04d-%02d-%02d",
        year_expire_date,
        month_expire_date,
        day_expire_date
      )
    ))
  ]
  dt[]
}

# Carica e congiunge le ragioni sociali dalla tabella _postings_raw.
.attach_companyname <- function(dt_postings, raw_zip_path) {
  raw <- data.table::fread(raw_zip_path, showProgress = FALSE)
  if (!all(c("general_id", "companyname") %in% names(raw))) {
    cli::cli_abort(
      "Colonne {.val general_id} / {.val companyname} mancanti in {.path {raw_zip_path}}."
    )
  }
  if (!is.character(raw$general_id)) {
    raw[, general_id := as.character(general_id)]
  }
  raw <- unique(raw, by = "general_id")
  dt_postings[raw, companyname := i.companyname, on = "general_id"]
  dt_postings
}

# UPSERT generico: scrive una temp table dentro la connessione e fa
# INSERT ... SELECT ... ON CONFLICT DO NOTHING contro la dim di destinazione.
.upsert_dim <- function(con, dim_table, dim_data, conflict_col) {
  if (!nrow(dim_data)) {
    return(invisible(0L))
  }
  staging <- paste0("__stg_", dim_table)
  duckdb::dbWriteTable(
    con,
    staging,
    dim_data,
    temporary = TRUE,
    overwrite = TRUE
  )
  cols <- DBI::dbQuoteIdentifier(con, names(dim_data))
  cols_csv <- paste(cols, collapse = ", ")
  sql <- sprintf(
    "INSERT INTO %s (%s) SELECT %s FROM %s ON CONFLICT (%s) DO NOTHING;",
    DBI::dbQuoteIdentifier(con, dim_table),
    cols_csv,
    cols_csv,
    DBI::dbQuoteIdentifier(con, staging),
    DBI::dbQuoteIdentifier(con, conflict_col)
  )
  n <- DBI::dbExecute(con, sql)
  DBI::dbExecute(
    con,
    sprintf("DROP TABLE %s;", DBI::dbQuoteIdentifier(con, staging))
  )
  invisible(n)
}

# Estrae le dimensioni puramente dipendenti dalle postings.
.build_postings_dims <- function(postings) {
  d_geo <- unique(postings[, .(
    idcity,
    city,
    idprovince,
    province,
    idregion,
    region,
    idmacro_region,
    macro_region,
    idcountry,
    country
  )])
  d_geo <- d_geo[!is.na(idcity) & idcity != ""]

  d_contract <- unique(postings[!is.na(idcontract), .(idcontract, contract)])
  d_education <- unique(postings[
    !is.na(ideducational_level),
    .(ideducational_level, educational_level)
  ])
  d_sector <- unique(postings[
    !is.na(idsector),
    .(
      idsector,
      sector,
      idmacro_sector,
      macro_sector,
      idcategory_sector,
      category_sector
    )
  ])
  d_experience <- unique(postings[
    !is.na(idexperience),
    .(idexperience, experience)
  ])
  d_hours <- unique(postings[
    !is.na(idworking_hours),
    .(idworking_hours, working_hours)
  ])
  d_salary <- unique(postings[!is.na(idsalary), .(idsalary, salary)])
  d_cp <- unique(postings[
    !is.na(cp2021_id_level_5) & cp2021_id_level_5 != "",
    .(
      cp2021_id_level_5,
      cp2021_level_5,
      cp2021_id_level_4,
      cp2021_level_4,
      cp2021_id_level_3,
      cp2021_level_3,
      cp2021_id_level_2,
      cp2021_level_2,
      cp2021_id_level_1,
      cp2021_level_1
    )
  ])
  d_esco <- unique(postings[
    !is.na(idesco_level_5) & idesco_level_5 != "",
    .(
      idesco_level_5,
      esco_level_5,
      idesco_level_4,
      esco_level_4,
      uri
    )
  ])
  d_source <- unique(postings[
    !is.na(source) & source != "",
    .(
      source,
      source_category_analysis,
      source_relevance
    )
  ])

  list(
    dim_geography = d_geo,
    dim_contract = d_contract,
    dim_education = d_education,
    dim_sector = d_sector,
    dim_experience = d_experience,
    dim_working_hours = d_hours,
    dim_salary = d_salary,
    dim_cp2021 = d_cp,
    dim_esco_occupation = d_esco,
    dim_source = d_source
  )
}

# Mapping (table -> conflict column) per .upsert_dim.
.dim_pk <- function() {
  c(
    dim_geography = "idcity",
    dim_contract = "idcontract",
    dim_education = "ideducational_level",
    dim_sector = "idsector",
    dim_experience = "idexperience",
    dim_working_hours = "idworking_hours",
    dim_salary = "idsalary",
    dim_cp2021 = "cp2021_id_level_5",
    dim_esco_occupation = "idesco_level_5",
    dim_source = "source"
  )
}

# Stream dello skills CSV: alimenta dim_esco_skill (aggregato) + fact_skills.
.stream_skills <- function(con, skills_zip, snapshot_id) {
  csv_path <- .unzip_to_temp(skills_zip)
  on.exit(unlink(dirname(csv_path), recursive = TRUE), add = TRUE)

  csv_lit <- paste0("'", gsub("'", "''", csv_path), "'")
  read_csv <- sprintf(
    "read_csv_auto(%s, header=true, sample_size=-1)",
    csv_lit
  )

  # 1. dim_esco_skill: prima occorrenza per IDESCOSKILL_LEVEL_3
  ddl_skill_cols <- DBI::dbGetQuery(
    con,
    "PRAGMA table_info('dim_esco_skill')"
  )$name
  skill_col_pairs <- vapply(
    ddl_skill_cols,
    function(c) {
      if (c == "idescoskill_level_3") {
        "idescoskill_level_3"
      } else {
        sprintf("any_value(%s) AS %s", c, c)
      }
    },
    character(1)
  )
  skill_select <- paste(skill_col_pairs, collapse = ",\n  ")
  sql_dim <- sprintf(
    "INSERT INTO dim_esco_skill (%s)
     SELECT %s
       FROM %s
      WHERE idescoskill_level_3 IS NOT NULL AND idescoskill_level_3 <> ''
      GROUP BY idescoskill_level_3
     ON CONFLICT (idescoskill_level_3) DO NOTHING;",
    paste(ddl_skill_cols, collapse = ", "),
    skill_select,
    read_csv
  )
  DBI::dbExecute(con, sql_dim)

  # 2. fact_skills - general_id come VARCHAR per coerenza con fact_postings
  sql_fact <- sprintf(
    "INSERT INTO fact_skills (snapshot_id, general_id, idescoskill_level_3)
     SELECT DISTINCT ?, CAST(general_id AS VARCHAR), idescoskill_level_3
       FROM %s
      WHERE general_id IS NOT NULL
        AND idescoskill_level_3 IS NOT NULL
        AND idescoskill_level_3 <> ''
     ON CONFLICT DO NOTHING;",
    read_csv
  )
  n <- DBI::dbExecute(con, sql_fact, params = list(snapshot_id))
  invisible(as.integer(n))
}

# Validazioni post-ingest. Solleva con messaggio dettagliato in caso di errore.
.validate_snapshot <- function(con, snapshot_id) {
  res <- DBI::dbGetQuery(
    con,
    "SELECT
       (SELECT COUNT(*)            FROM fact_postings WHERE snapshot_id = ?) AS n_post,
       (SELECT COUNT(DISTINCT general_id) FROM fact_postings WHERE snapshot_id = ?) AS n_post_unique,
       (SELECT COUNT(*) FROM fact_skills s
          WHERE s.snapshot_id = ?
            AND NOT EXISTS (
              SELECT 1 FROM fact_postings p
               WHERE p.snapshot_id = s.snapshot_id
                 AND p.general_id  = s.general_id
            )) AS n_orphan_skills",
    params = list(snapshot_id, snapshot_id, snapshot_id)
  )
  if (res$n_post != res$n_post_unique) {
    cli::cli_abort(c(
      "Dedup non riuscito: {res$n_post} righe in fact_postings ma {res$n_post_unique} general_id distinti.",
      "i" = "Snapshot: {.val {snapshot_id}}."
    ))
  }
  if (res$n_orphan_skills > 0L) {
    cli::cli_abort(c(
      "{res$n_orphan_skills} righe in fact_skills senza posting corrispondente.",
      "i" = "Snapshot: {.val {snapshot_id}}."
    ))
  }
  invisible(res)
}

# 2. Ingestione di un singolo snapshot ---------------------------------------

#' Ingerisce un singolo snapshot OJA nel database DuckDB
#'
#' Legge i tre archivi zip Lightcast (`<snapshot_id>_postings.zip`,
#' `<snapshot_id>_postings_raw.zip`, `<snapshot_id>_skills.zip`) presenti in
#' `zip_dir`, deduplica i posting su `general_id` mantenendo la riga con
#' `(year, month, day)_grab_date` piu' recente, costruisce le dimensioni
#' (UPSERT), alimenta `fact_postings` e — via DuckDB `read_csv_auto` — anche
#' `fact_skills` e `dim_esco_skill` senza materializzare la tabella delle skill
#' (~27M righe) in R. L'intera operazione e' avvolta in una singola
#' transazione con validazione di unicita' e integrita' referenziale prima
#' del COMMIT.
#'
#' @param zip_dir Directory che contiene i tre archivi.
#' @param snapshot_id Identificativo dello snapshot, es. `"ITC4_2026_2"`.
#' @param overwrite Logico. Se `TRUE`, rimuove l'eventuale snapshot omonimo
#'   gia' presente prima di reinserirlo. Default `FALSE` (errore se gia'
#'   ingerito).
#' @param path Percorso del file DuckDB. Default: [oja_db_path()].
#' @param con Connessione DuckDB in scrittura, opzionale. Quando fornita la
#'   funzione non apre/chiude connessioni.
#'
#' @return Invisibilmente una lista con `snapshot_id`, `n_postings`,
#'   `n_skills`, `ingested_at`.
#' @export
#' @examples
#' \dontrun{
#'   oja_init_db()
#'   oja_ingest_snapshot(
#'     zip_dir     = "~/Documents/funzioni/itaposts",
#'     snapshot_id = "ITC4_2026_2"
#'   )
#' }
oja_ingest_snapshot <- function(
  zip_dir,
  snapshot_id,
  overwrite = FALSE,
  path = oja_db_path(),
  con = NULL
) {
  meta <- .parse_snapshot_id(snapshot_id)
  zips <- .resolve_zip_paths(zip_dir, snapshot_id)

  if (is.null(con)) {
    con <- oja_connect(path = path, read_only = FALSE)
    on.exit(oja_disconnect(con), add = TRUE)
  }
  oja_init_db(con = con)

  exists_q <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS n FROM dim_snapshot WHERE snapshot_id = ?",
    params = list(snapshot_id)
  )
  if (exists_q$n > 0L) {
    if (!overwrite) {
      cli::cli_abort(c(
        "Snapshot {.val {snapshot_id}} gia' presente nel database.",
        "i" = "Usa {.code overwrite = TRUE} per reingerirlo."
      ))
    }
    DBI::dbExecute(
      con,
      "DELETE FROM fact_skills    WHERE snapshot_id = ?",
      params = list(snapshot_id)
    )
    DBI::dbExecute(
      con,
      "DELETE FROM fact_postings  WHERE snapshot_id = ?",
      params = list(snapshot_id)
    )
    DBI::dbExecute(
      con,
      "DELETE FROM dim_snapshot   WHERE snapshot_id = ?",
      params = list(snapshot_id)
    )
  }

  cli::cli_inform("Lettura postings da {.path {basename(zips$postings)}}...")
  postings <- .read_postings(zips$postings)
  cli::cli_inform(
    "Allego companyname da {.path {basename(zips$postings_raw)}}..."
  )
  postings <- .attach_companyname(postings, zips$postings_raw)

  fact_cols <- c(
    "general_id",
    "grab_date",
    "expire_date",
    "idcity",
    "idcontract",
    "ideducational_level",
    "idsector",
    "idexperience",
    "idworking_hours",
    "idsalary",
    "salaryvalue",
    "idesco_level_5",
    "cp2021_id_level_5",
    "source",
    "companyname"
  )
  for (col in setdiff(fact_cols, names(postings))) {
    postings[, (col) := NA]
  }
  fact_dt <- data.table::data.table(
    snapshot_id = snapshot_id,
    general_id = postings$general_id,
    region_code = meta$region_code,
    grab_date = postings$grab_date,
    expire_date = postings$expire_date,
    idcity = postings$idcity,
    idcontract = postings$idcontract,
    ideducational_level = postings$ideducational_level,
    idsector = postings$idsector,
    idexperience = postings$idexperience,
    idworking_hours = postings$idworking_hours,
    idsalary = postings$idsalary,
    salaryvalue = as.numeric(postings$salaryvalue),
    idesco_level_5 = as.character(postings$idesco_level_5),
    cp2021_id_level_5 = as.character(postings$cp2021_id_level_5),
    source = postings$source,
    companyname = postings$companyname
  )

  DBI::dbExecute(con, "BEGIN TRANSACTION;")
  ok <- FALSE
  on.exit(
    {
      if (!ok) try(DBI::dbExecute(con, "ROLLBACK;"), silent = TRUE)
    },
    add = TRUE
  )

  cli::cli_inform("Costruzione e UPSERT delle dimensioni...")
  dims <- .build_postings_dims(postings)
  pk_map <- .dim_pk()
  for (tbl in names(dims)) {
    .upsert_dim(con, tbl, dims[[tbl]], pk_map[[tbl]])
  }

  cli::cli_inform("Caricamento {nrow(fact_dt)} righe in fact_postings...")
  duckdb::dbWriteTable(
    con,
    "__stg_fact_postings",
    fact_dt,
    temporary = TRUE,
    overwrite = TRUE
  )
  DBI::dbExecute(
    con,
    sprintf(
      "INSERT INTO fact_postings (%s) SELECT %s FROM __stg_fact_postings;",
      paste(names(fact_dt), collapse = ", "),
      paste(names(fact_dt), collapse = ", ")
    )
  )
  DBI::dbExecute(con, "DROP TABLE __stg_fact_postings;")

  cli::cli_inform("Streaming skills da {.path {basename(zips$skills)}}...")
  n_skills <- .stream_skills(con, zips$skills, snapshot_id)

  cli::cli_inform("Validazione snapshot...")
  .validate_snapshot(con, snapshot_id)

  ingested_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%OS3")
  itaposts_ver <- tryCatch(
    as.character(utils::packageVersion("itaposts")),
    error = function(e) NA_character_
  )
  DBI::dbExecute(
    con,
    "INSERT INTO dim_snapshot
       (snapshot_id, region_code, year, month, ingested_at,
        n_postings, n_skills, source_zip_postings, source_zip_skills, itaposts_version)
     VALUES (?, ?, ?, ?, CAST(? AS TIMESTAMP), ?, ?, ?, ?, ?);",
    params = list(
      snapshot_id,
      meta$region_code,
      meta$year,
      meta$month,
      ingested_at,
      nrow(fact_dt),
      n_skills,
      basename(zips$postings),
      basename(zips$skills),
      itaposts_ver
    )
  )

  DBI::dbExecute(con, "COMMIT;")
  ok <- TRUE

  cli::cli_alert_success(
    "Snapshot {.val {snapshot_id}}: {nrow(fact_dt)} postings, {n_skills} skills."
  )
  invisible(list(
    snapshot_id = snapshot_id,
    n_postings = nrow(fact_dt),
    n_skills = n_skills,
    ingested_at = ingested_at
  ))
}

# 3. Ingestione di una directory intera --------------------------------------

#' Ingerisce tutti gli snapshot OJA presenti in una directory
#'
#' Scansiona `zip_dir` per tutte le triplette `<id>_postings.zip` /
#' `<id>_postings_raw.zip` / `<id>_skills.zip` e invoca
#' [oja_ingest_snapshot()] per ognuna. Gli snapshot gia' presenti nel database
#' vengono saltati a meno di `overwrite = TRUE`.
#'
#' @param zip_dir Directory contenente gli archivi.
#' @param snapshots Vettore opzionale di `snapshot_id` da ingerire. Se
#'   `NULL` (default) ingerisce tutti quelli rilevati.
#' @param overwrite Logico. Inoltrato a [oja_ingest_snapshot()].
#' @param path Percorso del file DuckDB. Default: [oja_db_path()].
#'
#' @return Invisibilmente una `data.frame` con un riepilogo per ogni snapshot
#'   processato.
#' @export
oja_ingest_dirs <- function(
  zip_dir,
  snapshots = NULL,
  overwrite = FALSE,
  path = oja_db_path()
) {
  zips <- list.files(zip_dir, pattern = "_postings\\.zip$", full.names = FALSE)
  ids <- sub("_postings\\.zip$", "", zips)
  if (!is.null(snapshots)) {
    ids <- intersect(ids, snapshots)
  }
  if (!length(ids)) {
    cli::cli_warn("Nessuno snapshot da processare in {.path {zip_dir}}.")
    return(invisible(data.frame()))
  }

  con <- oja_connect(path = path, read_only = FALSE)
  on.exit(oja_disconnect(con), add = TRUE)
  oja_init_db(con = con)

  rows <- lapply(ids, function(id) {
    res <- tryCatch(
      oja_ingest_snapshot(
        zip_dir = zip_dir,
        snapshot_id = id,
        overwrite = overwrite,
        con = con
      ),
      error = function(e) {
        cli::cli_alert_danger("Snapshot {.val {id}}: {conditionMessage(e)}")
        list(snapshot_id = id, n_postings = NA, n_skills = NA, ingested_at = NA)
      }
    )
    as.data.frame(res, stringsAsFactors = FALSE)
  })
  invisible(do.call(rbind, rows))
}
