# itaposts — deployment containerizzato

Procedura per installare `itaposts` su un server Linux come container Docker
one-shot invocato dal cron host. Sostituisce la vecchia installazione bare-metal
documentata in `INSTALLAZIONE.md` (rimossa in v0.2.0).

## Architettura

- Immagine: `ghcr.io/gmontaletti/itaposts:VERSION` (base `rocker/r2u:noble`).
- Cron host invoca `docker run --rm` via `itaposts-sync.sh`. Il container esegue
  `oja_sync()` e termina.
- Stato persistente in `/var/itaposts/{shared,incoming,run}` sul host,
  bind-montato dentro il container.
- Segreti in `/etc/itaposts/itaposts.env` (chmod 0600), iniettati come env vars.
- Logging redirezionato dal cron a `/var/log/itaposts/sync.log`.

## Prerequisiti sul server

| | Pacchetto Debian/Ubuntu |
|---|---|
| Docker Engine | `docker.io` o `docker-ce` |
| Cron | `cron` (preinstallato) |
| `logrotate` (consigliato) | `logrotate` (preinstallato) |

L'utente che esegue il cron (`monty` in questi esempi) deve essere nel gruppo
`docker`:

```bash
sudo usermod -aG docker monty
```

## Procedura

### 1. Crea le directory di runtime

```bash
sudo mkdir -p /var/itaposts/{shared,incoming,run} \
              /var/log/itaposts \
              /etc/itaposts
sudo chown -R monty:monty /var/itaposts /var/log/itaposts
```

### 2. Pull dell'immagine

Modalita' online (raccomandata):

```bash
docker pull ghcr.io/gmontaletti/itaposts:0.2.0
docker tag  ghcr.io/gmontaletti/itaposts:0.2.0 \
            ghcr.io/gmontaletti/itaposts:latest
```

Modalita' offline (server senza accesso a ghcr.io):

```bash
# Sul build host (con accesso a ghcr.io):
docker pull ghcr.io/gmontaletti/itaposts:0.2.0
docker save ghcr.io/gmontaletti/itaposts:0.2.0 \
  | gzip > itaposts-0.2.0.tar.gz
scp itaposts-0.2.0.tar.gz monty@server:/tmp/

# Sul server:
gunzip -c /tmp/itaposts-0.2.0.tar.gz | docker load
docker tag  ghcr.io/gmontaletti/itaposts:0.2.0 \
            ghcr.io/gmontaletti/itaposts:latest
```

### 3. Configura le credenziali SFTP

```bash
sudo cp itaposts.env.example /etc/itaposts/itaposts.env
sudo chmod 0600 /etc/itaposts/itaposts.env
sudo chown monty:monty /etc/itaposts/itaposts.env
sudoedit /etc/itaposts/itaposts.env
```

Variabili minime da compilare:

```
ITAPOSTS_SFTP_HOST=custom-delivery.lightcast.io
ITAPOSTS_SFTP_USER=regionelombardia@lightcast.io
ITAPOSTS_SFTP_PASSWORD=<password ricevuta da Lightcast>
ITAPOSTS_SFTP_REMOTE_DIR=/data_v1/ITC4
```

Lightcast non registra chiavi pubbliche lato server: l'unica modalita'
supportata e' l'auth a password.

### 4. Installa il wrapper host

```bash
sudo install -m 0755 itaposts-sync.sh /usr/local/bin/itaposts-sync.sh
```

### 5. Smoke test manuale

```bash
sudo -u monty /usr/local/bin/itaposts-sync.sh
```

Atteso: log su stdout con `Listing remoto...`, `Sync ok in Xs: ...`, exit 0.
Verifica che il DuckDB sia stato creato:

```bash
ls -la /var/itaposts/shared/oja/itposts.duckdb
```

Una seconda esecuzione deve essere idempotente:

```bash
sudo -u monty /usr/local/bin/itaposts-sync.sh
# atteso: 0 download, 0 ingest, exit 0
```

### 6. Schedulazione cron

```bash
sudo install -m 0644 -o root -g root crontab.example /etc/cron.d/itaposts
sudo systemctl restart cron        # Debian/Ubuntu
```

### 7. Rotazione dei log

```bash
sudo tee /etc/logrotate.d/itaposts > /dev/null <<'EOF'
/var/log/itaposts/*.log {
  weekly
  rotate 12
  compress
  delaycompress
  missingok
  notifempty
}
EOF
```

## Aggiornamento

```bash
docker pull ghcr.io/gmontaletti/itaposts:<nuova_versione>
docker tag  ghcr.io/gmontaletti/itaposts:<nuova_versione> \
            ghcr.io/gmontaletti/itaposts:latest
```

Lo schema DuckDB e' preservato: `oja_init_db()` e' idempotente. `itaposts.env`
non viene toccato.

## Codici di uscita

| Codice | Significato |
|---:|---|
| `0` | Sync completata |
| `1` | Errore in `oja_sync()` o nelle dir di runtime |
| `2` | Pacchetto `itaposts` non trovato (immagine corrotta) |
| `3` | Lock attivo: run precedente ancora in corso |

## Diagnostica rapida

```bash
# Snapshot gia' nel DB
docker run --rm \
  -v /var/itaposts/shared:/var/itaposts/shared \
  ghcr.io/gmontaletti/itaposts:latest \
  -e 'itaposts::oja_snapshots() |> dplyr::collect() |> print(n = 100)'

# Listing remoto
docker run --rm --env-file /etc/itaposts/itaposts.env \
  ghcr.io/gmontaletti/itaposts:latest \
  -e 'itaposts::oja_remote_list() |> head()'

# Spazio occupato
du -sh /var/itaposts/shared/oja/itposts.duckdb

# Run attivi
docker ps --filter name=itaposts-sync
```
