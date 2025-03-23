import faststreams/inputs
import ../../src/tcp/[client, common]
import ../../src/msnrbf/[helpers, grammar, enums]
import asyncdispatch

proc main() {.async.} =
  let typename = "DotNimTester.Lib.IEchoService"
  let client = newNrtpTcpClient("tcp://127.0.0.1:8080/EchoService")
  await client.connect()
  let requestData = createMethodCallRequest(
    methodName = "Echo",
    typeName = typename,
    args = @[stringValue("Hello from Nim")]
  )
  let responseData = await client.invoke("Echo", typename, false, requestData)
  # Parse response (simplified; assumes string return)
  var input = memoryInput(responseData)
  let msg = readRemotingMessage(input)
  if msg.methodReturn.isSome:
    let ret = msg.methodReturn.get
    if ret.returnValue.primitiveType == ptString:
      echo "Response: ", ret.returnValue.value.stringVal.value
      if ret.returnValue.value.stringVal.value != "Hello from Nim":
        quit(1)
  await client.close()

waitFor main()