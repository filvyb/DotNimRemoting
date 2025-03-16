import asyncdispatch
import src/tcp/[client, server, common, helpers]
import src/msnrbf/helpers

# Example client usage
proc clientExample() {.async.} =
  let client = newNrtpTcpClient("tcp://localhost:8080/MyServer.rem")
  
  # Create method call with arguments
  let args = @[
    int32Value(42),
    stringValue("Hello, world!")
  ]
  
  let requestData = createMethodCallRequest("MyMethod", "MyNamespace.MyClass", args)
  
  # Invoke the method
  let responseData = await client.invoke("MyMethod", "MyNamespace.MyClass", false, requestData)
  
  # Process the response
  # (In a real implementation, you would deserialize the response data)
  echo "Received response, length: ", responseData.len
  
  await client.close()

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

# Run both examples
proc main() {.async.} =
  # Start the server
  asyncCheck serverExample()
  
  # Wait a bit for the server to start
  await sleepAsync(1000)
  
  # Run the client
  await clientExample()
  
  # Keep the program running
  while true:
    await sleepAsync(1000)

waitFor main()