# 1. DDL del database OJA -----------------------------------------------------

# Lo schema completo: due tabelle dei fatti, undici dimensioni, una di
# metadata. Ogni statement è idempotente (CREATE TABLE IF NOT EXISTS).
# Con `primary_keys = FALSE` le clausole PRIMARY KEY vengono rimosse: DuckLake
# non supporta vincoli di chiave e l'unicità delle chiavi dichiarate in
# .oja_keys() è verificata da .validate_snapshot() prima del COMMIT.

.oja_ddl <- function(primary_keys = TRUE) {
  ddl <- c(
    # 1.1 Dimensioni derivate dalle postings (UPSERT incrementale)
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
    dim_source = "
      CREATE TABLE IF NOT EXISTS dim_source (
        source                    VARCHAR PRIMARY KEY,
        source_category_analysis  VARCHAR,
        source_relevance          VARCHAR
      )
    ",

    # 1.2 Dimensioni globali del fornitore (ricaricate integralmente a ogni
    # ingest da /data_v2/dim_table: le postings e le skills portano soltanto
    # le chiavi esterne, non piu' le descrizioni gerarchiche).
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
        idesco_level_3  VARCHAR,
        esco_level_3    VARCHAR,
        idesco_level_2  VARCHAR,
        esco_level_2    VARCHAR,
        idesco_level_1  VARCHAR,
        esco_level_1    VARCHAR
      )
    ",
    dim_esco_skill = "
      CREATE TABLE IF NOT EXISTS dim_esco_skill (
        idescoskill_level_3          VARCHAR PRIMARY KEY,
        esco_v010200_label           VARCHAR,
        esco_v010200_uri             VARCHAR,
        esco_v010200_obsolete        VARCHAR,
        esco_v010200_skillstype      VARCHAR,
        esco_v010200_reusetype       VARCHAR,
        esco_v010200_description     VARCHAR,
        esco_v010200_digcomp         VARCHAR,
        esco_v010200_green           VARCHAR,
        esco_v010200_hier_code_3     VARCHAR,
        esco_v010200_hier_uri_3      VARCHAR,
        esco_v010200_hier_label_3    VARCHAR,
        esco_v010200_hier_code_2     VARCHAR,
        esco_v010200_hier_uri_2      VARCHAR,
        esco_v010200_hier_label_2    VARCHAR,
        esco_v010200_hier_code_1     VARCHAR,
        esco_v010200_hier_uri_1      VARCHAR,
        esco_v010200_hier_label_1    VARCHAR,
        esco_v010200_hier_uri_0      VARCHAR,
        esco_v010200_hier_label_0    VARCHAR,
        esco_v010200_digital         VARCHAR,
        esco_v010200_language        VARCHAR,
        esco_v010200_transversal     VARCHAR,
        esco_v010200_research        VARCHAR
      )
    ",

    # 1.3 Metadata
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

    # 1.4 Fatti
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
  if (!primary_keys) {
    ddl <- gsub(",\\s*PRIMARY KEY\\s*\\([^)]*\\)", "", ddl)
    ddl <- gsub("\\s+PRIMARY KEY", "", ddl)
  }
  ddl
}

# Chiavi logiche di ogni tabella. Coincidono con le PRIMARY KEY del DDL DuckDB
# e ne fanno le veci su DuckLake: le usano l'upsert delle dimensioni e la
# validazione di unicità.
.oja_keys <- function() {
  list(
    dim_geography = "idcity",
    dim_contract = "idcontract",
    dim_education = "ideducational_level",
    dim_sector = "idsector",
    dim_experience = "idexperience",
    dim_working_hours = "idworking_hours",
    dim_salary = "idsalary",
    dim_source = "source",
    dim_cp2021 = "cp2021_id_level_5",
    dim_esco_occupation = "idesco_level_5",
    dim_esco_skill = "idescoskill_level_3",
    dim_snapshot = "snapshot_id",
    fact_postings = c("snapshot_id", "general_id"),
    fact_skills = c("snapshot_id", "general_id", "idescoskill_level_3")
  )
}

# 2. Inizializzazione idempotente --------------------------------------------

#' Inizializza il database DuckDB OJA
#'
#' Crea (se non esistono) tutte le tabelle dello schema OJA: due tabelle dei
#' fatti (`fact_postings`, `fact_skills`), undici dimensioni e la tabella di
#' metadata `dim_snapshot`. La funzione e' idempotente: chiamarla su un
#' database gia' inizializzato non produce errori ne' modifica i dati.
#'
#' Le dimensioni si dividono in due gruppi: quelle derivate dalle postings
#' (geografia, contratto, istruzione, settore, esperienza, orario, salario,
#' fonte), popolate per UPSERT incrementale a ogni snapshot, e quelle globali
#' del fornitore (`dim_cp2021`, `dim_esco_occupation`, `dim_esco_skill`),
#' ricaricate integralmente dai file `dim_table` a ogni ingest.
#'
#' Apre una connessione in scrittura sul percorso `path` e la chiude prima di
#' restituire. Se il chiamante ha già una connessione in scrittura aperta può
#' passarla via `con`; in tal caso non viene aperta né chiusa alcuna
#' connessione aggiuntiva.
#'
#' @details
#' Su un database DuckDB le tabelle hanno PRIMARY KEY sulle chiavi logiche.
#' Quando il database corrente della connessione è un catalogo DuckLake
#' (rilevato con `duckdb_databases()`), le tabelle vengono create senza
#' PRIMARY KEY, perché DuckLake non supporta vincoli di chiave: l'unicità
#' delle chiavi è verificata dall'ingestione prima del COMMIT. Le tabelle
#' sono create nello schema corrente, cioè `lake.oja` per le connessioni
#' aperte con [oja_connect()] su un percorso `ducklake:`; lo schema deve
#' esistere.
#'
#' @param path Percorso del file DuckDB o del catalogo DuckLake (prefisso
#'   `ducklake:`). Default: [oja_db_path()]. Ignorato se `con` non è `NULL`.
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
  if (is.null(con)) {
    con <- oja_connect(path = path, read_only = FALSE)
    on.exit(oja_disconnect(con), add = TRUE)
  }
  ddl <- .oja_ddl(primary_keys = !.oja_is_ducklake(con))
  for (stmt in ddl) {
    DBI::dbExecute(con, stmt)
  }
  invisible(names(ddl))
}
