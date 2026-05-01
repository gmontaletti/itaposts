# 1. Shim di compatibilita' verso skillviz -----------------------------------

# Costruisce la query SQL che ricostruisce la tabella postings nella forma
# attesa da skillviz::normalize_ojv() (tutte le colonne sorgente piu' le date
# decostruite in (year_, month_, day_)).
.sql_postings_wide <- function() {
  "
    SELECT
      CAST(f.general_id AS BIGINT) AS general_id,
      EXTRACT(YEAR  FROM f.grab_date)   AS year_grab_date,
      EXTRACT(MONTH FROM f.grab_date)   AS month_grab_date,
      EXTRACT(DAY   FROM f.grab_date)   AS day_grab_date,
      EXTRACT(YEAR  FROM f.expire_date) AS year_expire_date,
      EXTRACT(MONTH FROM f.expire_date) AS month_expire_date,
      EXTRACT(DAY   FROM f.expire_date) AS day_expire_date,
      f.idcity, g.idprovince, g.idregion, g.idmacro_region, g.idcountry,
      g.city, g.province, g.region, g.macro_region, g.country,
      f.idcontract, c.contract,
      f.ideducational_level, e.educational_level,
      f.idsector, s.sector, s.idmacro_sector, s.macro_sector,
      s.idcategory_sector, s.category_sector,
      f.idexperience, x.experience,
      f.idworking_hours, h.working_hours,
      f.idsalary, sa.salary, f.salaryvalue,
      f.cp2021_id_level_5, cp.cp2021_id_level_4, cp.cp2021_id_level_3,
      cp.cp2021_id_level_2, cp.cp2021_id_level_1,
      cp.cp2021_level_5, cp.cp2021_level_4, cp.cp2021_level_3,
      cp.cp2021_level_2, cp.cp2021_level_1,
      f.source, src.source_category_analysis, src.source_relevance,
      eo.idesco_level_4, f.idesco_level_5, eo.uri,
      eo.esco_level_5, eo.esco_level_4,
      f.snapshot_id, f.region_code, f.companyname
    FROM fact_postings f
    LEFT JOIN dim_geography       g  ON g.idcity              = f.idcity
    LEFT JOIN dim_contract        c  ON c.idcontract          = f.idcontract
    LEFT JOIN dim_education       e  ON e.ideducational_level = f.ideducational_level
    LEFT JOIN dim_sector          s  ON s.idsector            = f.idsector
    LEFT JOIN dim_experience      x  ON x.idexperience        = f.idexperience
    LEFT JOIN dim_working_hours   h  ON h.idworking_hours     = f.idworking_hours
    LEFT JOIN dim_salary          sa ON sa.idsalary           = f.idsalary
    LEFT JOIN dim_cp2021          cp ON cp.cp2021_id_level_5  = f.cp2021_id_level_5
    LEFT JOIN dim_esco_occupation eo ON eo.idesco_level_5     = f.idesco_level_5
    LEFT JOIN dim_source          src ON src.source           = f.source
  "
}

# Query SQL per skills "lunghe" arricchite con le proprieta' di skill.
.sql_skills_wide <- function() {
  "
    SELECT
      CAST(fs.general_id AS BIGINT) AS general_id,
      EXTRACT(YEAR  FROM fp.grab_date) AS year_grab_date,
      EXTRACT(MONTH FROM fp.grab_date) AS month_grab_date,
      fs.idescoskill_level_3                     AS IDESCOSKILL_LEVEL_3,
      d.escoskill_level_3                        AS ESCOSKILL_LEVEL_3,
      d.esco_v0101_obsolete                      AS ESCO_V0101_OBSOLETE,
      d.esco_v0101_description                   AS ESCO_v0101_DESCRIPTION,
      d.onet_hier_level_1                        AS ONET_HIER_LEVEL_1,
      d.onet_hier_level_2                        AS ONET_HIER_LEVEL_2,
      d.onet_hier_level_3                        AS ONET_HIER_LEVEL_3,
      d.pillar_softskills                        AS PILLAR_SOFTSKILLS,
      d.pillar_digitalskills                     AS PILLAR_DIGITALSKILLS,
      d.pillar_bigdata                           AS PILLAR_BIGDATA,
      d.esco_v0101_uri                           AS ESCO_V0101_URI,
      d.esco_v0101_skillstype                    AS ESCO_V0101_SKILLSTYPE,
      d.esco_v0101_reusetype                     AS ESCO_V0101_REUSETYPE,
      d.esco_v0101_digcomp                       AS ESCO_V0101_DIGCOMP,
      d.esco_v0101_green                         AS ESCO_V0101_GREEN,
      d.esco_v0101_ict                           AS ESCO_V0101_ICT,
      d.esco_v0101_language                      AS ESCO_V0101_LANGUAGE,
      d.esco_v0101_transversal                   AS ESCO_V0101_TRANSVERSAL,
      d.esco_v0101_hier_code_3                   AS ESCO_V0101_HIER_CODE_3,
      d.esco_v0101_hier_uri_3                    AS ESCO_V0101_HIER_URI_3,
      d.esco_v0101_hier_label_3                  AS ESCO_V0101_HIER_LABEL_3,
      d.esco_v0101_hier_code_2                   AS ESCO_V0101_HIER_CODE_2,
      d.esco_v0101_hier_uri_2                    AS ESCO_V0101_HIER_URI_2,
      d.esco_v0101_hier_label_2                  AS ESCO_V0101_HIER_LABEL_2,
      d.esco_v0101_hier_code_1                   AS ESCO_V0101_HIER_CODE_1,
      d.esco_v0101_hier_uri_1                    AS ESCO_V0101_HIER_URI_1,
      d.esco_v0101_hier_label_1                  AS ESCO_V0101_HIER_LABEL_1,
      d.esco_v0101_hier_code_0                   AS ESCO_V0101_HIER_CODE_0,
      d.esco_v0101_hier_uri_0                    AS ESCO_V0101_HIER_URI_0,
      d.esco_v0101_hier_label_0                  AS ESCO_V0101_HIER_LABEL_0,
      fs.snapshot_id
    FROM fact_skills fs
    LEFT JOIN fact_postings   fp ON fp.snapshot_id = fs.snapshot_id
                                AND fp.general_id  = fs.general_id
    LEFT JOIN dim_esco_skill  d  ON d.idescoskill_level_3 = fs.idescoskill_level_3
  "
}

#' Forma compatibile con `skillviz::normalize_ojv()`
#'
#' Ricostruisce dal database DuckDB la lista a tre elementi (`postings`,
#' `skills`, `companies`) attesa dai consumatori a valle. Le `postings`
#' tornano "larghe" con tutte le colonne sorgente; le `skills` riportano
#' i nomi originali in maiuscolo come nella CSV Lightcast; le `companies`
#' riproducono la coppia `general_id`/`companyname`. Le tre tabelle hanno
#' chiave su `general_id`.
#'
#' @param con Connessione restituita da [oja_connect()].
#' @param snapshots Vettore opzionale di `snapshot_id` da includere.
#' @param region_code Vettore opzionale di codici regione.
#' @param years,months Vettori opzionali di anni/mesi da intersecare con gli
#'   snapshot disponibili (`dim_snapshot.year` / `month`).
#' @param verbose Logico. Stampa il numero di righe per tabella.
#'
#' @return Una `list(postings, skills, companies)` di `data.table`.
#' @export
#' @examples
#' \dontrun{
#'   con <- oja_connect()
#'   on.exit(oja_disconnect(con), add = TRUE)
#'   ojv <- oja_normalised(con, snapshots = "ITC4_2026_2")
#' }
oja_normalised <- function(
  con,
  snapshots = NULL,
  region_code = NULL,
  years = NULL,
  months = NULL,
  verbose = TRUE
) {
  effective <- .resolve_year_month_snapshots(con, snapshots, years, months)
  if (!is.null(effective) && length(effective) == 0L) {
    effective <- "__no_match__"
  }

  filt <- "WHERE 1=1"
  params <- list()
  if (!is.null(effective)) {
    filt <- paste0(
      filt,
      " AND f.snapshot_id IN (",
      paste(rep("?", length(effective)), collapse = ","),
      ")"
    )
    params <- c(params, as.list(effective))
  }
  if (!is.null(region_code)) {
    filt <- paste0(
      filt,
      " AND f.region_code IN (",
      paste(rep("?", length(region_code)), collapse = ","),
      ")"
    )
    params <- c(params, as.list(region_code))
  }

  sql_p <- paste0(.sql_postings_wide(), " ", filt)
  postings <- DBI::dbGetQuery(con, sql_p, params = params)
  data.table::setDT(postings)

  # Skills/Companies condividono il filtro postings via subquery sulla CTE.
  s_filt <- "WHERE 1=1"
  s_params <- list()
  if (!is.null(effective)) {
    s_filt <- paste0(
      s_filt,
      " AND fs.snapshot_id IN (",
      paste(rep("?", length(effective)), collapse = ","),
      ")"
    )
    s_params <- c(s_params, as.list(effective))
  }
  if (!is.null(region_code)) {
    s_filt <- paste0(
      s_filt,
      " AND fp.region_code IN (",
      paste(rep("?", length(region_code)), collapse = ","),
      ")"
    )
    s_params <- c(s_params, as.list(region_code))
  }
  sql_s <- paste0(.sql_skills_wide(), " ", s_filt)
  skills <- DBI::dbGetQuery(con, sql_s, params = s_params)
  data.table::setDT(skills)

  c_sql <- paste0(
    "SELECT CAST(general_id AS BIGINT) AS general_id, companyname FROM fact_postings f ",
    filt
  )
  companies <- DBI::dbGetQuery(con, c_sql, params = params)
  data.table::setDT(companies)
  companies <- companies[!is.na(companyname) & companyname != ""]

  if (nrow(postings) > 0L) {
    data.table::setkeyv(postings, "general_id")
  }
  if (nrow(skills) > 0L) {
    data.table::setkeyv(skills, "general_id")
  }
  if (nrow(companies) > 0L) {
    data.table::setkeyv(companies, "general_id")
  }

  if (isTRUE(verbose)) {
    cli::cli_inform(c(
      "i" = "postings:  {nrow(postings)} righe",
      "i" = "skills:    {nrow(skills)} righe",
      "i" = "companies: {nrow(companies)} righe"
    ))
  }

  list(postings = postings, skills = skills, companies = companies)
}
