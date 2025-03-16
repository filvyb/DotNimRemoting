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
    # Read the fixed header portion (12 bytes)
    var headerData = await client.recv(12)
    if headerData.len < 12:
      # Send a transport fault and close connection
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
        statusPhrase: CountedString(encoding: seUtf8, value: "Invalid message header")
      ))
      
      var output = memoryOutput()
      writeMessageFrame(output, errorFrame)
      await client.send(cast[string](output.getOutput(seq[byte])))
      return
    
    # Start parsing the header
    var input = memoryInput(headerData)
    let protocolId = readValue[int32](input)
    if protocolId != ProtocolId:
      raise newException(IOError, "Invalid protocol identifier")
    
    let majorVersion = input.read
    let minorVersion = input.read
    if majorVersion != MajorVersion or minorVersion != MinorVersion:
      raise newException(IOError, "Unsupported protocol version")
    
    let opType = OperationType(readValue[uint16](input))
    if opType != otRequest and opType != otOneWayRequest:
      raise newException(IOError, "Expected Request or OneWayRequest operation type")
    
    let isOneWay = (opType == otOneWayRequest)
    
    let distribution = ContentDistribution(readValue[uint16](input))
    var contentLength: int32 = 0
    if distribution == cdNotChunked:
      contentLength = readValue[int32](input)
    else:
      # Chunked content handling would be more complex
      raise newException(IOError, "Chunked message content not supported yet")
    
    # Read all headers
    var requestUri = ""
    var contentType = ""
    var closeConnection = false
    
    var endHeaderFound = false
    while not endHeaderFound:
      var headerByte = await client.recv(1)
      if headerByte.len == 0:
        raise newException(IOError, "Connection closed while reading headers")
      
      let token = HeaderToken(byte(headerByte[0]))
      if token == htEndHeaders:
        endHeaderFound = true
        break
      
      # Read the header based on its type
      case token
      of htRequestUri:
        # Read format byte
        let formatByte = await client.recv(1)
        if byte(formatByte[0]) != byte(hdfCountedString):
          raise newException(IOError, "Invalid header format for RequestUri")
        
        # Read the encoding byte
        let encodingByte = await client.recv(1)
        let encoding = StringEncoding(byte(encodingByte[0]))
        
        # Read the length (4 bytes)
        let lengthBytes = await client.recv(4)
        var lenInput = memoryInput(lengthBytes)
        let strLength = readValue[int32](lenInput)
        
        # Read the string value
        if strLength > 0:
          let strValue = await client.recv(strLength)
          requestUri = strValue
      
      of htContentType:
        # Similar processing for content type
        # Read format byte
        let formatByte = await client.recv(1)
        if byte(formatByte[0]) != byte(hdfCountedString):
          raise newException(IOError, "Invalid header format for ContentType")
        
        # Read the encoding byte
        let encodingByte = await client.recv(1)
        let encoding = StringEncoding(byte(encodingByte[0]))
        
        # Read the length (4 bytes)
        let lengthBytes = await client.recv(4)
        var lenInput = memoryInput(lengthBytes)
        let strLength = readValue[int32](lenInput)
        
        # Read the string value
        if strLength > 0:
          let strValue = await client.recv(strLength)
          contentType = strValue
      
      of htCloseConnection:
        # Read format byte
        let formatByte = await client.recv(1)
        if byte(formatByte[0]) != byte(hdfVoid):
          raise newException(IOError, "Invalid header format for CloseConnection")
        closeConnection = true
      
      else:
        # Skip other headers
        # This is a simplified implementation - in a real server we would need to
        # properly read and process all header types
        discard
    
    # Now read the message content
    var contentBuffer = newSeq[byte](contentLength)
    var contentPos = 0
    
    while contentPos < contentLength:
      let remaining = contentLength - contentPos
      let chunk = await client.recv(remaining)
      if chunk.len == 0:
        raise newException(IOError, "Connection closed while reading content")
      
      # Copy data into content buffer
      for i in 0..<chunk.len:
        contentBuffer[contentPos + i] = byte(chunk[i])
      contentPos += chunk.len
    
    # Process the request
    # Extract method name and type name from content
    # This would normally come from the binary format, but for simplicity
    # we'll just pass the raw content to the handler
    
    # Find the handler for this path
    if requestUri in server.handlers:
      let handler = server.handlers[requestUri]
      
      # For one-way methods, no response is sent
      if isOneWay:
        # Process the request but don't wait for a response
        discard handler(requestUri, "", "", contentBuffer)
      else:
        # Process the request and send a response
        let responseData = await handler(requestUri, "", "", contentBuffer)
        
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
