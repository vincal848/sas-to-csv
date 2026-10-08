# Reads irregular, whitespace-delimited text exports (the CRSP/USAR/USRR SAS
# dumps this repo was built for) and SAS binary files, coercing every file to
# the same column count without silently discarding or inventing data.

#' Read one irregular file into a data.frame with an exact column count.
#'
#' Short rows are padded with NA, long rows are truncated. Unlike
#' \code{read.table(fill = TRUE)}, which pads every row up to the widest row
#' in the file and gives no way to tell which rows were short, this counts
#' fields per line itself and reports how many rows were touched.
#'
#' @param path File to read. If it ends in .sas7bdat it is read with
#'   \code{haven::read_sas} instead of being parsed as whitespace text.
#' @param col_names Character vector giving the expected columns.
#' @param sep Field separator passed to \code{strsplit}. NULL or "" splits on
#'   runs of whitespace (the SAS text-export case).
#' @param skip Number of leading lines to drop (e.g. a header SAS left in).
#' @param na Strings to treat as NA.
#' @return A data.frame with exactly \code{length(col_names)} columns and
#'   attributes \code{n_padded} and \code{n_truncated} giving the row counts
#'   that were short or long.
read_irregular <- function(path, col_names, sep = NULL, skip = 0,
                            na = c("NA", "")) {
  expected <- length(col_names)
  if (expected == 0) stop("col_names must have at least one column name.")

  if (grepl("\\.sas7bdat$", path, ignore.case = TRUE)) {
    if (!requireNamespace("haven", quietly = TRUE)) {
      stop("Reading .sas7bdat files requires the 'haven' package.")
    }
    data <- as.data.frame(haven::read_sas(path), stringsAsFactors = FALSE)
    actual <- ncol(data)
    if (actual < expected) {
      data[, (actual + 1):expected] <- NA
      n_padded <- nrow(data)
      n_truncated <- 0L
    } else if (actual > expected) {
      data <- data[, seq_len(expected), drop = FALSE]
      n_truncated <- nrow(data)
      n_padded <- 0L
    } else {
      n_padded <- 0L
      n_truncated <- 0L
    }
    colnames(data) <- col_names
  } else {
    lines <- readLines(path, warn = FALSE)
    if (skip > 0) lines <- lines[-seq_len(min(skip, length(lines)))]
    lines <- lines[nzchar(trimws(lines))]

    if (length(lines) == 0) {
      data <- as.data.frame(
        matrix(character(0), nrow = 0, ncol = expected),
        stringsAsFactors = FALSE
      )
      colnames(data) <- col_names
      attr(data, "n_padded") <- 0L
      attr(data, "n_truncated") <- 0L
      return(data)
    }

    fields <- if (is.null(sep) || sep == "") {
      strsplit(trimws(lines), "\\s+")
    } else {
      strsplit(lines, sep, fixed = TRUE)
    }

    n_fields <- vapply(fields, length, integer(1))
    n_padded <- sum(n_fields < expected)
    n_truncated <- sum(n_fields > expected)

    fields <- lapply(fields, function(row) {
      if (length(row) < expected) {
        row <- c(row, rep(NA_character_, expected - length(row)))
      } else if (length(row) > expected) {
        row <- row[seq_len(expected)]
      }
      row
    })

    data <- as.data.frame(do.call(rbind, fields), stringsAsFactors = FALSE)
    colnames(data) <- col_names
    rownames(data) <- NULL
    data[] <- lapply(data, utils::type.convert, as.is = TRUE, na.strings = na)
  }

  attr(data, "n_padded") <- n_padded
  attr(data, "n_truncated") <- n_truncated
  data
}

# Reads one file and tags it with its source. Defined at top level (not
# nested inside convert_files) and takes every setting as an explicit
# argument, rather than closing over convert_files' local frame -- that frame
# also holds the cluster object itself, and shipping it to workers via a
# captured environment is fragile under PSOCK serialization.
.read_one_file <- function(f, col_names, sep, skip, na, source_col) {
  d <- read_irregular(f, col_names = col_names, sep = sep, skip = skip, na = na)
  if (isTRUE(source_col)) d$source_file <- basename(f)
  d
}

#' Convert a directory of irregular files into one CSV.
#'
#' Files are read in the order \code{list.files} returns them (alphabetical,
#' stable across serial and parallel runs since \code{parLapply} preserves
#' input order) and written to \code{out} in batches of \code{cores} files (one file at a time
#' when serial) via \code{data.table::fwrite(..., append = TRUE)}, so the
#' whole set is never held in memory as one \code{rbind}ed data.frame the way
#' the legacy script did. \code{return_data = TRUE} opts back in to holding it.
#'
#' @param dir Directory to search.
#' @param pattern Regex passed to \code{list.files}.
#' @param col_names Character vector of expected column names.
#' @param out Output CSV path, or NULL to skip writing.
#' @param cores Number of worker processes. 1 (the default) runs serially
#'   with no cluster at all; >1 opens a PSOCK cluster that is always closed
#'   via \code{on.exit}, even on error.
#' @param source_col If TRUE (default) add a \code{source_file} column.
#' @param append If TRUE, append to an existing \code{out} instead of
#'   overwriting it.
#' @param return_data If TRUE, also return the combined data.frame. Leave
#'   FALSE for large file sets; the CSV is written either way.
#' @return Invisibly, a list with \code{files}, \code{n_files}, \code{n_rows},
#'   \code{n_padded}, \code{n_truncated}, \code{out}, and \code{data} when
#'   \code{return_data} is TRUE.
convert_files <- function(dir, pattern, col_names, out, cores = 1,
                           sep = NULL, skip = 0, na = c("NA", ""),
                           source_col = TRUE, append = FALSE,
                           return_data = FALSE) {
  files <- list.files(path = dir, pattern = pattern, full.names = TRUE)
  if (length(files) == 0) {
    stop(sprintf(
      "No files in '%s' matched pattern '%s'.", dir, pattern
    ))
  }

  cores <- max(1, cores)
  read_batch <- lapply
  if (cores > 1) {
    cl <- parallel::makeCluster(cores) # PSOCK by default, works on Windows
    on.exit(parallel::stopCluster(cl), add = TRUE)
    # Workers start with an empty global environment, so read_irregular has
    # to be shipped over explicitly; everything else .read_one_file needs is
    # passed as an ordinary argument below, not captured from an enclosing
    # frame.
    parallel::clusterExport(cl, "read_irregular", envir = environment(convert_files))
    read_batch <- function(X, FUN, ...) parallel::parLapply(cl, X, FUN, ...)
  }

  if (!is.null(out) && file.exists(out) && !append) file.remove(out)

  n_padded <- 0
  n_truncated <- 0
  n_rows <- 0
  kept <- list()
  # Read `cores` files at a time and write them before reading the next
  # batch, so at most `cores` chunks are ever in memory.
  for (batch in split(files, ceiling(seq_along(files) / cores))) {
    chunks <- read_batch(
      batch, .read_one_file,
      col_names = col_names, sep = sep, skip = skip, na = na, source_col = source_col
    )
    for (chunk in chunks) {
      n_padded <- n_padded + attr(chunk, "n_padded")
      n_truncated <- n_truncated + attr(chunk, "n_truncated")
      n_rows <- n_rows + nrow(chunk)
      if (!is.null(out)) data.table::fwrite(chunk, out, append = file.exists(out))
    }
    if (isTRUE(return_data)) kept <- c(kept, chunks)
  }

  if (n_padded > 0 || n_truncated > 0) {
    message(sprintf(
      "convert_files: %d row(s) padded, %d row(s) truncated across %d file(s).",
      n_padded, n_truncated, length(files)
    ))
  }

  result <- list(
    files = files, n_files = length(files), n_rows = n_rows,
    n_padded = n_padded, n_truncated = n_truncated, out = out
  )

  if (isTRUE(return_data)) {
    combined <- do.call(rbind, kept)
    rownames(combined) <- NULL
    result$data <- combined
  }

  invisible(result)
}
