import asyncnet, asyncdispatch
import faststreams/[inputs, outputs]
import types, helpers, common
import ../msnrbf/[types]
import strutils, options, tables

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
  ## As specified in section 2.1.1.2.1 of MS-NRTP
  
  debugLog "[SERVER] New client connection accepted"
  
  try:
    debugLog "[SERVER] Reading message frame..."
    # Read the message frame using the async API
    let frameResult = await readMessageFrameAsync(client)
    let frame = frameResult.value
    let frameSize = frameResult.bytesRead
    
    debugLog "[SERVER] Successfully read message frame, size: ", frameSize, " bytes"
    
    # Validate operation type (should be Request or OneWayRequest)
    if frame.operationType != otRequest and frame.operationType != otOneWayRequest:
      debugLog "[SERVER] Error: Expected Request or OneWayRequest operation type, got ", frame.operationType
      raise newException(IOError, "Expected Request or OneWayRequest operation type")
    
    # Extract content length
    var contentLength = 0
    if frame.contentLength.distribution == cdNotChunked:
      contentLength = frame.contentLength.length
      debugLog "[SERVER] Content length: ", contentLength, " bytes"
    else:
      debugLog "[SERVER] Error: Chunked encoding not supported yet"
      raise newException(IOError, "Chunked encoding not supported yet")
    
    debugLog "[SERVER] Message frame parsed, extracting headers..."
    # Get the request URI and content type from the frame headers
    var requestUri = ""
    var contentType = ""
    var closeConnection = false
    
    for header in frame.headers:
      case header.token
      of htRequestUri:
        requestUri = header.requestUri.value
        debugLog "[SERVER] RequestUri header: ", requestUri
      of htContentType:
        contentType = header.contentType.value
        debugLog "[SERVER] ContentType header: ", contentType
      of htCloseConnection:
        closeConnection = true
        debugLog "[SERVER] CloseConnection header present"
      else:
        # Ignore other headers
        debugLog "[SERVER] Other header token: ", header.token
        discard
    
    debugLog "[SERVER] Reading message content..."
    # Read the message content with proper timeout
    var requestData = newSeq[byte](contentLength)
    var bytesRead = 0
    
    # Read content in chunks
    while bytesRead < contentLength:
      let chunkSize = min(1024, contentLength - bytesRead)
      debugLog "[SERVER] Reading chunk of ", chunkSize, " bytes..."
      
      var dataF = client.recv(chunkSize)
      if not await withTimeout(dataF, 10000): # 10 second timeout
        raise newException(IOError, "Timeout while reading content")
      
      let data = await dataF
      if data.len == 0:
        debugLog "[SERVER] Error: Connection closed while reading content"
        raise newException(IOError, "Connection closed while reading content")
      
      # Copy received data into our buffer at the correct position
      let dataBytes = cast[seq[byte]](data)
      for i in 0..<data.len:
        requestData[bytesRead + i] = dataBytes[i]
      
      bytesRead += data.len
      debugLog "[SERVER] Received chunk of ", data.len, " bytes, total read: ", bytesRead, "/", contentLength
    
    debugLog "[SERVER] Message content fully received, total size: ", requestData.len, " bytes"
    
    # Determine if this is a one-way method
    let isOneWay = (frame.operationType == otOneWayRequest)
    debugLog "[SERVER] Request type: ", if isOneWay: "OneWayRequest" else: "Request"
    
    # Find the handler for this path
    if requestUri in server.handlers:
      debugLog "[SERVER] Handler found for URI: ", requestUri
      let handler = server.handlers[requestUri]
      
      # For one-way methods, no response is sent
      if isOneWay:
        debugLog "[SERVER] Processing one-way request (no response will be sent)"
        # Process the request but don't wait for a response
        discard handler(requestUri, "", "", requestData)
      else:
        debugLog "[SERVER] Processing request and preparing response"
        # Process the request and send a response
        let responseData = await handler(requestUri, "", "", requestData)
        debugLog "[SERVER] Handler returned response data, length: ", responseData.len, " bytes"
        
        # Create response frame
        let responseFrame = createMessageFrame(
          operationType = otReply,
          requestUri = requestUri,
          contentType = contentType,
          messageContent = responseData,
          closeConnection = closeConnection
        )
        debugLog "[SERVER] Created response frame"
        
        # Send the response
        var output = memoryOutput()
        writeMessageFrame(output, responseFrame)
        debugLog "[SERVER] Serialized response frame"
        
        for b in responseData:
          output.write(b)
        
        let responseBytes = output.getOutput(seq[byte])
        debugLog "[SERVER] Total response size: ", responseBytes.len, " bytes"
        
        await client.send(cast[string](responseBytes))
        debugLog "[SERVER] Response sent"
    else:
      debugLog "[SERVER] No handler found for URI: ", requestUri
      # No handler found, send a fault
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
    # Handle any exceptions    
    # Try to send an error response if possible
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
      debugLog e.trace
    except:
      # Ignore errors in sending error response
      debugLog "[SERVER] Failed to send error response"
      discard
  
  finally:
    # Close the client connection
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
