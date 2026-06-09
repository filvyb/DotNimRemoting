import unittest
import asyncnet, asyncdispatch
import faststreams/outputs
import DotNimRemoting/tcp/[server, types, helpers, common]
import DotNimRemoting/msnrbf/helpers as msnrbf_helpers

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
    messageContent = request
  )
  var output = memoryOutput()
  writeMessageFrame(output, frame)
  await socket.send(cast[string](output.getOutput(seq[byte])))

  let replyResult = await readMessageFrameAsync(socket)

  # The server closes the connection after replying, so drain until EOF.
  # Any data here means the reply frame was followed by stray bytes
  # (e.g. message content written twice).
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
