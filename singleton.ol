from console import Console
from scheduler import Scheduler
from file import File
from runtime import Runtime
from time import Time
from .loader import LoaderAPI
from .function import FunctionAPI
from .provisioner import ProvisionerAPI
from .function_catalog import FunctionCatalogAPI
from .executor import ExecutorAPI
from .scheduler import SchedulerCallBackInterface

type SingletonParams {
  singletonName: string
  singletonLocation: string
  advertiseLocation: string
  functionCatalogLocation: string
  provisionerLocation: string
  function: string
  verbose: bool
  debug: bool
}

type RunRequest {
  data?: undefined
}

type RunResponse {
  error: bool
  data?: undefined
}

constants {
  SINGLETON_FUNCTION_PATH = "/tmp/fn.ol",
  DRAIN_POLL_MS = 250,
  DRAIN_TIMEOUT_MS = 30000
}

service Singleton( p : SingletonParams) {
  execution: concurrent
  embed Console as Console
  embed Scheduler as Scheduler
  embed File as File
  embed Runtime as Runtime
  embed Time as Time
  
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

  outputPort Embedded {
    protocol: sodep
    interfaces: FunctionAPI
  }

  outputPort Provisioner {
    location: p.provisionerLocation
    protocol: sodep
    interfaces: ProvisionerAPI
  }

  inputPort SingletonInput {
    location: p.singletonLocation
    protocol: sodep
    interfaces: ExecutorAPI, FunctionAPI
  }

  inputPort SchedulerCallBack {
    location: local
    interfaces: SchedulerCallBackInterface
  }

  define drain_and_exit {
    global.draining = true
    drainStart = getCurrentTimeMillis@Time()
    drainElapsed = 0
    while(global.activeCalls > 0 && drainElapsed < DRAIN_TIMEOUT_MS) {
      if(p.debug) {
        println@Console("Draining, " + global.activeCalls + " call(s) still in flight")()
      }
      sleep@Time(DRAIN_POLL_MS)()
      drainElapsed = getCurrentTimeMillis@Time() - drainStart
    }
    if(global.activeCalls > 0) {
      println@Console("Drain timeout reached with " + global.activeCalls + " call(s) still in flight, exiting anyway")()
    } else {
      println@Console("Drained, no calls left in flight. Quitting...")()
    }
    stop@Parent()()
  }

  init {
    enableTimestamp@Console(true)()

    prep_failed = false
    println@Console("Downloading function: " + p.function)()
    scope(prepare) {
      install(
        FunctionNotFound => {
          println@Console("Could not find function \"" + p.function + "\" in the catalog: " + prepare.FunctionNotFound)()
          prep_failed = true
        },
        BackendUnavailable => {
          println@Console("Could not download function \"" + p.function + "\": " + prepare.BackendUnavailable)()
          prep_failed = true
        },
        IOException => {
          println@Console("I/O error while preparing function \"" + p.function + "\": " + prepare.IOException)()
          prep_failed = true
        },
        Timeout => {
          println@Console("Timed out while preparing function \"" + p.function + "\"")()
          prep_failed = true
        },
        RuntimeException => {
          println@Console("Could not load function \"" + p.function + "\": " + prepare.RuntimeException)()
          prep_failed = true
        },
        default => {
          println@Console("Unexpected error while preparing function \"" + p.function + "\" (fault: " + prepare.default + ")")()
          prep_failed = true
        }
      )
      get@FunctionCatalog({
        name = p.function
      })(code)
      writeFile@File({
        filename = SINGLETON_FUNCTION_PATH
        format = "text"
        content = code
      })()

      println@Console("Embedding " + SINGLETON_FUNCTION_PATH)()
      loadEmbeddedService@Runtime({
        filepath = SINGLETON_FUNCTION_PATH
        type = "jolie"
      })(loc)
      Embedded.location = loc
    }

    if(prep_failed) {
      stop@Parent()()
    } else {
      println@Console("Attaching to provisioner at " + Provisioner.location)()
      register@Provisioner({
        type = "singleton"
        name = p.singletonName
        commsLocation = p.advertiseLocation
        invokeLocation = p.advertiseLocation
        function = p.function
      })()

      global.lastPing = true
      global.draining = false
      global.activeCalls = 0
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
      println@Console("Listening on " + p.singletonLocation + " (advertise: " + p.advertiseLocation + ")")()
    }
  }

  main {
    [ping( request )( response ) {
      response = request
      global.lastPing = true
    }]

    [schedulerCallback(request)] {
      if(!global.lastPing) {
        println@Console("Didn't receive a ping for more than 10 seconds, assuming the provisioner is dead. Quitting")()
        stop@Parent()()
      }
      global.lastPing = false
    }

    [stop()() {
      println@Console("Stop signal has been received. Draining in-flight calls before quitting...")()
      drain_and_exit
    }]

    [fn( request )( response ) {
      if(global.draining) {
        throw( ExecutorDraining, "the executor of this function is shutting down, please retry" )
      }

      global.activeCalls++
      scope( call_function ) {
        install(
          TypeMismatch => {
            global.activeCalls--
            throw( TypeMismatch, call_function.TypeMismatch )
          },
          InvocationFault => {
            global.activeCalls--
            throw( InvocationFault, call_function.InvocationFault )
          },
          Timeout => {
            global.activeCalls--
            throw( Timeout, call_function.Timeout )
          },
          IOException => {
            global.activeCalls--
            throw( IOException, call_function.IOException )
          },
          RuntimeException => {
            global.activeCalls--
            throw( RuntimeException, call_function.RuntimeException )
          },
          default => {
            global.activeCalls--
            throw( TypeMismatch, "Function threw fault \"" + call_function.default + "\": " + call_function.(call_function.default) )
          }
        )
        fn@Embedded( request )( response )
      }
      global.activeCalls--
    }]
  }
}
