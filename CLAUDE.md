# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`itaposts` centralises import, normalisation and storage of OJA (Online Job Advertisements) data — the same dataset consumed downstream by the sibling project `skillviz` (`../skillviz/`) — in a shared DuckDB store, so callers (notably `skillviz` and `skillviz_workflow`) do not reimplement the read/dedup/join/ingest logic.

## Package State

Fully scaffolded CRAN-compliant package (`DESCRIPTION`, `NAMESPACE`, `R/`, `man/`, `tests/testthat/`, `vignettes/`), released through 0.2.0, currently in the 0.3.0 dev cycle. Apply the parent ecosystem conventions in `../CLAUDE.md` (data.table mandatory, roxygen2 markdown, semver, `NEWS.md`, Italian variable names for domain terms).

The DuckDB store built by `oja_sync()` / `oja_ingest_dirs()` (see `## DuckDB Store` below) is the primary data source for downstream callers — not the local zip files described in `## Data Files` below, which are the raw ingest input, not a query-time source.

## Data Files

Since the `data_v2` migration, the vendor (Lightcast) delivers OJA snapshots over SFTP under `/data_v2`, synced by `oja_sync()` (`R/sftp.R`) into a local cache before ingest:

- `/data_v2/dim_table/*.csv` — three **global** (region-independent), semicolon-delimited, non-zipped CSVs: `dim_esco_skills.csv`, `dim_occ_cp2021.csv`, `dim_occ_esco.csv`. Re-downloaded on every sync (no skip-by-size — vendor-authoritative and small, ~12 MB combined). Land in `<LOCAL_DIR>/dim_table/`; loaded via `.load_global_dims()` (`R/ingest.R`) into `dim_cp2021`, `dim_esco_occupation`, `dim_esco_skill`.
- `/data_v2/fact_table/<REGION>/<REGION>_<year>_<month>_{postings,postings_raw,skills}.zip` — same per-region, per-month, 3-file convention as the legacy delivery, comma-delimited inside the zip, but narrower than before: `postings.csv` now carries only `cp2021_id_level_5` and `idesco_level_5` as FKs (the old inlined hierarchy/label columns are gone from the source, reconstructed downstream via joins against the two occupation dim tables); `skills.csv` now carries only `general_id, year_grab_date, month_grab_date, IDESCOSKILL_LEVEL_3`; `postings_raw.csv` (`general_id` + `companyname`) is unchanged. `ITC4` is the NUTS-2 code for Lombardy, the only region currently synced.

`general_id` is the universal join key across `postings`, `postings_raw` and `skills` within a snapshot. `postings.csv` **contains duplicate rows on `general_id`** — always dedup keeping the most recent `grab_date` (`R/ingest.R:.read_postings()`), never a plain `unique()`.

Root-level `ITC4_*.zip` files, if present, are a stale local cache predating the `data_v2` migration and gitignored (`ITC4_*.zip` in `.gitignore`) — not the primary data source. Do not read them directly in new code; use the ingest pipeline described below.

## Read Pattern

Do not hand-roll `fread` calls on the zips — use the package's ingest pipeline, which already implements the dedup/join/type-coercion rules and streams the large skills file straight into DuckDB:

```r
itaposts::oja_sync()                                       # SFTP -> local cache -> DuckDB, idempotent
# or, from an already-populated local cache:
itaposts::oja_ingest_dirs(zip_dir = "...", dim_dir = ".../dim_table")
```

Internally (`R/ingest.R`), `.read_postings()` freads the postings zip, coerces `id*` columns to `character`, sorts by grab date descending, and dedups with `unique(x, by = "general_id")` after sorting — keeping the latest grab; `.attach_companyname()` joins in `companyname` from the `_postings_raw` zip; `.stream_skills()` streams the skills zip into DuckDB via `read_csv_auto` without materialising it in R. Mirror this sequence (sort-then-dedup, id columns as character) in any new loader code.

## Downstream Contract

Whatever the package exports must satisfy `skillviz` and `skillviz_workflow`. Before changing column names, dedup logic, the postings/raw split, or the shim's output columns (`R/shim.R`), grep those sibling repos for the affected fields and confirm no breakage. The `data_v2` migration already dropped several skill-side columns from the shim output (`PILLAR_*`, `ONET_HIER_*`, `ESCO_V0101_ICT`, ...) — see `NEWS.md` for the full list and the confirmation that no live `skillviz` call path uses them.

## Repository Hygiene

Root-level `ITC4_*.zip` files (if present) and `.Rproj.user/` are gitignored — they should not enter regular history.

## DuckDB Store

The package writes a normalised star schema to a single DuckDB file in the shared data directory. Path is resolved via `Sys.getenv("SHARED_DATA_DIR", "~/Documents/funzioni/shared_data")` + `/oja/itposts.duckdb`.

**Schema** (see `R/schema.R` for the authoritative DDL): two fact tables, eleven dimensions split into two groups by refresh strategy, one metadata table.
- Facts: `fact_postings` (PK `(snapshot_id, general_id)`), `fact_skills` (PK `(snapshot_id, general_id, idescoskill_level_3)`). DDL unchanged since 0.1.0.
- **Postings-derived dimensions** (incremental UPSERT, `INSERT … ON CONFLICT DO NOTHING`, accumulate across snapshots): `dim_geography`, `dim_contract`, `dim_education`, `dim_sector`, `dim_experience`, `dim_working_hours`, `dim_salary`, `dim_source`.
- **Vendor-global dimensions** (full reload — `DELETE` + re-`INSERT` from `/data_v2/dim_table` on every ingest, not incremental, because they are vendor-authoritative and small): `dim_cp2021`, `dim_esco_occupation` (full 1–5 hierarchy; `uri` dropped, no longer in the vendor source), `dim_esco_skill` (PK `idescoskill_level_3`; descriptive columns renamed `esco_v0101_*` → `esco_v010200_*` following the vendor's ESCO taxonomy bump v01.01 → v01.02.00; `onet_hier_level_*`, `pillar_softskills`, `pillar_digitalskills`, `pillar_bigdata`, `esco_v0101_ict` dropped with no vendor substitute; `esco_v010200_digital` and `esco_v010200_research` added).
- Meta: `dim_snapshot` (one row per ingest, with counts and provenance).

`companyname` is inlined in `fact_postings` rather than in a `dim_company` (skillviz never queries by employer; surrogate-key dedup adds complexity for no read-side win).

**Connection idiom** — same as `data_pipeline/R/person_employer_links.R`:

```r
con <- itaposts::oja_connect()                 # read-only by default
on.exit(itaposts::oja_disconnect(con), add = TRUE)
```

**Ingest** is single-snapshot, idempotent, transactional. Postings (small) flow through `data.table::fread` → R → DuckDB; skills stream straight into DuckDB via `read_csv_auto` on a temp-extracted CSV — never materialised in R memory. The three vendor-global dimensions are reloaded once per call (`oja_ingest_snapshot(dim_dir = ...)`) or once before the whole batch (`oja_ingest_dirs()`). Validation (PK uniqueness, skill→posting referential integrity) runs before COMMIT.

```r
itaposts::oja_init_db()
itaposts::oja_ingest_snapshot(
  zip_dir     = "~/Documents/funzioni/itaposts/incoming",
  snapshot_id = "ITC4_2026_6",
  dim_dir     = "~/Documents/funzioni/itaposts/incoming/dim_table"
)
```

**Read API**: `oja_postings()`, `oja_skills()`, `oja_snapshots()`, `oja_skill_dim()` return `dbplyr` lazy tables (collect via `dplyr::collect()`). `oja_normalised()` is a compatibility shim returning the `list(postings, skills, companies)` shape produced by `skillviz::normalize_ojv()` — use it during the migration of skillviz call sites. Its `skills` output exposes fewer columns than before `data_v2` (see `NEWS.md` for the exact list of columns dropped and kept).

**SFTP sync**: `oja_sync()` reads credentials and remote paths from `.Renviron` (`ITAPOSTS_SFTP_HOST/PORT/USER/PASSWORD/REMOTE_DIR/DIM_DIR/LOCAL_DIR`), downloads only missing per-snapshot fact archives (skip-by-size, atomic `.part` rename) plus the three `dim_table` CSVs (always re-downloaded), and chains into `oja_ingest_dirs()`. Idempotent on both download and ingest (`dim_snapshot` lookup). Backend is the OpenSSH `sftp` client invoked via `processx::process`: key auth uses non-interactive batch mode (`sftp -b`), password auth uses an interactive pty session (`processx::process$new(pty = TRUE, ...)`) since `sftp -b` forces `BatchMode=yes`, which blocks OpenSSH from ever prompting for a password. No `expect`/`sshpass` runtime dependency.

**Conventions** (inherited from the parent ecosystem):
- Lowercase, underscored table and column names. Source SHOUTING column names from the skills CSV are normalised at ingest; the shim re-emits them in their original case for skillviz parity.
- Italian roxygen prose with proper accents (`è`, `à`, …) per `../CLAUDE.md`.
- 2-space indent, `# 1. name -----` section comments, no `####`-only rows.
- DuckDB file is regenerated by ingest; do not commit it (gitignored).
