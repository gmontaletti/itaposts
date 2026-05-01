test_that("oja_normalised emette la forma list(postings, skills, companies)", {
  fx <- build_fixtures()
  on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
  db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(c(db, paste0(db, ".wal"))), add = TRUE)

  oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = db)

  con <- oja_connect(db)
  on.exit(oja_disconnect(con), add = TRUE)

  ojv <- oja_normalised(con, snapshots = fx$snapshot_id, verbose = FALSE)

  expect_named(ojv, c("postings", "skills", "companies"))
  expect_s3_class(ojv$postings, "data.table")
  expect_s3_class(ojv$skills, "data.table")
  expect_s3_class(ojv$companies, "data.table")

  expect_equal(nrow(ojv$postings), fx$n_postings_unique)
  expect_true(
    data.table::uniqueN(ojv$postings$general_id) == nrow(ojv$postings)
  )
  expect_equal(data.table::key(ojv$postings), "general_id")
  expect_equal(data.table::key(ojv$skills), "general_id")
})

test_that("oja_normalised mantiene i nomi colonna attesi da skillviz", {
  fx <- build_fixtures()
  on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
  db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(c(db, paste0(db, ".wal"))), add = TRUE)

  oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = db)
  con <- oja_connect(db)
  on.exit(oja_disconnect(con), add = TRUE)

  ojv <- oja_normalised(con, snapshots = fx$snapshot_id, verbose = FALSE)

  posting_cols <- c(
    "general_id",
    "year_grab_date",
    "month_grab_date",
    "day_grab_date",
    "salaryvalue",
    "idsector",
    "idmacro_sector",
    "cp2021_id_level_4",
    "cp2021_id_level_3",
    "idesco_level_4",
    "idesco_level_5",
    "source",
    "companyname"
  )
  expect_true(all(posting_cols %in% names(ojv$postings)))

  skill_cols <- c(
    "general_id",
    "IDESCOSKILL_LEVEL_3",
    "ESCOSKILL_LEVEL_3",
    "ESCO_V0101_GREEN",
    "ESCO_V0101_REUSETYPE",
    "ESCO_V0101_HIER_LABEL_0",
    "PILLAR_SOFTSKILLS"
  )
  expect_true(all(skill_cols %in% names(ojv$skills)))

  expect_named(
    ojv$companies,
    c("general_id", "companyname"),
    ignore.order = TRUE
  )
})

test_that("filtri snapshots/years restringono il risultato", {
  fx <- build_fixtures(snapshot_id = "TEST_2026_1")
  on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
  db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(c(db, paste0(db, ".wal"))), add = TRUE)

  oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = db)
  con <- oja_connect(db)
  on.exit(oja_disconnect(con), add = TRUE)

  empty <- oja_normalised(con, years = 2099L, verbose = FALSE)
  expect_equal(nrow(empty$postings), 0L)
  expect_equal(nrow(empty$skills), 0L)

  hit <- oja_normalised(con, years = 2026L, verbose = FALSE)
  expect_equal(nrow(hit$postings), fx$n_postings_unique)
})
