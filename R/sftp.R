# 1. Lettura della configurazione SFTP da .Renviron --------------------------

#' Rimuove whitespace e una eventuale coppia di virgolette esterne.
#'
#' Difensivo contro `.Renviron` quotati: `readRenviron()` non spoglia le
#' virgolette, quindi `PASSWORD="abc"` arriva alla configurazione come
#' `"abc"` (con le virgolette) e l'auth SFTP fallisce silenziosamente.
#'
#' @param x Stringa.
#' @return Stringa trimmata, senza virgolette esterne accoppiate.
#' @noRd
.strip_outer_quotes <- function(x) {
  x <- trimws(x)
  if (nchar(x) >= 2L) {
    first <- substr(x, 1L, 1L)
    last <- substr(x, nchar(x), nchar(x))
    if (first == last && first %in% c("\"", "'")) {
      x <- substr(x, 2L, nchar(x) - 1L)
    }
  }
  x
}

# Backport di rlang::`%||%` per evitare di toccare il namespace.
`%||%` <- function(a, b) if (is.null(a)) b else a

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
#' Il backend SFTP del pacchetto si appoggia al client OpenSSH `sftp`
#' invocato via [processx::run()] (libcurl su macOS CRAN non e' compilato
#' con il backend libssh, quindi non parla SFTP). Il client OpenSSH e'
#' presente di default su macOS e su pressoche' tutte le distribuzioni
#' Linux: nessun pacchetto da installare per l'autenticazione a chiave.
#' Per l'autenticazione a password serve `expect` (preinstallato su macOS;
#' `apt install expect` su Debian/Ubuntu) oppure `sshpass`.
#'
#' La fiducia sulla chiave host SSH si configura tramite
#' `ITAPOSTS_SFTP_KNOWN_HOSTS` (percorso a un file `known_hosts`): viene
#' propagato a `sftp` come `-o UserKnownHostsFile=...` con
#' `StrictHostKeyChecking=yes`. Senza questa variabile vale il default di
#' OpenSSH moderno (`accept-new`), che memorizza la chiave la prima volta.
#' Le variabili `ITAPOSTS_SFTP_HOST_FINGERPRINT_MD5` e
#' `ITAPOSTS_SFTP_HOST_FINGERPRINT_SHA256` sono mantenute per retro-
#' compatibilita' del contratto di `oja_sftp_config()` ma non vengono
#' piu' usate (il vecchio backend libcurl le rispettava): per pinnare
#' l'host key con il backend OpenSSH usare `ITAPOSTS_SFTP_KNOWN_HOSTS`.
#'
#' Autenticazione SSH: per public-key impostare
#' `ITAPOSTS_SFTP_PRIVATE_KEY` (path al file privato; opzionali
#' `ITAPOSTS_SFTP_PUBLIC_KEY`, `ITAPOSTS_SFTP_PRIVATE_KEY_PASSPHRASE`).
#' Quando una chiave privata e' configurata, `sftp` viene lanciato in
#' modalita' batch (`BatchMode=yes`) e la passphrase deve essere caricata
#' a parte in `ssh-agent` (questo backend non la digita per conto
#' dell'utente, per non scriverla mai sull'argv). La maschera di bit
#' `ITAPOSTS_SFTP_AUTH_TYPES` (1=password, 2=publickey, 4=hostbased,
#' 8=keyboard-interactive; sommabili) viene tradotta in
#' `PreferredAuthentications` quando differisce dal default 9
#' (password+keyboard-interactive).
#'
#' Sia `USER` sia `PASSWORD` vengono trimmati su whitespace ed
#' eventuali coppie di virgolette esterne (`"..."` o `'...'`) vengono
#' rimosse: questo evita "Login denied" causati da quoting nel file
#' `.Renviron`.
#'
#' @param env Funzione di lettura variabili (default `Sys.getenv`). Iniettabile
#'   nei test.
#'
#' @return Lista con campi `host`, `port`, `user`, `password`, `remote_dir`,
#'   `local_dir`, `known_hosts`, `host_fingerprint_md5`,
#'   `host_fingerprint_sha256`, `private_key`, `public_key`,
#'   `private_key_passphrase`, `auth_types`. I tre campi
#'   `host_fingerprint_*` e `auth_types` sono informativi: il backend
#'   OpenSSH usa `known_hosts` ed eventualmente
#'   `PreferredAuthentications` derivato da `auth_types`.
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
  # Defensive: utenti con `.Renviron` quotato (PASSWORD="abc") vedrebbero
  # le virgolette finire nella stringa e l'auth fallire silenziosamente.
  vals[["user"]] <- .strip_outer_quotes(vals[["user"]])
  vals[["password"]] <- .strip_outer_quotes(vals[["password"]])
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

  known_hosts <- env("ITAPOSTS_SFTP_KNOWN_HOSTS", unset = "")
  if (nzchar(known_hosts)) {
    known_hosts <- path.expand(known_hosts)
  } else {
    known_hosts <- ""
  }
  fp_md5 <- env("ITAPOSTS_SFTP_HOST_FINGERPRINT_MD5", unset = "")
  if (nzchar(fp_md5)) {
    fp_md5 <- gsub(":", "", tolower(fp_md5), fixed = TRUE)
    if (!grepl("^[0-9a-f]{32}$", fp_md5)) {
      cli::cli_abort(c(
        "{.envvar ITAPOSTS_SFTP_HOST_FINGERPRINT_MD5} non valido.",
        "i" = "Sono attesi 32 caratteri esadecimali (eventuali `:` vengono ignorati)."
      ))
    }
  }
  fp_sha256 <- env("ITAPOSTS_SFTP_HOST_FINGERPRINT_SHA256", unset = "")
  fp_sha256 <- sub("^SHA256:", "", fp_sha256)

  private_key <- env("ITAPOSTS_SFTP_PRIVATE_KEY", unset = "")
  if (nzchar(private_key)) {
    private_key <- path.expand(private_key)
  }
  public_key <- env("ITAPOSTS_SFTP_PUBLIC_KEY", unset = "")
  if (nzchar(public_key)) {
    public_key <- path.expand(public_key)
  }
  private_key_passphrase <- env(
    "ITAPOSTS_SFTP_PRIVATE_KEY_PASSPHRASE",
    unset = ""
  )

  # Maschera di bit di libssh2: 1=password, 2=publickey, 4=hostbased,
  # 8=keyboard-interactive. Default = 1|8 (password + keyboard-interactive),
  # che copre la maggior parte degli OpenSSH che disabilitano `password` puro.
  # Se l'utente ha configurato una chiave privata, aggiungiamo publickey.
  auth_raw <- env("ITAPOSTS_SFTP_AUTH_TYPES", unset = "")
  if (nzchar(auth_raw)) {
    auth_types <- suppressWarnings(as.integer(auth_raw))
    if (is.na(auth_types) || auth_types < 1L || auth_types > 15L) {
      cli::cli_abort(c(
        "{.envvar ITAPOSTS_SFTP_AUTH_TYPES} non valido: {.val {auth_raw}}.",
        "i" = "Atteso un intero positivo (1=password, 2=publickey, 4=hostbased, 8=keyboard-interactive; sommabili)."
      ))
    }
  } else {
    auth_types <- bitwOr(1L, 8L) # password + keyboard-interactive
    if (nzchar(private_key)) auth_types <- bitwOr(auth_types, 2L)
  }

  # Avviso una sola volta per sessione se l'utente ha configurato i campi
  # libcurl-only (fingerprint pinning): il backend OpenSSH non li legge.
  if (nzchar(fp_md5) || nzchar(fp_sha256)) {
    rlang::warn(
      paste0(
        "ITAPOSTS_SFTP_HOST_FINGERPRINT_MD5 e ",
        "ITAPOSTS_SFTP_HOST_FINGERPRINT_SHA256 sono ignorate dal backend ",
        "OpenSSH. Per pinnare la chiave host usare ITAPOSTS_SFTP_KNOWN_HOSTS."
      ),
      .frequency = "once",
      .frequency_id = "itaposts_sftp_fingerprint_deprecated"
    )
  }

  list(
    host = unname(vals["host"]),
    port = port,
    user = unname(vals["user"]),
    password = unname(vals["password"]),
    remote_dir = sub("/+$", "", unname(vals["remote_dir"])),
    local_dir = local_dir,
    known_hosts = known_hosts,
    host_fingerprint_md5 = fp_md5,
    host_fingerprint_sha256 = fp_sha256,
    private_key = private_key,
    public_key = public_key,
    private_key_passphrase = private_key_passphrase,
    auth_types = auth_types
  )
}

# 2. Helper interni: argv builder e runner -----------------------------------

# Mappa la maschera di bit `auth_types` nel valore della direttiva OpenSSH
# `PreferredAuthentications`. Se la maschera coincide col default 9
# (password + keyboard-interactive) restituisce "" — in quel caso lasciamo
# che OpenSSH applichi il proprio ordine di preferenza.
.auth_types_to_preferred <- function(auth_types) {
  if (is.null(auth_types) || is.na(auth_types)) {
    return("")
  }
  default_mask <- bitwOr(1L, 8L)
  if (as.integer(auth_types) == default_mask) {
    return("")
  }
  parts <- character()
  if (bitwAnd(auth_types, 2L) != 0L) {
    parts <- c(parts, "publickey")
  }
  if (bitwAnd(auth_types, 4L) != 0L) {
    parts <- c(parts, "hostbased")
  }
  if (bitwAnd(auth_types, 8L) != 0L) {
    parts <- c(parts, "keyboard-interactive")
  }
  if (bitwAnd(auth_types, 1L) != 0L) {
    parts <- c(parts, "password")
  }
  paste(parts, collapse = ",")
}

# Costruisce l'argv (senza il binario `sftp`) per una singola invocazione
# batch del client OpenSSH. Restituisce un vettore di carattere.
#
# La forma finale e' `<flag>... <user>@<host>` (no `sftp://` URL: legacy
# quoting issues quando lo username contiene `@`).
.sftp_argv <- function(config, batchfile) {
  port <- as.integer(config$port %||% 22L)
  argv <- c(
    "-q",
    "-b",
    batchfile,
    "-P",
    as.character(port),
    "-o",
    "ConnectTimeout=30",
    "-o",
    "ServerAliveInterval=30",
    "-o",
    "NumberOfPasswordPrompts=1"
  )
  if (isTRUE(nzchar(config$known_hosts %||% ""))) {
    argv <- c(
      argv,
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      paste0("UserKnownHostsFile=", config$known_hosts)
    )
  }
  if (isTRUE(nzchar(config$private_key %||% ""))) {
    argv <- c(
      argv,
      "-i",
      config$private_key,
      "-o",
      "BatchMode=yes"
    )
  }
  pref <- .auth_types_to_preferred(config$auth_types)
  if (nzchar(pref)) {
    argv <- c(argv, "-o", paste0("PreferredAuthentications=", pref))
  }
  argv <- c(argv, paste0(config$user, "@", config$host))
  argv
}

# Sceglie il runner adatto in funzione della modalita' di auth disponibile.
# Restituisce una lista `list(cmd, args, stdin, env)` da passare a
# processx::run().
.sftp_runner <- function(config, batchfile) {
  argv <- .sftp_argv(config, batchfile)
  has_key <- isTRUE(nzchar(config$private_key %||% ""))
  has_password <- isTRUE(nzchar(config$password %||% ""))

  if (has_key || !has_password) {
    return(list(
      cmd = "sftp",
      args = argv,
      password = NULL,
      env = NULL
    ))
  }

  # Auth a password: serve un helper esterno perche' OpenSSH `sftp` legge
  # la password solo dal terminale, mai da stdin/env.
  expect_bin <- Sys.which("expect")
  sshpass_bin <- Sys.which("sshpass")

  if (nzchar(expect_bin)) {
    helper <- system.file(
      "sftp_password.expect",
      package = "itaposts",
      mustWork = FALSE
    )
    if (!nzchar(helper) || !file.exists(helper)) {
      cli::cli_abort(
        "Helper {.path inst/sftp_password.expect} non trovato nel pacchetto."
      )
    }
    return(list(
      cmd = unname(expect_bin),
      args = c("-f", helper, "--", "sftp", argv),
      password = config$password,
      env = NULL
    ))
  }

  if (nzchar(sshpass_bin)) {
    return(list(
      cmd = unname(sshpass_bin),
      args = c("-e", "sftp", argv),
      password = NULL,
      # `-e` legge da SSHPASS — niente password sull'argv, niente sul disco.
      env = c("current", SSHPASS = config$password)
    ))
  }

  cli::cli_abort(c(
    "Auth SFTP a password richiesta ma nessun helper esterno disponibile.",
    "i" = "Preferire l'auth a chiave: {.envvar ITAPOSTS_SFTP_PRIVATE_KEY}.",
    "i" = "Altrimenti installare {.code expect} (gia' presente su macOS; su Debian/Ubuntu: {.code apt install expect}) o {.code sshpass}."
  ))
}

# Invoca il client `sftp` con un batch di comandi. `batch_lines` e' un
# vettore di carattere (una direttiva sftp per riga). Ritorna
# `list(stdout, status)`. Su exit-code != 0 esce con cli::cli_abort()
# riportando lo stderr.
.sftp_run <- function(
  config,
  batch_lines,
  timeout = 1800,
  runner = .sftp_runner
) {
  if (!length(batch_lines) || !is.character(batch_lines)) {
    cli::cli_abort(
      "Argomento {.arg batch_lines} vuoto o non di tipo carattere."
    )
  }
  batchfile <- tempfile("itaposts_sftp_", fileext = ".batch")
  on.exit(try(unlink(batchfile), silent = TRUE), add = TRUE)
  writeLines(batch_lines, batchfile)
  Sys.chmod(batchfile, "0600")

  spec <- runner(config, batchfile)
  res <- .sftp_invoke(spec, timeout = timeout)

  if (!isTRUE(res$status == 0L)) {
    .sftp_abort_with_output(res, spec$cmd)
  }
  list(stdout = res$stdout %||% "", status = res$status)
}

# Esegue uno `spec` (output di .sftp_runner). Usa processx::process$new()
# perche' richiede di scrivere la password su stdin del processo (per la
# variante expect): processx::run() non espone l'API di stdin pipe.
# Restituisce list(stdout, stderr, status).
.sftp_invoke <- function(spec, timeout = 1800) {
  stdin_arg <- if (!is.null(spec$password)) "|" else NULL
  proc <- processx::process$new(
    command = spec$cmd,
    args = spec$args,
    stdin = stdin_arg,
    stdout = "|",
    stderr = "|",
    env = spec$env,
    cleanup = TRUE
  )
  on.exit(
    {
      if (proc$is_alive()) try(proc$kill(), silent = TRUE)
    },
    add = TRUE
  )

  if (!is.null(spec$password)) {
    # Scrive una sola riga su stdin (l'helper expect fa `gets stdin`)
    # poi chiude la connessione cosi' il processo non resta in attesa.
    try(
      proc$write_input(paste0(spec$password, "\n")),
      silent = TRUE
    )
    try(close(proc$get_input_connection()), silent = TRUE)
  }

  finished <- proc$wait(timeout = timeout * 1000)
  if (!finished) {
    try(proc$kill_tree(), silent = TRUE)
    cli::cli_abort(
      "Timeout ({timeout}s) in attesa di {.code {spec$cmd}}."
    )
  }
  list(
    stdout = proc$read_all_output(),
    stderr = proc$read_all_error(),
    status = proc$get_exit_status()
  )
}

# Solleva un cli_abort con stdout+stderr troncati a ~50 righe per non
# travolgere il chiamante con il rumore del client OpenSSH.
.sftp_abort_with_output <- function(res, cmd) {
  trunc <- function(x, n = 50L) {
    if (is.null(x) || !nzchar(x)) {
      return(character())
    }
    lines <- strsplit(x, "\r?\n", perl = TRUE)[[1]]
    if (length(lines) > n) {
      c(
        utils::head(lines, n),
        sprintf("... (%d righe omesse)", length(lines) - n)
      )
    } else {
      lines
    }
  }
  out <- trunc(res$stdout)
  err <- trunc(res$stderr)
  body <- character()
  if (length(err)) {
    body <- c(body, "stderr:", err)
  }
  if (length(out)) {
    body <- c(body, "stdout:", out)
  }
  cli::cli_abort(c(
    "Client {.code {cmd}} fallito (exit {res$status}).",
    body
  ))
}

# Parser di una riga `ls -l` Unix-style (output che il client SFTP
# restituisce per le directory). Esempio:
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
  remote_dir <- config$remote_dir %||% ""
  batch <- if (nzchar(remote_dir)) {
    c(sprintf("cd %s", remote_dir), "ls -l")
  } else {
    "ls -l"
  }
  res <- .sftp_run(config, batch)
  files <- .parse_listing(res$stdout)
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
  part <- paste0(local_path, ".part")
  # Niente resume: il pacchetto non lo promette e un `.part` parziale
  # corromperebbe la skip-by-size in oja_sync().
  if (file.exists(part)) {
    unlink(part)
  }

  remote_dir <- config$remote_dir %||% ""
  batch <- character()
  if (nzchar(remote_dir)) {
    batch <- c(batch, sprintf("cd %s", remote_dir))
  }
  # `get` in OpenSSH sftp accetta path locale come secondo argomento.
  batch <- c(batch, sprintf("get %s %s", remote_name, part))

  .sftp_run(config, batch)

  if (!file.exists(part)) {
    cli::cli_abort(
      "Download SFTP non ha prodotto {.path {part}}: server o batch errato."
    )
  }
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
    # Fix 2: guardia esplicita su "snapshot_id" %in% names(summary) come
    # belt-and-suspenders contro future regressioni nella forma di ritorno di
    # oja_ingest_dirs(). Fix 1 garantisce gia' che snapshot_id sia sempre
    # presente, ma il check rende il codice robusto a modifiche future.
    if (nrow(summary) > 0 && "snapshot_id" %in% names(summary)) {
      m <- match(
        unname(vapply(rows, `[[`, character(1), "snapshot_id")),
        summary$snapshot_id
      )
      for (i in seq_along(rows)) {
        if (!is.na(m[i])) {
          rows[[i]]$ingested <- TRUE
          if ("n_postings" %in% names(summary)) {
            rows[[i]]$n_postings <- summary$n_postings[m[i]]
          }
          if ("n_skills" %in% names(summary)) {
            rows[[i]]$n_skills <- summary$n_skills[m[i]]
          }
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
