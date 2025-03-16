import asyncdispatch
import ../src/tcp/[client, common, helpers]
import ../src/msnrbf/helpers

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

# Run client example
when isMainModule:
  waitFor clientExample()