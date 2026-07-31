include "console.iol"

type GatewayRequest {
  fn: string
  data?: undefined
}

type GatewayResponse {
  error: bool
  data?: undefined
}

interface GatewayInterface {
  RequestResponse: op( GatewayRequest )( GatewayResponse )
}

outputPort Gateway {
  protocol: http { format = "json" }
  interfaces: GatewayInterface
}

main {
  // --- Test 1: Query Node 1 for 'hello' ---
  Gateway.location = "socket://localhost:8000"
  req.fn = "hello"
  req.data = "Thesis Researcher"
  op@Gateway( req )( res1 )
  println@Console( "Result from Node 1 (port 8000): " + res1.data )()

  // --- Test 2: Query Node 2 for 'sum' ---
  Gateway.location = "socket://localhost:8001"
  req.fn = "sum"
  req.data.a = 15
  req.data.b = 27
  op@Gateway( req )( res2 )
  println@Console( "Result from Node 2 (port 8001): " + res2.data )()

  // --- Test 3: Query Node 3 for 'time' ---
  Gateway.location = "socket://localhost:8002"
  req.fn = "time"
  req.data = nil
  op@Gateway( req )( res3 )
  println@Console( "Result from Node 3 (port 8002): " + res3.data )()

  // --- Test 4: Query Node 4 for 'echo' ---
  Gateway.location = "socket://localhost:8003"
  req.fn = "echo"
  req.data = "Testing Baseline"
  op@Gateway( req )( res4 )
  println@Console( "Result from Node 4 (port 8003): " + res4.data )()
}
