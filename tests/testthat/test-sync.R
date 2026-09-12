make_remote_listing <- function(snapshot_ids, region = "ITC4") {
  rows <- lapply(snapshot_ids, function(sid) {
    data.frame(
      name = paste0(sid, "_", c("postings", "postings_raw", "skills"), ".zip"),
      size_bytes = c(100, 50, 200),
      snapshot_id = sid,
      kind = c("postings", "postings_raw", "skills"),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

# I tre CSV dimensionali vengono scaricati a ogni sync, senza skip-by-size e
# indipendentemente dagli snapshot presenti: i downloader finti devono
# gestirli, altrimenti mascherano le asserzioni sugli archivi mensili.
.write_dummy_dim <- function(local_path) {
  writeBin(raw(10L), local_path)
  invisible(local_path)
}

test_that("oja_sync ignora snapshot incompleti sul remoto", {
  cfg <- list(
    host = "h",
    port = 22L,
    user = "u",
    password = "p",
    remote_dir = "/x",
    dim_dir = "/data_v2/dim_table",
    local_dir = tempfile("itaposts_sync_")
  )
  fake_lister <- function(config, region_code) {
    df <- make_remote_listing("ITC4_2026_3")
    df <- df[df$kind != "skills", ]
    df
  }
  fake_dl <- function(remote_name, local_path, config) {
    file.create(local_path)
    invisible(local_path)
  }
  ws <- testthat::capture_warnings(
    res <- oja_sync(
      config = cfg,
      path = tempfile(fileext = ".duckdb"),
      lister = fake_lister,
      downloader = fake_dl,
      ingest = FALSE
    )
  )
  expect_match(ws, "incompleti", all = FALSE)
  expect_equal(nrow(res), 0L)
})

test_that("oja_sync scarica solo i file mancanti e salta i duplicati per dimensione", {
  cfg <- list(
    host = "h",
    port = 22L,
    user = "u",
    password = "p",
    remote_dir = "/x",
    dim_dir = "/data_v2/dim_table",
    local_dir = tempfile("itaposts_sync_")
  )
  dir.create(cfg$local_dir, recursive = TRUE)

  listing <- make_remote_listing("ITC4_2026_4")
  fake_lister <- function(config, region_code) listing

  # File "_postings.zip" gia' presente in locale con stessa dimensione: skip.
  pre_existing <- file.path(cfg$local_dir, "ITC4_2026_4_postings.zip")
  writeBin(raw(100), pre_existing)
  expect_equal(file.info(pre_existing)$size, 100L)

  downloaded <- character()
  fake_dl <- function(remote_name, local_path, config) {
    downloaded <<- c(downloaded, remote_name)
    if (remote_name %in% .oja_dim_files) {
      return(.write_dummy_dim(local_path))
    }
    sz <- listing$size_bytes[match(remote_name, listing$name)]
    writeBin(raw(sz), local_path)
    invisible(local_path)
  }

  res <- oja_sync(
    config = cfg,
    path = tempfile(fileext = ".duckdb"),
    lister = fake_lister,
    downloader = fake_dl,
    ingest = FALSE
  )
  # Gli archivi mensili: solo i due mancanti, il terzo e' saltato per size match.
  expect_setequal(
    setdiff(downloaded, .oja_dim_files),
    c("ITC4_2026_4_postings_raw.zip", "ITC4_2026_4_skills.zip")
  )
  # Le dimensioni globali sono sempre riscaricate.
  expect_true(all(.oja_dim_files %in% downloaded))
  expect_equal(res$snapshot_id, "ITC4_2026_4")
  expect_true(res$downloaded)
  expect_false(res$ingested)
})

test_that("oja_sync salta gli snapshot gia' presenti in dim_snapshot", {
  fx <- build_fixtures(snapshot_id = "TEST_2027_1")
  on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
  db <- tempfile(fileext = ".duckdb")
  on.exit(unlink(c(db, paste0(db, ".wal"))), add = TRUE)

  oja_ingest_snapshot(fx$zip_dir, fx$snapshot_id, path = db)

  cfg <- list(
    host = "h",
    port = 22L,
    user = "u",
    password = "p",
    remote_dir = "/x",
    dim_dir = "/data_v2/dim_table",
    local_dir = fx$zip_dir
  )
  fake_lister <- function(config, region_code) {
    data.frame(
      name = c(
        "TEST_2027_1_postings.zip",
        "TEST_2027_1_postings_raw.zip",
        "TEST_2027_1_skills.zip"
      ),
      size_bytes = file.info(file.path(
        fx$zip_dir,
        c(
          "TEST_2027_1_postings.zip",
          "TEST_2027_1_postings_raw.zip",
          "TEST_2027_1_skills.zip"
        )
      ))$size,
      snapshot_id = "TEST_2027_1",
      kind = c("postings", "postings_raw", "skills"),
      stringsAsFactors = FALSE
    )
  }
  called <- FALSE
  fake_dl <- function(remote_name, local_path, config) {
    if (remote_name %in% .oja_dim_files) {
      return(.write_dummy_dim(local_path))
    }
    called <<- TRUE
    invisible(local_path)
  }

  res <- oja_sync(
    region_code = "TEST",
    config = cfg,
    path = db,
    lister = fake_lister,
    downloader = fake_dl
  )
  expect_false(called)
  expect_false(res$downloaded)
  expect_false(res$ingested)
})

for (backend in .oja_backends) {
  test_that(
    sprintf(
      "oja_sync scrive nella connessione fornita e non la chiude [%s]",
      backend
    ),
    {
      fx <- build_fixtures(snapshot_id = "TEST_2027_2")
      on.exit(unlink(fx$zip_dir, recursive = TRUE), add = TRUE)
      path <- local_temp_store(backend)
      con <- oja_connect(path, read_only = FALSE)
      on.exit(oja_disconnect(con), add = TRUE)

      zip_names <- paste0(
        "TEST_2027_2_",
        c("postings", "postings_raw", "skills"),
        ".zip"
      )
      cfg <- list(
        host = "h",
        port = 22L,
        user = "u",
        password = "p",
        remote_dir = "/x",
        dim_dir = "/data_v2/dim_table",
        local_dir = fx$zip_dir
      )
      fake_lister <- function(config, region_code) {
        data.frame(
          name = zip_names,
          size_bytes = file.info(file.path(fx$zip_dir, zip_names))$size,
          snapshot_id = "TEST_2027_2",
          kind = c("postings", "postings_raw", "skills"),
          stringsAsFactors = FALSE
        )
      }
      # Gli archivi sono gia' in locale con la dimensione del remoto; i CSV
      # dimensionali vengono copiati dalla fixture invece che scaricati.
      fake_dl <- function(remote_name, local_path, config) {
        if (remote_name %in% .oja_dim_files) {
          file.copy(
            file.path(fx$zip_dir, remote_name),
            local_path,
            overwrite = TRUE
          )
          return(invisible(local_path))
        }
        stop("il downloader non doveva essere invocato per gli archivi")
      }

      res <- oja_sync(
        region_code = "TEST",
        config = cfg,
        lister = fake_lister,
        downloader = fake_dl,
        con = con
      )
      expect_true(res$ingested)
      expect_equal(res$n_postings, fx$n_postings_unique)
      expect_true(DBI::dbIsValid(con))
      expect_identical(oja_snapshots(con)$snapshot_id, "TEST_2027_2")

      # Seconda esecuzione: lo snapshot risulta presente nella connessione.
      res2 <- oja_sync(
        region_code = "TEST",
        config = cfg,
        lister = fake_lister,
        downloader = fake_dl,
        con = con
      )
      expect_false(res2$ingested)
      expect_true(DBI::dbIsValid(con))
    }
  )
}
