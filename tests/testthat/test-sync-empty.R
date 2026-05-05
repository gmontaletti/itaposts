# Regressione: oja_sync() non deve sollevare "invalid argument type" quando
# oja_ingest_dirs() ritorna un data.frame vuoto (tutti gli snapshot sono gia'
# su disco ma non ancora nel DB, oppure l'ingest fallisce per ognuno di essi).
# Prima del fix, summary$snapshot_id era NULL (data.frame senza colonne) e
# match(<chr>, NULL) sollevava "invalid argument type".

# Helper: listing remoto di due snapshot completi, usato da tutti i test qui.
.fake_listing_two <- function(config, region_code) {
  do.call(
    rbind,
    lapply(c("ITC4_2026_1", "ITC4_2026_2"), function(sid) {
      data.frame(
        name = paste0(
          sid,
          "_",
          c("postings", "postings_raw", "skills"),
          ".zip"
        ),
        size_bytes = c(100, 50, 200),
        snapshot_id = sid,
        kind = c("postings", "postings_raw", "skills"),
        stringsAsFactors = FALSE
      )
    })
  )
}

# Helper: config minima senza credenziali reali.
.fake_cfg <- function(local_dir) {
  list(
    host = "sftp.example",
    port = 22L,
    user = "u",
    password = "p",
    remote_dir = "/data",
    local_dir = local_dir
  )
}

# Frame canonico vuoto che Fix 1 garantisce come ritorno di oja_ingest_dirs()
# quando nessuno snapshot viene processato.
.typed_empty_summary <- function() {
  data.frame(
    snapshot_id = character(),
    n_postings = integer(),
    n_skills = integer(),
    ingested_at = as.POSIXct(character()),
    stringsAsFactors = FALSE
  )
}

test_that("oja_sync non solleva errore quando oja_ingest_dirs ritorna frame vuoto", {
  # Scenario: i file sono gia' su disco (size match), oja_ingest_dirs() viene
  # chiamato con i due snapshot_id ma restituisce un data.frame con 0 righe e
  # colonne tipizzate (Fix 1). Prima del Fix 2, nrow(data.frame()) == 0 faceva
  # saltare il blocco, quindi non c'era errore in questo scenario specifico.
  # Il test verifica comunque che il ritorno sia integro e privo di errori.
  local_dir <- tempfile("itaposts_sync_empty_")
  dir.create(local_dir, recursive = TRUE)
  on.exit(unlink(local_dir, recursive = TRUE), add = TRUE)

  # Crea file locali con stessa dimensione del remoto: il downloader non viene
  # mai invocato (tutti i file vengono saltati per size match).
  for (sid in c("ITC4_2026_1", "ITC4_2026_2")) {
    sizes <- c(postings = 100, postings_raw = 50, skills = 200)
    for (kind in names(sizes)) {
      fname <- file.path(local_dir, paste0(sid, "_", kind, ".zip"))
      writeBin(raw(sizes[[kind]]), fname)
    }
  }

  fake_dl <- function(remote_name, local_path, config) {
    stop("downloader non dovrebbe essere invocato in questo test")
  }

  testthat::with_mocked_bindings(
    oja_ingest_dirs = function(...) .typed_empty_summary(),
    {
      out <- oja_sync(
        config = .fake_cfg(local_dir),
        path = tempfile(fileext = ".duckdb"),
        lister = .fake_listing_two,
        downloader = fake_dl,
        ingest = TRUE
      )
    },
    .package = "itaposts"
  )

  expect_equal(nrow(out), 2L)
  expect_true(all(out$downloaded == FALSE))
  expect_true(all(out$ingested == FALSE))
  expect_setequal(out$snapshot_id, c("ITC4_2026_1", "ITC4_2026_2"))
})

test_that("oja_sync non solleva errore quando summary ha snapshot_id ma zero righe", {
  # Scenario alternativo: Fix 2 copre il caso in cui il guard 'nrow(summary)'
  # e' rimasto il vecchio 'if (nrow(summary))' e summary e' data.frame() puro
  # (0 colonne). Dopo Fix 1 questo non puo' piu' accadere, ma il test rimane
  # come barriera di non-regressione.
  local_dir <- tempfile("itaposts_sync_empty2_")
  dir.create(local_dir, recursive = TRUE)
  on.exit(unlink(local_dir, recursive = TRUE), add = TRUE)

  for (sid in c("ITC4_2026_1", "ITC4_2026_2")) {
    sizes <- c(postings = 100, postings_raw = 50, skills = 200)
    for (kind in names(sizes)) {
      writeBin(
        raw(sizes[[kind]]),
        file.path(
          local_dir,
          paste0(sid, "_", kind, ".zip")
        )
      )
    }
  }

  # Simula il vecchio comportamento difettoso: data.frame senza colonne.
  # Il Fix 2 previene che match() venga chiamato con NULL come secondo arg.
  testthat::with_mocked_bindings(
    oja_ingest_dirs = function(...) data.frame(),
    {
      expect_no_error(
        oja_sync(
          config = .fake_cfg(local_dir),
          path = tempfile(fileext = ".duckdb"),
          lister = .fake_listing_two,
          downloader = function(...) stop("no download"),
          ingest = TRUE
        )
      )
    },
    .package = "itaposts"
  )
})

test_that("oja_sync integra correttamente i conteggi quando oja_ingest_dirs ha risultati", {
  # Verifica il path positivo: quando oja_ingest_dirs ritorna righe con
  # snapshot_id/n_postings/n_skills, oja_sync propaga i valori nelle righe.
  local_dir <- tempfile("itaposts_sync_counts_")
  dir.create(local_dir, recursive = TRUE)
  on.exit(unlink(local_dir, recursive = TRUE), add = TRUE)

  # File mancanti: il downloader li "crea" localmente.
  fake_dl <- function(remote_name, local_path, config) {
    listing <- .fake_listing_two(NULL, NULL)
    sz <- listing$size_bytes[match(remote_name, listing$name)]
    writeBin(raw(sz), local_path)
    invisible(local_path)
  }

  fake_summary <- data.frame(
    snapshot_id = c("ITC4_2026_1", "ITC4_2026_2"),
    n_postings = c(100L, 200L),
    n_skills = c(400L, 800L),
    ingested_at = as.POSIXct(c("2026-05-01 10:00:00", "2026-05-01 10:05:00")),
    stringsAsFactors = FALSE
  )

  testthat::with_mocked_bindings(
    oja_ingest_dirs = function(...) fake_summary,
    {
      out <- oja_sync(
        config = .fake_cfg(local_dir),
        path = tempfile(fileext = ".duckdb"),
        lister = .fake_listing_two,
        downloader = fake_dl,
        ingest = TRUE
      )
    },
    .package = "itaposts"
  )

  expect_equal(nrow(out), 2L)
  expect_true(all(out$ingested == TRUE))
  # I conteggi devono essere propagati correttamente (indipendentemente
  # dall'ordine di restituzione di oja_ingest_dirs).
  snap1 <- out[out$snapshot_id == "ITC4_2026_1", ]
  snap2 <- out[out$snapshot_id == "ITC4_2026_2", ]
  expect_equal(snap1$n_postings, 100L)
  expect_equal(snap2$n_postings, 200L)
  expect_equal(snap1$n_skills, 400L)
  expect_equal(snap2$n_skills, 800L)
})
