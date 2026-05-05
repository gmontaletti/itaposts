# itaposts (in sviluppo)

Modifiche destinate alla prossima versione minore (0.2.0). Aggiungere qui
le nuove funzionalità, le correzioni e le rotture di API mano a mano che
vengono implementate.

## Backend SFTP riscritto su OpenSSH

* Il client SFTP non si appoggia più a `libcurl`: la versione di
  `libcurl` distribuita con i binari CRAN di `curl` su macOS (e su molte
  distribuzioni Linux) è compilata senza il backend `libssh`/`libssh2`,
  quindi non parla SFTP. Il sintomo era `Invalid or unsupported value`
  su `ssh_auth_types` e, a valle, `oja_sync()` non funzionante. Il
  pacchetto ora invoca il client OpenSSH `sftp` via `processx::run()`
  (in realtà via `processx::process$new()` per poter scrivere la
  password su `stdin` quando serve). `sftp` è installato di default su
  macOS e su pressoché tutte le distribuzioni Linux, senza dipendenze
  native aggiuntive.
* `curl` rimosso dagli `Imports`. Aggiunto `processx`.
* `ITAPOSTS_SFTP_HOST_FINGERPRINT_MD5` e
  `ITAPOSTS_SFTP_HOST_FINGERPRINT_SHA256` sono ora informativi: il
  backend OpenSSH non li legge. Per pinnare la chiave host SSH usare
  `ITAPOSTS_SFTP_KNOWN_HOSTS` (path a un file `known_hosts`), che viene
  passato a `sftp` come `-o UserKnownHostsFile=...` con
  `StrictHostKeyChecking=yes`. La presenza di una delle due variabili
  fingerprint produce un avviso una volta per sessione. I tre campi
  (insieme a `auth_types`) restano comunque nella lista restituita da
  `oja_sftp_config()` per non rompere `.Renviron` esistenti.
* La maschera `ITAPOSTS_SFTP_AUTH_TYPES` viene tradotta in
  `PreferredAuthentications` (1=`password`, 2=`publickey`,
  4=`hostbased`, 8=`keyboard-interactive`). Quando coincide col default
  9 (password+keyboard-interactive) non viene passata, lasciando agli
  algoritmi di default di OpenSSH la scelta.
* Auth a chiave (raccomandata in cron): impostare
  `ITAPOSTS_SFTP_PRIVATE_KEY` al path della chiave privata. Il client
  viene allora invocato con `BatchMode=yes` (errore immediato in caso
  di prompt password). Eventuali passphrase devono essere già caricate
  in `ssh-agent`: questo backend non le digita per non scriverle mai
  sull'argv.
* Auth a password: serve `expect` (preinstallato su macOS; su
  Debian/Ubuntu `apt install expect`) oppure `sshpass`. La password
  viene passata su `stdin` dell'helper expect o tramite la variabile
  `SSHPASS` (`sshpass -e`); mai sull'argv (per non comparire in `ps`).
  Senza alcuno dei due helper il pacchetto si interrompe con messaggio
  esplicito.

## Nuove funzionalita'

* `oja_sftp_config()` ora trimma whitespace e virgolette esterne da
  `ITAPOSTS_SFTP_USER` e `ITAPOSTS_SFTP_PASSWORD` (es. `PASSWORD="abc"`
  produceva un'autenticazione fallita perche' `readRenviron()` lascia le
  virgolette nella stringa).
* Il default di `ssh_auth_types` per il client SFTP passa da `1L`
  (password puro) a `1L | 8L = 9L` (password + keyboard-interactive).
  Molti server OpenSSH disabilitano `password` e annunciano solo
  `keyboard-interactive`: il vecchio default produceva `Login denied`
  anche con credenziali corrette. La maschera puo' essere forzata via
  `ITAPOSTS_SFTP_AUTH_TYPES` (1=password, 2=publickey, 4=hostbased,
  8=keyboard-interactive; sommabili).
* Aggiunto supporto a public-key authentication via
  `ITAPOSTS_SFTP_PRIVATE_KEY`, `ITAPOSTS_SFTP_PUBLIC_KEY`,
  `ITAPOSTS_SFTP_PRIVATE_KEY_PASSPHRASE`. Quando una chiave privata e'
  configurata, il bit `publickey` viene aggiunto in automatico alla
  maschera di default.
* `oja_sftp_config()` legge tre nuove variabili `.Renviron` per il pinning
  della chiave host SSH:
    * `ITAPOSTS_SFTP_KNOWN_HOSTS` — path a un file `known_hosts` dedicato.
    * `ITAPOSTS_SFTP_HOST_FINGERPRINT_MD5` — fingerprint MD5 (32 hex,
      con o senza `:`).
    * `ITAPOSTS_SFTP_HOST_FINGERPRINT_SHA256` — fingerprint SHA-256
      base64 (eventuale prefisso `SHA256:` viene scartato; richiede
      libcurl >= 7.80).
  Le tre variabili vengono propagate sul `curl::handle` SFTP, evitando
  il fallback a `~/.ssh/known_hosts` dell'utente che esegue il processo
  e quindi l'errore "SSL peer certificate or SSH remote key was not OK"
  visto sui run cron senza HOME popolato. Le opzioni sono opzionali e
  retro-compatibili: senza alcuna delle tre il comportamento e' invariato.

## Correzioni

* Bundle cron: `inst/cron/run_sync.sh` ora invoca `Rscript` con
  `--no-save --no-restore --no-init-file --no-site-file` invece di
  `--vanilla`. `--vanilla` implicava `--no-environ`, quindi `.Renviron` non
  veniva letto all'avvio di R e `R_LIBS_USER` non entrava in `.libPaths()`:
  il cron falliva con exit code 2 ("Pacchetto 'itaposts' non installato")
  anche quando il pacchetto era regolarmente installato nella libreria
  utente. Aggiunto inoltre in `sync_oja.R` un fallback difensivo che
  estende `.libPaths()` con `R_LIBS_USER` dopo `readRenviron()`, e un log
  diagnostico più verboso quando `requireNamespace("itaposts")` fallisce.
* `tools/install.sh.template` allineato a `dist/.../install.sh` (era
  rimasto indietro): risolve `R_LIBS_USER`, lo esporta, installa
  dipendenze e pacchetto in quella libreria, e ora pinna anche
  `R_LIBS_USER=…` in `cron/.Renviron` se la riga non esiste, così il run
  successivo del cron vede subito il pacchetto.

# itaposts 0.1.0

Versione iniziale.

## Nuove funzionalita'

* Inizializzazione e gestione di un database DuckDB centralizzato per i dati OJA
  (`oja_db_path()`, `oja_connect()`, `oja_init_db()`).
* Pipeline di ingestione di snapshot mensili da archivi zip Lightcast
  (`oja_ingest_snapshot()`, `oja_ingest_dirs()`) con dedup su `general_id`,
  costruzione delle dimensioni e validazione di integrita' referenziale dentro
  un'unica transazione.
* API di lettura lazy (`oja_postings()`, `oja_skills()`, `oja_snapshots()`)
  basata su `dbplyr`.
* Shim di compatibilita' (`oja_normalised()`) che riproduce la forma tabellare
  attesa da `skillviz::normalize_ojv()`.

## Sincronizzazione SFTP

* `oja_sync()`, `oja_remote_list()`, `oja_sftp_download()`,
  `oja_sftp_config()` — pipeline end-to-end di download dei snapshot
  mensili da server SFTP a partire da credenziali in `.Renviron`,
  seguita da ingest in DuckDB. Implementata su `curl` (libcurl
  parla SFTP nativamente, nessuna nuova dipendenza nativa).

## Documentazione

* Vignetta `struttura-dataset.Rmd` con dizionario completo delle colonne
  per ogni tabella, gerarchia delle dimensioni ed esempi di query
  ricorrenti.

## Schema

Star schema con due tabelle dei fatti (`fact_postings`, `fact_skills`), undici
dimensioni (geografia, contratto, istruzione, settore, esperienza, orario,
salario, CP2021, occupazione ESCO, source, skill ESCO) e una tabella di
metadata (`dim_snapshot`). Identificatori (`general_id`, `id*`) tipizzati
`VARCHAR` per accomodare codici alfanumerici Lightcast (es. `idmacro_sector =
'C'`, `idcategory_sector = 'D'`).

## Benchmark (snapshot ITC4_2026_2, 89.124 postings / 879.894 skills)

Parita' bit-exact con `skillviz::normalize_ojv()` su `general_id` (setdiff =
0 in entrambi i versi, conteggi identici).

| Operazione                                  | skillviz | itaposts | speedup |
|---------------------------------------------|---------:|---------:|--------:|
| Caricamento `normalize_ojv()` / `oja_normalised()` | 3.21 s | 1.14 s | 2.8× |
| Q2: count skills per `idesco_level_4`       |  0.284 s |  0.013 s | 22.6× |
| Q3: green-skill share per `idmacro_sector`  |  0.026 s |  0.011 s |  2.4× |

DuckDB sul disco: 67 MB (vs 117 MB di zip sorgenti).
