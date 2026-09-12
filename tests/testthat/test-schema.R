test_that("il DDL DuckDB dichiara le PRIMARY KEY delle chiavi logiche", {
  path <- local_temp_store("duckdb")
  con <- oja_connect(path, read_only = FALSE)
  on.exit(oja_disconnect(con), add = TRUE)

  expect_false(.oja_is_ducklake(con))
  tables <- oja_init_db(con = con)
  expect_setequal(tables, names(.oja_keys()))

  pk <- DBI::dbGetQuery(
    con,
    "SELECT table_name, constraint_column_names
       FROM duckdb_constraints()
      WHERE constraint_type = 'PRIMARY KEY'"
  )
  got <- stats::setNames(pk$constraint_column_names, pk$table_name)
  expect_setequal(names(got), names(.oja_keys()))
  for (tbl in names(.oja_keys())) {
    expect_identical(as.character(got[[tbl]]), .oja_keys()[[tbl]], info = tbl)
  }
})

test_that("su DuckLake il DDL non crea PRIMARY KEY ed è idempotente", {
  lake <- local_temp_lake()
  con <- oja_connect(lake, read_only = FALSE)
  on.exit(oja_disconnect(con), add = TRUE)

  expect_true(.oja_is_ducklake(con))
  oja_init_db(con = con)
  n_snap <- lake_snapshot_count(con)
  expect_no_error(oja_init_db(con = con))
  # Un DDL già applicato non crea snapshot DuckLake.
  expect_equal(lake_snapshot_count(con), n_snap)

  tabs <- DBI::dbGetQuery(
    con,
    "SELECT table_name, has_primary_key
       FROM duckdb_tables()
      WHERE database_name = 'lake' AND schema_name = 'oja'"
  )
  expect_setequal(tabs$table_name, names(.oja_keys()))
  expect_false(any(tabs$has_primary_key))
})

test_that(".oja_ddl senza chiavi rimuove ogni clausola PRIMARY KEY", {
  with_pk <- .oja_ddl()
  without_pk <- .oja_ddl(primary_keys = FALSE)

  expect_identical(names(without_pk), names(with_pk))
  expect_true(all(grepl("PRIMARY KEY", with_pk, fixed = TRUE)))
  expect_false(any(grepl("PRIMARY KEY", without_pk, fixed = TRUE)))
  # I vincoli NOT NULL dei fatti restano.
  expect_match(without_pk[["fact_skills"]], "NOT NULL")
})

test_that("oja_init_db propaga gli errori di connessione", {
  missing <- file.path(withr::local_tempdir(), "nessuno.sqlite")
  expect_error(
    oja_init_db(path = paste0("ducklake:sqlite:", missing)),
    "Catalogo DuckLake inesistente"
  )
})
