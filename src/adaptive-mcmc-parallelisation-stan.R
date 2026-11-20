
get_mcmc_median_runtimes <- function(
  input_model = NULL, input_data = NULL, min_cores = 1, max_cores = 1,
  min_chains = 1, max_chains = 4, num_evals = 1, num_warmup = NULL,
  num_iter = NULL, input_seed = -1, bool_hyperthreaded, progress_comment = ""
) {

  # This function gets the median runtimes of Stan chains parallelised over
  # different numbers n of cores. Stan options can then be adjusted for
  # efficiency accordingly.
  #
  # Best results will be obtained when the performance testing code and data
  # closely reflects the target application environment.
  #
  # Notes:
  #
  #   - Setting n > 1, but low (e.g. 2) can hurt performance, as the overheads
  #     of parallelisation can exceed the gains from computation distribution.
  #
  #   - Setting n so high it hurts performance is possible if it's difficult to
  #     dynamically distinguish between logical and physical cores (as is the
  #     case for results returned from parallel::detectCores() on some systems),
  #     and parallelisation over high n logical cores is slower than low n
  #     physical cores.
  #
  #   - Consider benchmarking multiple times for every comparison, to give some
  #     test-retest reliability.
  #
  #
  # Parameters:
  #   input_model  stanmodel; Stan model.
  #   input_data   model-specific data; Stan model data.
  #   min_cores    numeric; minimum number of cores to use.
  #   max_cores    numeric; maximum number of cores to use.
  #   min_chains   numeric; minimum number of Markov chains to use.
  #   max_chains   numeric; maximum number of Markov chains to use.
  #   num_evals    numeric; number of evaluations to run per microbenchmark.
  #   num_warmup   numeric; number of warmup iterations per chain.
  #   num_iter     numeric; number of iterations per chain.
  #   input_seed   numeric; a Stan RNG seed.
  #   bool_hyperthreaded  logical; specifies if hyperthreading is active.
  #   progress_comment character; a comment to append to progress messages.
  #
  #
  # Return a list holding:
  #    - a vector of microbenchmark median evaluation times.
  #    - a vector of benchmark start times.
  #    - a vector of benchmark end times.
  #    - the fastest number of cores to use.
  #    - the fastest number of chains to use.
  #
  #
  # Roxygen-formatted example:
  #` # Avoid recompilation of unchanged Stan programs.
  #` rstan::rstan_options(auto_write = TRUE)
  #`
  #` model_simple <- "data {real y_mean;}
  #`   parameters {real y;}
  #`   model {y ~ normal(y_mean, 1);}"
  #` stan_model_simple <- rstan::stan_model(
  #`   model_code = model_simple, save_dso = FALSE)
  #` get_mcmc_median_runtimes(
  #`   input_model = stan_model_simple,
  #`   input_data = list(y_mean = 0),
  #`   min_cores = 1,
  #`   max_cores = 2,
  #`   min_chains = 4,
  #`   max_chains = 5,
  #`   num_evals = 1,
  #`   num_warmup = 80,
  #`   num_iter = 160,
  #`   input_seed = 1,
  #`   bool_hyperthreaded = FALSE,
  #`   progress_comment = "")


  # Ensure lower cores and chains bounds don't exceed the upper bounds.
  stopifnot(min_cores <= max_cores, min_chains <= max_chains)

  # Restrict parallelisation to the input specified number of max_cores.
  #
  # N.B. Using 'logical = FALSE' detects physical cores.
  #      Using 'logical = TRUE' (the default) detects logical cores.
  #
  active_cores <- parallel::detectCores(logical = bool_hyperthreaded)
  if (active_cores > max_cores) {
    active_cores <- max_cores
  }

  # RStan parallelises over the number of Markov chains (four by default).
  # So, unless the number of chains has been manually changed, throttle
  # parallelisation.
  #
  if (active_cores > max_chains) {
    active_cores <- max_chains
  }

  # Here a 'sampling' call is used with a compiled stan model (produced earlier
  # with 'stan_model') instead of using a 'stan' call. Maintaining an explicit
  # reference to a compiled stan model stops it getting garbage collected, in
  # turn preventing "recompiling to avoid crashing R session" operations. If
  # a single 'stan' call was used here instead, the compiled model would be
  # eligible for garbage collection after each evaluation of microbenchmark.
  #
  # N.B. The 'rstan_options(auto_write = TRUE)' call during setup only prevents
  # recompilation of unchanged AND un-garbage collected stan models.

  # Allocate space for benchmarking results.
  benchmark_results <- vector()
  for (i in min_cores:active_cores) {
    for (j in min_chains:max_chains) {
      if (i <= j) {
        benchmark_results <- append(benchmark_results, NA)
      }
    }
  }
  start_times <- benchmark_results
  end_times <- benchmark_results

  # Perform benchmarking over different numbers of cores and chains.
  #
  benchmark_min <- Inf
  chains_fastest <- 0
  cores_fastest <- 0
  counter <- 0
  #
  for (i in min_cores:active_cores) {
    options(mc.cores = i)

    for (j in min_chains:max_chains) {
      # Set default benchmarking time unit to seconds.
      # Remember, microbenchmark does (needed) warmup iterations.

      # Only evaluate when num cores <= num chains.
      if (i <= j) {

        counter <- counter + 1

        # Give a progress indication.
        cat("get_mcmc_median_runtimes progress: evaluating cores = ", i,
            ", chains = ", j, "...", progress_comment, "\n", sep = "")

        start_times[counter] <- Sys.time()
        if (input_seed < 0) {
          # Unseeded.
          benchmark_results[counter] <- summary(
            microbenchmark::microbenchmark(
              rstan::sampling(
                input_model,
                data = input_data,
                chains = j,
                warmup = num_warmup,
                iter = round(((num_iter - num_warmup) / j) + num_warmup)
              ),
              times = num_evals, unit = "s"
            )
          )$median

        } else {
          # Seeded.
          benchmark_results[counter] <- summary(
            microbenchmark::microbenchmark(
              rstan::sampling(
                input_model,
                data = input_data,
                chains = j,
                warmup = num_warmup,
                iter = round(((num_iter - num_warmup) / j) + num_warmup),
                seed = input_seed
              ),
              times = num_evals, unit = "s"
            )
          )$median
        }
        end_times[counter] <- Sys.time()


        # Check for fastest combination of cores and chains.
        if (benchmark_results[[counter]] < benchmark_min) {
          benchmark_min <- benchmark_results[[counter]]
          cores_fastest <- i
          chains_fastest <- j
        }
        # Print results in units of seconds.
        cat("# cores = ", i, ", # chains = ", j,
            ", median runtime = ", benchmark_results[[counter]],
            " seconds. (# evaluations = ", num_evals, ")\n", sep = "")

      }
    }
  }

  # Return the median run times.
  list("medians" = benchmark_results,
       "start" = start_times, "end" = end_times,
       "cores_fastest" = cores_fastest, "chains_fastest" = chains_fastest)
}


get_mcmc_optimum_config <- function(stan_model_input, stan_data_input) {

  # This function should be used to implement adaptive MCMC parallelisation.
  # An optimum number of cores and chains to process a stan model are returned.
  #
  #
  # Parameters:
  #   stan_model_input  stanmodel; Stan model.
  #   stan_data_input   model-specific data; Stan model data.
  #
  #
  # Return:
  #   a list with the optimum number of chains and cores.
  #
  #
  # Roxygen-formatted example:
  #` # Avoid recompilation of unchanged Stan programs.
  #` rstan::rstan_options(auto_write = TRUE)
  #`
  #` model_simple <- "data {real y_mean;}
  #`   parameters {real y;}
  #`   model {y ~ normal(y_mean, 1);}"
  #` stan_model_simple <- rstan::stan_model(model_code = model_simple,
  #`                                        save_dso = FALSE)
  #` get_mcmc_optimum_config(
  #`   stan_model_input = stan_model_simple,
  #`   stan_data_input = list(y_mean = 0))


  # Dynamically set the number of physical cores.
  # Note, these must be set to a maximum of two during package compilation
  # checks activated by check(). CRAN builds in this restriction.
  cran_check <- Sys.getenv("_R_CHECK_LIMIT_CORES_", "")
  if (nzchar(cran_check) && cran_check == "TRUE") {
    # Allow for single core machines.
    num_physical_cores <- min(2, parallel::detectCores(logical = FALSE))
  } else {
    num_physical_cores <- parallel::detectCores(logical = FALSE)
  }

  benchmarks <- get_mcmc_median_runtimes(
    input_model = stan_model_input,
    input_data = stan_data_input,
    min_cores = 1,
    max_cores = num_physical_cores,
    min_chains = 4,
    max_chains = max(4, num_physical_cores),   # Use >= four on all hardware.
    num_evals = 1,
    num_warmup = 80,   # The RStan default is num_iter/2.
    num_iter = 160,    # 2000 is the RStan default.
    input_seed = 1,
    bool_hyperthreaded = FALSE,
    progress_comment = "(warmups = 80)"
  )

  # Process benchmarks.
  list(optimum_chains = benchmarks$chains_fastest,
       optimum_cores = benchmarks$cores_fastest)
}
