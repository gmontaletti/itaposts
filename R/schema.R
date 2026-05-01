# 1. DDL del database OJA -----------------------------------------------------

# Lo schema completo: due tabelle dei fatti, dieci dimensioni, una di metadata.
# Ogni statement e' idempotente (CREATE TABLE IF NOT EXISTS).

.oja_ddl <- function() {
  c(
    # 1.1 Dimensioni statiche
    dim_geography = "
      CREATE TABLE IF NOT EXISTS dim_geography (
        idcity          VARCHAR PRIMARY KEY,
        city            VARCHAR,
        idprovince      VARCHAR,
        province        VARCHAR,
        idregion        VARCHAR,
        region          VARCHAR,
        idmacro_region  VARCHAR,
        macro_region    VARCHAR,
        idcountry       VARCHAR,
        country         VARCHAR
      )
    ",
    dim_contract = "
      CREATE TABLE IF NOT EXISTS dim_contract (
        idcontract  VARCHAR PRIMARY KEY,
        contract    VARCHAR
      )
    ",
    dim_education = "
      CREATE TABLE IF NOT EXISTS dim_education (
        ideducational_level  VARCHAR PRIMARY KEY,
        educational_level    VARCHAR
      )
    ",
    dim_sector = "
      CREATE TABLE IF NOT EXISTS dim_sector (
        idsector            VARCHAR PRIMARY KEY,
        sector              VARCHAR,
        idmacro_sector      VARCHAR,
        macro_sector        VARCHAR,
        idcategory_sector   VARCHAR,
        category_sector     VARCHAR
      )
    ",
    dim_experience = "
      CREATE TABLE IF NOT EXISTS dim_experience (
        idexperience  VARCHAR PRIMARY KEY,
        experience    VARCHAR
      )
    ",
    dim_working_hours = "
      CREATE TABLE IF NOT EXISTS dim_working_hours (
        idworking_hours  VARCHAR PRIMARY KEY,
        working_hours    VARCHAR
      )
    ",
    dim_salary = "
      CREATE TABLE IF NOT EXISTS dim_salary (
        idsalary  VARCHAR PRIMARY KEY,
        salary    VARCHAR
      )
    ",
    dim_cp2021 = "
      CREATE TABLE IF NOT EXISTS dim_cp2021 (
        cp2021_id_level_5  VARCHAR PRIMARY KEY,
        cp2021_level_5     VARCHAR,
        cp2021_id_level_4  VARCHAR,
        cp2021_level_4     VARCHAR,
        cp2021_id_level_3  VARCHAR,
        cp2021_level_3     VARCHAR,
        cp2021_id_level_2  VARCHAR,
        cp2021_level_2     VARCHAR,
        cp2021_id_level_1  VARCHAR,
        cp2021_level_1     VARCHAR
      )
    ",
    dim_esco_occupation = "
      CREATE TABLE IF NOT EXISTS dim_esco_occupation (
        idesco_level_5  VARCHAR PRIMARY KEY,
        esco_level_5    VARCHAR,
        idesco_level_4  VARCHAR,
        esco_level_4    VARCHAR,
        uri             VARCHAR
      )
    ",
    dim_source = "
      CREATE TABLE IF NOT EXISTS dim_source (
        source                    VARCHAR PRIMARY KEY,
        source_category_analysis  VARCHAR,
        source_relevance          VARCHAR
      )
    ",
    dim_esco_skill = "
      CREATE TABLE IF NOT EXISTS dim_esco_skill (
        idescoskill_level_3        VARCHAR PRIMARY KEY,
        escoskill_level_3          VARCHAR,
        esco_v0101_obsolete        VARCHAR,
        esco_v0101_description     VARCHAR,
        onet_hier_level_1          VARCHAR,
        onet_hier_level_2          VARCHAR,
        onet_hier_level_3          VARCHAR,
        pillar_softskills          VARCHAR,
        pillar_digitalskills       VARCHAR,
        pillar_bigdata             VARCHAR,
        esco_v0101_uri             VARCHAR,
        esco_v0101_skillstype      VARCHAR,
        esco_v0101_reusetype       VARCHAR,
        esco_v0101_digcomp         VARCHAR,
        esco_v0101_green           VARCHAR,
        esco_v0101_ict             VARCHAR,
        esco_v0101_language        VARCHAR,
        esco_v0101_transversal     VARCHAR,
        esco_v0101_hier_code_3     VARCHAR,
        esco_v0101_hier_uri_3      VARCHAR,
        esco_v0101_hier_label_3    VARCHAR,
        esco_v0101_hier_code_2     VARCHAR,
        esco_v0101_hier_uri_2      VARCHAR,
        esco_v0101_hier_label_2    VARCHAR,
        esco_v0101_hier_code_1     VARCHAR,
        esco_v0101_hier_uri_1      VARCHAR,
        esco_v0101_hier_label_1    VARCHAR,
        esco_v0101_hier_code_0     VARCHAR,
        esco_v0101_hier_uri_0      VARCHAR,
        esco_v0101_hier_label_0    VARCHAR
      )
    ",

    # 1.2 Metadata
    dim_snapshot = "
      CREATE TABLE IF NOT EXISTS dim_snapshot (
        snapshot_id           VARCHAR PRIMARY KEY,
        region_code           VARCHAR,
        year                  INTEGER,
        month                 INTEGER,
        ingested_at           TIMESTAMP,
        n_postings            BIGINT,
        n_skills              BIGINT,
        source_zip_postings   VARCHAR,
        source_zip_skills     VARCHAR,
        itaposts_version      VARCHAR
      )
    ",

    # 1.3 Fatti
    fact_postings = "
      CREATE TABLE IF NOT EXISTS fact_postings (
        snapshot_id          VARCHAR NOT NULL,
        general_id           VARCHAR NOT NULL,
        region_code          VARCHAR,
        grab_date            DATE,
        expire_date          DATE,
        idcity               VARCHAR,
        idcontract           VARCHAR,
        ideducational_level  VARCHAR,
        idsector             VARCHAR,
        idexperience         VARCHAR,
        idworking_hours      VARCHAR,
        idsalary             VARCHAR,
        salaryvalue          DOUBLE,
        idesco_level_5       VARCHAR,
        cp2021_id_level_5    VARCHAR,
        source               VARCHAR,
        companyname          VARCHAR,
        PRIMARY KEY (snapshot_id, general_id)
      )
    ",
    fact_skills = "
      CREATE TABLE IF NOT EXISTS fact_skills (
        snapshot_id          VARCHAR NOT NULL,
        general_id           VARCHAR NOT NULL,
        idescoskill_level_3  VARCHAR NOT NULL,
        PRIMARY KEY (snapshot_id, general_id, idescoskill_level_3)
      )
    "
  )
}

# 2. Inizializzazione idempotente --------------------------------------------

#' Inizializza il database DuckDB OJA
#'
#' Crea (se non esistono) tutte le tabelle dello schema OJA: due tabelle dei
#' fatti (`fact_postings`, `fact_skills`), dieci dimensioni e la tabella di
#' metadata `dim_snapshot`. La funzione e' idempotente: chiamarla su un
#' database gia' inizializzato non produce errori ne' modifica i dati.
#'
#' Apre una connessione in scrittura sul percorso `path` e la chiude prima di
#' restituire. Se il chiamante ha gia' una connessione in scrittura aperta puo'
#' passarla via `con`; in tal caso non viene aperta ne' chiusa alcuna
#' connessione aggiuntiva.
#'
#' @param path Percorso del file DuckDB. Default: [oja_db_path()]. Ignorato se
#'   `con` non e' `NULL`.
#' @param con Connessione DuckDB in scrittura, opzionale. Quando fornita la
#'   funzione si limita a eseguire il DDL.
#'
#' @return Invisibilmente i nomi delle tabelle dello schema.
#' @export
#' @examples
#' \dontrun{
#'   oja_init_db()
#' }
oja_init_db <- function(path = oja_db_path(), con = NULL) {
  ddl <- .oja_ddl()
  if (is.null(con)) {
    con <- oja_connect(path = path, read_only = FALSE)
    on.exit(oja_disconnect(con), add = TRUE)
  }
  for (stmt in ddl) {
    DBI::dbExecute(con, stmt)
  }
  invisible(names(ddl))
}
