import asyncdispatch
import ../src/tcp/[server, common, helpers]
import ../src/msnrbf/helpers

# Example server usage
proc handleRequest(requestUri, methodName, typeName: string,
                  requestData: seq[byte]): Future[seq[byte]] {.async.} =
  # Extract method and arguments from the request
  let info = extractMethodCallInfo(requestData)
  echo "Received request for method: ", info.methodName, " on type: ", info.typeName
  
  # In a real implementation, you would dispatch to the actual method
  # and serialize its return value
  
  # For this example, just return a simple response
  return createMethodReturnResponse(stringValue("Method execution successful"))

proc serverExample() {.async.} =
  let server = newNrtpTcpServer(8080)
  
  # Register handlers
  server.registerHandler("/MyServer.rem", handleRequest)
  
  # Start the server
  await server.start()
  echo "Server started on port 8080"

  # Keep the server running
  while true:
    await sleepAsync(1000)

# Run server example
when isMainModule:
  waitFor serverExample()