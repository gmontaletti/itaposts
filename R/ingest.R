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

# Forme di codice fiscale di persona fisica, per l'oscuramento delle ragioni
# sociali (decisione D-COB-1, sezione 11 del piano del data lake: la forma di
# un codice fiscale diventa `[CF]`). La soglia sulle occorrenze rare prevista
# dalla stessa decisione riguarda il testo libero dei microdati COB e non si
# applica qui.
#
# Si usano due forme, perche' una ragione sociale non e' testo libero:
# - `.RE_CF_INTERO`: il valore, dopo trim, e' tutto e solo un codice fiscale.
#   Ammette le lettere dell'omocodia (LMNPQRSTUV) nelle posizioni numeriche,
#   con la lettera del mese fra ABCDEHLMPRST, oppure cifre vere in quelle
#   posizioni con una lettera qualsiasi per il mese. E' il caso della ditta
#   individuale registrata con il codice del titolare.
# - `.RE_CF_IMMERSO`: una sottostringa con cifre vere in tutte le posizioni
#   numeriche, che intercetta il codice scritto accanto al nome. Le cifre sono
#   obbligatorie di proposito: una forma che ammetta lettere ovunque fa
#   passare per codice fiscale qualsiasi parola di sedici lettere, e in una
#   colonna di ragioni sociali cancellerebbe nomi legittimi.
.CF_NUM <- "[0-9LMNPQRSTUVlmnpqrstuv]"
.RE_CF_IMMERSO <- "[A-Za-z]{6}[0-9]{2}[A-Za-z][0-9]{2}[A-Za-z][0-9]{3}[A-Za-z]"
# Senza ancore: serve cosi' a regexp_full_match() di DuckDB nella validazione.
.RE_CF_VALORE <- sprintf(
  "(%s|%s)",
  sprintf(
    "[A-Za-z]{6}%1$s{2}[ABCDEHLMPRSTabcdehlmprst]%1$s{2}[A-Za-z]%1$s{3}[A-Za-z]",
    .CF_NUM
  ),
  .RE_CF_IMMERSO
)
.RE_CF_INTERO <- paste0("^", .RE_CF_VALORE, "$")

# Sostituisce con `[CF]` le forme di codice fiscale in un vettore di testo.
# `NA` resta `NA`. Vettorizzata: nessun ciclo sulle righe.
.mask_cf <- function(x) {
  if (!is.character(x)) {
    return(x)
  }
  intero <- !is.na(x) & grepl(.RE_CF_INTERO, trimws(x))
  x[intero] <- "[CF]"
  gsub(.RE_CF_IMMERSO, "[CF]", x)
}

# Carica e congiunge le ragioni sociali dalla tabella _postings_raw.
# Le forme di codice fiscale vengono oscurate prima che la colonna raggiunga
# `fact_postings`: il valore di origine non viene mai scritto.
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
  dt_postings[, companyname := .mask_cf(as.character(companyname))]
  dt_postings
}

# UPSERT portabile: scrive una temp table di staging e inserisce nella dim di
# destinazione solo le chiavi assenti (anti-join), con una sola riga per
# chiave. A parità di chiave vince la prima riga nell'ordine di `dim_data`,
# come con il precedente ON CONFLICT DO NOTHING; per le dimensioni derivate
# dalle postings è la riga del posting con grab_date più recente. Non usa
# ON CONFLICT, che richiede una PRIMARY KEY assente su DuckLake.
.upsert_dim <- function(con, dim_table, dim_data, key) {
  if (!nrow(dim_data)) {
    return(invisible(0L))
  }
  staging <- paste0("__stg_", dim_table)
  stg <- data.table::copy(dim_data)
  data.table::setDT(stg)
  data.table::set(stg, j = "stg_ord__", value = seq_len(nrow(stg)))
  duckdb::dbWriteTable(
    con,
    staging,
    stg,
    temporary = TRUE,
    overwrite = TRUE
  )
  cols_csv <- paste(
    DBI::dbQuoteIdentifier(con, names(dim_data)),
    collapse = ", "
  )
  key_q <- DBI::dbQuoteIdentifier(con, key)
  sql <- sprintf(
    "INSERT INTO %1$s (%2$s)
     SELECT %2$s
       FROM (
         SELECT *,
                row_number() OVER (PARTITION BY %3$s ORDER BY stg_ord__) AS stg_rn__
           FROM %4$s
          WHERE %5$s
       ) s
      WHERE s.stg_rn__ = 1
        AND NOT EXISTS (SELECT 1 FROM %1$s d WHERE %6$s);",
    DBI::dbQuoteIdentifier(con, dim_table),
    cols_csv,
    paste(key_q, collapse = ", "),
    DBI::dbQuoteIdentifier(con, staging),
    paste(sprintf("%s IS NOT NULL", key_q), collapse = " AND "),
    paste(sprintf("d.%s = s.%s", key_q, key_q), collapse = " AND ")
  )
  n <- DBI::dbExecute(con, sql)
  DBI::dbExecute(
    con,
    sprintf("DROP TABLE %s;", DBI::dbQuoteIdentifier(con, staging))
  )
  invisible(n)
}

# Ricarica integrale di una dimensione: DELETE + INSERT dalla staging temp.
# Usata per le dimensioni globali del fornitore, che sono autoritative: una
# ricarica evita che restino righe obsolete di consegne precedenti. La
# ricarica si esegue solo se il contenuto cambia: EXCEPT ALL nei due sensi
# tra staging e tabella, sulle colonne di `dim_data`, conta anche le righe
# ripetute e tratta i NULL come uguali. A contenuto invariato nessuna
# istruzione modifica la tabella, per cui su DuckLake non viene registrata
# alcuna modifica.
# Restituisce invisibilmente TRUE se la tabella è stata ricaricata, FALSE se
# il contenuto era invariato.
.reload_dim <- function(con, dim_table, dim_data) {
  staging <- paste0("__stg_", dim_table)
  tbl_q <- DBI::dbQuoteIdentifier(con, dim_table)
  stg_q <- DBI::dbQuoteIdentifier(con, staging)
  duckdb::dbWriteTable(
    con,
    staging,
    dim_data,
    temporary = TRUE,
    overwrite = TRUE
  )
  on.exit(
    try(
      DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s;", stg_q)),
      silent = TRUE
    ),
    add = TRUE
  )
  cols_csv <- paste(
    DBI::dbQuoteIdentifier(con, names(dim_data)),
    collapse = ", "
  )
  diff <- DBI::dbGetQuery(
    con,
    sprintf(
      "SELECT
         (SELECT COUNT(*) FROM (
            SELECT %1$s FROM %2$s EXCEPT ALL SELECT %1$s FROM %3$s
          )) AS n_nuove,
         (SELECT COUNT(*) FROM (
            SELECT %1$s FROM %3$s EXCEPT ALL SELECT %1$s FROM %2$s
          )) AS n_obsolete",
      cols_csv,
      stg_q,
      tbl_q
    )
  )
  if (diff$n_nuove == 0 && diff$n_obsolete == 0) {
    return(invisible(FALSE))
  }
  DBI::dbExecute(con, sprintf("DELETE FROM %s;", tbl_q))
  DBI::dbExecute(
    con,
    sprintf(
      "INSERT INTO %s (%s) SELECT %s FROM %s;",
      tbl_q,
      cols_csv,
      cols_csv,
      stg_q
    )
  )
  invisible(TRUE)
}

# Legge un CSV dim_table del fornitore (delimitatore ';'), rinomina le colonne
# secondo il DDL e restituisce una data.table deduplicata sulla chiave.
.read_dim_csv <- function(csv_path, mapping, pk) {
  dt <- data.table::fread(
    csv_path,
    sep = ";",
    colClasses = "character",
    showProgress = FALSE
  )
  miss <- setdiff(names(mapping), names(dt))
  if (length(miss)) {
    cli::cli_abort("Colonne mancanti in {.path {csv_path}}: {.val {miss}}.")
  }
  dt <- dt[, names(mapping), with = FALSE]
  data.table::setnames(dt, unname(mapping))
  dt <- dt[!is.na(get(pk)) & get(pk) != ""]
  unique(dt, by = pk)
}

# Ricarica le tre dimensioni globali (CP2021, occupazioni ESCO, skill ESCO)
# dai CSV di /data_v2/dim_table scaricati in `dim_dir`.
.load_global_dims <- function(con, dim_dir) {
  specs <- list(
    dim_cp2021 = list(
      file = "dim_occ_cp2021.csv",
      pk = "cp2021_id_level_5",
      mapping = c(
        cod_5 = "cp2021_id_level_5",
        descr_5 = "cp2021_level_5",
        cod_4 = "cp2021_id_level_4",
        descr_4 = "cp2021_level_4",
        cod_3 = "cp2021_id_level_3",
        descr_3 = "cp2021_level_3",
        cod_2 = "cp2021_id_level_2",
        descr_2 = "cp2021_level_2",
        cod_1 = "cp2021_id_level_1",
        descr_1 = "cp2021_level_1"
      )
    ),
    dim_esco_occupation = list(
      file = "dim_occ_esco.csv",
      pk = "idesco_level_5",
      mapping = c(
        idlevel_5 = "idesco_level_5",
        level_5 = "esco_level_5",
        idlevel_4 = "idesco_level_4",
        level_4 = "esco_level_4",
        idlevel_3 = "idesco_level_3",
        level_3 = "esco_level_3",
        idlevel_2 = "idesco_level_2",
        level_2 = "esco_level_2",
        idlevel_1 = "idesco_level_1",
        level_1 = "esco_level_1"
      )
    ),
    dim_esco_skill = list(
      file = "dim_esco_skills.csv",
      pk = "idescoskill_level_3",
      mapping = c(
        skill_id = "idescoskill_level_3",
        esco_v010200_label = "esco_v010200_label",
        esco_v010200_uri = "esco_v010200_uri",
        esco_v010200_obsolete = "esco_v010200_obsolete",
        esco_v010200_skillstype = "esco_v010200_skillstype",
        esco_v010200_reusetype = "esco_v010200_reusetype",
        esco_v010200_description = "esco_v010200_description",
        esco_v010200_digcomp = "esco_v010200_digcomp",
        esco_v010200_green = "esco_v010200_green",
        esco_v010200_hier_code_3 = "esco_v010200_hier_code_3",
        esco_v010200_hier_uri_3 = "esco_v010200_hier_uri_3",
        esco_v010200_hier_label_3 = "esco_v010200_hier_label_3",
        esco_v010200_hier_code_2 = "esco_v010200_hier_code_2",
        esco_v010200_hier_uri_2 = "esco_v010200_hier_uri_2",
        esco_v010200_hier_label_2 = "esco_v010200_hier_label_2",
        esco_v010200_hier_code_1 = "esco_v010200_hier_code_1",
        esco_v010200_hier_uri_1 = "esco_v010200_hier_uri_1",
        esco_v010200_hier_label_1 = "esco_v010200_hier_label_1",
        esco_v010200_hier_uri_0 = "esco_v010200_hier_uri_0",
        esco_v010200_hier_label_0 = "esco_v010200_hier_label_0",
        esco_v010200_digital = "esco_v010200_digital",
        esco_v010200_language = "esco_v010200_language",
        esco_v010200_transversal = "esco_v010200_transversal",
        esco_v010200_research = "esco_v010200_research"
      )
    )
  )

  paths <- vapply(specs, function(s) file.path(dim_dir, s$file), character(1))
  missing <- !file.exists(paths)
  if (any(missing)) {
    cli::cli_abort(c(
      "File {.path dim_table} mancanti in {.path {dim_dir}}.",
      "x" = "Non trovati: {.path {paths[missing]}}",
      "i" = "Usa {.code dim_dir = NULL} per saltare la ricarica delle dimensioni globali."
    ))
  }

  counts <- integer(length(specs))
  names(counts) <- names(specs)
  for (tbl in names(specs)) {
    spec <- specs[[tbl]]
    dt <- .read_dim_csv(paths[[tbl]], spec$mapping, spec$pk)
    ricaricata <- .reload_dim(con, tbl, dt)
    n <- nrow(dt)
    if (ricaricata) {
      cli::cli_inform(
        "Dimensione globale {.field {tbl}} ricaricata: {n} righe."
      )
    } else {
      cli::cli_inform("Dimensione globale {.field {tbl}} invariata: {n} righe.")
    }
    counts[[tbl]] <- n
  }
  invisible(counts)
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
    dim_source = d_source
  )
}

# Stream dello skills CSV in fact_skills. La CSV sorgente porta soltanto
# (general_id, date, IDESCOSKILL_LEVEL_3): le proprietà delle skill arrivano
# da dim_esco_skill, ricaricata da .load_global_dims().
.stream_skills <- function(con, skills_zip, snapshot_id) {
  csv_path <- .unzip_to_temp(skills_zip)
  on.exit(unlink(dirname(csv_path), recursive = TRUE), add = TRUE)

  csv_lit <- paste0("'", gsub("'", "''", csv_path), "'")
  read_csv <- sprintf(
    "read_csv_auto(%s, header=true, sample_size=-1)",
    csv_lit
  )

  # general_id come VARCHAR per coerenza con fact_postings. DISTINCT deduplica
  # sulla chiave completa della tabella; l'anti-join rende l'inserimento
  # idempotente senza ON CONFLICT (assente su DuckLake). Il filtro esplicito
  # su snapshot_id nella sottoquery limita la scansione di fact_skills allo
  # snapshot corrente.
  sql_fact <- sprintf(
    "INSERT INTO fact_skills (snapshot_id, general_id, idescoskill_level_3)
     SELECT s.snapshot_id, s.general_id, s.idescoskill_level_3
       FROM (
         SELECT DISTINCT
                CAST(? AS VARCHAR)          AS snapshot_id,
                CAST(general_id AS VARCHAR) AS general_id,
                idescoskill_level_3
           FROM %s
          WHERE general_id IS NOT NULL
            AND idescoskill_level_3 IS NOT NULL
            AND idescoskill_level_3 <> ''
       ) s
      WHERE NOT EXISTS (
        SELECT 1 FROM fact_skills f
         WHERE f.snapshot_id = ?
           AND f.snapshot_id = s.snapshot_id
           AND f.general_id = s.general_id
           AND f.idescoskill_level_3 = s.idescoskill_level_3
      );",
    read_csv
  )
  n <- DBI::dbExecute(con, sql_fact, params = list(snapshot_id, snapshot_id))
  invisible(as.integer(n))
}

# Conta, per ogni tabella dello schema, le chiavi di .oja_keys() duplicate e
# quelle con almeno una componente nulla. I fatti sono controllati sul solo
# snapshot, le dimensioni e dim_snapshot per intero (sono piccole).
.oja_key_violations <- function(con, snapshot_id) {
  keys <- .oja_keys()
  rows <- lapply(names(keys), function(tbl) {
    key_q <- DBI::dbQuoteIdentifier(con, keys[[tbl]])
    by_snapshot <- startsWith(tbl, "fact_")
    sql <- sprintf(
      "SELECT
         (SELECT COUNT(*) FROM (
            SELECT 1 FROM %1$s WHERE %2$s GROUP BY %3$s HAVING COUNT(*) > 1
          )) AS n_duplicate,
         (SELECT COUNT(*) FROM %1$s WHERE %2$s AND (%4$s)) AS n_null",
      DBI::dbQuoteIdentifier(con, tbl),
      if (by_snapshot) "snapshot_id = ?" else "TRUE",
      paste(key_q, collapse = ", "),
      paste(sprintf("%s IS NULL", key_q), collapse = " OR ")
    )
    res <- if (by_snapshot) {
      DBI::dbGetQuery(con, sql, params = list(snapshot_id, snapshot_id))
    } else {
      DBI::dbGetQuery(con, sql)
    }
    list(
      table = tbl,
      n_duplicate = as.integer(res$n_duplicate),
      n_null = as.integer(res$n_null)
    )
  })
  data.table::rbindlist(rows)
}

# Validazioni prima del COMMIT. Solleva con messaggio dettagliato in caso di
# errore. Su DuckLake non esistono PRIMARY KEY: l'unicità delle chiavi è
# verificata qui per tutte le tabelle, oltre all'integrità referenziale
# skill -> posting.
.validate_snapshot <- function(con, snapshot_id) {
  keys <- .oja_key_violations(con, snapshot_id)
  bad <- keys[n_duplicate > 0L | n_null > 0L]
  if (nrow(bad)) {
    detail <- sprintf(
      "%s: %d chiavi duplicate, %d chiavi con valori nulli.",
      bad$table,
      bad$n_duplicate,
      bad$n_null
    )
    cli::cli_abort(c(
      "Chiavi duplicate o con valori nulli dopo l'ingestione.",
      stats::setNames(detail, rep("x", length(detail))),
      "i" = "Snapshot: {.val {snapshot_id}}."
    ))
  }
  res <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS n_orphan_skills
       FROM fact_skills s
      WHERE s.snapshot_id = ?
        AND NOT EXISTS (
          SELECT 1 FROM fact_postings p
           WHERE p.snapshot_id = s.snapshot_id
             AND p.general_id  = s.general_id
        )",
    params = list(snapshot_id)
  )
  if (res$n_orphan_skills > 0L) {
    cli::cli_abort(c(
      "{res$n_orphan_skills} righe in fact_skills senza posting corrispondente.",
      "i" = "Snapshot: {.val {snapshot_id}}."
    ))
  }
  .validate_companyname(con, snapshot_id)
  invisible(keys)
}

# Controllo bloccante sulle ragioni sociali dello snapshot appena scritto:
# nessun valore deve avere la forma di un codice fiscale di persona fisica.
# Gira dentro la transazione di `oja_ingest_snapshot()`, quindi un residuo
# annulla la scrittura. Il messaggio riporta solo conteggi, mai valori.
.validate_companyname <- function(con, snapshot_id) {
  res <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS n_righe,
            COUNT(DISTINCT companyname) AS n_valori
       FROM fact_postings
      WHERE snapshot_id = ?
        AND (regexp_full_match(trim(companyname), ?)
          OR regexp_matches(companyname, ?))",
    params = list(snapshot_id, .RE_CF_VALORE, .RE_CF_IMMERSO)
  )
  if (res$n_righe > 0L) {
    cli::cli_abort(c(
      "Forme di codice fiscale in {.field companyname} dopo l'ingestione.",
      "x" = "{res$n_righe} righe, {res$n_valori} valori distinti.",
      "i" = "Snapshot: {.val {snapshot_id}}."
    ))
  }
  invisible(res$n_righe)
}

# 2. Ingestione di un singolo snapshot ---------------------------------------

#' Ingerisce un singolo snapshot OJA nel database
#'
#' Legge i tre archivi zip Lightcast (`<snapshot_id>_postings.zip`,
#' `<snapshot_id>_postings_raw.zip`, `<snapshot_id>_skills.zip`) presenti in
#' `zip_dir`, deduplica i posting su `general_id` mantenendo la riga con
#' `(year, month, day)_grab_date` più recente, costruisce le dimensioni
#' derivate dalle postings (UPSERT), alimenta `fact_postings` e — via DuckDB
#' `read_csv_auto` — anche `fact_skills` senza materializzare la tabella delle
#' skill (~27M righe) in R. L'intera operazione, compresa la rimozione dello
#' snapshot omonimo con `overwrite = TRUE`, è avvolta in una singola
#' transazione con validazione di unicità delle chiavi e di integrità
#' referenziale prima del COMMIT: in caso di errore il database resta
#' com'era.
#'
#' @details
#' Le dimensioni globali del fornitore (`dim_cp2021`, `dim_esco_occupation`,
#' `dim_esco_skill`) non sono derivabili dagli archivi dello snapshot: le
#' postings portano soltanto le chiavi esterne `cp2021_id_level_5` e
#' `idesco_level_5`, la tabella delle skill soltanto `idescoskill_level_3`.
#' Vengono quindi ricaricate integralmente dai tre CSV globali presenti in
#' `dim_dir` (`dim_occ_cp2021.csv`, `dim_occ_esco.csv`,
#' `dim_esco_skills.csv`, delimitatore `;`). La ricarica (`DELETE` e
#' `INSERT`) avviene solo se il contenuto dei CSV differisce da quello della
#' tabella, verificato con `EXCEPT ALL` nei due sensi: con dimensioni
#' invariate le tabelle non vengono modificate e su un catalogo DuckLake non
#' si registrano modifiche.
#'
#' Le ragioni sociali (`companyname`) passano per un oscuramento prima di
#' essere scritte: ogni forma di codice fiscale di persona fisica diventa
#' `[CF]`. E' la regola dei microdati COB (decisione D-COB-1 del piano del
#' data lake), qui senza la soglia sulle occorrenze rare, che riguarda il
#' testo libero. Sono oscurati sia il valore che e' tutto e solo un codice —
#' il caso della ditta individuale registrata con il codice del titolare —
#' sia un codice scritto accanto al nome. In quest'ultimo caso la forma
#' richiede cifre vere nelle posizioni numeriche, perche' una forma che
#' ammetta lettere ovunque cancellerebbe qualsiasi ragione sociale di sedici
#' lettere. Un controllo bloccante dentro la stessa transazione annulla la
#' scrittura se una forma sopravvive; nei messaggi compaiono solo conteggi.
#'
#' Il valore `"Unclassifiable"` puo' comparire in `idesco_level_5` come
#' sentinella: non corrisponde a nessuna chiave di `dim_esco_occupation` e i
#' join in lettura restituiscono `NA` per le descrizioni.
#'
#' Il database può essere un file DuckDB o un catalogo DuckLake (percorso
#' `ducklake:`, vedi [oja_connect()]). Le tabelle DuckLake non hanno PRIMARY
#' KEY: l'UPSERT delle dimensioni e l'inserimento delle skill usano un
#' anti-join con deduplica esplicita per chiave (a parità di chiave vince la
#' riga del posting più recente) e la validazione controlla l'unicità delle
#' chiavi di tutte le tabelle. Senza transazione esterna i dati di uno
#' snapshot OJA vengono scritti con un solo commit.
#'
#' Se `con` ha già una transazione aperta, la funzione vi partecipa senza
#' COMMIT né ROLLBACK: la conclusione della transazione e la gestione
#' dell'errore spettano al chiamante.
#'
#' @param zip_dir Directory che contiene i tre archivi.
#' @param snapshot_id Identificativo dello snapshot, es. `"ITC4_2026_2"`.
#' @param overwrite Logico. Se `TRUE`, rimuove l'eventuale snapshot omonimo
#'   gia' presente prima di reinserirlo. Default `FALSE` (errore se gia'
#'   ingerito).
#' @param dim_dir Directory che contiene i tre CSV `dim_table` globali.
#'   Default: `zip_dir`. Con `NULL` la ricarica delle dimensioni globali viene
#'   saltata (utile quando il chiamante l'ha gia' eseguita, come fa
#'   [oja_ingest_dirs()]).
#' @param path Percorso del file DuckDB o del catalogo DuckLake. Default:
#'   [oja_db_path()]. Ignorato se `con` non è `NULL`.
#' @param con Connessione in scrittura, opzionale. Quando fornita la
#'   funzione non apre né chiude connessioni.
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
  dim_dir = zip_dir,
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
  already <- exists_q$n > 0L
  if (already && !overwrite) {
    cli::cli_abort(c(
      "Snapshot {.val {snapshot_id}} gia' presente nel database.",
      "i" = "Usa {.code overwrite = TRUE} per reingerirlo."
    ))
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

  ingested_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%OS3")
  itaposts_ver <- tryCatch(
    as.character(utils::packageVersion("itaposts")),
    error = function(e) NA_character_
  )
  keys <- .oja_keys()

  # Rimozione dello snapshot omonimo, dimensioni, fatti, metadata e
  # validazione in una sola transazione: un errore annulla anche i DELETE e
  # lo snapshot precedente resta intatto.
  n_skills <- .oja_with_transaction(con, {
    if (already) {
      for (tbl in c("fact_skills", "fact_postings", "dim_snapshot")) {
        DBI::dbExecute(
          con,
          sprintf("DELETE FROM %s WHERE snapshot_id = ?;", tbl),
          params = list(snapshot_id)
        )
      }
    }

    if (!is.null(dim_dir)) {
      .load_global_dims(con, dim_dir)
    }

    cli::cli_inform("Costruzione e UPSERT delle dimensioni...")
    dims <- .build_postings_dims(postings)
    for (tbl in names(dims)) {
      .upsert_dim(con, tbl, dims[[tbl]], keys[[tbl]])
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
    n <- .stream_skills(con, zips$skills, snapshot_id)

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
        n,
        basename(zips$postings),
        basename(zips$skills),
        itaposts_ver
      )
    )

    cli::cli_inform("Validazione snapshot...")
    .validate_snapshot(con, snapshot_id)
    n
  })

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
#' Le dimensioni globali del fornitore vengono ricaricate una sola volta prima
#' del ciclo, in una transazione propria: sono identiche per tutti gli
#' snapshot, quindi ripeterne la lettura per ogni mese sarebbe lavoro
#' inutile.
#'
#' @details
#' Senza transazione esterna ogni snapshot è ingerito nella propria
#' transazione: un errore su uno snapshot viene segnalato, le sue scritture
#' vengono annullate e il ciclo prosegue con gli snapshot successivi.
#'
#' Se `con` ha già una transazione aperta, tutte le scritture vi
#' partecipano. In questo caso il primo errore interrompe il ciclo e viene
#' propagato, perché le scritture parziali di uno snapshot non possono
#' essere annullate singolarmente: il ROLLBACK spetta al chiamante.
#'
#' @param zip_dir Directory contenente gli archivi.
#' @param snapshots Vettore opzionale di `snapshot_id` da ingerire. Se
#'   `NULL` (default) ingerisce tutti quelli rilevati.
#' @param overwrite Logico. Inoltrato a [oja_ingest_snapshot()].
#' @param dim_dir Directory che contiene i tre CSV `dim_table` globali.
#'   Default: `zip_dir`. Con `NULL` la ricarica viene saltata.
#' @param path Percorso del file DuckDB o del catalogo DuckLake. Default:
#'   [oja_db_path()]. Ignorato se `con` non è `NULL`.
#' @param con Connessione in scrittura, opzionale, per esempio aperta con
#'   [oja_connect()] su un catalogo DuckLake. Quando fornita la funzione non
#'   apre né chiude connessioni: al termine la connessione resta aperta.
#'
#' @return Invisibilmente una `data.frame` con un riepilogo per ogni snapshot
#'   processato.
#' @export
#' @examples
#' \dontrun{
#'   # Database predefinito (oja_db_path())
#'   oja_ingest_dirs("~/Documents/funzioni/shared_data/oja/incoming")
#'
#'   # Connessione esterna allo schema oja di un lago DuckLake
#'   con <- oja_connect("ducklake:sqlite:/percorso/lake.sqlite", read_only = FALSE)
#'   oja_ingest_dirs("~/Documents/funzioni/shared_data/oja/incoming", con = con)
#'   oja_disconnect(con)
#' }
oja_ingest_dirs <- function(
  zip_dir,
  snapshots = NULL,
  overwrite = FALSE,
  dim_dir = zip_dir,
  path = oja_db_path(),
  con = NULL
) {
  zips <- list.files(zip_dir, pattern = "_postings\\.zip$", full.names = FALSE)
  ids <- sub("_postings\\.zip$", "", zips)
  if (!is.null(snapshots)) {
    ids <- intersect(ids, snapshots)
  }
  # Frame canonico di ritorno: usato sia dall'early-return sia come fallback
  # per ogni riga in errore. La tipizzazione esplicita e' necessaria perche'
  # do.call(rbind, ...) non inferisce i tipi quando tutte le righe sono NA,
  # e summary$snapshot_id risulterebbe NULL causando "invalid argument type"
  # nella match() di oja_sync().
  .empty_summary <- function() {
    data.frame(
      snapshot_id = character(),
      n_postings = integer(),
      n_skills = integer(),
      ingested_at = as.POSIXct(character()),
      stringsAsFactors = FALSE
    )
  }

  if (!length(ids)) {
    cli::cli_warn("Nessuno snapshot da processare in {.path {zip_dir}}.")
    return(invisible(.empty_summary()))
  }

  if (is.null(con)) {
    con <- oja_connect(path = path, read_only = FALSE)
    on.exit(oja_disconnect(con), add = TRUE)
  }
  oja_init_db(con = con)
  in_outer_txn <- .oja_in_transaction(con)

  if (!is.null(dim_dir)) {
    .oja_with_transaction(con, .load_global_dims(con, dim_dir))
  }

  rows <- lapply(ids, function(id) {
    res <- tryCatch(
      oja_ingest_snapshot(
        zip_dir = zip_dir,
        snapshot_id = id,
        overwrite = overwrite,
        dim_dir = NULL,
        con = con
      ),
      error = function(e) {
        if (in_outer_txn) {
          cli::cli_abort(
            "Ingestione dello snapshot {.val {id}} interrotta nella transazione del chiamante.",
            parent = e
          )
        }
        cli::cli_alert_danger("Snapshot {.val {id}}: {conditionMessage(e)}")
        list(
          snapshot_id = id,
          n_postings = NA_integer_,
          n_skills = NA_integer_,
          ingested_at = NA_character_
        )
      }
    )
    data.frame(
      snapshot_id = as.character(res$snapshot_id),
      n_postings = as.integer(res$n_postings),
      n_skills = as.integer(res$n_skills),
      ingested_at = as.POSIXct(res$ingested_at),
      stringsAsFactors = FALSE
    )
  })
  invisible(do.call(rbind, c(rows, list(.empty_summary()))))
}
