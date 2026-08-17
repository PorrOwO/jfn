from console import Console
from runtime import Runtime
from .checksum import Checksum

type FunctionCatalogParams {
  functionCatalogLocation: string
  etcdLocation: string
  verbose: bool
}

// ETCD TYPES
type EtcdPutRequest {
  key:   string
  value: string
}

type EtcdRangeRequest {
  key: string
  range_end?: string
}

type EtcdKv {
  key: string
  value: string
  create_revision: long
  mod_revision: long
  version: long
}

type EtcdRangeResponse {
  kvs*: EtcdKv
  count: long
}

interface EtcdInterface {
  RequestResponse:
    put(EtcdPutRequest)(void),
    range(EtcdRangeRequest)(EtcdRangeResponse)
}

type FunctionCatalogRequest { name: string }
type FunctionCatalogPutRequest {
  name: string
  code: string
}
type FunctionCatalogResult {
  error: bool
  data: string
}

interface FunctionCatalogAPI {
  RequestResponse:
    checksum( FunctionCatalogRequest )( string ),
    get( FunctionCatalogRequest )( string ),
    put( FunctionCatalogPutRequest )( FunctionCatalogResult )
}

service FunctionCatalog(p : FunctionCatalogParams) {
  execution: concurrent
  embed Console as Console
  embed Runtime as Runtime
  embed Checksum as Checksum

  outputPort Etcd {
    location: p.etcdLocation
    protocol: http {
      format = "json"
      osc.put.alias = "v3/kv/put"
      osc.put.method = "post"
      osc.range.alias = "v3/kv/range"
      osc.range.method = "post"
    }
    interfaces: EtcdInterface
  }

  inputPort FunctionCatalogInput {
    location: p.functionCatalogLocation
    protocol: sodep
    interfaces: FunctionCatalogAPI
  }

  init {
    enableTimestamp@Console(true)()
    println@Console("Listening on " + p.functionCatalogLocation)()
  }

  main {
       [ put( request )() {
         sha256@Checksum( request.code )( codeHash );

         // base64 encoding for etcd requirements
         base64Encode@Checksum( "/functions/" + request.name + "/code" )( keyCode );
         base64Encode@Checksum( request.code )( valCode );

         base64Encode@Checksum( "/functions/" + request.name + "/checksum" )( keyHash );
         base64Encode@Checksum( codeHash )( valHash );

         // Write code to etcd
         put_code_req.key = keyCode;
         put_code_req.value = valCode;
         put@Etcd( put_code_req )();
         // Write hash to etcd
         put_hash_req.key = keyHash;
         put_hash_req.value = valHash;
         put@Etcd( put_hash_req )()

         response.error = false
         response.data = "Function " + request.name + " upload successful"
      }]

      [ get( request )( response ) {
            base64Encode@Checksum( "/functions/" + request.name + "/code" )( encodedKey );
            range_req.key = encodedKey;
            
            // Read from etcd
            range@Etcd( range_req )( etcd_res );

            if ( #etcd_res.kvs > 0 ) {
                base64Decode@Checksum( etcd_res.kvs[0].value )( response.code )
            } else {
                throw( FunctionNotFound, "Function " + request.name + " not found" )
            }
      }]
      [ checksum( request )( response ) {
            base64Encode@Checksum( "/functions/" + request.name + "/checksum" )( encodedKey );
            range_req.key = encodedKey;
            
            // Read from etcd
            range@Etcd( range_req )( etcd_res );

            if ( #etcd_res.kvs > 0 ) {
                base64Decode@Checksum( etcd_res.kvs[0].value )( response.checksum )
            } else {
                throw( FunctionNotFound, "Function " + request.name + " not found" )
            }
      }]
    }
}
