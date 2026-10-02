# Il file dim_occ_cp2021.csv del fornitore e' malformato: record svuotati in
# posizione e riversati in coda senza virgolette coerenti, entita' HTML nelle
# etichette. Il fixture riproduce i tre difetti in piccolo.

.mapping_cp2021 <- c(
  cod_5 = "cp2021_id_level_5",
  descr_5 = "cp2021_level_5",
  cod_4 = "cp2021_id_level_4",
  descr_4 = "cp2021_level_4",
  cod_3 = "cp2021_id_level_3",
  descr_3 = "cp2021_level_3",
  cod_2 = "cp2021_id_level_2",
  descr_2 = "cp2021_level_2",
  cod_1 = "cp2021_id_level_1",
  descr_1 = "cp2021_level_1"
)

# Scrive un CSV nel formato del fornitore. `n_valide` controlla quante righe
# regolari precedono i record svuotati.
.fx_csv_cp2021 <- function(vuoti = TRUE, coda = TRUE, entita = TRUE) {
  q <- function(...) paste0('"', c(...), '"', collapse = ";")
  riga <- function(c5, d5, d4, d3, d2, d1) {
    c4 <- sub("\\.[0-9]$", "", c5)
    c3 <- sub("\\.[0-9]$", "", c4)
    c2 <- sub("\\.[0-9]$", "", c3)
    c1 <- sub("\\..*$", "", c5)
    q(c5, c5, c4, c3, c2, c1, d5, d4, d3, d2, d1)
  }
  righe <- c(
    q("_id", "cod_5", "cod_4", "cod_3", "cod_2", "cod_1", "descr_5", "descr_4",
      "descr_3", "descr_2", "descr_1"),
    riga("2.3.1.1.0", "Biologi", "Biologi e professioni assimilate",
         if (entita) "Specialisti nelle scienze della vita" else "Specialisti",
         "Specialisti nelle scienze", "PROFESSIONI INTELLETTUALI"),
    riga("2.6.2.1.1", "Ricercatori", "Ricercatori e tecnici",
         if (entita) "Ricercatori nell'universit&agrave;" else "Ricercatori",
         "Specialisti della formazione", "PROFESSIONI INTELLETTUALI")
  )
  if (vuoti) {
    righe <- c(righe, q("2.3.1.4.0", rep("", 10L)), q("2.3.1.4.1", rep("", 10L)))
  }
  # Righe regolari di riempimento: la quarantena ammette fino al 5% delle righe.
  righe <- c(
    righe,
    vapply(
      seq_len(80L),
      function(i) {
        riga(sprintf("7.%d.%d.1.0", i %/% 10L, i %% 10L), "Operai", "Operai", "Operai", "Operai", "OPERAI")
      },
      character(1L)
    ),
    riga("9.3.1.1.0", "Truppa", "Truppa", "Truppa", "Truppa", "FORZE ARMATE")
  )
  if (coda) {
    righe <- c(
      righe,
      # Record riversato: nessuna virgoletta di campo, definizione con ';' e a capo.
      paste0(
        '";2.3.1.4.0;2.3.1.4;2.3.1;2.3;2;Medici veterinari;Veterinari;',
        "Specialisti nelle scienze della vita;Specialisti nelle scienze;",
        "PROFESSIONI INTELLETTUALI;Le professioni conducono ricerche"
      ),
      'e applicano le conoscenze";"";"";"";"";"";"";"";"";"";""',
      # Frammento senza ancora: definizione spezzata sui punti e virgola.
      '"Dedicano la loro opera alla protezione";" alla conservazione";"";""'
    )
  }
  f <- tempfile(fileext = ".csv")
  writeLines(righe, f, useBytes = TRUE)
  f
}

# 1. Entita' HTML -------------------------------------------------------------

test_that(".decode_html_entities decodifica le entita' note e lascia NA", {
  expect_identical(
    .decode_html_entities(c("universit&agrave;", "caff&egrave; &amp; t&eacute;", NA)),
    c("università", "caffè & té", NA)
  )
  expect_identical(.decode_html_entities("&#224; &#xE8;"), "à è")
  expect_identical(.decode_html_entities("&sconosciuta;"), "&sconosciuta;")
  expect_identical(.decode_html_entities(character()), character())
})

# 2. Lettura -------------------------------------------------------------------

test_that(".read_dim_cp2021 ricostruisce i record vuoti, decodifica e mette in quarantena", {
  f <- .fx_csv_cp2021()
  on.exit(unlink(f), add = TRUE)
  avvisi <- testthat::capture_warnings(
    dt <- .read_dim_cp2021(f, .mapping_cp2021, "cp2021_id_level_5")
  )
  expect_true(any(grepl("ricostruiti", avvisi)))
  expect_true(any(grepl("quarantena", avvisi)))
  # Nessun frammento nelle colonne dei codici.
  expect_true(all(grepl("^[0-9](\\.[0-9]){4}$", dt$cp2021_id_level_5)))
  expect_true(all(grepl("^[0-9](\\.[0-9]){3}$", dt$cp2021_id_level_4)))
  expect_true(all(grepl("^[0-9](\\.[0-9]){2}$", dt$cp2021_id_level_3)))
  # 2.3.1.4.0 e' ricostruito con le etichette dell'ancora; 2.3.1.4.1 no.
  rec <- dt[cp2021_id_level_5 == "2.3.1.4.0"]
  expect_identical(rec$cp2021_level_5, "Medici veterinari")
  expect_identical(rec$cp2021_level_4, "Veterinari")
  expect_false("2.3.1.4.1" %in% dt$cp2021_id_level_5)
  expect_identical(attr(dt, "recuperate"), "2.3.1.4.0")
  quar <- attr(dt, "quarantena")
  expect_true("2.3.1.4.1" %in% quar$id)
  expect_gte(nrow(quar), 2L)
  # Entita' decodificate.
  expect_false(any(grepl("&[a-z]+;", unlist(dt))))
  expect_identical(
    dt[cp2021_id_level_5 == "2.6.2.1.1"]$cp2021_level_3,
    "Ricercatori nell'università"
  )
  # Chiave unica.
  expect_false(anyDuplicated(dt$cp2021_id_level_5) > 0L)
})

test_that(".read_dim_cp2021 eredita le etichette assenti dall'ancora", {
  f <- tempfile(fileext = ".csv")
  on.exit(unlink(f), add = TRUE)
  base <- readLines(.fx_csv_cp2021(vuoti = FALSE, coda = FALSE))
  q <- function(...) paste0('"', c(...), '"', collapse = ";")
  writeLines(
    c(
      base,
      q("2.3.1.4.0", rep("", 10L)),
      '";2.3.1.4.0;2.3.1.4;2.3.1;2.3;2;Medici veterinari";"";"";"";"";"";"";"";"";"";""'
    ),
    f
  )
  avvisi <- testthat::capture_warnings(
    dt <- .read_dim_cp2021(f, .mapping_cp2021, "cp2021_id_level_5")
  )
  expect_true(any(grepl("senza etichetta", avvisi)))
  rec <- dt[cp2021_id_level_5 == "2.3.1.4.0"]
  expect_identical(rec$cp2021_level_5, "Medici veterinari")
  # Livelli 3..1 ereditati da 2.3.1.1.0; livello 4 senza riga di riferimento.
  expect_identical(rec$cp2021_level_3, "Specialisti nelle scienze della vita")
  expect_identical(rec$cp2021_level_1, "PROFESSIONI INTELLETTUALI")
  expect_true(is.na(rec$cp2021_level_4))
})

test_that(".read_dim_cp2021 non ricostruisce se l'ancora contraddice le etichette note", {
  f <- tempfile(fileext = ".csv")
  on.exit(unlink(f), add = TRUE)
  base <- readLines(.fx_csv_cp2021(vuoti = FALSE, coda = FALSE))
  q <- function(...) paste0('"', c(...), '"', collapse = ";")
  writeLines(
    c(
      base,
      q("2.3.1.4.0", rep("", 10L)),
      '";2.3.1.4.0;2.3.1.4;2.3.1;2.3;2;A;B;Etichetta diversa;C;D";"";"";"";"";"";"";"";"";"";""'
    ),
    f
  )
  suppressWarnings(dt <- .read_dim_cp2021(f, .mapping_cp2021, "cp2021_id_level_5"))
  expect_false("2.3.1.4.0" %in% dt$cp2021_id_level_5)
  expect_true("2.3.1.4.0" %in% attr(dt, "quarantena")$id)
})

test_that(".read_dim_cp2021 su un file regolare non emette avvisi ne' quarantena", {
  f <- .fx_csv_cp2021(vuoti = FALSE, coda = FALSE, entita = FALSE)
  on.exit(unlink(f), add = TRUE)
  expect_no_warning(
    dt <- .read_dim_cp2021(f, .mapping_cp2021, "cp2021_id_level_5")
  )
  expect_identical(nrow(dt), 83L)
  expect_identical(nrow(attr(dt, "quarantena")), 0L)
})

test_that(".read_dim_cp2021 fallisce se la quota in quarantena e' anomala", {
  f <- tempfile(fileext = ".csv")
  on.exit(unlink(f), add = TRUE)
  writeLines(
    c(
      '"_id";"cod_5";"cod_4";"cod_3";"cod_2";"cod_1";"descr_5";"descr_4";"descr_3";"descr_2";"descr_1"',
      rep('"x";"y";"z";"w";"v";"u";"a";"b";"c";"d";"e"', 5L)
    ),
    f
  )
  expect_error(
    suppressWarnings(.read_dim_cp2021(f, .mapping_cp2021, "cp2021_id_level_5")),
    "non e' leggibile"
  )
})

test_that(".read_dim_cp2021 segnala le colonne mancanti", {
  f <- tempfile(fileext = ".csv")
  on.exit(unlink(f), add = TRUE)
  writeLines(c('"cod_5";"cod_4"', '"1.1.1.1.1";"1.1.1.1"'), f)
  expect_error(
    .read_dim_cp2021(f, .mapping_cp2021, "cp2021_id_level_5"),
    "Colonne mancanti"
  )
})

# 3. Caricamento nel database ------------------------------------------------

for (backend in .oja_backends) {
  test_that(
    sprintf("oja_reload_dims carica la dimensione CP2021 corretta [%s]", backend),
    {
      path <- local_temp_store(backend)
      dim_dir <- tempfile("dim_")
      dir.create(dim_dir)
      on.exit(unlink(dim_dir, recursive = TRUE), add = TRUE)
      fx <- .fx_csv_cp2021()
      file.copy(fx, file.path(dim_dir, "dim_occ_cp2021.csv"))
      data.table::fwrite(.fx_dim_esco_occupation(), file.path(dim_dir, "dim_occ_esco.csv"), sep = ";")
      data.table::fwrite(.fx_dim_esco_skills(c("S1", "S2")), file.path(dim_dir, "dim_esco_skills.csv"), sep = ";")
      suppressWarnings(n <- oja_reload_dims(dim_dir, path = path))
      expect_identical(n[["dim_cp2021"]], 84L)
      con <- oja_connect(path)
      on.exit(oja_disconnect(con), add = TRUE)
      cod <- DBI::dbGetQuery(con, "SELECT cp2021_id_level_5 AS c FROM dim_cp2021 ORDER BY 1")$c
      expect_true(all(c("2.3.1.1.0", "2.3.1.4.0", "2.6.2.1.1", "9.3.1.1.0") %in% cod))
      expect_false("2.3.1.4.1" %in% cod)
    }
  )
}
