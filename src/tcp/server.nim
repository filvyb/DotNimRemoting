import asyncnet, asyncdispatch
import faststreams/[inputs, outputs]
import ../tcp/[types, helpers]
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
  
  try:
    var buffer = newSeq[byte]()
    var frameSize = 0
    var contentLength = 0
    var frame: MessageFrame
    
    # Keep reading until we have a complete message frame
    while true:
      let data = await client.recv(1024)
      if data.len == 0:
        # Client disconnected
        return
      
      # Add received data to our buffer
      buffer.add(cast[seq[byte]](data))
      
      # Try to parse the message frame without consuming
      try:
        let result = peekMessageFrame(buffer)
        frame = result.frame
        frameSize = result.bytesRead
        
        # Validate operation type (should be Request or OneWayRequest)
        if frame.operationType != otRequest and frame.operationType != otOneWayRequest:
          raise newException(IOError, "Expected Request or OneWayRequest operation type")
        
        # Extract content length
        if frame.contentLength.distribution == cdNotChunked:
          contentLength = frame.contentLength.length
        else:
          raise newException(IOError, "Chunked encoding not supported yet")
        
        # We've successfully parsed the frame
        break
      except IOError:
        # Not enough data yet, continue reading
        continue
    
    # Get the request URI and content type from the frame headers
    var requestUri = ""
    var contentType = ""
    var closeConnection = false
    
    for header in frame.headers:
      case header.token
      of htRequestUri:
        requestUri = header.requestUri.value
      of htContentType:
        contentType = header.contentType.value
      of htCloseConnection:
        closeConnection = true
      else:
        # Ignore other headers
        discard
    
    # Now read the message content if not already complete
    while buffer.len < frameSize + contentLength:
      let bytesToRead = min(1024, frameSize + contentLength - buffer.len)
      let data = await client.recv(bytesToRead)
      if data.len == 0:
        raise newException(IOError, "Connection closed while reading content")
      
      buffer.add(cast[seq[byte]](data))
    
    # Extract just the content (without the frame)
    let requestData = buffer[frameSize ..< frameSize + contentLength]
    
    # Determine if this is a one-way method
    let isOneWay = (frame.operationType == otOneWayRequest)
    
    # Find the handler for this path
    if requestUri in server.handlers:
      let handler = server.handlers[requestUri]
      
      # For one-way methods, no response is sent
      if isOneWay:
        # Process the request but don't wait for a response
        discard handler(requestUri, "", "", requestData)
      else:
        # Process the request and send a response
        let responseData = await handler(requestUri, "", "", requestData)
        
        # Create response frame
        let responseFrame = createMessageFrame(
          operationType = otReply,
          requestUri = requestUri,
          contentType = contentType,
          messageContent = responseData,
          closeConnection = closeConnection
        )
        
        # Send the response
        var output = memoryOutput()
        writeMessageFrame(output, responseFrame)
        for b in responseData:
          output.write(b)
        await client.send(cast[string](output.getOutput(seq[byte])))
    else:
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
  
  except Exception as e:
    # Handle any exceptions
    echo "Error processing client: ", e.msg
    
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
    except:
      # Ignore errors in sending error response
      discard
  
  finally:
    # Close the client connection
    client.close()

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
