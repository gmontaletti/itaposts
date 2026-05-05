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
      # Default: password (1) + keyboard-interactive (8) = 9
      expect_equal(cfg$auth_types, 9L)
    }
  )
})

test_that("oja_sftp_config rimuove virgolette esterne e whitespace da USER/PASSWORD", {
  withr::with_envvar(
    c(
      ITAPOSTS_SFTP_HOST = "h",
      ITAPOSTS_SFTP_USER = '  "alice"  ',
      ITAPOSTS_SFTP_PASSWORD = "'p@ss word'",
      ITAPOSTS_SFTP_REMOTE_DIR = "/x"
    ),
    {
      cfg <- oja_sftp_config()
      expect_equal(cfg$user, "alice")
      expect_equal(cfg$password, "p@ss word")
    }
  )
})

test_that("oja_sftp_config aggiunge publickey ad auth_types se private_key e' impostato", {
  withr::with_envvar(
    c(
      ITAPOSTS_SFTP_HOST = "h",
      ITAPOSTS_SFTP_USER = "u",
      ITAPOSTS_SFTP_PASSWORD = "p",
      ITAPOSTS_SFTP_REMOTE_DIR = "/x",
      ITAPOSTS_SFTP_PRIVATE_KEY = "/etc/itaposts/id_ed25519",
      ITAPOSTS_SFTP_PRIVATE_KEY_PASSPHRASE = "secret"
    ),
    {
      cfg <- oja_sftp_config()
      # 1 (password) | 2 (publickey) | 8 (kbd-int) = 11
      expect_equal(cfg$auth_types, 11L)
      expect_equal(cfg$private_key, "/etc/itaposts/id_ed25519")
      expect_equal(cfg$private_key_passphrase, "secret")
    }
  )
})

test_that("oja_sftp_config rispetta override esplicito di AUTH_TYPES", {
  withr::with_envvar(
    c(
      ITAPOSTS_SFTP_HOST = "h",
      ITAPOSTS_SFTP_USER = "u",
      ITAPOSTS_SFTP_PASSWORD = "p",
      ITAPOSTS_SFTP_REMOTE_DIR = "/x",
      ITAPOSTS_SFTP_AUTH_TYPES = "2"
    ),
    {
      cfg <- oja_sftp_config()
      expect_equal(cfg$auth_types, 2L)
    }
  )
  withr::with_envvar(
    c(
      ITAPOSTS_SFTP_HOST = "h",
      ITAPOSTS_SFTP_USER = "u",
      ITAPOSTS_SFTP_PASSWORD = "p",
      ITAPOSTS_SFTP_REMOTE_DIR = "/x",
      ITAPOSTS_SFTP_AUTH_TYPES = "abc"
    ),
    expect_error(oja_sftp_config(), regexp = "ITAPOSTS_SFTP_AUTH_TYPES")
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

test_that("oja_sftp_config legge known_hosts e fingerprint host SSH", {
  withr::with_envvar(
    c(
      ITAPOSTS_SFTP_HOST = "h",
      ITAPOSTS_SFTP_USER = "u",
      ITAPOSTS_SFTP_PASSWORD = "p",
      ITAPOSTS_SFTP_REMOTE_DIR = "/x",
      ITAPOSTS_SFTP_KNOWN_HOSTS = "/etc/ssh/known_hosts_itaposts",
      ITAPOSTS_SFTP_HOST_FINGERPRINT_MD5 = "AA:bb:CC:dd:11:22:33:44:55:66:77:88:99:00:11:22",
      ITAPOSTS_SFTP_HOST_FINGERPRINT_SHA256 = "SHA256:Abcdefg/HiJkLmNoPqRsTuVwXyZ0123456789abcdEFG="
    ),
    {
      cfg <- oja_sftp_config()
      expect_equal(cfg$known_hosts, "/etc/ssh/known_hosts_itaposts")
      # MD5 normalizzato: lowercase, senza `:`, 32 hex.
      expect_equal(
        cfg$host_fingerprint_md5,
        "aabbccdd1122334455667788990011" |>
          paste0("22")
      )
      # Prefisso SHA256: scartato.
      expect_equal(
        cfg$host_fingerprint_sha256,
        "Abcdefg/HiJkLmNoPqRsTuVwXyZ0123456789abcdEFG="
      )
    }
  )
})

test_that("oja_sftp_config rifiuta MD5 host key non valido", {
  withr::with_envvar(
    c(
      ITAPOSTS_SFTP_HOST = "h",
      ITAPOSTS_SFTP_USER = "u",
      ITAPOSTS_SFTP_PASSWORD = "p",
      ITAPOSTS_SFTP_REMOTE_DIR = "/x",
      ITAPOSTS_SFTP_HOST_FINGERPRINT_MD5 = "non-hex"
    ),
    expect_error(
      oja_sftp_config(),
      regexp = "ITAPOSTS_SFTP_HOST_FINGERPRINT_MD5"
    )
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
