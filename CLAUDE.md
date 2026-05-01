# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`itaposts` is intended as a small R package to streamline import and preprocessing of OJA (Online Job Advertisements) data — the same dataset consumed downstream by the sibling project `skillviz` (`../skillviz/`). The package centralises the read/dedup/join logic so callers (notably `skillviz` and `skillviz_workflow`) do not reimplement it.

## Current State

The repository is a project shell, not yet a scaffolded package:

- No `DESCRIPTION`, `NAMESPACE`, `R/`, `man/`, `tests/`
- No git repository (`git init` not yet run)
- Only `read.R` exists as a working sketch of the load + dedup flow

Use the `r-package-setup` skill before adding exported functions. Apply the parent ecosystem conventions in `../CLAUDE.md` (data.table mandatory, roxygen2 markdown, semver, `NEWS.md`, Italian variable names for domain terms).

## Data Files

Three zipped CSVs ship at the repo root, following the naming pattern `ITC4_<year>_<month>_<part>.zip`. `ITC4` is the NUTS-2 code for Lombardy. Current snapshot: `2026_2`.

- `ITC4_2026_2_postings.zip` (~10 MB zipped, ~66 MB CSV) — main job-posting fact table; many columns including ISTAT CP2021 occupation hierarchy (levels 1–5), ESCO occupation (levels 4–5), contract, education, sector, salary, geography. **Contains duplicate rows on `general_id`** — always dedup with `unique(x, by = "general_id")` after read, as in `read.R`.
- `ITC4_2026_2_postings_raw.zip` (~1 MB zipped, ~3 MB CSV) — narrow companion table holding only `general_id` + `companyname`. Joined on `general_id` to the deduped postings when employer information is needed. Kept separate because `companyname` is the field most likely to contain PII or licence-restricted strings.
- `ITC4_2026_2_skills.zip` (~100 MB zipped, ~700 MB CSV) — long-format skills table, one row per (`general_id`, ESCO skill). Carries the full ESCO v0101 hierarchy (levels 0–3), ONET hierarchy, and the `PILLAR_SOFTSKILLS` / `PILLAR_DIGITALSKILLS` / `PILLAR_BIGDATA` / `ESCO_V0101_GREEN` / `ESCO_V0101_ICT` / `ESCO_V0101_LANGUAGE` / `ESCO_V0101_TRANSVERSAL` flags used by `skillviz`. Read this with `data.table::fread` directly from the zip; it dwarfs the postings file.

`general_id` is the universal join key across the three files.

## Read Pattern

`fread` reads zip archives transparently — do not unzip. Canonical sequence (mirror in any exported loader):

```r
ann  <- unique(fread("ITC4_2026_2_postings.zip"),     by = "general_id")
raw  <- fread("ITC4_2026_2_postings_raw.zip")          # companyname lookup
skil <- fread("ITC4_2026_2_skills.zip")                # large; long format
```

When designing the package API, prefer a single entry point that takes a snapshot tag (e.g. `"ITC4_2026_2"`) and a directory, returning the three deduped data.tables (or a list/environment), so downstream callers do not hard-code filenames.

## Downstream Contract

Whatever the package exports must satisfy `skillviz` and `skillviz_workflow`. Before changing column names, dedup logic, or the postings/raw split, grep those sibling repos for the affected fields and confirm no breakage.

## Repository Hygiene

The three `ITC4_*.zip` files are large. Once git is initialised, add them to `.gitignore` (or use Git LFS) — they should not enter regular history. The `.Rproj.user/` directory is also ignorable.

## DuckDB Store (v0.1.0)

The package writes a normalised star schema to a single DuckDB file in the shared data directory. Path is resolved via `Sys.getenv("SHARED_DATA_DIR", "~/Documents/funzioni/shared_data")` + `/oja/itposts.duckdb`.

**Schema** (see `R/schema.R` for the DDL):
- Facts: `fact_postings` (PK `(snapshot_id, general_id)`), `fact_skills` (PK `(snapshot_id, general_id, idescoskill_level_3)`).
- Dimensions: `dim_geography`, `dim_contract`, `dim_education`, `dim_sector`, `dim_experience`, `dim_working_hours`, `dim_salary`, `dim_cp2021`, `dim_esco_occupation`, `dim_source`, `dim_esco_skill`. All accumulate across snapshots via `INSERT … ON CONFLICT DO NOTHING`.
- Meta: `dim_snapshot` (one row per ingest, with counts and provenance).

`companyname` is inlined in `fact_postings` rather than in a `dim_company` (skillviz never queries by employer; surrogate-key dedup adds complexity for no read-side win).

**Connection idiom** — same as `data_pipeline/R/person_employer_links.R`:

```r
con <- itaposts::oja_connect()                 # read-only by default
on.exit(itaposts::oja_disconnect(con), add = TRUE)
```

**Ingest** is single-snapshot, idempotent, transactional. Postings (small) flow through `data.table::fread` → R → DuckDB; skills (~27M rows) stream straight into DuckDB via `read_csv_auto` on a temp-extracted CSV — never materialised in R memory. Validation (PK uniqueness, skill→posting referential integrity) runs before COMMIT.

```r
itaposts::oja_init_db()
itaposts::oja_ingest_snapshot(
  zip_dir     = "~/Documents/funzioni/itaposts",
  snapshot_id = "ITC4_2026_2"
)
```

**Read API**: `oja_postings()`, `oja_skills()`, `oja_snapshots()`, `oja_skill_dim()` return `dbplyr` lazy tables (collect via `dplyr::collect()`). `oja_normalised()` is a compatibility shim returning the `list(postings, skills, companies)` shape produced by `skillviz::normalize_ojv()` — use it during the migration of skillviz call sites.

**SFTP sync**: `oja_sync()` reads credentials from `.Renviron` (`ITAPOSTS_SFTP_HOST/PORT/USER/PASSWORD/REMOTE_DIR/LOCAL_DIR`), downloads only missing snapshots via libcurl SFTP (atomic `.part` rename), and chains into `oja_ingest_dirs()`. Idempotent on both download (size match) and ingest (`dim_snapshot` lookup). Uses `curl::curl_download` — no `ssh`/libssh2 dep.

**Conventions** (inherited from the parent ecosystem):
- Lowercase, underscored table and column names. Source SHOUTING column names from the skills CSV are normalised at ingest; the shim re-emits them in their original case for skillviz parity.
- Italian roxygen prose with proper accents (`è`, `à`, …) per `../CLAUDE.md`.
- 2-space indent, `# 1. name -----` section comments, no `####`-only rows.
- DuckDB file is regenerated by ingest; do not commit it. Path is gitignored once git is initialised.
