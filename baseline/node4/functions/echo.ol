type FunctionRequest { data?: undefined }
type FunctionResponse { data?: undefined }

interface Function {
  RequestResponse: fn(FunctionRequest)(FunctionResponse)
}

service Echo {
  execution: concurrent
  inputPort Input { location: "local" interfaces: Function }
  main {
    [ fn( request )( response ) {
      response.data = "Node 4 Echo: " + request.data
    } ]
  }
}
