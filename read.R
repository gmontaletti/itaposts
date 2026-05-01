# Demo del flusso di ingestione + lettura via itaposts.

# 1. Ingestione (una tantum, scrive in $SHARED_DATA_DIR/oja/itposts.duckdb) -----
# itaposts::oja_init_db()
# itaposts::oja_ingest_snapshot(
#   zip_dir     = "~/Documents/funzioni/itaposts",
#   snapshot_id = "ITC4_2026_2"
# )

# 2. Lettura lazy via dbplyr ----------------------------------------------------
library(itaposts)
library(dplyr)

con <- oja_connect()
on.exit(oja_disconnect(con), add = TRUE)

oja_snapshots(con)

oja_postings(con, snapshots = "ITC4_2026_2") |>
  count(idesco_level_5, sort = TRUE) |>
  head(10) |>
  collect()

# 3. Forma compatibile skillviz ------------------------------------------------
ojv <- oja_normalised(con, snapshots = "ITC4_2026_2")
ojv$postings[, uniqueN(general_id)]
