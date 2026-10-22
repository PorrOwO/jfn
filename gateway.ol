from console import Console
from math import Math
from string_utils import StringUtils
from runtime import Runtime
from reflection import Reflection
from .runner import RunnerAPI
from .function import FunctionAPI
from .provisioner import ProvisionerAPI
from .function_catalog import FunctionCatalogAPI

type GatewayParams {
  gatewayLocation: string
  provisionerLocation: string
  catalogLocation: string
  verbose: bool
}

type GatewayRequest {
  fn: string
  data?: undefined
}

type GatewayResponse {
  error: bool
  data?: undefined
}

type FunctionCatalogPutRequest {
  name: string
  code: string 
}

type FunctionCatalogRemoveRequest {
  name: string
}

type FunctionCatalogResult {
  error: bool
  data: string 
}

interface GatewayAPI {
  RequestResponse:
    op( GatewayRequest )( GatewayResponse ),
    put( FunctionCatalogPutRequest )( FunctionCatalogResult ),
    remove( FunctionCatalogRemoveRequest )( FunctionCatalogResult )

}

service Gateway(p : GatewayParams) {
  execution: concurrent
  embed Console as Console
  embed Math as Math
  embed StringUtils as StringUtils
  embed Runtime as Runtime
  embed Reflection as Reflection

  inputPort GatewayInput {
    location: p.gatewayLocation
    protocol: http { format = "json" }
    interfaces: GatewayAPI
  }

  outputPort Catalog {
    location: p.catalogLocation
    protocol: sodep
    interfaces: FunctionCatalogAPI
  }

  outputPort Provisioner {
    location: p.provisionerLocation
    protocol: sodep
    interfaces: ProvisionerAPI
  }

  outputPort Runner {
    protocol: sodep
    interfaces: RunnerAPI
  }

  outputPort Singleton {
    protocol: sodep
    interfaces: FunctionAPI
  }

  init {
    enableTimestamp@Console(true)()
    println@Console("Listening on " + p.gatewayLocation)()
  }

  main {
    
    [put( request )( response ) {
      scope( put_scope ) {
        // === SANITY CHECK: What is the Gateway holding? ===
        println@Console("=== GATEWAY: INCOMING PUT REQUEST ===")()
        println@Console("DEBUG GW: request.name = " + request.name)()
        println@Console("DEBUG GW: request.code length = " + #request.code)()
        println@Console("DEBUG GW: request.code = " + request.code)()
        
        install( IOException => {
          response.error = true
          response.data = "Failed to communicate with Catalog: " + put_scope.IOException
        }, default => {
          response.error = true
          response.data = "Catalog error: " + put_scope.(put_scope.default)
        })
        
        put@Catalog( request )( catalog_res )
        
        // Check the logical result from the Catalog
        if ( catalog_res.error == true ) {
          response.error = true
          response.data = catalog_res.data
        } else {
          response.error = false
          response.data = "Function uploaded successfully"
        }
      }
    }]

    [remove( request )( response ) {
      // Tear down the function's executors first: if that fails, the catalog
      // is left untouched and invoke keeps working. If the catalog delete
      // then fails, the singletons are already gone and invocations fall
      // back to runners, which reject the removed function (hash check) --
      // self-healing either way.
      prov_failed = false
      scope( teardown ) {
        install(
          IOException => {
            prov_failed = true
            response.data = "Could not communicate with the provisioner: " + teardown.IOException
          },
          default => {
            prov_failed = true
            response.data = "Provisioner error (fault: " + teardown.default + ")"
          }
        )
        removeFunction@Provisioner({
          function = request.name
        })( prov_res )
      }

      if( prov_failed ) {
        response.error = true
      } else {
        scope( remove_from_catalog ) {
          install(
            IOException => {
              response.error = true
              response.data = "Executors were torn down, but the catalog could not be reached: " + remove_from_catalog.IOException
            },
            default => {
              response.error = true
              response.data = "Executors were torn down, but the catalog could not be reached: " + remove_from_catalog.default
            }
          )
          remove@Catalog({ name = request.name })( catalog_res )
        }

        if( !is_defined( response.error ) ) {
          if( catalog_res.error ) {
            response.error = true
            response.data = "Executors were torn down, but catalog removal failed: " + catalog_res.data
          } else {
            response.error = false
            response.data = catalog_res.data + " (" + prov_res.data + ")"
          }
        }
      }
    }]

    [op( request )( response ) {
      scope(call_executor) {
        // Catch everything: an escaping fault here would reach the HTTP
        // client as a bare TypeMismatch with no useful information.
        install(
          IOException => {
            response.error = true
            response.data = "Could not communicate with the provisioner: " + call_executor.IOException
          },
          Timeout => {
            response.error = true
            response.data = "Timed out waiting for the provisioner"
          },
          default => {
            response.error = true
            response.data = "Provisioner error (fault: " + call_executor.default + ")"
          }
        )
        executor@Provisioner({
          function = request.fn
        })(executor)
      }
      if( !is_defined( executor.type ) ) {
        // provisioner call failed
        if( !is_defined( response.error ) ) {
          response.error = true
          response.data = "Invalid response from the provisioner"
        }
      } else if(executor.type == "runner") {
        scope(call_runner) {
          install(
            TypeMismatch => {
              response.error = true
              response.data = "Internal error while talking to the runner: " + call_runner.TypeMismatch
            },
            InvocationFault => {
              response.error = true
              response.data = "Could not invoke runner: " + call_runner.InvocationFault
            },
            IOException => {
              response.error = true
              response.data = "Could not reach the runner (it may have shut down): " + call_runner.IOException
            },
            Timeout => {
              response.error = true
              response.data = "The runner did not respond in time"
            },
            default => {
              response.error = true
              response.data = "Runner error (fault: " + call_runner.default + ")"
            }
          )

          invoke_data << {
            name = request.fn
            data << request.data
          }
          if(p.verbose) {
            valueToPrettyString@StringUtils( request )( t )
            println@Console( "Sending to runner at " + executor.location)()
          }
          Runner.location = executor.location
          run@Runner(invoke_data)(response)
        }
      } else if(executor.type == "singleton") {
        scope(call_singleton) {
          install(
            ExecutorDraining => {
              response.error = true
              response.data = "The executor is shutting down, please retry: " + call_singleton.ExecutorDraining
            },
            TypeMismatch => {
              response.error = true
              response.data = "The function failed while executing: " + call_singleton.TypeMismatch + " (see the singleton logs for details)"
            },
            InvocationFault => {
              response.error = true
              response.data = "Could not invoke singleton: " + call_singleton.InvocationFault
            },
            IOException => {
              response.error = true
              response.data = "Could not reach the singleton (it may have shut down): " + call_singleton.IOException
            },
            Timeout => {
              response.error = true
              response.data = "The singleton did not respond in time"
            },
            default => {
              response.error = true
              response.data = "Singleton error (fault: " + call_singleton.default + ")"
            }
          )

          invoke_data << {
            data << request.data
          }
          if(p.verbose) {
            valueToPrettyString@StringUtils( request )( t )
            println@Console( "Sending to singleton at " + executor.location)()
          }
          Singleton.location = executor.location
          fn@Singleton(invoke_data)(response)
          response.error = false
        }
      } else if(executor.type == "error") {
        response.error = true
        if(is_defined(executor.message)) {
          response.data = "Provisioner error: " + executor.message
        } else {
          response.data = "Provisioner-level error. Possibly, no executor was found."
        }
      } else {
        valueToPrettyString@StringUtils( executor )( t )
        println@Console( "executor: " + t )()
        response.error = true
        response.data = "Invalid executor type: " + executor.type
      }
    }]
  }
}
