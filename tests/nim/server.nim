import faststreams/inputs
import ../../src/DotNimRemoting/tcp/[server, common]
import ../../src/DotNimRemoting/msnrbf/[grammar, helpers, types]
import ../../src/DotNimRemoting/msnrbf/records/[member, methodinv]
import asyncdispatch, strutils, options
import interop

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
  let args = extractMethodCallArgs(msg)
  case name
  of "Echo":
    return createMethodReturnResponse(stringValue(args[0].stringVal.value))
  of "Concat":
    return createMethodReturnResponse(
      stringValue(args[0].stringVal.value & args[1].stringVal.value))
  of "Add":
    return createMethodReturnResponse(
      int32Value(args[0].int32Val + args[1].int32Val))
  of "Sum":
    return createMethodReturnResponse(
      int64Value(args[0].int64Val + args[1].int64Val))
  of "Multiply":
    return createMethodReturnResponse(
      doubleValue(args[0].doubleVal * args[1].doubleVal))
  of "IsPositive":
    return createMethodReturnResponse(boolValue(args[0].int32Val > 0))
  of "EchoDecimal", "EchoDateTime", "EchoTimeSpan", "EchoChar",
     "EchoUInt16", "EchoUInt32", "EchoUInt64":
    # Pure round-trips: send the parsed argument straight back.
    return createMethodReturnResponse(args[0])
  of "MultiplyFloat":
    return createMethodReturnResponse(
      singleValue(args[0].singleVal * args[1].singleVal))
  of "IncrementByte":
    return createMethodReturnResponse(byteValue(args[0].byteVal + 1))
  of "NegateSByte":
    return createMethodReturnResponse(sbyteValue(-args[0].sbyteVal))
  of "NegateShort":
    return createMethodReturnResponse(int16Value(-args[0].int16Val))
  of "Ping":
    return createMethodReturnResponse()
  of "EchoIntArray", "EchoDoubleArray", "EchoStringArray":
    # Echo the parsed array value back; object ids are reassigned on write
    return createComplexReturnResponse(callArgs(msg)[0])
  of "SumIntArray":
    var sum = 0'i32
    for elem in resolvedElements(msg, callArgs(msg)[0]):
      sum += elem.primitiveVal.int32Val
    return createMethodReturnResponse(int32Value(sum))
  of "JoinStrings":
    let cargs = callArgs(msg)
    var parts: seq[string]
    for elem in resolvedElements(msg, cargs[0]):
      parts.add(elem.stringVal.value)
    return createMethodReturnResponse(
      stringValue(parts.join(cargs[1].stringVal.value)))
  of "MakeRange":
    let cargs = callArgs(msg)
    let start = cargs[0].primitiveVal.int32Val
    let count = cargs[1].primitiveVal.int32Val
    var values: seq[int32]
    for i in 0..<count:
      values.add(start + i)
    return createComplexReturnResponse(int32ArrayValue(values))
  of "EchoPerson":
    # Rebuild the Person from the parsed fields rather than echoing the parsed
    # record, so the response carries our own class metadata and library
    let (pname, age, score) = personFields(msg, callArgs(msg)[0])
    return createComplexReturnResponse(personValue(pname, age, score),
                                       @[personLibrary()])
  of "DescribePerson":
    let (pname, age, _) = personFields(msg, callArgs(msg)[0])
    return createMethodReturnResponse(stringValue(pname & ":" & $age))
  of "MakePerson":
    let cargs = callArgs(msg)
    let pname = cargs[0].stringVal.value
    let age = cargs[1].primitiveVal.int32Val
    return createComplexReturnResponse(personValue(pname, age, age.float64 * 0.5),
                                       @[personLibrary()])
  of "EchoPersonArray":
    var people: seq[RemotingValue]
    for elem in resolvedElements(msg, callArgs(msg)[0]):
      let (pname, age, score) = personFields(msg, elem)
      people.add(personValue(pname, age, score))
    return createComplexReturnResponse(personArrayValue(people),
                                       @[personLibrary()])
  else:
    # Unknown method: reply void so the client sees a well-formed response.
    return createMethodReturnResponse()

proc main() {.async.} =
  let server = newNrtpTcpServer(8081)
  server.registerHandler("/EchoService", serviceHandler)
  await server.start()

waitFor main()
