#' Run SWAT+
#'
#' This function allows to run a SWAT+ project in parallel from within R.
#' Basic settings for the SWAT run such as the simulation period or the time
#' interval for the outputs can be done directly. SWAT simulation outputs can be
#' defined that are returned for defined parameter sets.
#'
#' @param project_path Path to the SWAT project folder (i.e. TxtInOut)
#' @param output Define the output variables to extract from the SWAT model
#'   runs. See function \code{\link{define_output}} help file to see how to
#'   define an output.
#' @param parameter (optional) SWAT model parameters either provided as named
#'   vector or data.frame. If \code{parameter} is provided respective parameters
#'   are modified accordingly.
#' @param start_date (optional) Start date of the SWAT simulation. Provided as
#'   character string in any ymd format (e.g. 'yyyy-mm-dd') or in Date format
#'   project are located.
#' @param end_date (optional) End date of the SWAT simulation. Provided as
#'   character string in any ymd format (e.g. 'yyyy-mm-dd') or in Date format
#'   project are located
#' @param output_interval (optional) Time interval in which the SWAT model
#'   outputs are written. Provided either as character string ("d" for daily,
#'   "m" for monthly, or "y" for yearly) or as SWAT input values (0 for monthly,
#'   1 for daily, 2 for yearly).
#' @param years_skip (optional) Integer value that provides the numbe of years
#'   to be skipped during writing the SWAT model outputs
#' @param run_index (optional) Numeric vector (e.g.\code{run_index = c(1:100,
#'   110, 115)}) to run a subset of the provided \code{parameter} sets. If NULL
#'   all provided parameter sets are used.
#' @param run_path (optional) Character string that provides the path where the
#'   '.model_run' folder is written and the SWAT models are executed. If NULL
#'   '.model_run' is built in the project folder.
#' @param n_thread (optional) Number of threads to be used for the parallel
#'   model run. If not provided models are run on single core
#' @param save_path (optional) Character string to define the path where the
#'   model runs are saved if save_file is defined. If \code{save_path = NULL}
#'   the \code{save_file} is saved in the project_path.
#' @param save_file (optional) Character string to define the name of the file
#'   where the simulations are saved.
#' @param return_output (optional) Logical. Whether outputs should be returned
#'   or not. Set \code{return_out = FALSE} and provide \code{save_file} if
#'   outputs should only be saved on hard drive.  \code{Default = TRUE}
#' @param add_date (optional) Logical. If \code{add_date = TRUE} a date column
#'   is added to every simulatiuon output table.  \code{Default = TRUE}
#' @param add_parameter (optional) Logical. If \code{add_parameter = TRUE}
#'   used parameter sets are saved and/or returned together with the model
#'   outputs.  \code{Default = TRUE}
#' @param refresh (optional) Logical. \code{refresh = TRUE} always forces that
#'   '.model_run' is newly written when SWAT run ins started. \code{Default =
#'   TRUE}
#' @param keep_folder (optional) Logical. If \code{keep_folder = TRUE}
#'   '.model_run' is kept and not deleted after finishing model runs. In this
#'   case '.model_run' is reused in a new model run if \code{refresh = FALSE}.
#'   \code{Default = FALSE}
#' @param quiet (optional) Logical. If \code{quiet = TRUE} no messages are
#'   written.  \code{Default = FALSE}
#'
#' @return Returns the simulation results for the defined output variables as a
#'   tibble. If more than one parameter set was provided the list of tibbles is
#'   returned where each column is a model run and each list entry is an output
#'   variable.
#'
#' @importFrom doSNOW registerDoSNOW
#' @importFrom dplyr %>%
#' @importFrom foreach foreach %dopar%
#' @importFrom lubridate now
#' @importFrom parallel detectCores makeCluster parSapply stopCluster
#' @importFrom pasta %//%
#' @importFrom tibble tibble
#' @export

run_swatplus <- function(project_path, output, parameter = NULL,
                         start_date = NULL, end_date = NULL,
                         output_interval = NULL, years_skip = NULL,
                         run_index = NULL, run_path = NULL,
                         n_thread = NULL, save_path = NULL,
                         save_file = NULL, return_output = TRUE,
                         add_parameter = TRUE, add_date = TRUE,
                         refresh = TRUE, keep_folder = FALSE, quiet = FALSE) {

  #-------------------------------------------------------------------------------
  # Check settings before starting to set up '.model_run'
  ## Check if all parameter names exist in the Absolute_SWAT_Value.txt
  if(!is.null(parameter)) {
    parameter <- format_swatplus_parameter(parameter)

    # here would be clever to implement parameter boundary checkup
    # keep parameter boundary file in R package and write to project folder when
    # it does not exist. Otherwise read boundary file from there and do check!
  }
  ## Check values provided with run_index and prepare run_index for simulation
  if(!is.null(run_index)){
    run_index <- check_run_index(run_index, parameter$values)
  } else {
    run_index <- 1:max(nrow(parameter$values), 1)
  }

  ## Check if save file already exists
  if(!is.null(save_file)) {
    if(file.exists(save_file)) stop("'save_file' allready exists in provided path!")
  }

  ## General function input checks
  stopifnot(is.character(project_path))
  stopifnot(is.character(run_path)|is.null(run_path))
  stopifnot(is.numeric(n_thread)|is.null(n_thread))
  stopifnot(is.logical(add_parameter))
  stopifnot(is.logical(add_date))
  stopifnot(is.logical(return_output))
  stopifnot(is.logical(refresh))
  stopifnot(is.logical(keep_folder))
  stopifnot(is.logical(quiet))

  ## Read and modify the projects' file.cio, internal variable checks done.
  # file_cio <- modify_file_cio(project_path, start_date, end_date,
  #                             output_interval, years_skip,
  #                             rch_out_var, sub_out_var,
  #                             hru_out_var, hru_out_nr)

  ## Convert output to named list in case single unnamed output was defined
  output <- check_output(output)
  #-------------------------------------------------------------------------------
  # Build folder structure where the model will be executed
  ## Identify the required number of parallel threads to build.
  n_thread <- min(max(nrow(parameter$values),1),
                  max(n_thread,1),
                  detectCores())

  ## Set the .model_run folder as the run_path
  if(is.null(run_path)){
    run_path <- project_path%//%".model_run"
  } else {
    run_path <- run_path%//%".model_run"
  }

  ## Case .model_run exists already and no forced refresh considered
  if(dir.exists(run_path) & !refresh) {
    ## Check how many parallel threads are available
    n_thread_avail <- dir(run_path) %>%
      substr(.,(nchar(.) - 7), nchar(.)) %>%
      grepl("thread_",.) %>%
      sum()
    ## The existing folder strucuture is used when more parallel folders are
    ## available than parallel threads are needed
    if(n_thread_avail >= n_thread) {
      if(!quiet) {
        message("Model will be executed in existing '.model_run' folder structure"%&%
                  "\nMake shure '.model_run' is up to date with the project folder!")
      }
      ## If the number of available parallel folders is not sufficient
      ## a new setup of the folder structures is forced
    } else {
      unlink(run_path, recursive = TRUE)
      if(!quiet) {
        message("The number of existing threads is lower than the required number."%&%
                  "\nParallel folder structure will be created from scratch!\n\n")
      }
      build_model_run(project_path, run_path, n_thread, abs_swat_val, quiet)
    }
    ## Build the parallel folder structure if it does not exist or if a
    ## forced refresh was set with refresh = TRUE
  } else {
    unlink(run_path, recursive = TRUE)
    build_model_run(project_path, run_path, n_thread, abs_swat_val, quiet)
  }
  #-------------------------------------------------------------------------------
  # Write files
  ## Write file.cio
  write_run_files(run_path, run_files)

  ## Initialize the save_file if defined
  if(!is.null(save_file)) {
    save_path <- set_save_path(project_path, save_path, save_file)
    initialize_save_file(save_path, parameter, file_cio)
  }

  #-------------------------------------------------------------------------------
  # Initiate foreach loop to run SWAT models
  ## make and register cluster, create table that links the parallel worker
  ## with the created parallel thread folders in '.model_run'
  cl <- makeCluster(n_thread)
  worker <- tibble(worker_id = parSapply(cl, 1:n_thread,
                                         function(x) paste(Sys.info()[['nodename']],
                                                           Sys.getpid(), sep = "-")),
                   thread_id = dir(run_path) %>% .[grepl("thread_",.)])

  registerDoSNOW(cl)
  #-------------------------------------------------------------------------------
  # Start parallel SWAT model execution with foreach

  ## If not quiet a function for displaying the simulation progress is generated
  ## and provided to foreach via the SNOW options
  n_run <- max(nrow(parameter$values), 1)
  if(!quiet) {
    cat("Performing", n_run, ifelse(n_run == 1, "simulation", "simulations"),
        "on", n_thread, "cores:", "\n")
    t0 <- now()
    progress <- function(n){
      display_progress(n, n_run, t0, "Simulation")
    }
    opts <- list(progress = progress)
  } else {
    opts <- list()
  }

  sim_result <- foreach(i_run = 1:n_run,
    .packages = c("dplyr", "pasta", "lubridate"), .options.snow = opts) %dopar% {
    # for(i_run in 1:max(nrow(parameter), 1)) {
    ## Identify worker of the parallel process and link it with respective thread
    worker_id <- paste(Sys.info()[['nodename']], Sys.getpid(), sep = "-")
    thread_id <- worker[worker$worker_id == worker_id, 2][[1]]
    thread_path <- run_path%//%thread_id
    # thread_path <- "D:/UnLoadC3/00_SW_SWAT/model_struct/sb03_thru/.model_run/thread_1"

    ## Modify model parameters if parameter set was provided and write
    ## calibration file
    if(!is.null(parameter)) {
      write_calibration(thread_path, parameter, run_files$calibration.cal, i_run)
    }

    ## Execute the SWAT exe file located in the thread folder
    system(thread_path%//%"swat_run.bat")

    model_output <- read_swatplus_output(output, thread_path) %>%
      extract_output(output, .)

    if(!is.null(save_path)) {
      save_run(save_path, model_output, parameter, i_run, thread_id)
    }

    return(model_output)
  }

  ## Stop cluster after parallel run
  stopCluster(cl)

  ## Show total runs and elapsed time in console if not quiet
  if(!quiet) {
    finish_progress(n_run, t0, "simulation")
    ## Delete the time stamp t0 created for the progress estimation
    rm(t0)
  }

  ## Delete the parallel threads if keep_folder is not TRUE
  if(!keep_folder)unlink(run_path, recursive = TRUE)

  ##Tidy up and return simulation results if return_output is TRUE
  if(return_output) {
    date <- read_date(file_cio)
    sim_result <- tidy_results(sim_result, parameter, date, add_parameter,
                               add_date)
    return(sim_result)
  }
}