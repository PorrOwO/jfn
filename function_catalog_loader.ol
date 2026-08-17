from console import Console
from runtime import Runtime
from string_utils import StringUtils

interface FunctionCatalogLoaderAPI {
  RequestResponse:
    stop( void )( void ) 
}

service FunctionCatalogLoader {
  execution: concurrent
  embed Runtime as Runtime
  embed Console as Console
  embed StringUtils as StringUtils

  inputPort Local {
    location: "local"
    interfaces: FunctionCatalogLoaderAPI
  }

  init {
    params = {}
    
    // Fetch and validate mandatory location variables (Fail-Fast)
    getenv@Runtime( "FUNCTION_CATALOG_LOCATION" )( params.functionCatalogLocation )
    getenv@Runtime( "ETCD_LOCATION" )( params.etcdLocation )

    if ( !is_defined( params.functionCatalogLocation ) || !is_defined( params.etcdLocation ) ) {
      println@Console( "FATAL: Missing FUNCTION_CATALOG_LOCATION or ETCD_LOCATION environment variables!" )()
      exit
    }

    // cast boolean parameters
    getenv@Runtime( "VERBOSE" )( verbose_str )
    if ( is_defined( verbose_str ) ) {
      params.verbose = bool( verbose_str )
    } else {
      params.verbose = false
    }

    valueToPrettyString@StringUtils( params )( t )
    println@Console( "Loading the function catalog with params: " + t )()

    // fault handling
    scope( embed_scope ) {
      install( FileNotFoundException => 
        println@Console( "FATAL: function_catalog.ol not found in the container image!" )();
        exit
      );
      
      loadEmbeddedService@Runtime({
        filepath = "function_catalog.ol"
        type = "jolie"
        params << params
      })(_)
    }
    
    println@Console( "Function Catalog successfully embedded and running." )()
  }
  
  main {
    [stop(req)(res) {
      println@Console("Received stop signal. Shutting down Function Catalog Loader.")()
      exit
    }]
  }
}