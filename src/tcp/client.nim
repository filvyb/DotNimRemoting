import asyncnet, asyncdispatch
import faststreams/[inputs, outputs]
import ../tcp/[types, helpers]
import strutils, uri

const 
  DefaultTimeout = 30000 # 30 seconds default timeout

type
  NrtpTcpClient* = ref object
    socket: AsyncSocket
    serverUri: Uri
    timeout: int
    connected: bool

proc newNrtpTcpClient*(serverUri: string, timeout: int = DefaultTimeout): NrtpTcpClient =
  ## Creates a new MS-NRTP client for TCP communication
  ## serverUri should be in the format: tcp://hostname:port/path
  ## As specified in section 2.2.3.2.2 of MS-NRTP
  
  # Parse and validate URI
  let uri = parseUri(serverUri)
  if uri.scheme != "tcp":
    raise newException(ValueError, "Invalid URI scheme, expected 'tcp://'")
  
  if uri.hostname == "":
    raise newException(ValueError, "Missing hostname in URI")
  
  if uri.port == "":
    raise newException(ValueError, "Missing port in URI")

  # Return a new client instance
  result = NrtpTcpClient(
    socket: newAsyncSocket(),
    serverUri: uri,
    timeout: timeout,
    connected: false
  )

proc connect*(client: NrtpTcpClient): Future[void] {.async.} =
  ## Connects to the remote server
  ## As specified in section 2.1.1.1.1 of MS-NRTP
  
  if client.connected:
    return
  
  try:
    await client.socket.connect(client.serverUri.hostname, Port(client.serverUri.port.parseInt()))
    client.connected = true
  except:
    client.connected = false
    raise

proc close*(client: NrtpTcpClient): Future[void] {.async.} =
  ## Closes the connection to the remote server
  if client.connected:
    client.socket.close()
    client.connected = false

proc sendRequest*(client: NrtpTcpClient, 
                  methodName: string, 
                  typeName: string, 
                  isOneWay: bool = false,
                  messageContent: seq[byte]): Future[void] {.async.} =
  ## Sends a request message to the server
  ## This follows the specification in section 2.1.1.1.1 of MS-NRTP
  
  if not client.connected:
    await client.connect()
  
  # Determine operation type from method type
  let opType = if isOneWay: otOneWayRequest else: otRequest
  
  # Get the server object URI path from the URI
  let serverObjectUri = client.serverUri.path
  if serverObjectUri == "":
    raise newException(ValueError, "Missing Server Object URI path")

  # Create message frame for transmission
  let frame = createMessageFrame(
    operationType = opType,
    requestUri = serverObjectUri, 
    contentType = BinaryFormatId,
    messageContent = messageContent
  )
  
  # Serialize frame to bytes
  var output = memoryOutput()
  writeMessageFrame(output, frame)
  
  # Add the message content after the frame
  for b in messageContent:
    output.write(b)
  
  # Get the complete message bytes
  let messageBytes = output.getOutput(seq[byte])
  
  # Send the message
  await client.socket.send(cast[string](messageBytes))

proc recvReply*(client: NrtpTcpClient): Future[seq[byte]] {.async.} =
  ## Receives a reply from the server
  ## This follows the specification in section 2.1.1.1.2 of MS-NRTP
  
  if not client.connected:
    raise newException(IOError, "Not connected to server")
  
  var buffer = newSeq[byte]()
  var messageFrame: MessageFrame
  var frameEndPos = 0
  var contentLength = 0
  
  # Read the message frame
  while true:
    let data = await client.socket.recv(1024)
    if data.len == 0:
      raise newException(IOError, "Connection closed by peer")
    
    # Add received data to our buffer
    buffer.add(cast[seq[byte]](data))
    
    # Try to parse the message frame from the accumulated data
    var inp = memoryInput(buffer)
    try:
      messageFrame = readMessageFrame(inp)
      frameEndPos = inp.pos()
      
      # Extract content length
      if messageFrame.contentLength.distribution == cdNotChunked:
        contentLength = messageFrame.contentLength.length
      else:
        raise newException(IOError, "Chunked encoding not supported yet")
      
      # Validate that this is a reply message
      if messageFrame.operationType != otReply:
        raise newException(IOError, "Expected Reply operation type, got " & $messageFrame.operationType)
      
      # We've successfully parsed the frame
      break
    except IOError:
      # We don't have enough data yet, continue reading
      continue
  
  # Now we need to read the message content
  # First check if we already have enough data
  if buffer.len >= frameEndPos + contentLength:
    # We already have all the content
    return buffer[frameEndPos ..< frameEndPos + contentLength]
  
  # We need to read more data for the content
  var contentBuffer = buffer[frameEndPos .. ^1]  # Start with what we already have
  let remainingBytes = contentLength - contentBuffer.len
  
  while contentBuffer.len < contentLength:
    let bytesToRead = min(1024, contentLength - contentBuffer.len)
    let data = await client.socket.recv(bytesToRead)
    if data.len == 0:
      raise newException(IOError, "Connection closed while reading content")
    
    contentBuffer.add(cast[seq[byte]](data))
  
  return contentBuffer

proc invoke*(client: NrtpTcpClient, 
             methodName: string, 
             typeName: string, 
             isOneWay: bool = false,
             requestData: seq[byte]): Future[seq[byte]] {.async.} =
  ## Invokes a remote method and returns the response
  ## This combines sendRequest and recvReply into a single operation
  
  # Send the request
  await client.sendRequest(methodName, typeName, isOneWay, requestData)
  
  # If one-way method, no response is expected
  if isOneWay:
    return @[]
  
  # Receive and return the reply
  return await client.recvReply()