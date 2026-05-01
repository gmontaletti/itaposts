#' itaposts: Importazione e Normalizzazione di OJA Italiani in DuckDB
#'
#' Il pacchetto fornisce una pipeline per portare i dati OJA Lightcast
#' (annunci di lavoro, skill ESCO, ragioni sociali) da archivi zip mensili a
#' un database DuckDB normalizzato condiviso, e una API di lettura per i
#' consumatori a valle (in primis [skillviz](https://github.com/gmontaletti/skillviz)).
#'
#' @section Punti d'ingresso principali:
#' * [oja_db_path()], [oja_connect()] — risoluzione percorso e connessione.
#' * [oja_init_db()] — DDL idempotente.
#' * [oja_ingest_snapshot()], [oja_ingest_dirs()] — ingestione.
#' * [oja_postings()], [oja_skills()], [oja_snapshots()] — lettura lazy.
#' * [oja_normalised()] — shim di compatibilita' verso `skillviz::normalize_ojv()`.
#'
#' @keywords internal
"_PACKAGE"

## usethis namespace: start
#' @importFrom data.table :=
#' @importFrom rlang .data
#' @importFrom dbplyr sql
## usethis namespace: end
NULL

# Silenzia i NOTE di R CMD check sulle non-standard evaluation di data.table.
utils::globalVariables(c(
  ".",
  "i.companyname",
  "general_id",
  "grab_date",
  "expire_date",
  "year_grab_date",
  "month_grab_date",
  "day_grab_date",
  "year_expire_date",
  "month_expire_date",
  "day_expire_date",
  "idcity",
  "city",
  "idprovince",
  "province",
  "idregion",
  "region",
  "idmacro_region",
  "macro_region",
  "idcountry",
  "country",
  "idcontract",
  "contract",
  "ideducational_level",
  "educational_level",
  "idsector",
  "sector",
  "idmacro_sector",
  "macro_sector",
  "idcategory_sector",
  "category_sector",
  "idexperience",
  "experience",
  "idworking_hours",
  "working_hours",
  "idsalary",
  "salary",
  "cp2021_id_level_1",
  "cp2021_id_level_2",
  "cp2021_id_level_3",
  "cp2021_id_level_4",
  "cp2021_id_level_5",
  "cp2021_level_1",
  "cp2021_level_2",
  "cp2021_level_3",
  "cp2021_level_4",
  "cp2021_level_5",
  "idesco_level_4",
  "idesco_level_5",
  "esco_level_4",
  "esco_level_5",
  "uri",
  "source_category_analysis",
  "source_relevance",
  "companyname"
))
