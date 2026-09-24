# I test di ingestione girano su entrambi i backend: file DuckDB temporaneo e
# lago DuckLake temporaneo (saltati se le estensioni non si caricano).

for (backend in .oja_backends) {
  # 1. Comportamento di base ---------------------------------------------------

  test_that(
    sprintf(
      "oja_ingest_snapshot popola fact_postings senza duplicati [%s]",
      backend
    ),
    {
      fx <- build_fixtures()
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)

      res <- oja_ingest_snapshot(
        zip_dir = fx$zip_dir,
        snapshot_id = fx$snapshot_id,
        path = path
      )
      expect_equal(res$n_postings, fx$n_postings_unique)

      con <- oja_connect(path)
      on.exit(oja_disconnect(con), add = TRUE)

      q <- DBI::dbGetQuery(
        con,
        "SELECT COUNT(*) AS n, COUNT(DISTINCT general_id) AS d
           FROM fact_postings WHERE snapshot_id = ?",
        params = list(fx$snapshot_id)
      )
      expect_equal(q$n, q$d)
      expect_equal(q$n, fx$n_postings_unique)
    }
  )

  test_that(
    sprintf("le skills referenziano postings esistenti [%s]", backend),
    {
      fx <- build_fixtures()
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)

      oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = path)

      con <- oja_connect(path)
      on.exit(oja_disconnect(con), add = TRUE)

      orphans <- DBI::dbGetQuery(
        con,
        "SELECT COUNT(*) AS n FROM fact_skills s
         WHERE NOT EXISTS (
           SELECT 1 FROM fact_postings p
            WHERE p.snapshot_id = s.snapshot_id
              AND p.general_id  = s.general_id
         )"
      )
      expect_equal(orphans$n, 0L)
    }
  )

  test_that(
    sprintf(
      "re-ingest dello stesso snapshot fallisce senza overwrite [%s]",
      backend
    ),
    {
      fx <- build_fixtures()
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)

      oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = path)

      expect_error(
        oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = path),
        regexp = "gia' presente"
      )

      res <- oja_ingest_snapshot(
        fx$zip_dir,
        fx$snapshot_id,
        path = path,
        overwrite = TRUE
      )
      expect_equal(res$n_postings, fx$n_postings_unique)

      con <- oja_connect(path)
      on.exit(oja_disconnect(con), add = TRUE)
      n_snap <- DBI::dbGetQuery(
        con,
        "SELECT COUNT(*) AS n FROM dim_snapshot WHERE snapshot_id = ?",
        params = list(fx$snapshot_id)
      )$n
      expect_equal(n_snap, 1L)
      expect_equal(
        DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM fact_skills")$n,
        fx$n_skills_total
      )
    }
  )

  test_that(sprintf("le dimensioni sono popolate e univoche [%s]", backend), {
    fx <- build_fixtures()
    on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
    path <- local_temp_store(backend)

    oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = path)

    con <- oja_connect(path)
    on.exit(oja_disconnect(con), add = TRUE)

    # Dimensioni derivate dalle postings (UPSERT incrementale).
    expect_gt(
      DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM dim_geography")$n,
      0
    )
    # Dimensioni globali ricaricate dai CSV dim_table.
    for (tbl in c("dim_cp2021", "dim_esco_occupation", "dim_esco_skill")) {
      expect_gt(
        DBI::dbGetQuery(
          con,
          sprintf("SELECT COUNT(*) AS n FROM %s", tbl)
        )$n,
        0
      )
    }
    # Univocita' su PK
    expect_equal(
      DBI::dbGetQuery(
        con,
        "SELECT COUNT(*) AS n, COUNT(DISTINCT idescoskill_level_3) AS d FROM dim_esco_skill"
      ) |>
        (\(x) x$n - x$d)(),
      0
    )
    # Ogni chiave esterna dei fatti deve trovare corrispondenza in dimensione.
    orphan_fk <- DBI::dbGetQuery(
      con,
      "SELECT
         (SELECT COUNT(*) FROM fact_postings f
           WHERE NOT EXISTS (SELECT 1 FROM dim_cp2021 d
                              WHERE d.cp2021_id_level_5 = f.cp2021_id_level_5)) AS cp,
         (SELECT COUNT(*) FROM fact_postings f
           WHERE NOT EXISTS (SELECT 1 FROM dim_esco_occupation d
                              WHERE d.idesco_level_5 = f.idesco_level_5)) AS occ,
         (SELECT COUNT(*) FROM fact_skills s
           WHERE NOT EXISTS (SELECT 1 FROM dim_esco_skill d
                              WHERE d.idescoskill_level_3 = s.idescoskill_level_3)) AS skl"
    )
    expect_equal(orphan_fk$cp, 0L)
    expect_equal(orphan_fk$occ, 0L)
    expect_equal(orphan_fk$skl, 0L)
  })

  test_that(
    sprintf(
      "i CSV dim_table sono obbligatori quando dim_dir non e' NULL [%s]",
      backend
    ),
    {
      fx <- build_fixtures()
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)

      unlink(fx$dim_files[["dim_occ_esco"]])

      expect_error(
        oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = path),
        regexp = "dim_table"
      )

      # Con dim_dir = NULL l'ingest procede: le dimensioni globali restano vuote.
      res <- oja_ingest_snapshot(
        fx$zip_dir,
        fx$snapshot_id,
        path = path,
        dim_dir = NULL
      )
      expect_equal(res$n_postings, fx$n_postings_unique)

      con <- oja_connect(path)
      on.exit(oja_disconnect(con), add = TRUE)
      expect_equal(
        DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM dim_esco_occupation")$n,
        0L
      )
    }
  )

  # 2. Upsert portabile e idempotenza -------------------------------------------

  test_that(
    sprintf(
      ".upsert_dim è idempotente e tiene una riga per chiave [%s]",
      backend
    ),
    {
      path <- local_temp_store(backend)
      con <- oja_connect(path, read_only = FALSE)
      on.exit(oja_disconnect(con), add = TRUE)
      oja_init_db(con = con)

      geo <- data.table::data.table(
        idcity = c("001", "001", "002", NA),
        city = c("Pavia", "Pavia (PV)", "Vigevano", "Senza codice"),
        idprovince = "ITC48",
        province = "Pavia",
        idregion = "ITC4",
        region = "Lombardia",
        idmacro_region = "ITC",
        macro_region = "Nord-Ovest",
        idcountry = "IT",
        country = "ITALIA"
      )
      expect_equal(.upsert_dim(con, "dim_geography", geo, "idcity"), 2)
      expect_equal(.upsert_dim(con, "dim_geography", geo, "idcity"), 0)
      # L'input non viene modificato per riferimento.
      expect_false("stg_ord__" %in% names(geo))

      out <- DBI::dbGetQuery(
        con,
        "SELECT idcity, city FROM dim_geography ORDER BY idcity"
      )
      expect_identical(out$idcity, c("001", "002"))
      # A parità di chiave vince la prima riga in ordine di input.
      expect_identical(out$city, c("Pavia", "Vigevano"))
    }
  )

  test_that(
    sprintf(
      ".reload_dim salta DELETE e INSERT se il contenuto non cambia [%s]",
      backend
    ),
    {
      path <- local_temp_store(backend)
      con <- oja_connect(path, read_only = FALSE)
      on.exit(oja_disconnect(con), add = TRUE)
      oja_init_db(con = con)

      dim <- data.table::data.table(
        cp2021_id_level_5 = c("2.5.1.1.0", "8.1.3.2.0", "3.1.1.2.0"),
        cp2021_level_5 = c("Specialisti in contabilità", "Addetti", NA),
        cp2021_level_1 = c("Professioni intellettuali", "", "Tecniche")
      )
      leggi <- function() {
        DBI::dbGetQuery(
          con,
          "SELECT cp2021_id_level_5, cp2021_level_5, cp2021_level_1
             FROM dim_cp2021 ORDER BY cp2021_id_level_5"
        )
      }
      # Traccia fisica delle scritture: su DuckDB DELETE e INSERT assegnano
      # nuovi rowid alle righe, su DuckLake ogni istruzione crea uno snapshot.
      traccia <- function() {
        if (identical(backend, "ducklake")) {
          lake_snapshot_count(con)
        } else {
          DBI::dbGetQuery(con, "SELECT max(rowid) AS r FROM dim_cp2021")$r
        }
      }
      staging_presente <- function() {
        DBI::dbGetQuery(
          con,
          "SELECT COUNT(*) AS n FROM duckdb_tables()
            WHERE table_name = '__stg_dim_cp2021'"
        )$n >
          0
      }

      expect_true(.reload_dim(con, "dim_cp2021", dim))
      prima <- leggi()
      traccia_prima <- traccia()

      # Stesso contenuto in altro ordine, con NULL e stringa vuota: nessuna
      # scrittura.
      expect_false(.reload_dim(con, "dim_cp2021", dim[c(3L, 1L, 2L)]))
      expect_identical(leggi(), prima)
      expect_identical(traccia(), traccia_prima)
      expect_false(staging_presente())

      # Un valore diverso nei dati letti: ricarica.
      modificata <- data.table::copy(dim)
      modificata[2L, cp2021_level_5 := "Addetti alla pulizia"]
      expect_true(.reload_dim(con, "dim_cp2021", modificata))
      expect_gt(traccia(), traccia_prima)
      dopo <- leggi()
      expect_identical(
        dopo$cp2021_level_5[dopo$cp2021_id_level_5 == "8.1.3.2.0"],
        "Addetti alla pulizia"
      )

      # Una riga presente solo nella tabella: ricarica che la rimuove.
      DBI::dbExecute(
        con,
        "INSERT INTO dim_cp2021 (cp2021_id_level_5) VALUES ('9.9.9.9.0')"
      )
      expect_true(.reload_dim(con, "dim_cp2021", modificata))
      expect_identical(nrow(leggi()), 3L)
      expect_false(staging_presente())
    }
  )

  test_that(
    sprintf(
      "le dimensioni globali invariate non vengono riscritte [%s]",
      backend
    ),
    {
      fx <- build_fixtures()
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)
      con <- oja_connect(path, read_only = FALSE)
      on.exit(oja_disconnect(con), add = TRUE)
      oja_init_db(con = con)

      primo <- testthat::capture_messages(
        .oja_with_transaction(con, .load_global_dims(con, fx$zip_dir))
      )
      expect_length(grep("ricaricata", primo), 3L)
      n_snapshot <- if (identical(backend, "ducklake")) {
        lake_snapshot_count(con)
      }

      secondo <- testthat::capture_messages(
        .oja_with_transaction(con, .load_global_dims(con, fx$zip_dir))
      )
      expect_length(grep("invariata", secondo), 3L)
      expect_length(grep("ricaricata", secondo), 0L)
      if (identical(backend, "ducklake")) {
        expect_identical(lake_snapshot_count(con), n_snapshot)
      }
    }
  )

  test_that(
    sprintf(
      "lo streaming delle skill non duplica righe già presenti [%s]",
      backend
    ),
    {
      fx <- build_fixtures(n_postings = 10L, n_skills_per = 3L)
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)
      oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = path)

      con <- oja_connect(path, read_only = FALSE)
      on.exit(oja_disconnect(con), add = TRUE)
      expect_identical(.stream_skills(con, fx$skills, fx$snapshot_id), 0L)
      expect_equal(
        DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM fact_skills")$n,
        fx$n_skills_total
      )
    }
  )

  test_that(
    sprintf(
      "due snapshot con dimensioni comuni lasciano chiavi univoche [%s]",
      backend
    ),
    {
      path <- local_temp_store(backend)
      for (sid in c("TEST_2026_1", "TEST_2026_2")) {
        fx <- build_fixtures(snapshot_id = sid)
        on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
        oja_ingest_snapshot(fx$zip_dir, sid, path = path)
      }

      con <- oja_connect(path)
      on.exit(oja_disconnect(con), add = TRUE)

      viol <- .oja_key_violations(con, "TEST_2026_2")
      expect_setequal(viol$table, names(.oja_keys()))
      expect_true(all(viol$n_duplicate == 0L))
      expect_true(all(viol$n_null == 0L))

      # Le fixture assegnano nomi di città diversi allo stesso idcity.
      geo <- DBI::dbGetQuery(
        con,
        "SELECT COUNT(*) AS n, COUNT(DISTINCT idcity) AS d FROM dim_geography"
      )
      expect_equal(geo$n, geo$d)
      expect_equal(
        DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM dim_snapshot")$n,
        2
      )
    }
  )

  # 3. Transazioni ----------------------------------------------------------------

  test_that(
    sprintf("un errore dopo i DELETE lascia intatto lo snapshot [%s]", backend),
    {
      fx <- build_fixtures()
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)
      oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = path)

      read_state <- function() {
        con <- oja_connect(path)
        on.exit(oja_disconnect(con), add = TRUE)
        DBI::dbGetQuery(
          con,
          "SELECT
             (SELECT COUNT(*) FROM fact_postings) AS n_post,
             (SELECT COUNT(*) FROM fact_skills)   AS n_skill,
             (SELECT COUNT(*) FROM dim_snapshot)  AS n_snap,
             (SELECT MAX(ingested_at) FROM dim_snapshot) AS ingested_at"
        )
      }
      before <- read_state()

      local_mocked_bindings(
        .validate_snapshot = function(con, snapshot_id) {
          cli::cli_abort("Validazione simulata fallita.")
        }
      )
      expect_error(
        oja_ingest_snapshot(
          fx$zip_dir,
          fx$snapshot_id,
          overwrite = TRUE,
          path = path
        ),
        "Validazione simulata"
      )
      expect_identical(read_state(), before)
    }
  )

  test_that(
    sprintf(
      "oja_ingest_dirs con connessione esterna la lascia aperta [%s]",
      backend
    ),
    {
      fx <- build_fixtures()
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)
      con <- oja_connect(path, read_only = FALSE)
      on.exit(oja_disconnect(con), add = TRUE)

      res <- oja_ingest_dirs(fx$zip_dir, con = con)
      expect_identical(res$snapshot_id, fx$snapshot_id)
      expect_equal(res$n_postings, fx$n_postings_unique)

      expect_true(DBI::dbIsValid(con))
      expect_equal(
        DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM fact_postings")$n,
        fx$n_postings_unique
      )
      if (identical(backend, "ducklake")) {
        expect_identical(
          DBI::dbGetQuery(con, "SELECT current_schema() AS s")$s,
          "oja"
        )
      }
    }
  )

  test_that(
    sprintf(
      "con una transazione aperta l'ingestione vi partecipa [%s]",
      backend
    ),
    {
      fx <- build_fixtures()
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)
      con <- oja_connect(path, read_only = FALSE)
      on.exit(oja_disconnect(con), add = TRUE)
      oja_init_db(con = con)

      # Nessun COMMIT interno: il ROLLBACK del chiamante annulla tutto.
      DBI::dbExecute(con, "BEGIN TRANSACTION")
      oja_ingest_dirs(fx$zip_dir, con = con)
      expect_true(.oja_in_transaction(con))
      DBI::dbExecute(con, "ROLLBACK")
      expect_equal(
        DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM dim_snapshot")$n,
        0
      )

      # Un errore nella transazione del chiamante non viene assorbito.
      local_mocked_bindings(
        .validate_snapshot = function(con, snapshot_id) {
          cli::cli_abort("Validazione simulata fallita.")
        }
      )
      DBI::dbExecute(con, "BEGIN TRANSACTION")
      expect_error(oja_ingest_dirs(fx$zip_dir, con = con), "transazione")
      DBI::dbExecute(con, "ROLLBACK")
      expect_equal(
        DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM fact_postings")$n,
        0
      )
    }
  )

  # 4. Lettura ---------------------------------------------------------------------

  test_that(
    sprintf("le funzioni di lettura usano nomi non qualificati [%s]", backend),
    {
      fx <- build_fixtures()
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)
      oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = path)

      con <- oja_connect(path)
      on.exit(oja_disconnect(con), add = TRUE)

      n_post <- dplyr::collect(
        dplyr::count(oja_postings(con, snapshots = fx$snapshot_id))
      )$n
      expect_equal(n_post, fx$n_postings_unique)
      expect_equal(nrow(oja_snapshots(con)), 1L)
      expect_gt(dplyr::collect(dplyr::count(oja_skill_dim(con)))$n, 0)

      # Nessuna moltiplicazione di righe dai join con le dimensioni.
      ojv <- oja_normalised(con, snapshots = fx$snapshot_id, verbose = FALSE)
      expect_equal(nrow(ojv$postings), fx$n_postings_unique)
      expect_equal(nrow(ojv$skills), fx$n_skills_total)
    }
  )
}

# 5. Validazione e argomenti ---------------------------------------------------------

test_that("la validazione rileva chiavi duplicate su DuckLake", {
  fx <- build_fixtures(n_postings = 10L, n_skills_per = 2L)
  on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
  lake <- local_temp_lake()
  oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = lake)

  con <- oja_connect(lake, read_only = FALSE)
  on.exit(oja_disconnect(con), add = TRUE)
  expect_no_error(.validate_snapshot(con, fx$snapshot_id))

  # Senza PRIMARY KEY un duplicato entra nella tabella: lo intercetta la
  # validazione.
  DBI::dbExecute(
    con,
    "INSERT INTO dim_contract SELECT * FROM dim_contract LIMIT 1"
  )
  expect_error(.validate_snapshot(con, fx$snapshot_id), "dim_contract")

  DBI::dbExecute(con, "DELETE FROM dim_contract")
  DBI::dbExecute(
    con,
    "INSERT INTO fact_skills SELECT * FROM fact_skills LIMIT 1"
  )
  expect_error(.validate_snapshot(con, fx$snapshot_id), "fact_skills")
})

test_that("snapshot_id parsing rifiuta formati invalidi", {
  expect_error(
    oja_ingest_snapshot(zip_dir = tempdir(), snapshot_id = "qualcosa"),
    regexp = "snapshot_id"
  )
})

# 6. Oscuramento dei codici fiscali nelle ragioni sociali ---------------------

# Fixture di forme di codice fiscale. I codici sono sintetici e non
# appartengono a nessuna persona: servono solo a esercitare la forma.
.cf_fixture <- c(
  # 1. valore che e' tutto e solo un codice, maiuscolo
  "RSSMRA80A01H501U",
  # 2. stesso codice in minuscolo
  "rssmra80a01h501u",
  # 3. valore con le lettere dell'omocodia nelle posizioni numeriche
  "RSSMRA8LA0MH50NU",
  # 4. codice scritto accanto al nome
  "Ditta RSSMRA80A01H501U",
  # 5. codice con spazi attorno
  "  RSSMRA80A01H501U  ",
  # 6. ragione sociale legittima di sedici lettere: la forma larga della
  #    decisione D-COB-1 la colpirebbe, la regola adottata qui no
  "TRASPORTIMPERSUD",
  # 7. ragione sociale ordinaria
  "Acme Spa"
)

test_that(".mask_cf sostituisce le forme di codice fiscale e conserva il resto", {
  atteso <- c(
    "[CF]",
    "[CF]",
    "[CF]",
    "Ditta [CF]",
    "[CF]",
    "TRASPORTIMPERSUD",
    "Acme Spa"
  )
  expect_identical(.mask_cf(.cf_fixture), atteso)

  # NA resta NA, il vettore vuoto resta vuoto, i non caratteri passano.
  expect_identical(
    .mask_cf(c(NA_character_, "Beta Srl")),
    c(NA_character_, "Beta Srl")
  )
  expect_identical(.mask_cf(character()), character())
  expect_identical(.mask_cf(1:3), 1:3)

  # Codice di 11 cifre della persona giuridica: resta in chiaro per decisione
  # della sezione 10 del piano.
  expect_identical(.mask_cf("12345678901"), "12345678901")
})

for (backend in .oja_backends) {
  test_that(
    sprintf(
      "oja_ingest_snapshot non scrive forme di codice fiscale in companyname [%s]",
      backend
    ),
    {
      fx <- build_fixtures(
        n_postings = length(.cf_fixture),
        n_skills_per = 2L,
        include_duplicates = FALSE,
        companynames = .cf_fixture
      )
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)

      res <- oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = path)
      expect_equal(res$n_postings, length(.cf_fixture))

      con <- oja_connect(path)
      on.exit(oja_disconnect(con), add = TRUE)

      # Nessun residuo: e' lo stesso controllo del lago.
      q <- DBI::dbGetQuery(
        con,
        "SELECT COUNT(*) AS n_righe, COUNT(*) AS n_tot
           FROM fact_postings
          WHERE snapshot_id = ?
            AND (regexp_full_match(trim(companyname), ?)
              OR regexp_matches(companyname, ?))",
        params = list(fx$snapshot_id, .RE_CF_VALORE, .RE_CF_IMMERSO)
      )
      expect_equal(q$n_righe, 0L)

      # Il conteggio delle righe non cambia e i valori non interessati
      # restano identici.
      valori <- DBI::dbGetQuery(
        con,
        "SELECT companyname, COUNT(*) AS n
           FROM fact_postings WHERE snapshot_id = ?
          GROUP BY companyname ORDER BY companyname",
        params = list(fx$snapshot_id)
      )
      expect_equal(sum(valori$n), length(.cf_fixture))
      expect_identical(
        sort(valori$companyname),
        sort(unique(c("[CF]", "Ditta [CF]", "TRASPORTIMPERSUD", "Acme Spa")))
      )
    }
  )
}

test_that("la validazione blocca una forma di codice fiscale in companyname", {
  fx <- build_fixtures(n_postings = 10L, n_skills_per = 2L)
  on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
  lake <- local_temp_lake()
  oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = lake)

  con <- oja_connect(lake, read_only = FALSE)
  on.exit(oja_disconnect(con), add = TRUE)
  expect_no_error(.validate_companyname(con, fx$snapshot_id))

  # Scrittura diretta, che scavalca l'oscuramento dell'ingestione.
  id_uno <- DBI::dbGetQuery(
    con,
    "SELECT min(general_id) AS id FROM fact_postings WHERE snapshot_id = ?",
    params = list(fx$snapshot_id)
  )$id
  DBI::dbExecute(
    con,
    "UPDATE fact_postings SET companyname = ?
      WHERE snapshot_id = ? AND general_id = ?",
    params = list("RSSMRA80A01H501U", fx$snapshot_id, id_uno)
  )
  # Il messaggio riporta conteggi, non valori.
  expect_error(
    .validate_companyname(con, fx$snapshot_id),
    "codice fiscale"
  )
  expect_error(.validate_snapshot(con, fx$snapshot_id), "codice fiscale")
})
