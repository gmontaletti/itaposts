# itaposts — bundle cron

Pacchetto trasferibile per installare `itaposts` e schedulare la sync OJA su
una macchina Linux/macOS pulita. Lo zip auto-contenuto viene prodotto da
`tools/build_transfer_zip.sh` nel repository sorgente.

## Contenuto

- `itaposts_<versione>.tar.gz` — sorgente del pacchetto R
- `install.sh` — installer idempotente (deps CRAN + pacchetto + schema DuckDB)
- `cron/sync_oja.R` — entry point R per la sync (download + ingest)
- `cron/run_sync.sh` — wrapper bash invocato dal cron
- `cron/crontab.example` — esempio di schedulazione
- `cron/.Renviron.template` — template credenziali SFTP

## Prerequisiti

- R >= 4.1 con `Rscript` in `PATH`
- Connessione di rete verso il server SFTP
- Permessi di scrittura su `SHARED_DATA_DIR` (path del DuckDB condiviso)

## Setup su macchina pulita

```bash
unzip itaposts-cron-<versione>.zip
cd itaposts-cron-<versione>
./install.sh

# Compilare credenziali SFTP e percorsi
$EDITOR cron/.Renviron
chmod 600 cron/.Renviron

# Smoke test manuale
./cron/run_sync.sh
tail -n 50 cron/logs/sync_*.log

# Installazione cron
crontab -l 2>/dev/null | { cat; cat cron/crontab.example; } | crontab -
```

## Codici di uscita di `sync_oja.R`

| Stato | Significato |
|------:|-------------|
| `0`   | Sync completata correttamente |
| `1`   | Errore durante `oja_sync()` (rete, ingest, schema DB) |
| `2`   | Pacchetto `itaposts` non installato |
| `3`   | Lock attivo: run precedente ancora in corso |

## Log

`run_sync.sh` scrive in `$ITAPOSTS_LOG_DIR/sync_YYYYMMDD.log` (default
`cron/logs/` accanto al wrapper). Cron riceve solo l'exit code; configurare
`MAILTO` nel crontab per ricevere stderr non vuoto in caso di fallimento.

## Concorrenza

Il lock file PID-based in `$ITAPOSTS_LOCK_DIR/sync_oja.lock` impedisce a una
seconda istanza di partire prima che la precedente abbia chiuso il DuckDB.
Se il run precedente e' stato killato senza pulire il lock, il successivo
rileva il PID stale via `ps -p` e lo rimuove automaticamente.

## Aggiornamento

Per aggiornare il pacchetto basta rilanciare `./install.sh` con un nuovo
bundle: `R CMD INSTALL` sovrascrive la versione precedente. Lo schema
DuckDB e' idempotente (`oja_init_db()` non distrugge dati esistenti).
