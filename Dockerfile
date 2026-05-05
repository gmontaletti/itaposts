FROM rocker/r2u:noble

# 1. System tools ------------------------------------------------------------
# openssh-client: client `sftp` invocato via processx dal backend.
# sshpass: helper per passare la password a sftp via env (mai su argv).
# procps: `ps` usato dal lock file per stale-PID detection.
# tzdata: fuso orario Europe/Rome per i timestamp dei log.
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-client \
      sshpass \
      ca-certificates \
      procps \
      tzdata \
    && rm -rf /var/lib/apt/lists/*

ENV TZ=Europe/Rome \
    LANG=C.UTF-8

# 2. CRAN deps ----------------------------------------------------------------
# r2u risolve queste come binari apt via bspm: minuti, non ore.
RUN install2.r --error --skipinstalled \
      cli \
      data.table \
      DBI \
      dplyr \
      dbplyr \
      duckdb \
      processx \
      rlang

# 3. Pacchetto itaposts -------------------------------------------------------
WORKDIR /build
COPY . /build
RUN R CMD INSTALL --no-multiarch --with-keep.source /build \
    && rm -rf /build

# 4. Layout runtime -----------------------------------------------------------
# Tutti i path sono fissati: il chiamante li mappa via bind mount sul host.
ENV SHARED_DATA_DIR=/var/itaposts/shared \
    ITAPOSTS_SFTP_LOCAL_DIR=/var/itaposts/incoming \
    ITAPOSTS_LOCK_DIR=/var/itaposts/run
WORKDIR /var/itaposts

# 5. Entry point --------------------------------------------------------------
# Esegue il sync wrapper installato dentro il pacchetto.
ENTRYPOINT ["Rscript", "--no-save", "--no-restore", "--no-init-file", "--no-site-file"]
CMD ["-e", "source(system.file('cron/sync_oja.R', package='itaposts'))"]
