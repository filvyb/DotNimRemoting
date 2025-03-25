import asyncnet, asyncdispatch
import faststreams/[outputs]
import types, helpers
import strutils, tables, uri

type
  RequestHandler* = proc(requestUri: string, 
                        methodName: string, 
                        typeName: string, 
                        requestData: seq[byte]): Future[seq[byte]] {.async.}

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
  ## Registers a handler for a specific server object URI path
  server.handlers[path] = handler

proc processClient(server: NrtpTcpServer, client: AsyncSocket) {.async.} =
  ## Processes a client connection
  ## Follows MS-NRTP section 2.1.1.2.1
  
  debugLog "[SERVER] New client connection accepted"
  
  try:
    debugLog "[SERVER] Reading message frame..."
    let frameResult = await readMessageFrameAsync(client)
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
        discard handler(requestUri, "", "", requestData)
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
        for b in responseData:
          output.write(b)
        
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
