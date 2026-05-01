# itaposts (in sviluppo)

Modifiche destinate alla prossima versione minore (0.2.0). Aggiungere qui
le nuove funzionalità, le correzioni e le rotture di API mano a mano che
vengono implementate.

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
