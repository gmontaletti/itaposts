# Generatore di fixture sintetiche minime per i test di ingestione.
# Produce in tempdir() i tre archivi zip nello schema atteso da
# oja_ingest_snapshot().

build_fixtures <- function(
  zip_dir = tempfile("itaposts_fix_"),
  snapshot_id = "TEST_2026_1",
  n_postings = 50L,
  n_skills_per = 4L,
  include_duplicates = TRUE
) {
  if (!dir.exists(zip_dir)) {
    dir.create(zip_dir, recursive = TRUE)
  }
  set.seed(42)

  ids <- seq_len(n_postings) + 100000L
  postings <- data.table::data.table(
    general_id = ids,
    year_grab_date = 2026L,
    month_grab_date = 1L,
    day_grab_date = sample.int(28L, n_postings, replace = TRUE),
    year_expire_date = 2026L,
    month_expire_date = 2L,
    day_expire_date = 28L,
    idcity = sprintf("0%05d", sample.int(20L, n_postings, replace = TRUE)),
    idprovince = "ITC48",
    idregion = "ITC4",
    idmacro_region = "ITC",
    idcountry = "IT",
    city = paste0("City", sample.int(20L, n_postings, replace = TRUE)),
    province = "Pavia",
    region = "Lombardia",
    macro_region = "Nord-Ovest",
    country = "ITALIA",
    idcontract = sample.int(5L, n_postings, replace = TRUE),
    contract = "Tempo determinato",
    ideducational_level = sample.int(6L, n_postings, replace = TRUE),
    educational_level = "Diploma",
    idsector = sample.int(50L, n_postings, replace = TRUE),
    sector = "Servizi",
    idmacro_sector = "H",
    macro_sector = "Trasporti",
    idcategory_sector = 3L,
    category_sector = "Servizi",
    idexperience = sample.int(4L, n_postings, replace = TRUE),
    experience = "Da 2 a 4 anni",
    idworking_hours = sample.int(3L, n_postings, replace = TRUE),
    working_hours = "Full time",
    idsalary = NA_integer_,
    salary = NA_character_,
    salaryvalue = stats::runif(n_postings, 1500, 3500),
    cp2021_id_level_5 = sprintf(
      "%s.0",
      sample(c("8.1.3.2", "2.5.1.1", "3.1.1.2"), n_postings, replace = TRUE)
    ),
    cp2021_id_level_4 = sample(
      c("8.1.3.2", "2.5.1.1", "3.1.1.2"),
      n_postings,
      replace = TRUE
    ),
    cp2021_id_level_3 = sample(
      c("8.1.3", "2.5.1", "3.1.1"),
      n_postings,
      replace = TRUE
    ),
    cp2021_id_level_2 = sample(
      c("8.1", "2.5", "3.1"),
      n_postings,
      replace = TRUE
    ),
    cp2021_id_level_1 = sample(c("8", "2", "3"), n_postings, replace = TRUE),
    cp2021_level_5 = "L5",
    cp2021_level_4 = "L4",
    cp2021_level_3 = "L3",
    cp2021_level_2 = "L2",
    cp2021_level_1 = "L1",
    source = sample(c("IT_RANDSTAD", "IT_INDEED"), n_postings, replace = TRUE),
    source_category_analysis = "agency",
    source_relevance = "high",
    idesco_level_4 = sample(c("9333", "1234"), n_postings, replace = TRUE),
    idesco_level_5 = sample(c("9333.8", "1234.5"), n_postings, replace = TRUE),
    uri = "http://data.europa.eu/esco/occupation/test",
    esco_level_5 = "warehouse worker",
    esco_level_4 = "Freight handlers"
  )

  if (isTRUE(include_duplicates)) {
    dup_idx <- sample.int(n_postings, 5L)
    dups <- data.table::copy(postings[dup_idx])
    dups[, day_grab_date := pmax(day_grab_date - 5L, 1L)] # dup piu' vecchio
    postings <- data.table::rbindlist(list(postings, dups))
  }

  postings_raw <- data.table::data.table(
    general_id = ids,
    companyname = sample(
      c("Acme Spa", "Beta Srl", "Randstad"),
      n_postings,
      replace = TRUE
    )
  )

  skills <- data.table::CJ(
    general_id = ids,
    IDESCOSKILL_LEVEL_3 = sprintf("ESCOv1_%d", seq_len(n_skills_per))
  )
  skills[, `:=`(
    ESCOSKILL_LEVEL_3 = paste("skill", IDESCOSKILL_LEVEL_3),
    ESCO_V0101_OBSOLETE = "N",
    ESCO_v0101_DESCRIPTION = "lorem ipsum",
    ONET_HIER_LEVEL_1 = "Work Styles",
    ONET_HIER_LEVEL_2 = "Conscientiousness",
    ONET_HIER_LEVEL_3 = "Dependability",
    PILLAR_SOFTSKILLS = "",
    PILLAR_DIGITALSKILLS = "",
    PILLAR_BIGDATA = "",
    ESCO_V0101_URI = "http://data.europa.eu/esco/skill/test",
    ESCO_V0101_SKILLSTYPE = "skill/competence",
    ESCO_V0101_REUSETYPE = "cross-sector",
    ESCO_V0101_DIGCOMP = "N",
    ESCO_V0101_GREEN = sample(c("Y", "N"), .N, replace = TRUE),
    ESCO_V0101_ICT = "N",
    ESCO_V0101_LANGUAGE = "N",
    ESCO_V0101_TRANSVERSAL = "",
    ESCO_V0101_HIER_CODE_3 = "S3.3.3",
    ESCO_V0101_HIER_URI_3 = "http://x/3",
    ESCO_V0101_HIER_LABEL_3 = "lvl3",
    ESCO_V0101_HIER_CODE_2 = "S3.3",
    ESCO_V0101_HIER_URI_2 = "http://x/2",
    ESCO_V0101_HIER_LABEL_2 = "lvl2",
    ESCO_V0101_HIER_CODE_1 = "S3",
    ESCO_V0101_HIER_URI_1 = "http://x/1",
    ESCO_V0101_HIER_LABEL_1 = "lvl1",
    ESCO_V0101_HIER_CODE_0 = "S",
    ESCO_V0101_HIER_URI_0 = "http://x/0",
    ESCO_V0101_HIER_LABEL_0 = "abilita"
  )]
  skills[, year_grab_date := 2026L]
  skills[, month_grab_date := 1L]
  data.table::setcolorder(
    skills,
    c(
      "general_id",
      "year_grab_date",
      "month_grab_date",
      "IDESCOSKILL_LEVEL_3",
      "ESCOSKILL_LEVEL_3"
    )
  )

  csv_dir <- tempfile("itaposts_csv_")
  dir.create(csv_dir)
  on.exit(unlink(csv_dir, recursive = TRUE), add = TRUE)

  p_csv <- file.path(csv_dir, paste0(snapshot_id, "_postings.csv"))
  pr_csv <- file.path(csv_dir, paste0(snapshot_id, "_postings_raw.csv"))
  s_csv <- file.path(csv_dir, paste0(snapshot_id, "_skills.csv"))
  data.table::fwrite(postings, p_csv)
  data.table::fwrite(postings_raw, pr_csv)
  data.table::fwrite(skills, s_csv)

  zip_one <- function(csv_file) {
    zip_path <- file.path(zip_dir, sub("\\.csv$", ".zip", basename(csv_file)))
    old_wd <- setwd(dirname(csv_file))
    on.exit(setwd(old_wd), add = TRUE)
    utils::zip(zip_path, basename(csv_file), flags = "-q")
    zip_path
  }
  invisible(list(
    zip_dir = zip_dir,
    snapshot_id = snapshot_id,
    n_postings_unique = n_postings,
    n_skills_total = nrow(skills),
    postings = zip_one(p_csv),
    postings_raw = zip_one(pr_csv),
    skills = zip_one(s_csv)
  ))
}

with_temp_db <- function(code) {
  db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(c(db, paste0(db, ".wal"))), add = TRUE)
  withr::with_envvar(
    c(SHARED_DATA_DIR = dirname(db)),
    {
      # forziamo il path a un file specifico, non al default oja/itposts.duckdb
      eval.parent(substitute(code))
    }
  )
}
