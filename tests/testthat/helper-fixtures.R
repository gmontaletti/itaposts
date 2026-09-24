# Generatore di fixture sintetiche minime per i test di ingestione.
# Riproduce la consegna `data_v2` del fornitore: i tre archivi zip dello
# snapshot (postings ridotte alle sole chiavi esterne, skills ridotte alla
# sola chiave della skill) piu' i tre CSV `dim_table` globali che portano le
# gerarchie CP2021, ESCO occupazioni ed ESCO skill.

# 1. Universi dei codici condivisi tra fatti e dimensioni ---------------------

# Le dimensioni globali sono costruite da questi vettori, non dai valori
# campionati: garantisce che ogni chiave esterna presente nei fatti trovi
# corrispondenza in dimensione, quindi che i join di oja_normalised()
# restituiscano descrizioni non NA.
.fx_cp2021_codes <- c("8.1.3.2.0", "2.5.1.1.0", "3.1.1.2.0")
.fx_esco_codes <- c("9333.8", "2411.1")

# Gerarchia CP2021 (ISTAT): un livello per componente del codice puntato.
.fx_dim_cp2021 <- function() {
  data.table::data.table(
    cod_5 = .fx_cp2021_codes,
    cod_4 = c("8.1.3.2", "2.5.1.1", "3.1.1.2"),
    cod_3 = c("8.1.3", "2.5.1", "3.1.1"),
    cod_2 = c("8.1", "2.5", "3.1"),
    cod_1 = c("8", "2", "3"),
    descr_5 = c(
      "Personale non qualificato addetto alla pulizia di veicoli",
      "Specialisti in contabilità",
      "Tecnici informatici"
    ),
    descr_4 = c(
      "Personale non qualificato addetto alla pulizia di veicoli",
      "Specialisti in contabilità",
      "Tecnici informatici"
    ),
    descr_3 = c(
      "Personale non qualificato nei servizi di pulizia",
      "Specialisti in scienze gestionali, commerciali e bancarie",
      "Tecnici delle scienze quantitative, fisiche e chimiche"
    ),
    descr_2 = c(
      "Professioni non qualificate nelle attività gestionali e nei servizi",
      "Specialisti in scienze umane, sociali, artistiche e gestionali",
      "Professioni tecniche in campo scientifico e ingegneristico"
    ),
    descr_1 = c(
      "Professioni non qualificate",
      "Professioni intellettuali, scientifiche e di elevata specializzazione",
      "Professioni tecniche"
    )
  )
}

# Gerarchia ESCO delle occupazioni (ISCO-08): i livelli 1-4 sono prefissi del
# codice a quattro cifre, il livello 5 aggiunge il suffisso ESCO.
.fx_dim_esco_occupation <- function() {
  data.table::data.table(
    idlevel_5 = .fx_esco_codes,
    idlevel_4 = c("9333", "2411"),
    idlevel_3 = c("933", "241"),
    idlevel_2 = c("93", "24"),
    idlevel_1 = c("9", "2"),
    level_5 = c("addetto al carico e scarico merci", "contabile"),
    level_4 = c(
      "Facchini e addetti alla movimentazione merci",
      "Contabili"
    ),
    level_3 = c(
      "Manodopera per il trasporto e il magazzinaggio",
      "Specialisti in finanza e contabilità"
    ),
    level_2 = c(
      "Manodopera nelle costruzioni, nell'industria e nei trasporti",
      "Specialisti in scienze gestionali e commerciali"
    ),
    level_1 = c(
      "Professioni non qualificate",
      "Professioni intellettuali e scientifiche"
    )
  )
}

# Dimensione globale delle skill ESCO. Costruita da `skill_codes` perche' il
# numero di skill per posting e' parametrico. I quattro rami della gerarchia
# ESCO (S=skill, K=knowledge, T=transversal, L=language) vengono alternati per
# dare varieta' ai flag esposti dallo shim.
.fx_dim_esco_skills <- function(skill_codes) {
  n <- length(skill_codes)
  branch <- rep(c("S", "K", "T", "L"), length.out = n)
  code_1 <- sprintf("%s%d", branch, seq_len(n))
  code_2 <- sprintf("%s.%d", code_1, 1L)
  code_3 <- sprintf("%s.%d", code_2, 2L)
  data.table::data.table(
    skill_id = skill_codes,
    esco_v010200_label = sprintf("competenza %s", skill_codes),
    esco_v010200_uri = sprintf(
      "http://data.europa.eu/esco/skill/%s",
      skill_codes
    ),
    esco_v010200_obsolete = "N",
    esco_v010200_skillstype = ifelse(
      branch == "K",
      "knowledge",
      "skill/competence"
    ),
    esco_v010200_reusetype = data.table::fcase(
      branch == "T" , "transversal"     ,
      branch == "K" , "sector-specific" ,
      default = "cross-sector"
    ),
    esco_v010200_description = sprintf(
      "Descrizione sintetica della competenza %s.",
      skill_codes
    ),
    esco_v010200_digcomp = ifelse(branch == "K", "Y", "N"),
    esco_v010200_green = ifelse(seq_len(n) %% 2L == 0L, "Y", "N"),
    esco_v010200_hier_code_3 = code_3,
    esco_v010200_hier_uri_3 = sprintf(
      "http://data.europa.eu/esco/skill/%s",
      code_3
    ),
    esco_v010200_hier_label_3 = sprintf("gerarchia livello 3 %s", code_3),
    esco_v010200_hier_code_2 = code_2,
    esco_v010200_hier_uri_2 = sprintf(
      "http://data.europa.eu/esco/skill/%s",
      code_2
    ),
    esco_v010200_hier_label_2 = sprintf("gerarchia livello 2 %s", code_2),
    esco_v010200_hier_code_1 = code_1,
    esco_v010200_hier_uri_1 = sprintf(
      "http://data.europa.eu/esco/skill/%s",
      code_1
    ),
    esco_v010200_hier_label_1 = sprintf("gerarchia livello 1 %s", code_1),
    esco_v010200_hier_uri_0 = sprintf(
      "http://data.europa.eu/esco/skill/%s",
      branch
    ),
    esco_v010200_hier_label_0 = data.table::fcase(
      branch == "S" , "abilità e competenze"  ,
      branch == "K" , "conoscenze"             ,
      branch == "T" , "competenze trasversali" ,
      default = "lingue"
    ),
    esco_v010200_digital = ifelse(branch == "K", "Y", "N"),
    esco_v010200_language = ifelse(branch == "L", "Y", "N"),
    esco_v010200_transversal = ifelse(branch == "T", "Y", "N"),
    esco_v010200_research = "N"
  )
}

# 2. Costruzione delle fixture ------------------------------------------------

build_fixtures <- function(
  zip_dir = tempfile("itaposts_fix_"),
  snapshot_id = "TEST_2026_1",
  n_postings = 50L,
  n_skills_per = 4L,
  include_duplicates = TRUE,
  companynames = NULL
) {
  if (!dir.exists(zip_dir)) {
    dir.create(zip_dir, recursive = TRUE)
  }
  set.seed(42)

  ids <- seq_len(n_postings) + 100000L
  skill_codes <- sprintf("ESCOv1_%d", seq_len(n_skills_per))

  # Header della consegna data_v2: solo chiavi esterne per CP2021 ed ESCO, le
  # descrizioni arrivano dalle dimensioni globali.
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
    cp2021_id_level_5 = sample(.fx_cp2021_codes, n_postings, replace = TRUE),
    source = sample(c("IT_RANDSTAD", "IT_INDEED"), n_postings, replace = TRUE),
    source_category_analysis = "agency",
    source_relevance = "high",
    idesco_level_5 = sample(.fx_esco_codes, n_postings, replace = TRUE)
  )

  if (isTRUE(include_duplicates)) {
    dup_idx <- sample.int(n_postings, 5L)
    dups <- data.table::copy(postings[dup_idx])
    dups[, day_grab_date := pmax(day_grab_date - 5L, 1L)] # dup piu' vecchio
    postings <- data.table::rbindlist(list(postings, dups))
  }

  # `companynames` permette di iniettare ragioni sociali scelte, in ordine e
  # riciclate sugli id: serve ai test sull'oscuramento dei codici fiscali.
  postings_raw <- data.table::data.table(
    general_id = ids,
    companyname = if (is.null(companynames)) {
      sample(c("Acme Spa", "Beta Srl", "Randstad"), n_postings, replace = TRUE)
    } else {
      rep_len(as.character(companynames), n_postings)
    }
  )

  # La CSV delle skill in data_v2 porta soltanto la chiave della skill.
  skills <- data.table::CJ(
    general_id = ids,
    IDESCOSKILL_LEVEL_3 = skill_codes
  )
  skills[, `:=`(year_grab_date = 2026L, month_grab_date = 1L)]
  data.table::setcolorder(
    skills,
    c("general_id", "year_grab_date", "month_grab_date", "IDESCOSKILL_LEVEL_3")
  )

  # 3. Scrittura degli archivi e dei dim_table -------------------------------

  csv_dir <- tempfile("itaposts_csv_")
  dir.create(csv_dir)
  on.exit(unlink(csv_dir, recursive = TRUE), add = TRUE)

  p_csv <- file.path(csv_dir, paste0(snapshot_id, "_postings.csv"))
  pr_csv <- file.path(csv_dir, paste0(snapshot_id, "_postings_raw.csv"))
  s_csv <- file.path(csv_dir, paste0(snapshot_id, "_skills.csv"))
  data.table::fwrite(postings, p_csv)
  data.table::fwrite(postings_raw, pr_csv)
  data.table::fwrite(skills, s_csv)

  # I dim_table finiscono in `zip_dir`: e' il default di `dim_dir` in
  # oja_ingest_snapshot() e oja_ingest_dirs().
  dim_files <- c(
    dim_occ_cp2021 = file.path(zip_dir, "dim_occ_cp2021.csv"),
    dim_occ_esco = file.path(zip_dir, "dim_occ_esco.csv"),
    dim_esco_skills = file.path(zip_dir, "dim_esco_skills.csv")
  )
  data.table::fwrite(.fx_dim_cp2021(), dim_files[["dim_occ_cp2021"]], sep = ";")
  data.table::fwrite(
    .fx_dim_esco_occupation(),
    dim_files[["dim_occ_esco"]],
    sep = ";"
  )
  data.table::fwrite(
    .fx_dim_esco_skills(skill_codes),
    dim_files[["dim_esco_skills"]],
    sep = ";"
  )

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
    companynames = postings_raw$companyname,
    n_skills_total = nrow(skills),
    skill_codes = skill_codes,
    dim_files = dim_files,
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
