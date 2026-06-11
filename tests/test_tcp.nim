import unittest
import asyncnet, asyncdispatch, options
import faststreams/outputs
import DotNimRemoting/tcp/[client, server, types, helpers, common]
import DotNimRemoting/msnrbf/helpers as msnrbf_helpers
import DotNimRemoting/msnrbf/[enums, context, grammar]
import DotNimRemoting/msnrbf/types as msnrbf_types
import DotNimRemoting/msnrbf/records/methodinv

proc echoHandler(requestUri, methodName, typeName: string,
                 requestData: seq[byte]): Future[seq[byte]] {.async.} =
  return createMethodReturnResponse(stringValue("pong"))

proc runExchange(port: int): Future[tuple[reply: MessageFrame, trailing: string]] {.async.} =
  ## Sends one request frame over a raw socket and returns the reply frame
  ## plus any bytes the server sent after it (there must be none).
  let socket = newAsyncSocket()
  await socket.connect("127.0.0.1", Port(port))

  let request = createMethodCallRequest("Ping", "MyServer")
  let frame = createMessageFrame(
    operationType = otRequest,
    requestUri = "tcp://127.0.0.1:" & $port & "/test",
    contentType = BinaryFormatId,
    messageContent = request,
    closeConnection = true
  )
  var output = memoryOutput()
  writeMessageFrame(output, frame)
  await socket.send(cast[string](output.getOutput(seq[byte])))

  let replyResult = await readMessageFrameAsync(socket)

  # The request carries CloseConnection, so the server closes after
  # replying; drain until EOF. Any data here means the reply frame was
  # followed by stray bytes (e.g. message content written twice).
  var trailing = ""
  while true:
    let recvF = socket.recv(1024)
    if not await withTimeout(recvF, 5000):
      break
    let extra = await recvF
    if extra.len == 0:
      break
    trailing.add(extra)
  socket.close()
  return (replyResult.value, trailing)

suite "NRTP TCP Server Tests":
  test "Reply frame contains message content exactly once":
    const port = 18391
    let srv = newNrtpTcpServer(port)
    srv.registerHandler("/test", echoHandler)
    asyncCheck srv.start()

    let (reply, trailing) = waitFor runExchange(port)
    check reply.operationType == otReply
    check reply.contentLength.length == reply.messageContent.len.int32
    check reply.messageContent.len > 0
    check trailing.len == 0

    # The reply content must parse as a valid remoting message
    let ret = extractReturnValue(reply.messageContent)
    check ret.stringVal.value == "pong"

    waitFor srv.stop()

  test "Server keeps connection alive across multiple calls":
    const port = 18392
    let srv = newNrtpTcpServer(port)
    srv.registerHandler("/test", echoHandler)
    asyncCheck srv.start()

    let cl = newNrtpTcpClient("tcp://127.0.0.1:" & $port & "/test")
    for i in 1..3:
      let ret = waitFor cl.callMethod("Ping", "MyServer")
      check ret.stringVal.value == "pong"
    waitFor cl.close()
    waitFor srv.stop()

  test "Client reconnects after close":
    const port = 18393
    let srv = newNrtpTcpServer(port)
    srv.registerHandler("/test", echoHandler)
    asyncCheck srv.start()

    let cl = newNrtpTcpClient("tcp://127.0.0.1:" & $port & "/test")
    let first = waitFor cl.callMethod("Ping", "MyServer")
    check first.stringVal.value == "pong"
    waitFor cl.close()

    # A closed client must get a fresh socket on the next call
    let second = waitFor cl.callMethod("Ping", "MyServer")
    check second.stringVal.value == "pong"
    waitFor cl.close()
    waitFor srv.stop()

suite "Method call argument extraction":
  test "extractMethodCallArgs handles inline args":
    let request = createMethodCallRequest("M", "Type.Server",
      @[int32Value(42), stringValue("hi")])
    let args = extractMethodCallArgs(deserializeRemotingMessage(request))
    check args.len == 2
    check args[0].kind == ptInt32
    check args[0].int32Val == 42
    check args[1].kind == ptString
    check args[1].stringVal.value == "hi"

  test "extractMethodCallArgs handles no args":
    let request = createMethodCallRequest("M", "Type.Server")
    check extractMethodCallArgs(deserializeRemotingMessage(request)).len == 0

  test "extractMethodCallArgs handles one call-array element per arg (ArgsIsArray)":
    # .NET/Mono clients use this layout when an argument is e.g. DateTime,
    # TimeSpan or char, which they never inline in the method-call record.
    var call = methodCallBasic("M", "Type.Server")
    call.messageEnum = {MessageFlag.NoContext, MessageFlag.ArgsIsArray}
    let callArray = @[
      RemotingValue(kind: rvPrimitive,
        primitiveVal: dateTimeValue(637_500_000_000_000_000'i64, 1)),
      RemotingValue(kind: rvString,
        stringVal: LengthPrefixedString(value: "hi"))]
    let ctx = newSerializationContext()
    let msg = newRemotingMessage(ctx, methodCall = some(call), callArray = callArray)
    let args = extractMethodCallArgs(deserializeRemotingMessage(serializeRemotingMessage(msg)))
    check args.len == 2
    check args[0].kind == ptDateTime
    check args[0].dateTimeVal.ticks == 637_500_000_000_000_000'i64
    check args[0].dateTimeVal.kind == 1
    check args[1].kind == ptString
    check args[1].stringVal.value == "hi"

  test "extractMethodCallArgs handles args array in call array (ArgsInArray)":
    let (call, _) = methodCallArrayArgs("M", "Type.Server")
    let argsArray = RemotingValue(kind: rvArray, arrayVal: ArrayValue(
      record: ArrayRecord(kind: rtArraySingleObject,
        arraySingleObject: arraySingleObject(2)),
      elements: @[
        RemotingValue(kind: rvPrimitive, primitiveVal: int32Value(7)),
        RemotingValue(kind: rvNull)]))
    let ctx = newSerializationContext()
    let msg = newRemotingMessage(ctx, methodCall = some(call), callArray = @[argsArray])
    let args = extractMethodCallArgs(deserializeRemotingMessage(serializeRemotingMessage(msg)))
    check args.len == 2
    check args[0].kind == ptInt32
    check args[0].int32Val == 7
    check args[1].kind == ptNull
