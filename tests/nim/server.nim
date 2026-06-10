import faststreams/inputs
import ../../src/DotNimRemoting/tcp/[server, common]
import ../../src/DotNimRemoting/msnrbf/[grammar, helpers, types]
import ../../src/DotNimRemoting/msnrbf/records/[member, methodinv]
import asyncdispatch

# Direction 2: .NET (Mono) client -> Nim server.
# Implements the same IEchoService contract the .NET client expects, dispatching
# on the method name and replying with a correctly typed return value.

proc serviceHandler(requestUri, methodName, typeName: string,
                    requestData: seq[byte]): Future[seq[byte]] {.async.} =
  var input = memoryInput(requestData)
  let msg = readRemotingMessage(input)
  if msg.methodCall.isNone:
    return createMethodReturnResponse()

  # The server framework passes empty methodName/typeName to handlers, so the
  # method name has to be read from the parsed call itself.
  let call = msg.methodCall.get
  let name = call.methodName.value.stringVal.value
  let args = call.args
  case name
  of "Echo":
    return createMethodReturnResponse(stringValue(args[0].value.stringVal.value))
  of "Concat":
    return createMethodReturnResponse(
      stringValue(args[0].value.stringVal.value & args[1].value.stringVal.value))
  of "Add":
    return createMethodReturnResponse(
      int32Value(args[0].value.int32Val + args[1].value.int32Val))
  of "Sum":
    return createMethodReturnResponse(
      int64Value(args[0].value.int64Val + args[1].value.int64Val))
  of "Multiply":
    return createMethodReturnResponse(
      doubleValue(args[0].value.doubleVal * args[1].value.doubleVal))
  of "IsPositive":
    return createMethodReturnResponse(boolValue(args[0].value.int32Val > 0))
  else:
    # Unknown method: reply void so the client sees a well-formed response.
    return createMethodReturnResponse()

proc main() {.async.} =
  let server = newNrtpTcpServer(8081)
  server.registerHandler("/EchoService", serviceHandler)
  await server.start()

waitFor main()
