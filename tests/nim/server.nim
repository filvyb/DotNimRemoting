import faststreams/inputs
import ../../src/tcp/[server, common]
import ../../src/msnrbf/[grammar, enums, helpers]
import ../../src/msnrbf/records/member
import asyncdispatch

proc echoHandler(requestUri, methodName, typeName: string, requestData: seq[byte]): Future[seq[byte]] {.async.} =
  var input = memoryInput(requestData)
  let msg = readRemotingMessage(input)
  if msg.methodCall.isSome:
    let call = msg.methodCall.get
    if call.args.len > 0 and call.args[0].primitiveType == ptString:
      let inputStr = call.args[0].value.stringVal.value
      return createMethodReturnResponse(stringValue(inputStr))
  return createMethodReturnResponse()

proc main() {.async.} =
  let server = newNrtpTcpServer(8080)
  server.registerHandler("/EchoService", echoHandler)
  await server.start()

waitFor main()