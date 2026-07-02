import asyncnet, asyncdispatch
import faststreams/[inputs, outputs]
import types, helpers, common
import strutils, tables, uri
import ../msnrbf/grammar
import ../msnrbf/helpers as msnrbf
import ../msnrbf/records/[methodinv, serialization]

type
  RequestHandler* = proc(requestUri: string,
                        methodName: string,
                        typeName: string,
                        requestData: seq[byte]): Future[seq[byte]] {.async.}

  ServiceHandler* = proc(methodName: string,
                         args: seq[RemotingValue]): Future[RemotingValue] {.async.}
    ## Handler for registerService: method name and resolved args in, result
    ## value out; return nullValue() for void

  NrtpTcpServer* = ref object
    socket: AsyncSocket
    port: int
    running: bool
    handlers: TableRef[string, RequestHandler]

proc newNrtpTcpServer*(port: int): NrtpTcpServer =
  ## Creates a new MS-NRTP server for TCP communication
  ## As specified in section 2.1.1.2 of MS-NRTP
  result = NrtpTcpServer(
    socket: newAsyncSocket(),
    port: port,
    running: false,
    handlers: newTable[string, RequestHandler]()
  )

proc registerHandler*(server: NrtpTcpServer, path: string, handler: RequestHandler) =
  ## Registers a raw handler that parses and produces MS-NRBF payload bytes
  ## itself; most services are easier to write with registerService
  server.handlers[path] = handler

proc originalMsg(e: ref Exception): string =
  when not defined(release):
    const header = "\nAsync traceback:\n"
    let idx = e.msg.find(header)
    if idx >= 0: e.msg[0 ..< idx] else: e.msg
  else:
    e.msg

proc registerService*(server: NrtpTcpServer, path: string, service: ServiceHandler,
                      libraries: seq[BinaryLibrary] = @[]) =
  ## Registers a method-level service: requests are parsed for the handler
  ## and its result is serialized back with the right wire layout. libraries
  ## lists the binaryLibrary records class-valued results may reference.
  ## A raised exception travels back as a serialized System.Exception the
  ## client rethrows; raise RemoteException to pick the .NET exception class.
  proc wrapper(requestUri, methodName, typeName: string,
               requestData: seq[byte]): Future[seq[byte]] {.async.} =
    var input = memoryInput(requestData)
    let msg = readRemotingMessage(input)
    if msg.methodCall.isNone:
      return createMethodReturnResponse()
    try:
      let ret = await service(methodNameOf(msg), callArgs(msg))
      return createMethodReturnResponse(ret, libraries)
    except RemoteException as e:
      # The handler picked the .NET exception type to surface
      let className = if e.className.len > 0: e.className else: "System.Exception"
      return createMethodReturnExceptionResponse(
        dotNetExceptionValue(originalMsg(e), className))
    except CatchableError as e:
      # Any other handler failure travels as a plain System.Exception
      return createMethodReturnExceptionResponse(dotNetExceptionValue(originalMsg(e)))
  server.registerHandler(path, wrapper)

proc processClient(server: NrtpTcpServer, client: AsyncSocket) {.async.} =
  ## Processes a client connection, serving requests until the client
  ## disconnects or a request carries the CloseConnection header
  ## Follows MS-NRTP section 2.1.1.2.1

  debugLog "[SERVER] New client connection accepted"

  try:
    while true:
      debugLog "[SERVER] Reading message frame..."
      let frameResult = await tryReadMessageFrameAsync(client)
      if frameResult.eof:
        debugLog "[SERVER] Client disconnected"
        break
      let frame = frameResult.value
      let frameSize = frameResult.bytesRead

      debugLog "[SERVER] Successfully read message frame, size: ", frameSize, " bytes"

      # Validate operation type
      if frame.operationType != otRequest and frame.operationType != otOneWayRequest:
        debugLog "[SERVER] Error: Expected Request or OneWayRequest, got ", frame.operationType
        raise newException(IOError, "Expected Request or OneWayRequest operation type")

      debugLog "[SERVER] Content length: ", frame.messageContent.len, " bytes"
      debugLog "[SERVER] Message frame parsed, extracting headers..."

      # Extract headers
      var requestUri = ""
      var contentType = ""
      var closeConnection = false

      for header in frame.headers:
        case header.token
        of htRequestUri:
          requestUri = parseUri(header.requestUri.value).path
          debugLog "[SERVER] RequestUri header: ", requestUri
        of htContentType:
          contentType = header.contentType.value
          debugLog "[SERVER] ContentType header: ", contentType
        of htCloseConnection:
          closeConnection = true
          debugLog "[SERVER] CloseConnection header present"
        else:
          debugLog "[SERVER] Other header token: ", header.token
          discard

      # Process request
      let isOneWay = (frame.operationType == otOneWayRequest)
      debugLog "[SERVER] Request type: ", if isOneWay: "OneWayRequest" else: "Request"

      if requestUri in server.handlers:
        debugLog "[SERVER] Handler found for URI: ", requestUri
        let handler = server.handlers[requestUri]
        let requestData = frame.messageContent

        if isOneWay:
          debugLog "[SERVER] Processing one-way request"
          # One-way requests get no reply, so swallow handler failures here
          # instead of letting the outer handler send an error frame
          try:
            discard await handler(requestUri, "", "", requestData)
          except CatchableError as e:
            debugLog "[SERVER] One-way handler failed: ", e.msg
        else:
          debugLog "[SERVER] Processing request and preparing response"
          let responseData = await handler(requestUri, "", "", requestData)
          debugLog "[SERVER] Handler returned response data, length: ", responseData.len, " bytes"

          let responseFrame = createMessageFrame(
            operationType = otReply,
            requestUri = requestUri,
            contentType = contentType,
            messageContent = responseData,
            closeConnection = closeConnection
          )
          debugLog "[SERVER] Created response frame"

          var output = memoryOutput()
          writeMessageFrame(output, responseFrame)

          let responseBytes = output.getOutput(seq[byte])
          debugLog "[SERVER] Total response size: ", responseBytes.len, " bytes"
          await client.send(cast[string](responseBytes))
          debugLog "[SERVER] Response sent"
      else:
        debugLog "[SERVER] No handler found for URI: ", requestUri
        var errorFrame = createMessageFrame(
          operationType = otReply,
          requestUri = requestUri,
          contentType = contentType,
          messageContent = @[],
          closeConnection = true
        )
        errorFrame.headers.add(FrameHeader(token: htStatusCode, statusCode: tscError))
        errorFrame.headers.add(FrameHeader(
          token: htStatusPhrase,
          statusPhrase: CountedString(encoding: seUtf8, value: "No handler found for URI")
        ))

        var output = memoryOutput()
        writeMessageFrame(output, errorFrame)
        await client.send(cast[string](output.getOutput(seq[byte])))
        debugLog "[SERVER] Error response sent: No handler found for URI"
        # The error frame advertises CloseConnection, so honor it
        break

      if closeConnection:
        debugLog "[SERVER] Closing connection as requested"
        break

  except Exception as e:
    try:
      var errorFrame = createMessageFrame(
        operationType = otReply,
        requestUri = "",
        contentType = BinaryFormatId,
        messageContent = @[],
        closeConnection = true
      )
      errorFrame.headers.add(FrameHeader(token: htStatusCode, statusCode: tscError))
      errorFrame.headers.add(FrameHeader(
        token: htStatusPhrase,
        statusPhrase: CountedString(encoding: seUtf8, value: e.msg)
      ))
      
      var output = memoryOutput()
      writeMessageFrame(output, errorFrame)
      await client.send(cast[string](output.getOutput(seq[byte])))
      debugLog "[SERVER] Error response sent: ", e.msg
      debugLog e.getStackTrace()
    except:
      debugLog "[SERVER] Failed to send error response"
      discard
  
  finally:
    client.close()
    debugLog "[SERVER] Client connection closed"

proc start*(server: NrtpTcpServer) {.async.} =
  ## Starts the server
  ## As specified in section 2.1.1.2 and 3.2.3 of MS-NRTP
  
  if server.running:
    return
  
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.bindAddr(Port(server.port))
  server.socket.listen()
  server.running = true
  
  echo "NRTP TCP Server listening on port ", server.port
  
  while server.running:
    try:
      let client = await server.socket.accept()
      asyncCheck server.processClient(client)
    except:
      # If accept fails, wait a bit and try again
      await sleepAsync(100)

proc stop*(server: NrtpTcpServer) {.async.} =
  ## Stops the server
  if server.running:
    server.running = false
    server.socket.close()
