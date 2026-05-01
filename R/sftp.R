# 1. Lettura della configurazione SFTP da .Renviron --------------------------

#' Configurazione SFTP da variabili d'ambiente
#'
#' Legge le credenziali e il percorso remoto degli snapshot OJA dalle
#' variabili `ITAPOSTS_SFTP_*`. Le variabili `HOST`, `USER`, `PASSWORD` e
#' `REMOTE_DIR` sono obbligatorie; `PORT` ha default `22` e `LOCAL_DIR`
#' default `file.path(tempdir(), "itaposts_incoming")`.
#'
#' Convenzione `.Renviron`:
#'
#' ```
#' ITAPOSTS_SFTP_HOST=sftp.lightcast.example
#' ITAPOSTS_SFTP_PORT=22
#' ITAPOSTS_SFTP_USER=...
#' ITAPOSTS_SFTP_PASSWORD=...
#' ITAPOSTS_SFTP_REMOTE_DIR=/exports/oja
#' ITAPOSTS_SFTP_LOCAL_DIR=~/Documents/funzioni/itaposts/incoming
#' ```
#'
#' @param env Funzione di lettura variabili (default `Sys.getenv`). Iniettabile
#'   nei test.
#'
#' @return Lista con campi `host`, `port`, `user`, `password`, `remote_dir`,
#'   `local_dir`.
#' @export
#' @examples
#' \dontrun{
#'   readRenviron("~/.Renviron")
#'   cfg <- oja_sftp_config()
#' }
oja_sftp_config <- function(env = Sys.getenv) {
  required <- c(
    host = "ITAPOSTS_SFTP_HOST",
    user = "ITAPOSTS_SFTP_USER",
    password = "ITAPOSTS_SFTP_PASSWORD",
    remote_dir = "ITAPOSTS_SFTP_REMOTE_DIR"
  )
  vals <- vapply(required, function(v) env(v, unset = ""), character(1))
  missing <- required[vals == ""]
  if (length(missing)) {
    cli::cli_abort(c(
      "Variabili d'ambiente mancanti per la configurazione SFTP.",
      "x" = "Definire {.envvar {missing}} in {.path .Renviron}.",
      "i" = "Dopo l'edit: {.code readRenviron(\"~/.Renviron\")}."
    ))
  }
  port_raw <- env("ITAPOSTS_SFTP_PORT", unset = "22")
  port <- suppressWarnings(as.integer(port_raw))
  if (is.na(port) || port < 1 || port > 65535) {
    cli::cli_abort(
      "Valore non valido per {.envvar ITAPOSTS_SFTP_PORT}: {.val {port_raw}}."
    )
  }
  local_dir <- env(
    "ITAPOSTS_SFTP_LOCAL_DIR",
    unset = file.path(tempdir(), "itaposts_incoming")
  )
  local_dir <- path.expand(local_dir)

  list(
    host = unname(vals["host"]),
    port = port,
    user = unname(vals["user"]),
    password = unname(vals["password"]),
    remote_dir = sub("/+$", "", unname(vals["remote_dir"])),
    local_dir = local_dir
  )
}

# 2. Helper interni ----------------------------------------------------------

# Costruisce un curl handle autenticato per le chiamate SFTP.
.sftp_handle <- function(config) {
  h <- curl::new_handle()
  curl::handle_setopt(
    h,
    username = config$user,
    password = config$password,
    port = config$port,
    ssh_auth_types = 1L # password
  )
  h
}

.sftp_url <- function(config, path = "") {
  base <- sprintf(
    "sftp://%s%s",
    config$host,
    if (nzchar(config$remote_dir)) config$remote_dir else ""
  )
  if (!nzchar(path)) {
    paste0(base, "/")
  } else {
    paste0(base, "/", sub("^/", "", path))
  }
}

# Parser di una riga `ls -l` Unix-style (output che libcurl restituisce per le
# directory SFTP). Esempio:
#   -rw-r--r--   1 user grp   10595813 Mar 18 08:59 ITC4_2026_2_postings.zip
.parse_listing <- function(text) {
  lines <- strsplit(text, "\r?\n", perl = TRUE)[[1]]
  lines <- lines[nzchar(lines)]
  rx <- "^([\\-ldrwxsStT]+)\\s+\\d+\\s+\\S+\\s+\\S+\\s+(\\d+)\\s+\\S+\\s+\\S+\\s+\\S+\\s+(.+)$"
  m <- regmatches(lines, regexec(rx, lines, perl = TRUE))
  ok <- vapply(m, length, integer(1)) == 4L
  m <- m[ok]
  if (!length(m)) {
    return(data.frame(name = character(), size_bytes = double()))
  }
  data.frame(
    name = vapply(m, `[`, character(1), 4L),
    size_bytes = as.numeric(vapply(m, `[`, character(1), 3L)),
    stringsAsFactors = FALSE
  )
}

# Pattern di un nome file di snapshot e parser dello snapshot_id.
.snapshot_file_pattern <- function(region_code) {
  sprintf(
    "^(%s_\\d{4}_\\d{1,2})_(postings|postings_raw|skills)\\.zip$",
    region_code
  )
}

# 3. Listing remoto ----------------------------------------------------------

#' Elenca gli archivi snapshot presenti sul server SFTP
#'
#' @param config Output di [oja_sftp_config()].
#' @param region_code Filtro NUTS-2 sui nomi file. Default `"ITC4"`.
#'
#' @return `data.frame` con colonne `name`, `size_bytes`, `snapshot_id`,
#'   `kind` (uno tra `"postings"`, `"postings_raw"`, `"skills"`).
#' @export
#' @examples
#' \dontrun{
#'   oja_remote_list()
#' }
oja_remote_list <- function(config = oja_sftp_config(), region_code = "ITC4") {
  url <- .sftp_url(config)
  res <- curl::curl_fetch_memory(url, handle = .sftp_handle(config))
  if (res$status_code != 0L && !is.null(res$status_code)) {
    cli::cli_abort(
      "Listing SFTP fallito: status {res$status_code} su {.url {url}}."
    )
  }
  raw <- rawToChar(res$content)
  files <- .parse_listing(raw)
  if (!nrow(files)) {
    return(files)
  }

  pat <- .snapshot_file_pattern(region_code)
  m <- regmatches(files$name, regexec(pat, files$name, perl = TRUE))
  ok <- vapply(m, length, integer(1)) == 3L
  files <- files[ok, , drop = FALSE]
  m <- m[ok]
  if (!nrow(files)) {
    return(data.frame(
      name = character(),
      size_bytes = double(),
      snapshot_id = character(),
      kind = character()
    ))
  }
  files$snapshot_id <- vapply(m, `[`, character(1), 2L)
  files$kind <- vapply(m, `[`, character(1), 3L)
  rownames(files) <- NULL
  files
}

# 4. Download di un singolo file --------------------------------------------

#' Scarica un singolo file via SFTP
#'
#' Download atomico: scrive in `<local_path>.part` e rinomina al termine.
#' Errore lasciato propagare al chiamante; in caso di errore il file `.part`
#' resta sul disco come traccia diagnostica.
#'
#' @param remote_name Nome del file remoto (relativo a `config$remote_dir`).
#' @param local_path Percorso locale di destinazione.
#' @param config Output di [oja_sftp_config()].
#'
#' @return Invisibilmente `local_path`.
#' @export
oja_sftp_download <- function(
  remote_name,
  local_path,
  config = oja_sftp_config()
) {
  if (!dir.exists(dirname(local_path))) {
    dir.create(dirname(local_path), recursive = TRUE, showWarnings = FALSE)
  }
  url <- .sftp_url(config, remote_name)
  part <- paste0(local_path, ".part")
  curl::curl_download(
    url,
    destfile = part,
    handle = .sftp_handle(config),
    mode = "wb"
  )
  if (!file.rename(part, local_path)) {
    cli::cli_abort(
      "Rename atomico fallito da {.path {part}} a {.path {local_path}}."
    )
  }
  invisible(local_path)
}

# 5. Sincronizzazione end-to-end --------------------------------------------

#' Sincronizza gli snapshot OJA dal server SFTP e li ingerisce
#'
#' Scarica nella cartella locale tutti gli snapshot remoti non ancora
#' presenti (o solo quelli indicati in `snapshots`) e li ingerisce nel DB
#' DuckDB chiamando [oja_ingest_dirs()]. La funzione e' idempotente: file
#' locali con stessa dimensione del remoto vengono saltati, snapshot gia'
#' presenti in `dim_snapshot` non vengono reingeriti a meno di
#' `overwrite = TRUE`.
#'
#' @param region_code Codice NUTS-2 da scaricare. Default `"ITC4"`.
#' @param snapshots Vettore opzionale di `snapshot_id` da limitare.
#' @param ingest Logico. Se `FALSE` esegue solo il download.
#' @param overwrite Logico. Inoltrato a [oja_ingest_snapshot()].
#' @param config Output di [oja_sftp_config()].
#' @param path Percorso del file DuckDB. Default [oja_db_path()].
#' @param lister,downloader Funzioni iniettabili (per i test).
#'
#' @return Invisibilmente un `data.frame` con `snapshot_id`, `downloaded`,
#'   `ingested`, `n_postings`, `n_skills`.
#' @export
#' @examples
#' \dontrun{
#'   readRenviron("~/.Renviron")
#'   oja_sync()
#' }
oja_sync <- function(
  region_code = "ITC4",
  snapshots = NULL,
  ingest = TRUE,
  overwrite = FALSE,
  config = oja_sftp_config(),
  path = oja_db_path(),
  lister = oja_remote_list,
  downloader = oja_sftp_download
) {
  if (!dir.exists(config$local_dir)) {
    dir.create(config$local_dir, recursive = TRUE, showWarnings = FALSE)
  }

  cli::cli_inform(
    "Listing remoto su {.url sftp://{config$host}{config$remote_dir}/}..."
  )
  remote <- lister(config, region_code)
  if (!nrow(remote)) {
    cli::cli_warn(
      "Nessun file snapshot trovato per region {.val {region_code}}."
    )
    return(invisible(data.frame(
      snapshot_id = character(),
      downloaded = logical(),
      ingested = logical(),
      n_postings = integer(),
      n_skills = integer()
    )))
  }

  # Raggruppa per snapshot_id; tieni solo i triplet completi
  by_snap <- split(remote, remote$snapshot_id)
  needed_kinds <- c("postings", "postings_raw", "skills")
  complete <- vapply(
    by_snap,
    function(df) all(needed_kinds %in% df$kind),
    logical(1)
  )
  if (any(!complete)) {
    cli::cli_warn(c(
      "Snapshot remoti incompleti, ignorati: {.val {names(by_snap)[!complete]}}.",
      "i" = "Servono i tre archivi {.val {needed_kinds}}."
    ))
  }
  by_snap <- by_snap[complete]

  if (!is.null(snapshots)) {
    by_snap <- by_snap[intersect(names(by_snap), snapshots)]
  }
  if (!length(by_snap)) {
    cli::cli_warn("Nessuno snapshot da sincronizzare.")
    return(invisible(data.frame(
      snapshot_id = character(),
      downloaded = logical(),
      ingested = logical(),
      n_postings = integer(),
      n_skills = integer()
    )))
  }

  # Snapshot gia' nel DB
  already <- character()
  if (file.exists(path)) {
    con <- oja_connect(path = path)
    already <- oja_snapshots(con)$snapshot_id
    oja_disconnect(con)
  }

  rows <- vector("list", length(by_snap))
  to_ingest <- character()
  for (i in seq_along(by_snap)) {
    sid <- names(by_snap)[i]
    files <- by_snap[[sid]]
    skip_ingest <- ingest && !overwrite && sid %in% already
    if (skip_ingest) {
      cli::cli_alert_info(
        "Snapshot {.val {sid}}: gia' nel DB, skip download e ingest."
      )
      rows[[i]] <- data.frame(
        snapshot_id = sid,
        downloaded = FALSE,
        ingested = FALSE,
        n_postings = NA_integer_,
        n_skills = NA_integer_,
        stringsAsFactors = FALSE
      )
      next
    }
    downloaded_any <- FALSE
    for (j in seq_len(nrow(files))) {
      remote_name <- files$name[j]
      local_path <- file.path(config$local_dir, remote_name)
      if (
        file.exists(local_path) &&
          file.info(local_path)$size == files$size_bytes[j]
      ) {
        next
      }
      sz_fmt <- format(
        files$size_bytes[j],
        big.mark = ".",
        decimal.mark = ",",
        scientific = FALSE
      )
      cli::cli_inform("Download {.path {remote_name}} ({sz_fmt} byte)...")
      downloader(remote_name, local_path, config)
      downloaded_any <- TRUE
    }
    rows[[i]] <- data.frame(
      snapshot_id = sid,
      downloaded = downloaded_any,
      ingested = FALSE,
      n_postings = NA_integer_,
      n_skills = NA_integer_,
      stringsAsFactors = FALSE
    )
    if (ingest) to_ingest <- c(to_ingest, sid)
  }

  if (ingest && length(to_ingest)) {
    cli::cli_inform(
      "Ingest di {length(to_ingest)} snapshot in {.path {path}}..."
    )
    summary <- oja_ingest_dirs(
      zip_dir = config$local_dir,
      snapshots = to_ingest,
      overwrite = overwrite,
      path = path
    )
    if (nrow(summary)) {
      m <- match(
        unname(vapply(rows, `[[`, character(1), "snapshot_id")),
        summary$snapshot_id
      )
      for (i in seq_along(rows)) {
        if (!is.na(m[i])) {
          rows[[i]]$ingested <- TRUE
          rows[[i]]$n_postings <- summary$n_postings[m[i]]
          rows[[i]]$n_skills <- summary$n_skills[m[i]]
        }
      }
    }
  }

  out <- do.call(rbind, rows)
  cli::cli_alert_success(
    "Sync completata: {sum(out$downloaded)} download, {sum(out$ingested)} ingest."
  )
  invisible(out)
}
