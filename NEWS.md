# itaposts 0.4.1

## Correzioni

* Le dimensioni globali del fornitore (`dim_cp2021`, `dim_esco_occupation`,
  `dim_esco_skill`) vengono riscritte solo se il contenuto dei CSV
  `dim_table` differisce da quello delle tabelle: il confronto usa
  `EXCEPT ALL` nei due sensi. Con dimensioni invariate
  `oja_ingest_snapshot()` e `oja_ingest_dirs()` non eseguono `DELETE` e
  `INSERT` su quelle tabelle, per cui un catalogo DuckLake non registra
  modifiche; il messaggio indica la dimensione come invariata.
* I messaggi di `oja_sync()` non riportano più l'host SFTP: il messaggio
  "Listing remoto" indica solo la cartella remota. Negli errori del client
  `sftp`, host, utente e password vengono mascherati nell'output riportato.

# itaposts 0.4.0

## Backend DuckLake

* `oja_db_path()` restituisce il valore della variabile d'ambiente
  `ITAPOSTS_DB`, se valorizzata: un file DuckDB oppure un catalogo DuckLake
  con prefisso `ducklake:`. Senza `ITAPOSTS_DB` il percorso resta
  `<SHARED_DATA_DIR>/oja/itposts.duckdb`.
* `oja_connect()` accetta un percorso `ducklake:` (es.
  `ducklake:sqlite:/percorso/lake.sqlite`): apre DuckDB in memoria, carica
  le estensioni `ducklake` e `sqlite`, collega il catalogo come `lake`
  (`READ_ONLY` con `read_only = TRUE`) e rende corrente lo schema
  `lake.oja`, modificabile con l'opzione `itaposts.schema`. Le query con
  nomi di tabella non qualificati, comprese quelle di `oja_postings()`,
  `oja_skills()`, `oja_skill_dim()`, `oja_snapshots()` e
  `oja_normalised()`, restano invariate. Il catalogo e lo schema devono
  esistere: un catalogo SQLite assente produce un errore senza creare file.
* `oja_disconnect()` scollega il catalogo DuckLake prima di chiudere la
  connessione.
* `oja_init_db()` crea le tabelle senza PRIMARY KEY quando il database
  corrente è un catalogo DuckLake, che non supporta vincoli di chiave. Su
  DuckDB il DDL è invariato.
* `oja_ingest_dirs()` e `oja_sync()` hanno il nuovo argomento `con`: con una
  connessione fornita dal chiamante, per esempio allo schema `oja` di un
  lago DuckLake, le funzioni non aprono né chiudono connessioni. Se la
  connessione ha già una transazione aperta, l'ingestione vi partecipa senza
  COMMIT né ROLLBACK e `oja_ingest_dirs()` propaga il primo errore invece di
  passare allo snapshot successivo.
* Su DuckLake, senza transazione esterna, i dati di ogni snapshot OJA
  ingerito vengono scritti con un solo commit; un DDL già applicato non crea
  snapshot del catalogo.

## Ingestione

* L'UPSERT delle dimensioni derivate dalle postings e l'inserimento in
  `fact_skills` non usano più `INSERT ... ON CONFLICT DO NOTHING`, che
  richiede una PRIMARY KEY, ma un anti-join con deduplica esplicita per
  chiave. A parità di chiave resta la prima riga in ordine di input, cioè
  quella del posting con `grab_date` più recente, come in precedenza: su
  DuckDB il contenuto delle tabelle non cambia.
* La validazione prima del COMMIT verifica unicità e assenza di valori nulli
  nelle chiavi di tutte le tabelle (fatti limitati allo snapshot ingerito,
  dimensioni e `dim_snapshot` per intero), oltre all'integrità referenziale
  skill → posting.
* Correzione: con `overwrite = TRUE` i DELETE dello snapshot esistente
  avvenivano prima dell'apertura della transazione, quindi un errore
  successivo lasciava il database senza lo snapshot. Rimozione e
  reinserimento stanno ora nella stessa transazione e un errore conserva lo
  snapshot precedente.
* La ricarica delle dimensioni globali eseguita da `oja_ingest_dirs()` prima
  del ciclo avviene in una transazione: un errore non lascia le dimensioni
  vuote.
* `oja_sync()` apre il database per leggere gli snapshot presenti solo con
  `ingest = TRUE`; un database esistente ma privo di `dim_snapshot` viene
  trattato come vuoto invece di produrre un errore.

# itaposts 0.3.0

## Migrazione a `data_v2` **BREAKING**

Il fornitore (Lightcast) ha sostituito la consegna SFTP flat/denormalizzata
(`/data_v1`) con uno schema a stella normalizzato (`/data_v2`): tre CSV
globali in `/data_v2/dim_table/` (`dim_esco_skills.csv`,
`dim_occ_cp2021.csv`, `dim_occ_esco.csv`, delimitatore `;`, non zippati) più
gli archivi mensili per regione in
`/data_v2/fact_table/<REGION>/<REGION>_<year>_<month>_{postings,postings_raw,skills}.zip`,
più stretti di prima: `postings.csv` porta solo `cp2021_id_level_5` e
`idesco_level_5` come chiavi esterne (le colonne gerarchiche/descrittive
inlineate sono sparite dalla sorgente, ricostruite a valle via join sulle
due dimensioni di occupazione); `skills.csv` porta solo `general_id,
year_grab_date, month_grab_date, IDESCOSKILL_LEVEL_3` (contro ~30 colonne
descrittive inlineate in precedenza); `postings_raw.csv` è invariato.

Schema DuckDB riadattato di conseguenza (`R/schema.R`, `R/ingest.R`):

* `dim_cp2021` e `dim_esco_occupation` diventano dimensioni **globali del
  fornitore**, alimentate dai due CSV `dim_occ_cp2021.csv`/`dim_occ_esco.csv`
  invece che estratte dalle postings. `dim_esco_occupation` si espande alla
  gerarchia completa 1–5 (`idesco_level_1..5`, `esco_level_1..5`); la
  colonna `uri` scompare (nessun sostituto nella sorgente).
* `dim_esco_skill` **sostituita integralmente**: PK rinominata
  `idescoskill_level_3` (rispecchia il nome della FK nei fatti), tutte le
  colonne descrittive rinominate da `esco_v0101_*` a `esco_v010200_*` (il
  fornitore ha aggiornato la propria tassonomia ESCO da v01.01 a v01.02.00).
* `dim_cp2021`, `dim_esco_occupation` e `dim_esco_skill` passano da UPSERT
  incrementale a **ricarica integrale** (`DELETE` + re-`INSERT` da
  `/data_v2/dim_table` a ogni ingest) perché sono vendor-authoritative e di
  dimensioni contenute (~12 MB complessivi): la staleness da `ON CONFLICT DO
  NOTHING` sarebbe peggiore del costo della ricarica. Le altre otto
  dimensioni (`dim_geography`, `dim_contract`, `dim_education`,
  `dim_sector`, `dim_experience`, `dim_working_hours`, `dim_salary`,
  `dim_source`) restano derivate dalle postings e accumulano per UPSERT
  incrementale come prima. DDL di `fact_postings`/`fact_skills` invariata.

**Nessun percorso di migrazione**: chi ha un DuckDB locale precedente a
questa versione deve cancellarlo e risincronizzare da zero — `oja_db_path()`
(default `~/Documents/funzioni/shared_data/oja/itposts.duckdb`, o
`$SHARED_DATA_DIR/oja/itposts.duckdb` se la variabile è impostata).

Validato con una risincronizzazione completa contro il server vendor reale,
regione ITC4, 42 snapshot mensili (`ITC4_2023_1`..`ITC4_2026_6`):
3.332.448 postings e 31.143.630 righe di skill complessive, file DuckDB
2,1 GB su disco. Sostituisce integralmente lo stato precedente (snapshot
singolo `ITC4_2026_2`, 89mila postings / 880mila skill, DB 67 MB).

Validazione aggiuntiva su un'estrazione provinciale reale (Monza e della
Brianza, `idprovince = 'ITC4D'`, gennaio 2024 – giugno 2026, 156.321
annunci): confrontando l'estrazione con l'equivalente prodotta dal vecchio
schema `data_v1` si è verificato che le righe duplicate per `general_id`
presenti nell'estrazione storica (24.414 gruppi su 85.471 annunci distinti)
non derivavano mai da codici CP2021 o ESCO multipli sullo stesso annuncio,
ma da ri-acquisizioni non deduplicate (99,3% dei casi, righe identiche) e
da un singolo codice ESCO (`3323.2`) con etichetta incoerente nel vecchio
feed del fornitore (0,7% dei casi). La deduplica per
`(snapshot_id, general_id)` di `fact_postings` (invariata dalla 0.1.0) non
comporta quindi perdita di informazione di classificazione.

## Aggiornamento tassonomia ESCO del fornitore (v01.01 → v01.02.00)

Conseguenza diretta della migrazione a `data_v2`: la dimensione globale
`dim_esco_skills.csv` non porta più `onet_hier_level_1/2/3`,
`pillar_softskills`, `pillar_digitalskills`, `pillar_bigdata`,
`esco_v0101_ict` — colonne genuinamente non più disponibili dal
fornitore, non omesse per scelta implementativa. Compaiono due nuovi
flag: `esco_v010200_digital`, `esco_v010200_research`.

Lo shim `oja_normalised()` (`R/shim.R`) riflette la perdita: la tabella
`skills` restituita mantiene `IDESCOSKILL_LEVEL_3`, `ESCOSKILL_LEVEL_3`,
`ESCO_V0101_OBSOLETE`, `ESCO_v0101_DESCRIPTION`, `ESCO_V0101_URI`,
`ESCO_V0101_SKILLSTYPE`, `ESCO_V0101_REUSETYPE`, `ESCO_V0101_GREEN`,
`ESCO_V0101_LANGUAGE`; non restituisce più (senza riempimento a `NA`,
omissione pulita) `PILLAR_SOFTSKILLS`, `PILLAR_DIGITALSKILLS`,
`PILLAR_BIGDATA`, `ONET_HIER_LEVEL_1/2/3`, `ESCO_V0101_ICT`,
`ESCO_V0101_DIGCOMP`, `ESCO_V0101_TRANSVERSAL`,
`ESCO_V0101_HIER_CODE/URI/LABEL_0..3`.

Impatto verificato direttamente sul codice sorgente di `skillviz` e
`skillviz_workflow`: l'unico punto di chiamata realmente in uso da
`skillviz` verso `itaposts` (`match_professions_*()`) non tocca nessuna
delle colonne rimosse — nessuna rottura oggi. Il pannello per tipo di
competenza di `skillviz_workflow`, che usa `PILLAR_SOFTSKILLS` /
`ESCO_V0101_ICT`, legge da una pipeline Postgres separata e non da
`itaposts` — non impattato, ma quella capacità non potrà più essere
migrata su `itaposts` a meno che il fornitore non reintroduca quei campi.

## Backend SFTP: correzioni e nuova variabile `ITAPOSTS_SFTP_DIM_DIR`

Tre difetti corretti in `R/sftp.R`:

* `sftp -b` in modalità batch forzava `BatchMode=yes` lato SSH, che
  blocca silenziosamente l'auth a password (OpenSSH non chiede mai la
  password con quella direttiva attiva).
* uso scorretto del valore di ritorno di `processx::process$wait()`
  (restituisce il processo, non un flag di completamento).
* doppio `wait` nell'helper `inst/sftp_password.expect` (ora rimosso).

L'auth a password usa ora una sessione interattiva su pseudo-terminale
(`processx::process$new(pty = TRUE, ...)`) al posto dell'helper a
expect-script eliminato: nessuna dipendenza runtime da `expect`/`sshpass`.
L'auth a chiave resta non interattiva (`sftp -b`).

Nuova variabile d'ambiente `ITAPOSTS_SFTP_DIM_DIR` (default
`/data_v2/dim_table`), affiancata alla già esistente
`ITAPOSTS_SFTP_REMOTE_DIR` (che ora punta alla directory degli archivi
mensili di una singola regione, es. `/data_v2/fact_table/ITC4` — nessun
default cablato, resta obbligatoria). `oja_sync()` riscarica sempre i tre
file `dim_table` a ogni sincronizzazione (nessuno skip-by-size, a
differenza degli archivi mensili per snapshot).

# itaposts 0.2.0

## Backend SFTP

Completata la migrazione del backend SFTP a OpenSSH `sftp` invocato via `processx`, iniziata in `816daab`. Rimossa ogni traccia del backend libcurl/libssh. La configurazione vive in env vars `ITAPOSTS_SFTP_{HOST,PORT,USER,PASSWORD,REMOTE_DIR,LOCAL_DIR}`. L'auth a chiave SSH non è supportata contro `custom-delivery.lightcast.io` perché Lightcast non registra chiavi pubbliche lato server: l'unica modalità praticabile è l'auth a password con `sshpass` come helper.

## Deployment containerizzato

Nuovo `Dockerfile` su `rocker/r2u:noble` che impacchetta il pacchetto, le 8 dipendenze CRAN dirette (binari apt via bspm, niente compilazione) e il client OpenSSH `sftp` + `sshpass`. Lo script host `docker/itaposts-sync.sh` invoca `docker run --rm` con `--name itaposts-sync` per la collision-lock e `--user $(id -u):$(id -g)` per le perms sui bind mount (`/var/itaposts/{shared,incoming,run}`). I segreti arrivano via `--env-file`, mai sull'argv. CI GitHub Actions (`.github/workflows/docker.yml`) builda e pubblica su `ghcr.io/gmontaletti/itaposts:VERSION` ai tag `v*`. Documentazione operativa in `docker/README.md`. **BREAKING per ops** (la procedura di install cambia integralmente); la API R non cambia.

## Bug fix oja_sync()

Risolto il fallimento `oja_sync() fallita: invalid argument type` che si manifestava quando tutti gli snapshot remoti erano già presenti in `dim_snapshot`. Causa: `oja_ingest_dirs()` poteva ritornare un `data.frame` con colonne implicite o assenti, su cui `match()` lanciava `invalid argument type`. Fix in `R/ingest.R` (tutti i return path passano da `.empty_summary()` con colonne tipate) e in `R/sftp.R` (guardia `"snapshot_id" %in% names(summary)`). Test di regressione in `tests/testthat/test-sync-empty.R`.

## File rimossi

`tools/build_transfer_zip.sh`, `tools/install.sh.template`, `tools/vendor-cache/`, `INSTALLAZIONE.md`, `inst/cron/run_sync.sh`, `inst/cron/.Renviron.template`, `inst/cron/crontab.example`, `inst/cron/README.md`. Sostituiti dal Dockerfile + `docker/`.

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
