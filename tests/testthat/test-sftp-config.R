test_that("oja_sftp_config restituisce lista completa con tutte le variabili", {
  withr::with_envvar(
    c(
      ITAPOSTS_SFTP_HOST = "sftp.example",
      ITAPOSTS_SFTP_PORT = "2222",
      ITAPOSTS_SFTP_USER = "alice",
      ITAPOSTS_SFTP_PASSWORD = "s3cret",
      ITAPOSTS_SFTP_REMOTE_DIR = "/exports/oja/",
      ITAPOSTS_SFTP_LOCAL_DIR = "/tmp/itaposts_test"
    ),
    {
      cfg <- oja_sftp_config()
      expect_equal(cfg$host, "sftp.example")
      expect_equal(cfg$port, 2222L)
      expect_equal(cfg$user, "alice")
      expect_equal(cfg$password, "s3cret")
      # remote_dir senza trailing slash
      expect_equal(cfg$remote_dir, "/exports/oja")
      expect_equal(cfg$local_dir, "/tmp/itaposts_test")
    }
  )
})

test_that("oja_sftp_config applica i default a PORT e LOCAL_DIR", {
  withr::with_envvar(
    c(
      ITAPOSTS_SFTP_HOST = "h",
      ITAPOSTS_SFTP_USER = "u",
      ITAPOSTS_SFTP_PASSWORD = "p",
      ITAPOSTS_SFTP_REMOTE_DIR = "/x",
      ITAPOSTS_SFTP_PORT = NA,
      ITAPOSTS_SFTP_LOCAL_DIR = NA
    ),
    {
      cfg <- oja_sftp_config()
      expect_equal(cfg$port, 22L)
      expect_match(cfg$local_dir, "itaposts_incoming")
    }
  )
})

test_that("oja_sftp_config solleva errore se mancano variabili obbligatorie", {
  withr::with_envvar(
    c(
      ITAPOSTS_SFTP_HOST = NA,
      ITAPOSTS_SFTP_USER = "u",
      ITAPOSTS_SFTP_PASSWORD = "p",
      ITAPOSTS_SFTP_REMOTE_DIR = "/x"
    ),
    expect_error(oja_sftp_config(), regexp = "ITAPOSTS_SFTP_HOST")
  )
})

test_that("oja_sftp_config rifiuta PORT non valido", {
  withr::with_envvar(
    c(
      ITAPOSTS_SFTP_HOST = "h",
      ITAPOSTS_SFTP_USER = "u",
      ITAPOSTS_SFTP_PASSWORD = "p",
      ITAPOSTS_SFTP_REMOTE_DIR = "/x",
      ITAPOSTS_SFTP_PORT = "abc"
    ),
    expect_error(oja_sftp_config(), regexp = "ITAPOSTS_SFTP_PORT")
  )
})
