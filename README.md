# itaposts

<!-- badges: start -->
<!-- badges: end -->

Importazione e normalizzazione di OJA (Online Job Advertisements) italiani
Lightcast in un database DuckDB condiviso, con una API di lettura `dplyr`
e uno shim di compatibilità verso `skillviz::normalize_ojv()`.

Il pacchetto centralizza la logica di lettura, deduplica e join consumata a
valle da [`skillviz`](https://github.com/gmontaletti/skillviz) e
`skillviz_workflow`, evitando che le pipeline downstream re-implementino il
caricamento da archivi zip mensili.

## Installazione

Versione di sviluppo da GitHub:

``` r
# install.packages("remotes")
remotes::install_github("gmontaletti/itaposts")
```

## Uso

### Inizializzazione del database

Il database è risolto da `oja_db_path()`: se la variabile d'ambiente
`ITAPOSTS_DB` è valorizzata ne usa il valore (file DuckDB oppure catalogo
DuckLake con prefisso `ducklake:`), altrimenti il file
`Sys.getenv("SHARED_DATA_DIR", "~/Documents/funzioni/shared_data")` +
`/oja/itposts.duckdb`. La prima inizializzazione crea lo schema:

``` r
itaposts::oja_init_db()
```

### Ingestione di uno snapshot

L'ingestione è single-snapshot, idempotente e transazionale. La snapshot
viene identificata dal tag `<NUTS2>_<anno>_<mese>` (es. `ITC4_2026_2`):

``` r
itaposts::oja_ingest_snapshot(
  zip_dir     = "~/Documents/funzioni/itaposts",
  snapshot_id = "ITC4_2026_2"
)
```

Per ingestare in batch tutte le snapshot disponibili in una directory:

``` r
itaposts::oja_ingest_dirs("~/Documents/funzioni/itaposts")
```

### Lettura

Le funzioni di lettura restituiscono `dbplyr` lazy table; materializzare
con `dplyr::collect()`:

``` r
con <- itaposts::oja_connect()
on.exit(itaposts::oja_disconnect(con), add = TRUE)

itaposts::oja_postings(con) |>
  dplyr::filter(snapshot_id == "ITC4_2026_2") |>
  dplyr::count(idmacro_sector) |>
  dplyr::collect()
```

### Backend DuckLake

`oja_connect()` accetta anche un catalogo DuckLake. Con un percorso
`ducklake:` apre DuckDB in memoria, collega il catalogo come `lake` e rende
corrente lo schema `lake.oja` (nome modificabile con l'opzione
`itaposts.schema`): le query con nomi di tabella non qualificati restano
invariate.

``` r
Sys.setenv(
  ITAPOSTS_DB = "ducklake:sqlite:~/Documents/funzioni/datalake/catalog/lake.sqlite"
)
con <- itaposts::oja_connect()
itaposts::oja_snapshots(con)
itaposts::oja_disconnect(con)
```

Il catalogo e lo schema devono esistere e le estensioni DuckDB `ducklake` e
`sqlite` devono essere installate. Su DuckLake le tabelle non hanno PRIMARY
KEY: l'ingestione deduplica per chiave e verifica l'unicità delle chiavi
prima del COMMIT. `oja_ingest_dirs()` e `oja_sync()` accettano una
connessione esterna (`con`), che resta aperta al termine.

### Compatibilità con skillviz

Lo shim `oja_normalised()` riproduce la forma tabellare attesa da
`skillviz::normalize_ojv()` (`list(postings, skills, companies)`) ed è
pensato per la migrazione progressiva delle call site a valle.

### Sincronizzazione SFTP

`oja_sync()` legge le credenziali da `.Renviron` (`ITAPOSTS_SFTP_HOST`,
`ITAPOSTS_SFTP_PORT`, `ITAPOSTS_SFTP_USER`, `ITAPOSTS_SFTP_PASSWORD`,
`ITAPOSTS_SFTP_REMOTE_DIR`, `ITAPOSTS_SFTP_DIM_DIR`,
`ITAPOSTS_SFTP_LOCAL_DIR`), scarica solo le snapshot mancanti e ingerisce in
DuckDB:

``` r
itaposts::oja_sync()
```

`ITAPOSTS_SFTP_REMOTE_DIR` punta alla directory degli archivi mensili di una
regione (es. `/data_v2/fact_table/ITC4`); `ITAPOSTS_SFTP_DIM_DIR` alle tre
tabelle dimensionali globali (default `/data_v2/dim_table`), riscaricate a
ogni sync in `<LOCAL_DIR>/dim_table/`.

## Schema dati

Star schema con due tabelle dei fatti (`fact_postings`, `fact_skills`),
undici dimensioni (geografia, contratto, istruzione, settore, esperienza,
orario, salario, CP2021, occupazione ESCO, source, skill ESCO) e una
tabella di metadata (`dim_snapshot`). Il dizionario completo delle colonne
è documentato nella vignetta `vignette("struttura-dataset", package =
"itaposts")`.

## Citazione

In R:

``` r
citation("itaposts")
```

Riferimento bibliografico:

> Montaletti, G. (2026). *itaposts: Importazione e Normalizzazione di OJA
> Italiani in DuckDB*. Versione 0.4.0.
> <https://github.com/gmontaletti/itaposts>

## Licenza

MIT © 2026 Giampaolo Montaletti
([ORCID 0009-0002-5327-1122](https://orcid.org/0009-0002-5327-1122)).
