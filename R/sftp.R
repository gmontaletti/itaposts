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
#' Legge le credenziali e i percorsi remoti degli snapshot OJA dalle
#' variabili `ITAPOSTS_SFTP_*`. Le variabili `HOST`, `USER`, `PASSWORD` e
#' `REMOTE_DIR` sono obbligatorie; `PORT` ha default `22`, `LOCAL_DIR`
#' default `file.path(tempdir(), "itaposts_incoming")` e `DIM_DIR` default
#' `"/data_v2/dim_table"`.
#'
#' `REMOTE_DIR` punta alla directory degli archivi mensili di una singola
#' regione (`fact_table/<NUTS2>`), mentre `DIM_DIR` punta alle tabelle
#' dimensionali globali, che non sono suddivise per regione e vivono in una
#' directory sorella.
#'
#' Convenzione `.Renviron`:
#'
#' ```
#' ITAPOSTS_SFTP_HOST=sftp.lightcast.example
#' ITAPOSTS_SFTP_PORT=22
#' ITAPOSTS_SFTP_USER=...
#' ITAPOSTS_SFTP_PASSWORD=...
#' ITAPOSTS_SFTP_REMOTE_DIR=/data_v2/fact_table/ITC4
#' ITAPOSTS_SFTP_DIM_DIR=/data_v2/dim_table
#' ITAPOSTS_SFTP_LOCAL_DIR=~/Documents/funzioni/itaposts/incoming
#' ```
#'
#' Il backend SFTP del pacchetto si appoggia al client OpenSSH `sftp`
#' invocato via [processx::process] (libcurl su macOS CRAN non è compilato
#' con il backend libssh, quindi non parla SFTP). Il client OpenSSH è
#' presente di default su macOS e su pressoché tutte le distribuzioni
#' Linux: nessun pacchetto aggiuntivo da installare.
#'
#' Le due modalità di autenticazione usano due modalità di invocazione
#' diverse del client:
#'
#' - **chiave privata**: `sftp -b <batchfile>` con `BatchMode=yes`, non
#'   interattivo. La passphrase va caricata a parte in `ssh-agent`.
#' - **password**: sessione interattiva su pseudo-terminale
#'   ([processx::process] con `pty = TRUE`), perché `sftp -b` implica
#'   `BatchMode=yes` lato SSH e con quella direttiva OpenSSH rifiuta di
#'   chiedere la password. I comandi vengono inviati uno per volta sul pty
#'   attendendo il prompt `sftp>`. La password non compare mai sull'argv,
#'   nell'ambiente o su disco. Modalità non disponibile su Windows, dove
#'   `processx` non espone i pty.
#'
#' La fiducia sulla chiave host SSH si configura tramite
#' `ITAPOSTS_SFTP_KNOWN_HOSTS` (percorso a un file `known_hosts`): viene
#' propagato a `sftp` come `-o UserKnownHostsFile=...` con
#' `StrictHostKeyChecking=yes`. Senza questa variabile vale il default di
#' OpenSSH moderno (`accept-new`), che memorizza la chiave la prima volta.
#' Le variabili `ITAPOSTS_SFTP_HOST_FINGERPRINT_MD5` e
#' `ITAPOSTS_SFTP_HOST_FINGERPRINT_SHA256` sono mantenute per retro-
#' compatibilità del contratto di `oja_sftp_config()` ma non vengono
#' più usate (il vecchio backend libcurl le rispettava): per pinnare
#' l'host key con il backend OpenSSH usare `ITAPOSTS_SFTP_KNOWN_HOSTS`.
#'
#' Autenticazione SSH: per public-key impostare
#' `ITAPOSTS_SFTP_PRIVATE_KEY` (path al file privato; opzionali
#' `ITAPOSTS_SFTP_PUBLIC_KEY`, `ITAPOSTS_SFTP_PRIVATE_KEY_PASSPHRASE`).
#' La maschera di bit
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
#'   `dim_dir`, `local_dir`, `known_hosts`, `host_fingerprint_md5`,
#'   `host_fingerprint_sha256`, `private_key`, `public_key`,
#'   `private_key_passphrase`, `auth_types`. I due campi
#'   `host_fingerprint_*` sono informativi: il backend OpenSSH usa
#'   `known_hosts` ed eventualmente `PreferredAuthentications` derivato da
#'   `auth_types`.
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

  # Le tabelle dimensionali sono globali (non region-scoped) e stanno in una
  # directory sorella di `remote_dir`: default valido per tutte le regioni.
  dim_dir <- .strip_outer_quotes(env("ITAPOSTS_SFTP_DIM_DIR", unset = ""))
  if (!nzchar(dim_dir)) {
    dim_dir <- "/data_v2/dim_table"
  }
  dim_dir <- sub("/+$", "", dim_dir)

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
    dim_dir = dim_dir,
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
# del client OpenSSH. Restituisce un vettore di carattere.
#
# `batchfile = NULL` produce l'argv della sessione interattiva su pty: `-b`
# implica `BatchMode=yes` lato SSH, che disabilita il prompt della password.
#
# La forma finale e' `<flag>... <user>@<host>` (no `sftp://` URL: legacy
# quoting issues quando lo username contiene `@`).
.sftp_argv <- function(config, batchfile = NULL) {
  port <- as.integer(config$port %||% 22L)
  argv <- "-q"
  if (!is.null(batchfile)) {
    argv <- c(argv, "-b", batchfile)
  }
  argv <- c(
    argv,
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
  } else {
    # Su pty il default upstream `ask` bloccherebbe la sessione su una
    # domanda yes/no al primo contatto con l'host.
    argv <- c(argv, "-o", "StrictHostKeyChecking=accept-new")
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

# L'auth a password richiede la sessione interattiva su pty: `sftp -b`
# implica `BatchMode=yes` lato SSH e con quella direttiva OpenSSH non chiede
# la password, fallendo subito con "Permission denied".
.sftp_use_pty <- function(config) {
  !isTRUE(nzchar(config$private_key %||% "")) &&
    isTRUE(nzchar(config$password %||% ""))
}

# Costruisce lo `spec` da eseguire: `list(cmd, args, password, env, mode)`.
# `mode` discrimina fra invocazione batch (chiave o auth delegata a ssh) e
# sessione interattiva su pty (auth a password).
.sftp_runner <- function(config, batchfile = NULL) {
  argv <- .sftp_argv(config, batchfile)

  if (.sftp_use_pty(config)) {
    return(list(
      cmd = "sftp",
      args = argv,
      password = config$password,
      # TERM=dumb riduce le sequenze di escape che libedit emette sul pty.
      env = c("current", TERM = "dumb"),
      mode = "pty"
    ))
  }

  list(
    cmd = "sftp",
    args = argv,
    password = NULL,
    env = NULL,
    mode = "batch"
  )
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

  if (.sftp_use_pty(config)) {
    spec <- runner(config, NULL)
  } else {
    batchfile <- tempfile("itaposts_sftp_", fileext = ".batch")
    on.exit(try(unlink(batchfile), silent = TRUE), add = TRUE)
    writeLines(batch_lines, batchfile)
    Sys.chmod(batchfile, "0600")
    spec <- runner(config, batchfile)
  }

  res <- if (identical(spec$mode %||% "batch", "pty")) {
    .sftp_invoke_pty(spec, batch_lines, timeout = timeout)
  } else {
    .sftp_invoke(spec, timeout = timeout)
  }

  if (!isTRUE(res$status == 0L)) {
    .sftp_abort_with_output(res, spec$cmd)
  }
  list(stdout = res$stdout %||% "", status = res$status)
}

# Esegue uno `spec` in modalita' batch (`sftp -b`), senza terminale.
# Restituisce list(stdout, stderr, status).
.sftp_invoke <- function(spec, timeout = 1800) {
  proc <- processx::process$new(
    command = spec$cmd,
    args = spec$args,
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

  # `$wait()` restituisce il processo, non un flag di completamento: il
  # timeout si rileva verificando se il processo e' ancora vivo dopo l'attesa.
  proc$wait(timeout = timeout * 1000)
  if (proc$is_alive()) {
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

# Tronca un blocco di output a `n` righe e neutralizza le graffe: il
# risultato finisce nel corpo di un cli_abort(), dove ogni elemento viene
# interpolato da glue.
.sftp_trunc_lines <- function(x, n = 50L) {
  if (is.null(x) || !length(x) || !nzchar(x)) {
    return(character())
  }
  lines <- strsplit(x, "\r?\n", perl = TRUE)[[1]]
  if (length(lines) > n) {
    lines <- c(
      utils::head(lines, n),
      sprintf("... (%d righe omesse)", length(lines) - n)
    )
  }
  gsub("}", "}}", gsub("{", "{{", lines, fixed = TRUE), fixed = TRUE)
}

# Solleva un cli_abort con stdout+stderr troncati a ~50 righe per non
# travolgere il chiamante con il rumore del client OpenSSH.
.sftp_abort_with_output <- function(res, cmd) {
  out <- .sftp_trunc_lines(res$stdout)
  err <- .sftp_trunc_lines(res$stderr)
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

# 3. Sessione interattiva su pty (auth a password) ---------------------------

# Prompt della password/passphrase e prompt interattivo del client. Ancorati
# a fine buffer: la riga "Warning: Permanently added ... to the list of known
# hosts." che precede il prompt al primo contatto termina con newline e non
# puo' quindi produrre un falso positivo.
.sftp_rx_password <- "[Pp]ass(word|phrase)[^:]*:\\s*$"
.sftp_rx_prompt <- "sftp>\\s*$"

# Marcatori d'errore di OpenSSH sftp. In modalita' interattiva un comando
# fallito non altera l'exit status (un `cd` su path inesistente stampa
# "stat remote: No such file or directory" e la sessione esce 0), quindi
# l'errore va riconosciuto dall'output del singolo comando.
.sftp_rx_error <- paste(
  "No such file or directory",
  "Permission denied",
  "not found",
  "Couldn't ",
  "Cannot download",
  "Invalid command",
  "Connection closed",
  "Connection reset",
  "Broken pipe",
  "Host key verification failed",
  sep = "|"
)

# Maschera la password in un testo destinato a un messaggio d'errore. Il pty
# non riecheggia la password (il client disabilita l'echo), ma un log che la
# contenesse sarebbe un incidente: la sostituzione e' incondizionata.
.sftp_redact <- function(x, password) {
  if (is.null(password) || !nzchar(password)) {
    return(x)
  }
  gsub(password, "<password>", x, fixed = TRUE)
}

# processx incanala stdout e stderr del processo sullo stesso pty; la lettura
# e' non bloccante e restituisce "" quando non c'e' nulla di pronto.
.sftp_pty_read <- function(proc) {
  out <- tryCatch(proc$read_output(), error = function(e) "")
  if (is.null(out) || !length(out)) "" else paste(out, collapse = "")
}

# Accumula l'output del pty finche' `pattern` non compare in coda al buffer.
# Restituisce il buffer completo; aborta su timeout o su morte prematura del
# client (auth fallita, host key rifiutata, connessione caduta).
.sftp_pty_wait <- function(proc, pattern, timeout, what, password = NULL) {
  buffer <- ""
  deadline <- Sys.time() + timeout
  repeat {
    buffer <- paste0(buffer, .sftp_pty_read(proc))
    if (grepl(pattern, buffer, perl = TRUE)) {
      return(buffer)
    }
    if (!proc$is_alive()) {
      # Ultima lettura: l'output bufferato sopravvive all'uscita del processo.
      buffer <- paste0(buffer, .sftp_pty_read(proc))
      if (grepl(pattern, buffer, perl = TRUE)) {
        return(buffer)
      }
      cli::cli_abort(c(
        "Sessione {.code sftp} terminata (exit {proc$get_exit_status()}) prima di {what}.",
        .sftp_trunc_lines(.sftp_redact(buffer, password))
      ))
    }
    if (Sys.time() >= deadline) {
      try(proc$kill_tree(), silent = TRUE)
      cli::cli_abort(c(
        "Timeout ({timeout}s) in attesa di {what}.",
        .sftp_trunc_lines(.sftp_redact(buffer, password))
      ))
    }
    proc$poll_io(500)
  }
}

# Normalizza il testo letto fra due prompt: rimuove le sequenze di escape del
# terminale, i `\r` del pty, i prompt e l'eventuale eco del comando inviato,
# lasciando il solo output del comando (parsabile come in modalita' batch).
.sftp_pty_chunk <- function(text, command) {
  text <- gsub("\033\\[[0-9;?]*[a-zA-Z]", "", text, perl = TRUE)
  text <- gsub("\r", "", text, fixed = TRUE)
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  lines <- sub("sftp>\\s*$", "", sub("^sftp>\\s*", "", lines))
  lines <- lines[nzchar(trimws(lines))]
  if (length(lines) && identical(trimws(lines[[1]]), trimws(command))) {
    lines <- lines[-1]
  }
  if (!length(lines)) {
    return("")
  }
  paste0(paste(lines, collapse = "\n"), "\n")
}

# Verifica l'esito di un singolo comando: in modalita' interattiva l'unico
# segnale disponibile e' il testo emesso dal client.
.sftp_pty_check <- function(chunk, command) {
  if (!nzchar(chunk) || !grepl(.sftp_rx_error, chunk, perl = TRUE)) {
    return(invisible(NULL))
  }
  cli::cli_abort(c(
    "Comando {.code {command}} fallito nella sessione {.code sftp}.",
    .sftp_trunc_lines(chunk)
  ))
}

# Esegue `batch_lines` in una sessione `sftp` interattiva su pseudo-terminale:
# risponde al prompt della password, poi invia un comando per volta attendendo
# ogni volta il prompt successivo. Restituisce list(stdout, stderr, status)
# con la stessa forma di .sftp_invoke().
.sftp_invoke_pty <- function(spec, batch_lines, timeout = 1800) {
  if (.Platform$OS.type == "windows") {
    cli::cli_abort(c(
      "Auth SFTP a password non supportata su Windows.",
      "i" = "{.pkg processx} non espone pty su Windows: usare l'auth a chiave ({.envvar ITAPOSTS_SFTP_PRIVATE_KEY})."
    ))
  }
  password <- spec$password
  proc <- processx::process$new(
    command = spec$cmd,
    args = spec$args,
    pty = TRUE,
    env = spec$env,
    cleanup = TRUE
  )
  on.exit(
    {
      if (proc$is_alive()) try(proc$kill_tree(), silent = TRUE)
    },
    add = TRUE
  )

  deadline <- Sys.time() + timeout
  remaining <- function() {
    max(1, as.numeric(difftime(deadline, Sys.time(), units = "secs")))
  }

  # L'handshake ha un budget proprio: se l'host non risponde non serve
  # consumare il timeout complessivo, pensato per il download degli archivi.
  # Si attende il prompt della password *o* quello dei comandi: con una chiave
  # in ssh-agent l'auth puo' concludersi senza chiedere nulla.
  seen <- .sftp_pty_wait(
    proc,
    sprintf("(%s)|(%s)", .sftp_rx_password, .sftp_rx_prompt),
    min(remaining(), 120),
    "il prompt della password o il prompt `sftp>`",
    password
  )
  if (grepl(.sftp_rx_password, seen, perl = TRUE)) {
    proc$write_input(paste0(password, "\r"))
    .sftp_pty_wait(
      proc,
      .sftp_rx_prompt,
      min(remaining(), 120),
      "il prompt `sftp>` dopo l'autenticazione",
      password
    )
  }

  out <- character(length(batch_lines))
  for (i in seq_along(batch_lines)) {
    cmd <- batch_lines[[i]]
    # Se la sessione e' caduta la scrittura sul pty falla: l'attesa
    # successiva produce il messaggio d'errore con l'output raccolto.
    try(proc$write_input(paste0(cmd, "\r")), silent = TRUE)
    raw_chunk <- .sftp_pty_wait(
      proc,
      .sftp_rx_prompt,
      remaining(),
      sprintf("l'output del comando `%s`", cmd),
      password
    )
    chunk <- .sftp_pty_chunk(raw_chunk, cmd)
    .sftp_pty_check(chunk, cmd)
    out[[i]] <- chunk
  }

  stdout <- paste0(out, collapse = "")
  try(proc$write_input("quit\r"), silent = TRUE)
  proc$wait(timeout = 10000)
  if (proc$is_alive()) {
    # I comandi sono gia' stati eseguiti e validati: una chiusura pigra non
    # e' un fallimento da propagare al chiamante.
    try(proc$kill_tree(), silent = TRUE)
    return(list(stdout = stdout, stderr = "", status = 0L))
  }
  list(stdout = stdout, stderr = "", status = proc$get_exit_status())
}

# 4. Listing remoto ----------------------------------------------------------

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

# 5. Download di un singolo file --------------------------------------------

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

# 6. Tabelle dimensionali globali -------------------------------------------

# I tre file dimensionali serviti da `dim_dir`: CSV non zippati, non
# region-scoped, ~12 MB complessivi.
.oja_dim_files <- c(
  "dim_esco_skills.csv",
  "dim_occ_cp2021.csv",
  "dim_occ_esco.csv"
)

# Sottodirectory locale in cui atterrano i file dimensionali. Tenerli fuori da
# `local_dir` evita di mischiarli agli archivi mensili ed e' il path che
# oja_sync() passa a oja_ingest_dirs() come `dim_dir`.
.oja_dim_local_dir <- function(config) {
  file.path(config$local_dir, "dim_table")
}

# Scarica i tre file dimensionali. Non essendo versionati per snapshot
# vengono riscaricati a ogni sync, senza lo skip-by-size applicato agli
# archivi mensili: il costo (~12 MB) e' inferiore al rischio di lavorare su
# dimensioni obsolete.
.oja_download_dim_tables <- function(config, downloader = oja_sftp_download) {
  dim_local <- .oja_dim_local_dir(config)
  if (!dir.exists(dim_local)) {
    dir.create(dim_local, recursive = TRUE, showWarnings = FALSE)
  }
  # `oja_sftp_download()` fa `cd config$remote_dir`: le dimensioni vivono in
  # `dim_dir`, directory sorella degli archivi regionali.
  dim_config <- config
  dim_config$remote_dir <- config$dim_dir %||% ""
  for (nm in .oja_dim_files) {
    cli::cli_inform("Download tabella dimensionale {.path {nm}}...")
    downloader(nm, file.path(dim_local, nm), dim_config)
  }
  invisible(dim_local)
}

# Snapshot già presenti in dim_snapshot. Con `con = NULL` apre in sola
# lettura il database di `path`; un file DuckDB inesistente o un database
# senza schema OJA non hanno snapshot.
.oja_ingested_snapshots <- function(con = NULL, path = oja_db_path()) {
  if (is.null(con)) {
    if (!.is_ducklake_path(path) && !file.exists(path)) {
      return(character())
    }
    con <- oja_connect(path = path)
    on.exit(oja_disconnect(con), add = TRUE)
  }
  if (!.oja_table_exists(con, "dim_snapshot")) {
    return(character())
  }
  oja_snapshots(con)$snapshot_id
}

# 7. Sincronizzazione end-to-end --------------------------------------------

#' Sincronizza gli snapshot OJA dal server SFTP e li ingerisce
#'
#' Scarica nella cartella locale tutti gli snapshot remoti non ancora
#' presenti (o solo quelli indicati in `snapshots`) e li ingerisce nel DB
#' DuckDB chiamando [oja_ingest_dirs()]. La funzione è idempotente: file
#' locali con stessa dimensione del remoto vengono saltati, snapshot già
#' presenti in `dim_snapshot` non vengono reingeriti a meno di
#' `overwrite = TRUE`.
#'
#' Prima degli archivi mensili vengono scaricate le tre tabelle dimensionali
#' globali (`dim_esco_skills.csv`, `dim_occ_cp2021.csv`,
#' `dim_occ_esco.csv`) da `config$dim_dir` nella sottodirectory
#' `dim_table/` di `config$local_dir`, che viene poi passata a
#' [oja_ingest_dirs()] come `dim_dir`. Non essendo versionate per snapshot
#' vengono riscaricate a ogni sync, indipendentemente dal fatto che ci siano
#' snapshot nuovi.
#'
#' @param region_code Codice NUTS-2 da scaricare. Default `"ITC4"`.
#' @param snapshots Vettore opzionale di `snapshot_id` da limitare.
#' @param ingest Logico. Se `FALSE` esegue solo il download.
#' @param overwrite Logico. Inoltrato a [oja_ingest_snapshot()].
#' @param config Output di [oja_sftp_config()].
#' @param path Percorso del file DuckDB o del catalogo DuckLake. Default
#'   [oja_db_path()]. Ignorato se `con` non è `NULL`.
#' @param lister,downloader Funzioni iniettabili (per i test).
#' @param con Connessione in scrittura, opzionale, inoltrata a
#'   [oja_ingest_dirs()]: permette di scrivere in un database già aperto dal
#'   chiamante, per esempio lo schema `oja` di un lago DuckLake. È usata
#'   anche per leggere gli snapshot già presenti e non viene chiusa.
#'
#' @return Invisibilmente un `data.frame` con `snapshot_id`, `downloaded`,
#'   `ingested`, `n_postings`, `n_skills`.
#' @export
#' @examples
#' \dontrun{
#'   readRenviron("~/.Renviron")
#'   oja_sync()
#'
#'   # Scrittura nello schema oja di un lago DuckLake
#'   con <- oja_connect("ducklake:sqlite:/percorso/lake.sqlite", read_only = FALSE)
#'   oja_sync(con = con)
#'   oja_disconnect(con)
#' }
oja_sync <- function(
  region_code = "ITC4",
  snapshots = NULL,
  ingest = TRUE,
  overwrite = FALSE,
  config = oja_sftp_config(),
  path = oja_db_path(),
  lister = oja_remote_list,
  downloader = oja_sftp_download,
  con = NULL
) {
  if (!dir.exists(config$local_dir)) {
    dir.create(config$local_dir, recursive = TRUE, showWarnings = FALSE)
  }

  dim_local <- .oja_download_dim_tables(config, downloader = downloader)

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

  # Snapshot già nel DB: servono solo per decidere se ingerire.
  already <- if (ingest) {
    .oja_ingested_snapshots(con = con, path = path)
  } else {
    character()
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
    if (is.null(con)) {
      cli::cli_inform(
        "Ingest di {length(to_ingest)} snapshot in {.path {path}}..."
      )
    } else {
      cli::cli_inform(
        "Ingest di {length(to_ingest)} snapshot nella connessione fornita..."
      )
    }
    summary <- oja_ingest_dirs(
      zip_dir = config$local_dir,
      snapshots = to_ingest,
      overwrite = overwrite,
      dim_dir = dim_local,
      path = path,
      con = con
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
