# Lettura della dimensione CP2021 del fornitore (dim_occ_cp2021.csv).
#
# Il file Lightcast e' malformato in modo sistematico. L'intestazione dichiara
# 11 colonne (_id, cod_5..cod_1, descr_5..descr_1), ma alcuni record del
# fornitore portano anche i testi di definizione di ogni livello, lunghi, con
# punti e virgola e a capo interni. Per cinque codici CP5 (1.2.1.4.1,
# 1.2.1.4.2, 1.2.2.2.1, 1.2.2.2.2, 2.3.1.4.0) l'esportazione lascia nella
# posizione corretta un record vuoto (solo `_id`) e riversa il contenuto in
# coda al file, senza virgolette coerenti, in righe con 12-22 campi. fread()
# non puo' ricomporle: ne risultano righe con frammenti di testo nelle colonne
# dei codici. In piu' le etichette contengono entita' HTML (`&agrave;`).
#
# Il lettore: (1) decodifica le entita' HTML nelle sole colonne di etichetta;
# (2) classifica ogni riga come valida, vuota recuperabile o frammento;
# (3) ricostruisce i record vuoti dall'ancora `;cod_5;cod_4;cod_3;cod_2;cod_1;`
# presente nel testo grezzo, solo se le etichette coincidono con quelle gia'
# note per gli stessi codici; (4) mette in quarantena il resto, con un avviso
# esplicito, e fallisce se la quota in quarantena e' anomala.

# 1. Entita' HTML -----

.html_entita_nominali <- c(
  agrave = "\u00e0",
  egrave = "\u00e8",
  eacute = "\u00e9",
  igrave = "\u00ec",
  ograve = "\u00f2",
  ugrave = "\u00f9",
  Agrave = "\u00c0",
  Egrave = "\u00c8",
  Eacute = "\u00c9",
  Igrave = "\u00cc",
  Ograve = "\u00d2",
  Ugrave = "\u00d9",
  acirc = "\u00e2",
  ecirc = "\u00ea",
  icirc = "\u00ee",
  ocirc = "\u00f4",
  ucirc = "\u00fb",
  ccedil = "\u00e7",
  Ccedil = "\u00c7",
  rsquo = "\u2019",
  lsquo = "\u2018",
  rdquo = "\u201d",
  ldquo = "\u201c",
  ndash = "\u2013",
  mdash = "\u2014",
  euro = "\u20ac",
  nbsp = " ",
  amp = "&",
  lt = "<",
  gt = ">",
  quot = "\"",
  apos = "'"
)

# Decodifica le entita' HTML nominali note e quelle numeriche. Le entita'
# nominali non riconosciute restano invariate: la validazione le segnala.
# @noRd
.decode_html_entities <- function(x) {
  if (!length(x)) {
    return(x)
  }
  na <- is.na(x)
  y <- x
  y[na] <- ""
  # Numeriche: &#224; e &#xE0;
  y <- .sub_entita(y, "&#[xX]([0-9A-Fa-f]+);", function(m) {
    intToUtf8(strtoi(m, 16L))
  })
  y <- .sub_entita(y, "&#([0-9]+);", function(m) intToUtf8(strtoi(m, 10L)))
  # Nominali, `&amp;` per ultima per non produrre doppie decodifiche.
  nomi <- setdiff(names(.html_entita_nominali), "amp")
  for (n in nomi) {
    y <- gsub(paste0("&", n, ";"), .html_entita_nominali[[n]], y, fixed = TRUE)
  }
  y <- gsub("&amp;", "&", y, fixed = TRUE)
  y[na] <- NA_character_
  y
}

# Sostituisce ogni occorrenza di `pattern` (un gruppo di cattura) con
# `fun(gruppo)`, elemento per elemento.
# @noRd
.sub_entita <- function(x, pattern, fun) {
  hit <- grepl(pattern, x)
  for (i in which(hit)) {
    m <- regmatches(x[i], gregexpr(pattern, x[i]))[[1L]]
    for (tok in unique(m)) {
      grp <- sub(pattern, "\\1", tok)
      x[i] <- gsub(tok, fun(grp), x[i], fixed = TRUE)
    }
  }
  x
}

# 2. Validazione -----

.re_cp2021 <- c(
  cod_5 = "^[0-9](\\.[0-9]){4}$",
  cod_4 = "^[0-9](\\.[0-9]){3}$",
  cod_3 = "^[0-9](\\.[0-9]){2}$",
  cod_2 = "^[0-9]\\.[0-9]$",
  cod_1 = "^[0-9]$"
)

# Codici dei livelli superiori derivati dal codice a 5 cifre.
# @noRd
.cp2021_gerarchia <- function(cod_5) {
  list(
    cod_4 = sub("\\.[0-9]$", "", cod_5),
    cod_3 = sub("\\.[0-9]\\.[0-9]$", "", cod_5),
    cod_2 = sub("\\.[0-9]\\.[0-9]\\.[0-9]$", "", cod_5),
    cod_1 = sub("\\..*$", "", cod_5)
  )
}

# TRUE per le righe con cinque codici ben formati, coerenti con la gerarchia
# e con l'etichetta di livello 5 non vuota.
# @noRd
.cp2021_valida <- function(dt) {
  ok <- !is.na(dt$cod_5) & grepl(.re_cp2021[["cod_5"]], dt$cod_5)
  for (col in c("cod_4", "cod_3", "cod_2", "cod_1")) {
    ok <- ok & !is.na(dt[[col]]) & grepl(.re_cp2021[[col]], dt[[col]])
  }
  if (any(ok)) {
    att <- .cp2021_gerarchia(dt$cod_5)
    for (col in names(att)) {
      ok <- ok & dt[[col]] == att[[col]]
    }
  }
  ok & !is.na(dt$descr_5) & nzchar(dt$descr_5)
}

# 3. Recupero dei record vuoti -----

# Cerca nel testo grezzo l'ancora `;cod_5;cod_4;cod_3;cod_2;cod_1;` di `id` e
# restituisce i token di etichetta che la seguono, fino al primo `"` o a capo.
# Il punto e virgola delle entita' HTML non separa campi. NULL se l'ancora
# non e' univoca.
# @noRd
.cp2021_token_ancora <- function(id, raw) {
  att <- .cp2021_gerarchia(id)
  ancora <- paste0(
    ";",
    paste(c(id, att$cod_4, att$cod_3, att$cod_2, att$cod_1), collapse = ";"),
    ";"
  )
  pos <- gregexpr(ancora, raw, fixed = TRUE)[[1L]]
  if (length(pos) != 1L || pos[[1L]] < 0L) {
    return(NULL)
  }
  dopo <- substring(raw, pos[[1L]] + nchar(ancora))
  dopo <- sub("[\"\n].*$", "", dopo)
  dopo <- gsub("(&[A-Za-z]+|&#[0-9]+);", "\\1\001", dopo)
  tok <- strsplit(dopo, ";", fixed = TRUE)[[1L]]
  .decode_html_entities(gsub("\001", ";", tok, fixed = TRUE))
}

# Ricostruisce il record di `id`. Con un solo token questo e' l'etichetta di
# livello 5; con almeno cinque, i primi cinque sono i livelli 5..1; il resto
# e' ambiguo e non viene usato. I livelli non presenti nell'ancora sono
# ereditati dalle righe valide con lo stesso codice. Se un'etichetta
# dell'ancora contraddice quella gia' nota per lo stesso codice, il record non
# si ricostruisce. Restituisce una data.table di una riga o NULL.
# @noRd
.cp2021_ricostruisci <- function(id, raw, valide) {
  tok <- .cp2021_token_ancora(id, raw)
  n <- length(tok)
  if (n != 1L && n < 5L) {
    return(NULL)
  }
  if (any(!nzchar(tok[seq_len(min(n, 5L))]))) {
    return(NULL)
  }
  att <- .cp2021_gerarchia(id)
  rec <- data.table::data.table(
    cod_5 = id,
    cod_4 = att$cod_4,
    cod_3 = att$cod_3,
    cod_2 = att$cod_2,
    cod_1 = att$cod_1,
    descr_5 = tok[[1L]],
    descr_4 = NA_character_,
    descr_3 = NA_character_,
    descr_2 = NA_character_,
    descr_1 = NA_character_
  )
  livelli <- c(4L, 3L, 2L, 1L)
  for (k in seq_along(livelli)) {
    lv <- livelli[[k]]
    noto <- valide[
      valide[[paste0("cod_", lv)]] == rec[[paste0("cod_", lv)]],
      paste0("descr_", lv),
      with = FALSE
    ][[1L]]
    noto <- unique(noto)
    ancora_lv <- if (n >= 5L) tok[[k + 1L]] else NA_character_
    if (!is.na(ancora_lv) && length(noto) && !ancora_lv %in% noto) {
      return(NULL)
    }
    val <- if (!is.na(ancora_lv)) {
      ancora_lv
    } else if (length(noto)) {
      noto[[1L]]
    } else {
      NA_character_
    }
    data.table::set(rec, j = paste0("descr_", lv), value = val)
  }
  rec
}

# 4. Lettore -----

# Quota massima di righe in quarantena.
.cp2021_quota_max <- 0.05

# Legge `dim_occ_cp2021.csv`, applica le correzioni descritte in testa al file
# e restituisce la data.table con le colonne di `mapping` rinominate e
# deduplicata su `pk`. Attributi: `quarantena` (righe scartate, con il motivo)
# e `recuperate` (codici ricostruiti dal testo grezzo).
# @noRd
.read_dim_cp2021 <- function(csv_path, mapping, pk) {
  raw <- paste(
    readLines(csv_path, encoding = "UTF-8", warn = FALSE),
    collapse = "\n"
  )
  dt <- data.table::fread(
    text = raw,
    sep = ";",
    colClasses = "character",
    showProgress = FALSE
  )
  miss <- setdiff(names(mapping), names(dt))
  if (length(miss)) {
    cli::cli_abort("Colonne mancanti in {.path {csv_path}}: {.val {miss}}.")
  }
  if (!"_id" %in% names(dt)) {
    data.table::set(dt, j = "_id", value = NA_character_)
  }
  etichette <- grep("^descr_", names(mapping), value = TRUE)
  for (col in etichette) {
    data.table::set(dt, j = col, value = .decode_html_entities(dt[[col]]))
  }
  data.table::set(dt, j = "riga", value = seq_len(nrow(dt)) + 1L)

  # 4.1 Classificazione -----
  codici <- names(.re_cp2021)
  vuoto <- Reduce(
    `&`,
    lapply(c(codici, etichette), function(col) {
      is.na(dt[[col]]) | !nzchar(dt[[col]])
    })
  )
  valida <- .cp2021_valida(dt)
  id_ok <- !is.na(dt[["_id"]]) & grepl(.re_cp2021[["cod_5"]], dt[["_id"]])
  da_recuperare <- !valida & vuoto & id_ok
  frammento <- !valida & !da_recuperare

  # 4.2 Recupero dei record vuoti -----
  recuperati <- list()
  irrecuperabili <- character()
  for (id in unique(dt[["_id"]][da_recuperare])) {
    rec <- .cp2021_ricostruisci(id, raw, dt[valida, ])
    if (is.null(rec)) {
      irrecuperabili <- c(irrecuperabili, id)
    } else {
      recuperati[[id]] <- rec
    }
  }
  recuperate <- data.table::rbindlist(recuperati)
  if (nrow(recuperate)) {
    data.table::set(recuperate, j = "_id", value = recuperate$cod_5)
  }

  # 4.3 Quarantena -----
  quar_idx <- which(
    frammento | (da_recuperare & dt[["_id"]] %in% irrecuperabili)
  )
  quarantena <- dt[
    quar_idx,
    list(
      riga,
      motivo = ifelse(
        frammento[quar_idx],
        "frammento: codici non validi",
        "record vuoto non ricostruibile"
      ),
      id = dt[["_id"]][quar_idx],
      cod_5 = substr(cod_5, 1L, 60L),
      testo = substr(gsub("\n", " ", descr_5), 1L, 60L)
    )
  ]
  pulito <- data.table::rbindlist(
    list(dt[valida], recuperate),
    use.names = TRUE,
    fill = TRUE
  )
  if (
    nrow(pulito) == 0L ||
      nrow(quarantena) / nrow(dt) > .cp2021_quota_max
  ) {
    cli::cli_abort(c(
      "Il file {.path {csv_path}} non e' leggibile come dimensione CP2021.",
      "x" = "Righe valide: {nrow(pulito)}; in quarantena: {nrow(quarantena)} su {nrow(dt)}.",
      "i" = "Controllare delimitatore, virgolette e codifica del file del fornitore."
    ))
  }
  if (nrow(recuperate)) {
    cli::cli_warn(c(
      "Dimensione CP2021: {nrow(recuperate)} record vuoti ricostruiti dal testo grezzo.",
      "i" = "Codici: {.val {recuperate$cod_5}}.",
      "i" = "Etichette dei livelli assenti dall'ancora ereditate dalle righe con lo stesso codice."
    ))
  }
  if (nrow(quarantena)) {
    cli::cli_warn(c(
      "Dimensione CP2021: {nrow(quarantena)} righe in quarantena, non caricate.",
      "i" = "Righe del file: {.val {quarantena$riga}}.",
      "i" = "Sono frammenti di record malformati del fornitore o record non ricostruibili."
    ))
  }
  lacune <- pulito[
    is.na(descr_4) | is.na(descr_3) | is.na(descr_2) | is.na(descr_1)
  ]
  if (nrow(lacune)) {
    cli::cli_warn(
      "Dimensione CP2021: {nrow(lacune)} righe senza etichetta in almeno un livello: {.val {lacune$cod_5}}."
    )
  }

  out <- pulito[, names(mapping), with = FALSE]
  data.table::setnames(out, unname(mapping))
  out <- out[!is.na(get(pk)) & get(pk) != ""]
  dup <- anyDuplicated(out, by = pk)
  if (dup) {
    cli::cli_warn(
      "Dimensione CP2021: {sum(duplicated(out, by = pk))} codici duplicati, tenuta la prima occorrenza."
    )
  }
  out <- unique(out, by = pk)
  data.table::setattr(out, "quarantena", quarantena)
  data.table::setattr(out, "recuperate", recuperate$cod_5)
  out
}
