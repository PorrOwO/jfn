from console import Console
from runtime import Runtime
from .checksum import Checksum

type FunctionCatalogParams {
  functionCatalogLocation: string
  couchdbLocation: string
  couchdbUser: string
  couchdbPassword: string
  verbose: bool
}

// --- COUCHDB TYPES ---
type CouchDBError {
  error[0,1]: string
  reason[0,1]: string
}

type GetDocRequest { 
  name: string 
}

type CouchDBGetResponse {
  "_id": string
  "_rev": string
  code: string
  checksum: string
}

type CouchDBCreateResponse {
  ok: bool
}

// All fields optional [0,1] so Jolie can parse BOTH success and error JSON from CouchDB without TypeMismatch
type CouchDBPutResponse {
  ok[0,1]: bool
  id[0,1]: string
  rev[0,1]: string
  error[0,1]: string
  reason[0,1]: string
}

interface CouchDBInterface {
  RequestResponse:
    putDoc( undefined )( CouchDBPutResponse ) throws Conflict( CouchDBError ),
    getDoc( GetDocRequest )( CouchDBGetResponse ) throws FunctionNotFound( CouchDBError ),
    createDb( void )( CouchDBCreateResponse ) throws DbExists( CouchDBError )
}

// --- JFN CATALOG API ---
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
    hash( FunctionCatalogRequest )( string ) throws FunctionNotFound( string ),
    get( FunctionCatalogRequest )( string ) throws FunctionNotFound( string ),
    put( FunctionCatalogPutRequest )( FunctionCatalogResult )
}

service FunctionCatalog(p : FunctionCatalogParams) {
  execution: concurrent
  embed Console as Console
  embed Runtime as Runtime
  embed Checksum as Checksum

  outputPort CouchDB {
    location: p.couchdbLocation
    protocol: http {
      format = "json"

      addHeader.header[0] << "Authorization" {
        .value = "Basic YWRtaW46YWRtaW4="
      }

      osc.putDoc.template = "/jfn_functions/{name}"
      osc.putDoc.method = "put"
      osc.putDoc.statusCodes.Conflict = 409

      osc.getDoc.template = "/jfn_functions/{name}"
      osc.getDoc.method = "get"
      osc.getDoc.statusCodes.FunctionNotFound = 404

      osc.createDb.template = "/jfn_functions"
      osc.createDb.method = "put"
      osc.createDb.statusCodes.DbExists = 412
    }
    interfaces: CouchDBInterface
  }

  inputPort FunctionCatalogInput {
    location: p.functionCatalogLocation
    protocol: sodep
    interfaces: FunctionCatalogAPI
  }

  init {
    enableTimestamp@Console(true)()
    
    scope(create_db) {
      install( DbExists => {
        println@Console("CouchDB database 'jfn_functions' already exists.")()
      }, default => {
        println@Console("Created CouchDB database 'jfn_functions'.")()
      })
      createDb@CouchDB()( createRes )
    }

    println@Console("Listening on " + p.functionCatalogLocation)()
  }

  main {
    [ put( request )( response ) {
      println@Console("=== 1. INCOMING REQUEST TO CATALOG ===")()
      println@Console("DEBUG: request.name = " + request.name)()
      // Note: #request.code returns 1 because it counts the vector elements (1 string), not string length.
      // The actual code is printed below to verify it's correct.
      println@Console("DEBUG: request.code = " + request.code)()

      base64Encode@Checksum( request.code )( encodedCode );
      sha256@Checksum( request.code )( codeHash );

      undef(docRev)
      scope(check_exists) {
        install( FunctionNotFound => { 
          println@Console("DEBUG: FunctionNotFound fault caught!")()
        })
        getDoc@CouchDB({ name = request.name })( existingDoc )
        
        println@Console("DEBUG: existingDoc: " + existingDoc)()
        println@Console("DEBUG: After getDoc, is_defined(existingDoc) = " + is_defined(existingDoc))()
        if ( is_defined( existingDoc ) ) {
          docRev = existingDoc.("_rev")
          println@Console("DEBUG: Assigned docRev = " + docRev)()
        } else {
          println@Console("DEBUG: existingDoc is NOT defined, docRev remains undefined")()
        }
      }
      println@Console("DEBUG: After check_exists scope, is_defined(docRev) = " + is_defined(docRev))()

      undef( putReq )
      putReq.name = request.name
      putReq.code = encodedCode
      putReq.checksum = codeHash
      
      if ( is_defined( docRev ) ) {
        putReq.("_rev") = docRev
        println@Console("DEBUG: Assigned putReq._rev = " + putReq.("_rev"))()
      } else {
        println@Console("DEBUG: docRev is undefined, putReq._rev NOT assigned")()
        undef( putReq.("_rev") ) // Explicitly ensure it's completely removed
      }

      println@Console("=== 2. PAYLOAD TO COUCHDB ===")()
      println@Console("DEBUG: putReq._rev is defined? " + is_defined(putReq.("_rev")))()

      scope(write_doc) {
        install( Conflict => {
          println@Console("=== 3. CAUGHT CONFLICT ===")()
          response.error = true
          response.data = "Conflict writing to CouchDB."
        }, default => {
          println@Console("=== 3. CAUGHT WRITE ERROR ===")()
          println@Console("ERROR MESSAGE: " + write_doc.(write_doc.default))()
          response.error = true
          response.data = "Failed to write to CouchDB: " + write_doc.(write_doc.default)
        })
        
        putDoc@CouchDB( putReq )( putRes )
        
        if ( is_defined( putRes.ok ) && putRes.ok == true ) {
          println@Console("=== 4. COUCHDB SUCCESS ===")()
          response.error = false
          response.data = "Function " + request.name + " upload successful"
        } else {
          println@Console("=== 4. COUCHDB RETURNED JSON ERROR ===")()
          println@Console("DEBUG: putRes.error = " + putRes.error)()
          println@Console("DEBUG: putRes.reason = " + putRes.reason)()
          response.error = true
          response.data = "CouchDB rejected the document: " + putRes.reason
        }
      }
      
      println@Console("=== 5. FINAL RESPONSE TO GATEWAY ===")()
      println@Console("DEBUG: response.error = " + response.error)()
      println@Console("DEBUG: response.data = " + response.data)()
    }]

    [ get( request )( response ) {
      scope(fetch_doc) {
        install( FunctionNotFound => {
          throw( FunctionNotFound, "Function " + request.name + " not found" )
        })
        getDoc@CouchDB({ name = request.name })( doc )
        base64Decode@Checksum( doc.code )( decodedCode )
        response = decodedCode
      }
    }]

    [ hash( request )( response ) {
      scope(fetch_hash) {
        install( FunctionNotFound => {
          throw( FunctionNotFound, "Function " + request.name + " not found" )
        })
        getDoc@CouchDB({ name = request.name })( doc )
        response = doc.checksum
      }
    }]
  }
}