test_that("oja_ingest_snapshot popola fact_postings senza duplicati", {
  fx <- build_fixtures()
  on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
  db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(c(db, paste0(db, ".wal"))), add = TRUE)

  res <- oja_ingest_snapshot(
    zip_dir = fx$zip_dir,
    snapshot_id = fx$snapshot_id,
    path = db
  )
  expect_equal(res$n_postings, fx$n_postings_unique)

  con <- oja_connect(db)
  on.exit(oja_disconnect(con), add = TRUE)

  q <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS n, COUNT(DISTINCT general_id) AS d
       FROM fact_postings WHERE snapshot_id = ?",
    params = list(fx$snapshot_id)
  )
  expect_equal(q$n, q$d)
  expect_equal(q$n, fx$n_postings_unique)
})

test_that("le skills referenziano postings esistenti", {
  fx <- build_fixtures()
  on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
  db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(c(db, paste0(db, ".wal"))), add = TRUE)

  oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = db)

  con <- oja_connect(db)
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
})

test_that("re-ingest dello stesso snapshot fallisce senza overwrite", {
  fx <- build_fixtures()
  on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
  db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(c(db, paste0(db, ".wal"))), add = TRUE)

  oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = db)

  expect_error(
    oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = db),
    regexp = "gia' presente"
  )

  res <- oja_ingest_snapshot(
    fx$zip_dir,
    fx$snapshot_id,
    path = db,
    overwrite = TRUE
  )
  expect_equal(res$n_postings, fx$n_postings_unique)

  con <- oja_connect(db)
  on.exit(oja_disconnect(con), add = TRUE)
  n_snap <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS n FROM dim_snapshot WHERE snapshot_id = ?",
    params = list(fx$snapshot_id)
  )$n
  expect_equal(n_snap, 1L)
})

test_that("le dimensioni sono popolate e univoche", {
  fx <- build_fixtures()
  on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
  db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(c(db, paste0(db, ".wal"))), add = TRUE)

  oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = db)

  con <- oja_connect(db)
  on.exit(oja_disconnect(con), add = TRUE)

  expect_gt(
    DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM dim_geography")$n,
    0
  )
  expect_gt(
    DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM dim_esco_skill")$n,
    0
  )
  # Univocita' su PK
  expect_equal(
    DBI::dbGetQuery(
      con,
      "SELECT COUNT(*) AS n, COUNT(DISTINCT idescoskill_level_3) AS d FROM dim_esco_skill"
    ) |>
      (\(x) x$n - x$d)(),
    0
  )
})

test_that("snapshot_id parsing rifiuta formati invalidi", {
  expect_error(
    oja_ingest_snapshot(zip_dir = tempdir(), snapshot_id = "qualcosa"),
    regexp = "snapshot_id"
  )
})
