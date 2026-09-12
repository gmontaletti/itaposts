# 1. Risoluzione del percorso ---------------------------------------------------

test_that("oja_db_path privilegia ITAPOSTS_DB", {
  withr::local_envvar(ITAPOSTS_DB = "ducklake:sqlite:/percorso/lake.sqlite")
  expect_identical(
    oja_db_path(create_dir = FALSE),
    "ducklake:sqlite:/percorso/lake.sqlite"
  )

  withr::local_envvar(ITAPOSTS_DB = "~/itaposts_prova/oja.duckdb")
  expect_identical(
    oja_db_path(create_dir = FALSE),
    path.expand("~/itaposts_prova/oja.duckdb")
  )
})

test_that("senza ITAPOSTS_DB il percorso deriva da SHARED_DATA_DIR", {
  base <- withr::local_tempdir()
  withr::local_envvar(ITAPOSTS_DB = NA, SHARED_DATA_DIR = base)
  expect_identical(
    oja_db_path(create_dir = FALSE),
    file.path(base, "oja", "itposts.duckdb")
  )
})

# 2. Connessione DuckLake --------------------------------------------------------

test_that("oja_connect su ducklake: rende corrente lo schema oja", {
  lake <- local_temp_lake()
  con <- oja_connect(lake, read_only = FALSE)
  on.exit(oja_disconnect(con), add = TRUE)

  cur <- DBI::dbGetQuery(
    con,
    "SELECT current_database() AS db, current_schema() AS sch"
  )
  expect_identical(cur$db, "lake")
  expect_identical(cur$sch, "oja")
  expect_true(.oja_is_ducklake(con))

  # Le query non qualificate risolvono sullo schema del lago.
  DBI::dbExecute(con, "CREATE TABLE prova (id VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO prova VALUES ('a')")
  expect_identical(DBI::dbGetQuery(con, "SELECT id FROM prova")$id, "a")
  expect_equal(
    DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM lake.oja.prova")$n,
    1
  )
})

test_that("oja_connect in sola lettura rifiuta le scritture sul lago", {
  lake <- local_temp_lake()
  con <- oja_connect(lake)
  on.exit(oja_disconnect(con), add = TRUE)

  expect_error(
    DBI::dbExecute(con, "CREATE TABLE prova (id VARCHAR)"),
    "read-only"
  )
  # Il database in memoria resta disponibile per le viste temporanee.
  expect_no_error(
    duckdb::duckdb_register(con, "r_prova", data.frame(x = 1L))
  )
  duckdb::duckdb_unregister(con, "r_prova")
})

test_that("l'opzione itaposts.schema sceglie lo schema del lago", {
  lake <- local_temp_lake(schema = c("oja", "oja_prova"))
  withr::local_options(itaposts.schema = "oja_prova")
  con <- oja_connect(lake)
  on.exit(oja_disconnect(con), add = TRUE)

  expect_identical(
    DBI::dbGetQuery(con, "SELECT current_schema() AS s")$s,
    "oja_prova"
  )
})

test_that("oja_connect segnala schema e catalogo assenti", {
  lake <- local_temp_lake()
  withr::local_options(itaposts.schema = "inesistente")
  expect_error(oja_connect(lake), "Schema")

  missing <- file.path(withr::local_tempdir(), "nessuno.sqlite")
  expect_error(
    oja_connect(paste0("ducklake:sqlite:", missing), read_only = FALSE),
    "Catalogo DuckLake inesistente"
  )
  # Nessun catalogo vuoto lasciato su disco.
  expect_false(file.exists(missing))
})

test_that("oja_connect valida gli argomenti", {
  expect_error(oja_connect(path = NA_character_), "path")
  expect_error(oja_connect(path = c("a", "b")), "path")
  expect_error(oja_connect(path = ":memory:", read_only = NA), "read_only")
})

# 3. Chiusura e transazioni -------------------------------------------------------

for (backend in .oja_backends) {
  test_that(sprintf("oja_disconnect chiude la connessione [%s]", backend), {
    path <- local_temp_store(backend)
    con <- oja_connect(path, read_only = FALSE)
    expect_true(DBI::dbIsValid(con))
    expect_invisible(oja_disconnect(con))
    expect_false(DBI::dbIsValid(con))

    # Lo store resta riapribile in scrittura.
    con2 <- oja_connect(path, read_only = FALSE)
    on.exit(oja_disconnect(con2), add = TRUE)
    expect_true(DBI::dbIsValid(con2))
  })

  test_that(
    sprintf(".oja_in_transaction distingue autocommit e BEGIN [%s]", backend),
    {
      path <- local_temp_store(backend)
      con <- oja_connect(path, read_only = FALSE)
      on.exit(oja_disconnect(con), add = TRUE)

      expect_false(.oja_in_transaction(con))
      DBI::dbExecute(con, "BEGIN TRANSACTION")
      expect_true(.oja_in_transaction(con))
      DBI::dbExecute(con, "ROLLBACK")
      expect_false(.oja_in_transaction(con))
    }
  )
}
