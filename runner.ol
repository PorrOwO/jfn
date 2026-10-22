from console import Console
from scheduler import Scheduler
from string_utils import StringUtils
from file import File
from runtime import Runtime
from .loader import LoaderAPI
from .function import FunctionAPI
from .provisioner import ProvisionerAPI
from .function_catalog import FunctionCatalogAPI
from .executor import ExecutorAPI
from .scheduler import SchedulerCallBackInterface

type RunnerParams {
  runnerName: string
  runnerLocation: string
  advertiseLocation: string
  functionCatalogLocation: string
  provisionerLocation: string
  verbose: bool
  debug: bool
}

type RunRequest {
  name: string
  data?: undefined
}

type RunResponse {
  error: bool
  data?: undefined
}

interface RunnerAPI {
  RequestResponse:
    run( RunRequest )( RunResponse ),
}

constants {
  RUNNER_FUNCTIONS_PATH = "/tmp/jfn",
}

define derive_filename {
  filename = RUNNER_FUNCTIONS_PATH + sep + request.name + "-" + hash + ".ol"
}

service Runner( p : RunnerParams ) {
  execution: concurrent
  embed Console as Console
  embed Scheduler as Scheduler
  embed File as File
  embed Runtime as Runtime
  embed StringUtils as StringUtils

  outputPort Parent {
    location: "local://loader"
    protocol: sodep
    interfaces: LoaderAPI
  }

  outputPort FunctionCatalog {
    location: p.functionCatalogLocation
    protocol: sodep
    interfaces: FunctionCatalogAPI
  }

  outputPort Provisioner {
    Location: p.provisionerLocation
    protocol: sodep
    interfaces: ProvisionerAPI
  }

  inputPort RunnerInput {
    location: p.runnerLocation
    protocol: sodep
    interfaces: ExecutorAPI, RunnerAPI
  }

  outputPort Embedded {
    protocol: sodep
    interfaces: FunctionAPI
  }

  inputPort SchedulerCallBack {
    location: local
    interfaces: SchedulerCallBackInterface
  }

  init {
    enableTimestamp@Console(true)()
    getFileSeparator@File()(sep)

    exists@File(RUNNER_FUNCTIONS_PATH)(exists)
    if(!exists) {
      mkdir@File(RUNNER_FUNCTIONS_PATH)()
    }

    println@Console("Attaching to provisioner at " + Provisioner.location)()
    register@Provisioner({
      type = "runner"
      name = p.runnerName
      commsLocation = p.advertiseLocation
      invokeLocation = p.advertiseLocation
    })()

    global.lastPing = true
    setCronJob@Scheduler({
      jobName = "ping"
      groupName = "ping"
      cronSpecs << {
        year = "*"
        dayOfWeek = "*"
        month = "*"
        dayOfMonth = "?"
        hour = "*"
        minute = "*"
        second = "0/10"
      }
    })()
    println@Console("Listening on " + p.runnerLocation + " (advertise: " + p.advertiseLocation + ")")()
  }

  main {
    [ping( request )( response ) {
      response = request
      if(p.debug) {
        println@Console("Received a ping, sending pong")()
      }
      global.lastPing = true
    }]

    [schedulerCallback(request)] {
      if(!global.lastPing) {
        println@Console("Didn't receive a ping for more than 10 seconds, assuming the provisioner is dead. Quitting")()
        stop@Parent()()
      }
      global.lastPing = false
    }

    [run( request )( response ) {
      if(p.debug) {
        valueToPrettyString@StringUtils( request )( t )
        println@Console( "Calling: " + t )()
      }
      response.error = false

      scope(load_service) {
        install(
          FunctionNotFound => {
            response.error = true
            response.data = load_service.FunctionNotFound
          },
          BackendUnavailable => {
            response.error = true
            response.data = "Could not contact the function catalog: " + load_service.BackendUnavailable
          },
          IOException => {
            response.error = true
            response.data = "Could not contact the function catalog (to check the hash): " + load_service.IOException
          },
          Timeout => {
            response.error = true
            response.data = "Timed out contacting the function catalog (to check the hash)"
          },
          default => {
            response.error = true
            response.data = "Function catalog error (fault: " + load_service.default + ")"
          }
        )
        hash@FunctionCatalog({
          name = request.name
        })(hash)
      }
      if(!response.error) {
        derive_filename
        exists@File(filename)(exists)
        if(!exists) {
          scope(load_service) {
            install(
              FunctionNotFound => {
                response.error = true
                response.data = load_service.FunctionNotFound
              },
              BackendUnavailable => {
                response.error = true
                response.data = "Could not contact the function catalog: " + load_service.BackendUnavailable
              },
              IOException => {
                response.error = true
                response.data = "Could not contact the function catalog: " + load_service.IOException
              },
              Timeout => {
                response.error = true
                response.data = "Timed out contacting the function catalog"
              },
              default => {
                response.error = true
                response.data = "Function catalog error (fault: " + load_service.default + ")"
              }
            )
            get@FunctionCatalog({
              name = request.name
            })(function_code)
          }
          if(!response.error) {
            undef(response.data)
            scope(write_function) {
              install(
                FileNotFound => {
                  response.error = true
                  response.data = "Could not find function file or its parent directories"
                },
                IOException => {
                  response.error = true
                  response.data = "Could not write to the function file: " + write_function.IOException
                },
                default => {
                  response.error = true
                  response.data = "Could not store the function file (fault: " + write_function.default + ")"
                }
              )
              writeFile@File({
                filename = filename
                format = "text"
                content = function_code
              })()
              if(p.verbose) {
                println@Console("Wrote function to " + filename)()
              }
            }
          }
        }
        if(!response.error) {
          scope(load_service) {
            install(
              RuntimeException => {
                response.error = true
                response.data = "Could not load function service: " + load_service.RuntimeException
              },
              default => {
                response.error = true
                response.data = "Could not load function service (fault: " + load_service.default + ")"
              }
            )
            loadEmbeddedService@Runtime({
              filepath = filename
              type = "jolie"
            })(loc)
          }
        }
        if(!response.error) {
          invoke_data << request
          undef(invoke_data.name)
          scope(call_service) {
            install(
              InvocationFault => {
                response.error = true
                response.data = "Error while calling the function: " + call_service.InvocationFault.name
              },
              TypeMismatch => {
                response.error = true
                response.data = "The function failed while executing (see the runner logs for details)"
              },
              Timeout => {
                response.error = true
                response.data = "The function timed out while executing"
              },
              IOException => {
                response.error = true
                response.data = "Lost the connection to the function while executing: " + call_service.IOException
              },
              default => {
                response.error = true
                response.data = "Function invocation error (fault: " + call_service.default + ")"
              }
            )
            Embedded.location = loc
            fn@Embedded(invoke_data)(output)
            response.data << output.data
            response.error = false
            if(p.debug) {
              println@Console("Run successful")()
            }
          }
          scope(cleanup) {
            install(
              default => {
                println@Console( "Warning: could not shut down the function service (fault: " + cleanup.default + ")" )()
              }
            )
            callExit@Runtime( loc )()
          }
        }
      }
    }]

    [stop()() {
      println@Console("Stop signal has been received. Quitting...")()
      stop@Parent()()
    }]
  }
}
