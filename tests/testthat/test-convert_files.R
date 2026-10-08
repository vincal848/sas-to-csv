# Tests that convert_files combines files in order, matches serial to
# parallel output, and fails clearly on an empty match set.

ROOT <- testthat::test_path("..", "..")
source(file.path(ROOT, "R", "convert.R"))

test_that("multiple files are combined in listing order with a source-file column", {
  dir <- withr::local_tempdir()
  write_fixture(dir, "crsp_a.txt", c("1 10", "2 20"))
  write_fixture(dir, "crsp_b.txt", c("3 30"))

  out <- file.path(dir, "out.csv")
  result <- convert_files(
    dir = dir, pattern = "^crsp_.*\\.txt$", col_names = c("id", "val"),
    out = out, return_data = TRUE
  )

  expect_equal(result$data$id, c(1, 2, 3))
  expect_equal(result$data$val, c(10, 20, 30))
  expect_equal(result$data$source_file, c("crsp_a.txt", "crsp_a.txt", "crsp_b.txt"))
})

test_that("cores = 2 produces the same result as cores = 1", {
  dir <- withr::local_tempdir()
  for (i in 1:5) {
    write_fixture(dir, sprintf("crsp_%d.txt", i), c(
      sprintf("%d %d", i, i * 10),
      sprintf("%d %d", i + 100, i * 10 + 1)
    ))
  }

  serial <- convert_files(
    dir = dir, pattern = "^crsp_.*\\.txt$", col_names = c("id", "val"),
    out = file.path(dir, "serial.csv"), cores = 1, return_data = TRUE
  )
  parallel_result <- convert_files(
    dir = dir, pattern = "^crsp_.*\\.txt$", col_names = c("id", "val"),
    out = file.path(dir, "parallel.csv"), cores = 2, return_data = TRUE
  )

  expect_equal(serial$data, parallel_result$data)
  expect_equal(
    read.csv(file.path(dir, "serial.csv")),
    read.csv(file.path(dir, "parallel.csv"))
  )
})

test_that("an empty directory or a pattern with no matches errors clearly", {
  dir <- withr::local_tempdir()

  expect_error(
    convert_files(dir = dir, pattern = "^crsp_.*\\.txt$", col_names = c("a"), out = NULL),
    "No files"
  )

  write_fixture(dir, "unrelated.txt", c("1"))
  expect_error(
    convert_files(dir = dir, pattern = "^crsp_.*\\.txt$", col_names = c("a"), out = NULL),
    "No files"
  )
})

test_that("the written CSV round-trips to the same data", {
  dir <- withr::local_tempdir()
  write_fixture(dir, "crsp_a.txt", c("1 10.5 x", "2 20.25 y"))

  out <- file.path(dir, "out.csv")
  result <- convert_files(
    dir = dir, pattern = "^crsp_.*\\.txt$", col_names = c("id", "val", "grp"),
    out = out, source_col = FALSE, return_data = TRUE
  )

  roundtrip <- read.csv(out, stringsAsFactors = FALSE)
  expect_equal(roundtrip$id, result$data$id)
  expect_equal(roundtrip$val, result$data$val)
  expect_equal(roundtrip$grp, result$data$grp)
})

test_that("padded and truncated row counts are summed across files", {
  dir <- withr::local_tempdir()
  write_fixture(dir, "crsp_a.txt", c("1 2 3", "4 5")) # one short row
  write_fixture(dir, "crsp_b.txt", c("6 7 8 9"))      # one long row

  result <- convert_files(
    dir = dir, pattern = "^crsp_.*\\.txt$", col_names = c("a", "b", "c"), out = NULL
  )

  expect_equal(result$n_padded, 1)
  expect_equal(result$n_truncated, 1)
})

test_that("each batch is written before the next one is read", {
  dir <- withr::local_tempdir()
  for (i in 1:3) write_fixture(dir, sprintf("crsp_%d.txt", i), sprintf("%d %d", i, i))
  out <- file.path(dir, "out.csv")

  env <- environment(convert_files)
  real <- get(".read_one_file", envir = env)
  sizes <- numeric(0)
  assign(".read_one_file", function(...) {
    sizes <<- c(sizes, if (file.exists(out)) file.size(out) else 0)
    real(...)
  }, envir = env)
  withr::defer(assign(".read_one_file", real, envir = env))

  convert_files(dir = dir, pattern = "^crsp_.*\\.txt$", col_names = c("id", "val"), out = out)

  expect_equal(sizes[1], 0)
  expect_true(all(diff(sizes) > 0)) # output grew before every later read
})
