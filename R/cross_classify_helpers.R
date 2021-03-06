panel_dfs <- function(dfs) {
  # Error handling
  if (is.data.frame(dfs) || length(dfs) < 2) {
    stop("You must specify at least two data frames in a `cross_levels()` ",
         "call.")
  }

  # Do repeated merges
  base <- dfs[[1]]
  for (i in seq.int(from = 2, to = length(dfs))) {
    base <- merge(base, dfs[[i]], by = NULL, all = TRUE)
  }

  base
}

join_dfs <- function(dfs, variables, N, sigma=NULL, rho=0) {
  # Error handling
  if (is.data.frame(dfs)) {
    stop("You must specify at least two data frames in a `link_levels()` call.")
  }
  if (length(dfs) != length(variables)) {
    stop("You must define which variables to join in a `link_levels()` call.")
  }
  if (length(variables) < 2) {
    stop("You must define at least two variables to join on in a ",
         "`link_levels()` call.")
  }

  # Create the data list -- the subset from the dfs of the variables we're
  # joining on -- for each df in dfs, map it to a variable. Subset the df to
  # that variable. Unlist and unname, creating a vector. Plonk that in a
  # data_list
  data_list <- Map(function(x, y) {
    unname(unlist(x[y]))
  }, dfs, variables)

  # Do the joint draw
  result <- joint_draw_ecdf(
    data_list = data_list,
    N = N,
    sigma = sigma,
    rho = rho
  )

  # result now contains a matrix of indices. Each column of this matrix is
  # the indices for each df of dfs. Subset by row the df. This will return
  # a list of new dfs. We need to cbind these dfs to make the merged data.
  merged_data <- do.call(
    cbind.data.frame,
    Map(
      function(df, indices) {
        df[indices, ]
      },
      dfs,
      result
    )
  )

  # Cleanup: remove row names
  rownames(merged_data) <- NULL
  # Re-write the column names to be the original column names from the original
  # dfs.
  colnames(merged_data) <- unname(unlist(lapply(dfs, colnames)))

  merged_data
}

joint_draw_ecdf <- function(data_list, N, ndim=length(data_list),
                            sigma=NULL, rho=0, use_f = TRUE) {

  # We don't modify data_list, but this is useful to ensure the
  # argument is evaluated anyway
  force(ndim)

  # Error handling for N
  if (is.null(N) || is.na(N) || !is.atomic(N) || length(N) > 1 || N <= 0) {
    stop("N for `link_levels()` calls must be a single integer that is ",
         "positive.")
  }

  # Error handling for rho, if specified
  if (is.null(sigma)) {
    if (is.atomic(rho) & length(rho) == 1) {

      if (rho == 0) {
        # Uncorrelated draw would be way faster; just sample each column
        return(lapply(
          seq_along(data_list),
          function(vn) {
            sample.int(length(data_list[[vn]]), N, replace = TRUE)
          }
        ))
      }
      sigma <- matrix(rho, ncol = ndim, nrow = ndim)
      diag(sigma) <- 1
    } else {
      stop(
        "If `rho` is specified in a `link_levels()` call, it must be a single ",
        "number"
      )
    }
  }

  # Error handling for sigma
  if (ncol(sigma) != ndim | nrow(sigma) != ndim | any(diag(sigma) != 1)) {
    stop(
      "The correlation matrix must be square, with the number of dimensions ",
      "equal to the number of dimensions you are drawing from. In addition, ",
      "the diagonal of the matrix must be equal to 1."
    )
  }

  # Check if this is a symmetric matrix
  if(!isSymmetric(sigma)) {
    stop(
      "The correlation matrix `sigma` supplied to `link_levels()` must ",
      "be symmetric (the portion of the matrix below the diagonal must be ",
      "a transposition of the portion of the matrix above the diagonal), but ",
      "the supplied matrix does not satisfy that requirement."
    )
  }

  # Check if this is even plausibly a correlation matrix
  if(any(sigma < -1 | sigma > 1)) {
    stop(
      "Correlation matrix, `sigma`, supplied to `link_levels()` must ",
      "contain only values from -1 to 1. One or more of the values of your ",
      "correlation matrix was outside this range."
    )
  }

  # Check if matrix is PSD: required for correlation matrices
  if (is.complex(eigen(sigma)$values) || any(eigen(sigma)$values < 0)) {
    stop(
      "The correlation matrix, sigma, that you provided when running ",
      "`link_levels()` must be positive semi-definite. This means that ",
      "certain sets of correlations are not possible; ",
      "a common example of this is drawing from three or more variables at ",
      "once with negative correlation coefficients among each pair.\n\n"
    )
  }

  if (ndim > 2 & rho < 0) {
    stop(
      "The correlation matrix must be positive semi-definite. ",
      "Specifically, if the number of variables being drawn from jointly ",
      "is 3 or more, then the correlation coefficient rho must be ",
      "non-negative."
    )
  }

  # Can we use the fast package or are we stuck with the slow one?
  use_f <- use_f && requireNamespace("mvnfast", quietly = TRUE)

  # Standard normal = all dimensions mean 0.
  mu <- rep(0, ndim)

  # Possible options for the joint normal draw
  if (!use_f) {
    # Below code is a reimplementation of the operative parts of rmvnorm from
    # the mvtnorm package so that we don't induce a dependency

    # Right cholesky decomposition (i.e. LR = sigma s.t. L is lower triang, R
    # is upper triang.)
    right_chol <- chol(sigma, pivot = TRUE)
    # Order columns by the pivot attribute -- induces numerical stability?
    right_chol <- right_chol[, order(attr(right_chol, "pivot"))]
    # Generate standard normal data and right-multiply by decomposed matrix
    # with right_chol to make it correlated.
    correlated_sn <- matrix(
      rnorm(N * ndim),
      nrow = N
    ) %*% right_chol

    message(
      "`link_levels()` calls are faster if the `mvnfast` package is ",
      "installed."
    )
  } else {
    # Using mvnfast
    correlated_sn <- mvnfast::rmvn(N,
                                   ncores = getOption("mc.cores", 2L),
                                   mu, sigma)
  }

  # Z-scores to quantiles
  quantiles <- pnorm(correlated_sn)
  colnames(quantiles) <- names(data_list)

  # Quantiles to inverse eCDF.
  result <- lapply(
    seq_along(data_list),
    function(vn) {
      # What would the indices of the quantiles be if our data was ordered --
      # if the answer is below 0, set it to 1. round will ensure the tie-
      # breaking behaviour is random with respect to outcomes
      ordered_indices <- pmax(
        1,
        round(quantiles[, vn] * length(data_list[[vn]]))
      )

      # Now get the order permutation vector and map that to the ordered indices
      # to get the indices in the original space
      indices <- order(data_list[[vn]])[ordered_indices]
    }
  )


  # Set up response
  result
}
