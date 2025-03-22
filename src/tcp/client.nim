import asyncnet, asyncdispatch
import faststreams/[inputs, outputs]
import types, helpers, common
import strutils, uri

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
  
  debugLog "[CLIENT] Sending request: ", methodName, " on ", typeName, " (oneWay: ", isOneWay, ")"
  
  if not client.connected:
    debugLog "[CLIENT] Not connected, connecting to server..."
    await client.connect()
    debugLog "[CLIENT] Connected to server"
  else:
    debugLog "[CLIENT] Already connected to server"
  
  # Determine operation type from method type
  let opType = if isOneWay: otOneWayRequest else: otRequest
  debugLog "[CLIENT] Operation type: ", opType
  
  # Get the server object URI path from the URI
  let serverObjectUri = $client.serverUri
  if serverObjectUri == "":
    raise newException(ValueError, "Missing Server Object URI path")
  debugLog "[CLIENT] Server Object URI: ", serverObjectUri

  # Create message frame for transmission
  let frame = createMessageFrame(
    operationType = opType,
    requestUri = serverObjectUri, 
    contentType = BinaryFormatId,
    messageContent = messageContent
  )
  debugLog "[CLIENT] Created message frame, content length: ", frame.contentLength.length
  
  # Serialize frame to bytes
  var output = memoryOutput()
  writeMessageFrame(output, frame)
  
  # Get the complete message bytes
  let messageBytes = output.getOutput(seq[byte])
  debugLog "[CLIENT] Total message size: ", messageBytes.len, " bytes"
  
  # Send the message
  await client.socket.send(cast[string](messageBytes))
  debugLog "[CLIENT] Request sent"

proc recvReply*(client: NrtpTcpClient): Future[seq[byte]] {.async.} =
  ## Receives a reply from the server
  ## Follows MS-NRTP section 2.1.1.1.2
  
  debugLog "[CLIENT] Receiving reply..."
  
  if not client.connected:
    debugLog "[CLIENT] Error: Not connected to server"
    raise newException(IOError, "Not connected to server")
  
  debugLog "[CLIENT] Reading message frame..."
  let frameResult = await readMessageFrameAsync(client.socket, client.timeout)
  let frame = frameResult.value
  let frameSize = frameResult.bytesRead
  
  debugLog "[CLIENT] Successfully read message frame, size: ", frameSize, " bytes"
  
  # Validate that this is a reply message
  if frame.operationType != otReply:
    debugLog "[CLIENT] Error: Expected Reply operation type, got ", frame.operationType
    raise newException(IOError, "Expected Reply operation type, got " & $frame.operationType)
  
  debugLog "[CLIENT] Content length: ", frame.messageContent.len, " bytes"
  debugLog "[CLIENT] Response fully received"
  return frame.messageContent

proc invoke*(client: NrtpTcpClient, 
             methodName: string, 
             typeName: string, 
             isOneWay: bool = false,
             requestData: seq[byte]): Future[seq[byte]] {.async.} =
  ## Invokes a remote method and returns the response
  ## This combines sendRequest and recvReply into a single operation
  
  # Send the request
  debugLog "[CLIENT] Sending bytes: ", requestData
  await client.sendRequest(methodName, typeName, isOneWay, requestData)
  
  # If one-way method, no response is expected
  if isOneWay:
    return @[]
  
  # Receive and return the reply
  return await client.recvReply()
