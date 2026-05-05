# 1. Argv builder ------------------------------------------------------------

base_cfg <- function(...) {
  defaults <- list(
    host = "sftp.example",
    port = 22L,
    user = "alice",
    password = "p",
    remote_dir = "/exports/oja",
    local_dir = "/tmp/itaposts_x",
    known_hosts = "",
    host_fingerprint_md5 = "",
    host_fingerprint_sha256 = "",
    private_key = "",
    public_key = "",
    private_key_passphrase = "",
    auth_types = bitwOr(1L, 8L)
  )
  modifyList(defaults, list(...))
}

test_that(".sftp_argv produce un argv minimale per host+user", {
  cfg <- base_cfg()
  argv <- itaposts:::.sftp_argv(cfg, batchfile = "/tmp/x.batch")
  expect_true("-q" %in% argv)
  expect_true("-b" %in% argv)
  expect_true("/tmp/x.batch" %in% argv)
  # porta passata come stringa subito dopo `-P`
  i <- which(argv == "-P")
  expect_length(i, 1L)
  expect_equal(argv[i + 1L], "22")
  # user@host come ultimo elemento
  expect_equal(argv[length(argv)], "alice@sftp.example")
  # niente PreferredAuthentications quando auth_types == default
  expect_false(any(grepl("PreferredAuthentications", argv)))
  # niente BatchMode quando manca la chiave
  expect_false(any(grepl("BatchMode", argv)))
  # niente UserKnownHostsFile quando known_hosts e' vuoto
  expect_false(any(grepl("UserKnownHostsFile", argv)))
})

test_that(".sftp_argv aggiunge UserKnownHostsFile e StrictHostKeyChecking", {
  cfg <- base_cfg(known_hosts = "/etc/itaposts/known_hosts")
  argv <- itaposts:::.sftp_argv(cfg, batchfile = "/tmp/x.batch")
  expect_true("StrictHostKeyChecking=yes" %in% argv)
  expect_true("UserKnownHostsFile=/etc/itaposts/known_hosts" %in% argv)
})

test_that(".sftp_argv aggiunge -i e BatchMode quando private_key e' set", {
  cfg <- base_cfg(private_key = "/etc/itaposts/id_ed25519")
  argv <- itaposts:::.sftp_argv(cfg, batchfile = "/tmp/x.batch")
  i <- which(argv == "-i")
  expect_length(i, 1L)
  expect_equal(argv[i + 1L], "/etc/itaposts/id_ed25519")
  expect_true("BatchMode=yes" %in% argv)
})

test_that(".sftp_argv traduce auth_types=2 in PreferredAuthentications=publickey", {
  cfg <- base_cfg(auth_types = 2L)
  argv <- itaposts:::.sftp_argv(cfg, batchfile = "/tmp/x.batch")
  expect_true("PreferredAuthentications=publickey" %in% argv)
})

test_that(".sftp_argv traduce auth_types=11 in elenco completo", {
  cfg <- base_cfg(auth_types = bitwOr(bitwOr(1L, 2L), 8L))
  argv <- itaposts:::.sftp_argv(cfg, batchfile = "/tmp/x.batch")
  pref <- grep("^PreferredAuthentications=", argv, value = TRUE)
  expect_length(pref, 1L)
  parts <- strsplit(sub("^PreferredAuthentications=", "", pref), ",")[[1]]
  expect_setequal(parts, c("publickey", "keyboard-interactive", "password"))
})

# 2. Listing parser ----------------------------------------------------------

test_that(".parse_listing decodifica l'output `ls -l` di OpenSSH sftp", {
  txt <- paste(
    "drwxr-xr-x    2 1000     1000           96 Jan 12 09:00 .",
    "drwxr-xr-x    2 1000     1000           96 Jan 12 09:00 ..",
    "-rw-r--r--    1 1000     1000     10595813 Mar 18 08:59 ITC4_2026_2_postings.zip",
    "-rw-r--r--    1 1000     1000      3145728 Mar 18 08:59 ITC4_2026_2_postings_raw.zip",
    "-rw-r--r--    1 1000     1000    104857600 Mar 18 09:01 ITC4_2026_2_skills.zip",
    sep = "\n"
  )
  out <- itaposts:::.parse_listing(txt)
  expect_s3_class(out, "data.frame")
  expect_setequal(
    out$name,
    c(
      ".",
      "..",
      "ITC4_2026_2_postings.zip",
      "ITC4_2026_2_postings_raw.zip",
      "ITC4_2026_2_skills.zip"
    )
  )
  expect_equal(
    out$size_bytes[out$name == "ITC4_2026_2_postings.zip"],
    10595813
  )
})

test_that(".parse_listing tollera input vuoto", {
  out <- itaposts:::.parse_listing("")
  expect_s3_class(out, "data.frame")
  expect_equal(nrow(out), 0L)
})

# 3. oja_remote_list batch contract ------------------------------------------

test_that("oja_remote_list costruisce il batch giusto e parsa lo stdout", {
  cfg <- base_cfg(remote_dir = "/exports/oja")
  captured <- list()
  fake_run <- function(config, batch_lines, timeout = 1800, runner = NULL) {
    captured$batch <<- batch_lines
    captured$config <<- config
    list(
      stdout = paste(
        "-rw-r--r--   1 u g  100 Mar 18 08:59 ITC4_2026_2_postings.zip",
        "-rw-r--r--   1 u g   50 Mar 18 08:59 ITC4_2026_2_postings_raw.zip",
        "-rw-r--r--   1 u g  200 Mar 18 09:01 ITC4_2026_2_skills.zip",
        "-rw-r--r--   1 u g  999 Mar 18 09:01 README.txt",
        sep = "\n"
      ),
      status = 0L
    )
  }
  testthat::with_mocked_bindings(
    .sftp_run = fake_run,
    .package = "itaposts",
    {
      out <- oja_remote_list(cfg, region_code = "ITC4")
    }
  )
  # Batch contiene cd + ls -l (il README va scartato dal regex su nome file)
  expect_equal(captured$batch, c("cd /exports/oja", "ls -l"))
  expect_equal(nrow(out), 3L)
  expect_setequal(out$kind, c("postings", "postings_raw", "skills"))
  expect_true(all(out$snapshot_id == "ITC4_2026_2"))
})

test_that("oja_remote_list senza remote_dir non emette `cd`", {
  cfg <- base_cfg(remote_dir = "")
  captured <- list()
  fake_run <- function(config, batch_lines, timeout = 1800, runner = NULL) {
    captured$batch <<- batch_lines
    list(stdout = "", status = 0L)
  }
  testthat::with_mocked_bindings(
    .sftp_run = fake_run,
    .package = "itaposts",
    {
      oja_remote_list(cfg)
    }
  )
  expect_equal(captured$batch, "ls -l")
})

# 4. oja_sftp_download batch contract ----------------------------------------

test_that("oja_sftp_download usa cd + get e fa rename atomico", {
  cfg <- base_cfg(remote_dir = "/exports/oja")
  tmp <- tempfile("itaposts_dl_")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  local_path <- file.path(tmp, "ITC4_2026_2_postings.zip")

  captured <- list()
  fake_run <- function(config, batch_lines, timeout = 1800, runner = NULL) {
    captured$batch <<- batch_lines
    # Simula il lavoro del client: scrive il file `.part`.
    writeBin(raw(42), paste0(local_path, ".part"))
    list(stdout = "", status = 0L)
  }
  testthat::with_mocked_bindings(
    .sftp_run = fake_run,
    .package = "itaposts",
    {
      out <- oja_sftp_download(
        "ITC4_2026_2_postings.zip",
        local_path,
        config = cfg
      )
    }
  )
  expect_equal(out, local_path)
  expect_true(file.exists(local_path))
  expect_false(file.exists(paste0(local_path, ".part")))
  expect_equal(
    captured$batch,
    c(
      "cd /exports/oja",
      paste0(
        "get ITC4_2026_2_postings.zip ",
        local_path,
        ".part"
      )
    )
  )
})

test_that("oja_sftp_download rimuove `.part` preesistente prima del get", {
  cfg <- base_cfg(remote_dir = "/exports/oja")
  tmp <- tempfile("itaposts_dl_")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  local_path <- file.path(tmp, "ITC4_2026_2_postings.zip")
  writeBin(raw(7), paste0(local_path, ".part"))
  expect_true(file.exists(paste0(local_path, ".part")))

  fake_run <- function(config, batch_lines, timeout = 1800, runner = NULL) {
    # Verifica: al momento dell'invocazione, il `.part` precedente
    # deve essere gia' stato rimosso.
    expect_false(file.exists(paste0(local_path, ".part")))
    writeBin(raw(11), paste0(local_path, ".part"))
    list(stdout = "", status = 0L)
  }
  testthat::with_mocked_bindings(
    .sftp_run = fake_run,
    .package = "itaposts",
    {
      oja_sftp_download(
        "ITC4_2026_2_postings.zip",
        local_path,
        config = cfg
      )
    }
  )
  expect_equal(file.info(local_path)$size, 11L)
})
