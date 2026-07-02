import faststreams/outputs
import asyncnet, asyncdispatch
from ../msnrbf/types import readValueWithContext, readValue, writeValue

const
  # Protocol identifier for .NET Remoting, spelled "NET." in ASCII
  ProtocolId* = 0x54454E2E
  # Protocol version numbers
  MajorVersion*: byte = 1
  MinorVersion*: byte = 0
  # Default binary format identifier
  BinaryFormatId* = "application/octet-stream"
  ChunkDelimiterBytes* = [byte 0x0D, 0x0A]
  # Largest single recv issued by recvExact, to avoid huge upfront buffers
  RecvChunkSize = 4096
  DefaultMaxContentLength* = 64 * 1024 * 1024 * 10
    ## Default upper bound for message content accepted from the network.
    ## Clients and servers carry their own limit; set their maxContentLength
    ## field if larger messages are expected.

type
  OperationType* = enum
    ## Section 2.2.3.1.1 OperationType
    otRequest = 0        # Two-Way Method request
    otOneWayRequest = 1  # One-Way Method request
    otReply = 2          # Two-Way Method reply

  ContentDistribution* = enum
    ## Section 2.2.3.1.2 ContentDistribution
    cdNotChunked = 0     # Message content is not chunked
    cdChunked = 1        # Message content is written as chunked encoding

  HeaderToken* = enum
    ## Section 2.2.3.1.3 HeaderToken
    htEndHeaders = 0       # End of headers marker
    htCustom = 1           # Custom implementation-specific header
    htStatusCode = 2       # Status code for replies
    htStatusPhrase = 3     # Human-readable status message
    htRequestUri = 4       # URI that identifies the Server Object
    htCloseConnection = 5  # Indicates connection should not be cached
    htContentType = 6      # Serialization format identifier

  HeaderDataFormat* = enum
    ## Section 2.2.3.1.4 HeaderDataFormat
    hdfVoid = 0           # No data in header
    hdfCountedString = 1  # Data is a CountedString
    hdfByte = 2           # Data is a byte
    hdfUint16 = 3         # Data is a uint16
    hdfInt32 = 4          # Data is an int32

  StringEncoding* = enum
    ## Section 2.2.3.1.5 StringEncoding
    seUnicode = 0  # Unicode encoded string
    seUtf8 = 1     # UTF-8 encoded string

  TCPStatusCode* = enum
    ## Section 2.2.3.1.6 TCPStatusCode
    tscSuccess = 0  # No error
    tscError = 1    # Error processing message frame

  CountedString* = object
    ## Section 2.2.3.2.1 CountedString structure
    ## Strings in header section with format identifier, length, and data
    encoding*: StringEncoding
    value*: string
  
  ContentLength* = object
    ## Section
    distribution*: ContentDistribution
    length*: int32  # Length of content in bytes

  ChunkDelimiter* = object
    ## Section 2.2.3.2.3 ChunkDelimiter
    ## Used at end of each chunk in chunked message content
    delimiterValue*: uint16  # Must be 0x0D0A ('\r' '\n')

  # Message Frame Headers
  FrameHeader* = object
    case token*: HeaderToken
    of htEndHeaders:
      discard  # No additional data
    of htCustom:
      headerName*: CountedString
      headerValue*: CountedString
    of htStatusCode:
      statusCode*: TCPStatusCode
    of htStatusPhrase:
      statusPhrase*: CountedString
    of htRequestUri:
      requestUri*: CountedString
    of htCloseConnection:
      discard  # No additional data
    of htContentType:
      contentType*: CountedString

  MessageFrame* = object
    ## Section 2.2.3.3 Message Frame Structure
    protocolId*: int32               # Must be 0x54454E2E ("NET." in ASCII)
    majorVersion*: byte              # Major version (1)
    minorVersion*: byte              # Minor version (0)
    operationType*: OperationType    # Request/OneWayRequest/Reply
    contentLength*: ContentLength    # Length of message content
    headers*: seq[FrameHeader]       # Frame headers
    messageContent*: seq[byte]        # Message content

# Reading functions
proc toEnum[T: enum](value: SomeInteger): T =
  ## Converts a raw wire value to an enum
  let v = int(value)
  if v < ord(low(T)) or v > ord(high(T)):
    raise newException(IOError, "Invalid " & $T & " value: " & $v)
  T(v)

proc recvExact*(socket: AsyncSocket, size: int, timeout: int, context: string): Future[string] {.async.} =
  ## Reads exactly `size` bytes from the socket. Raises IOError on timeout
  ## or if the connection closes before `size` bytes are received.
  result = ""
  while result.len < size:
    let recvF = socket.recv(min(size - result.len, RecvChunkSize))
    if not await withTimeout(recvF, timeout):
      raise newException(IOError, "Timeout while " & context)
    let data = await recvF
    if data.len == 0:
      raise newException(IOError, "Connection closed while " & context)
    result.add(data)

proc readCountedStringAsync*(socket: AsyncSocket, timeout: int = 10000): Future[tuple[value: CountedString, bytesRead: int]] {.async.} =
  ## Read a CountedString from the async socket, returning the value and bytes read
  var bytesRead = 0

  # Read encoding byte
  let encodingData = await recvExact(socket, 1, timeout, "reading CountedString encoding")
  bytesRead += 1

  result.value.encoding = toEnum[StringEncoding](encodingData[0].byte)

  # Read length (4 bytes)
  let lengthData = await recvExact(socket, 4, timeout, "reading CountedString length")
  bytesRead += 4

  let length = cast[ptr int32](unsafeAddr lengthData[0])[]
  if length < 0:
    raise newException(IOError, "Invalid CountedString length: " & $length)

  if length == 0:
    result.value.value = ""
  else:
    result.value.value = await recvExact(socket, length, timeout, "reading CountedString data")
    bytesRead += length

  result.bytesRead = bytesRead

    
proc readContentLengthAsync*(socket: AsyncSocket, timeout: int = 10000,
                             maxContentLength: int = DefaultMaxContentLength): Future[tuple[value: ContentLength, bytesRead: int]] {.async.} =
  ## Read a ContentLength from the async socket, returning the value and bytes read
  var bytesRead = 0

  # Read distribution (2 bytes)
  let distributionData = await recvExact(socket, 2, timeout, "reading ContentDistribution")
  bytesRead += 2

  result.value.distribution = toEnum[ContentDistribution](cast[ptr uint16](unsafeAddr distributionData[0])[])

  if result.value.distribution == cdNotChunked:
    # Read length (4 bytes)
    let lengthData = await recvExact(socket, 4, timeout, "reading content length")
    bytesRead += 4

    let length = cast[ptr int32](unsafeAddr lengthData[0])[]
    if length < 0:
      raise newException(IOError, "Invalid content length: " & $length)
    if int(length) > maxContentLength:
      raise newException(IOError, "Content length " & $length & " exceeds maximum of " & $maxContentLength & " bytes")
    result.value.length = length

  result.bytesRead = bytesRead

proc readChunkedContentAsync*(socket: AsyncSocket, timeout: int,
                              maxContentLength: int = DefaultMaxContentLength): Future[seq[byte]] {.async.} =
  ## Reads chunked content from an async socket until a chunk size of 0 is encountered.
  ## Returns the complete message content as a sequence of bytes.
  ## Follows MS-NRTP section 2.2.3.3.2 for chunked message content.
  
  var content = newSeq[byte]()
  while true:
    # Read chunk size (4 bytes)
    let sizeData = await recvExact(socket, 4, timeout, "reading chunk size")
    let chunkSize = cast[ptr int32](unsafeAddr sizeData[0])[]

    # Check for end of chunked content
    if chunkSize == 0:
      # Read final delimiter (2 bytes)
      let delimiter = await recvExact(socket, 2, timeout, "reading final chunk delimiter")
      if delimiter != "\r\n":
        raise newException(IOError, "Invalid final chunk delimiter; expected '\\r\\n'")
      break

    # Validate chunk size
    if chunkSize < 0:
      raise newException(IOError, "Negative chunk size encountered")
    if content.len + int(chunkSize) > maxContentLength:
      raise newException(IOError, "Chunked content exceeds maximum of " & $maxContentLength & " bytes")

    # Read chunk data
    let data = await recvExact(socket, int(chunkSize), timeout, "reading chunk data")
    for c in data:
      content.add(byte(c))

    # Read delimiter (2 bytes)
    let delimiter = await recvExact(socket, 2, timeout, "reading chunk delimiter")
    if delimiter != "\r\n":
      raise newException(IOError, "Invalid chunk delimiter; expected '\\r\\n'")

  return content


proc readFrameHeaderAsync*(socket: AsyncSocket, timeout: int = 10000): Future[tuple[value: FrameHeader, bytesRead: int]] {.async.} =
  ## Reads a FrameHeader from the async socket, returning the value and bytes read
  var bytesRead = 0
  
  # Read token (2 bytes)
  let tokenData = await recvExact(socket, 2, timeout, "reading FrameHeader token")
  bytesRead += 2

  let tokenValue = cast[ptr uint16](unsafeAddr tokenData[0])[]
  result.value = FrameHeader(token: toEnum[HeaderToken](tokenValue))

  case result.value.token
  of htEndHeaders:
    # No data follows
    discard
  of htCustom:
    # Read format byte for header name
    let format1Data = await recvExact(socket, 1, timeout, "reading custom header format")
    bytesRead += 1

    let format1 = toEnum[HeaderDataFormat](format1Data[0].byte)
    if format1 != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for custom header name")

    let headerName = await readCountedStringAsync(socket, timeout)
    result.value.headerName = headerName.value
    bytesRead += headerName.bytesRead

    # Read format byte for header value
    let format2Data = await recvExact(socket, 1, timeout, "reading custom header value format")
    bytesRead += 1

    let format2 = toEnum[HeaderDataFormat](format2Data[0].byte)
    if format2 != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for custom header value")

    let headerValue = await readCountedStringAsync(socket, timeout)
    result.value.headerValue = headerValue.value
    bytesRead += headerValue.bytesRead

  of htStatusCode:
    # Read format byte
    let formatData = await recvExact(socket, 1, timeout, "reading status code format")
    bytesRead += 1

    let format = toEnum[HeaderDataFormat](formatData[0].byte)
    if format != hdfByte:
      raise newException(ValueError, "Expected hdfByte for status code")

    # Read status code byte
    let statusData = await recvExact(socket, 1, timeout, "reading status code")
    bytesRead += 1

    result.value.statusCode = toEnum[TCPStatusCode](statusData[0].byte)

  of htStatusPhrase:
    # Read format byte
    let formatData = await recvExact(socket, 1, timeout, "reading status phrase format")
    bytesRead += 1

    let format = toEnum[HeaderDataFormat](formatData[0].byte)
    if format != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for status phrase")

    let statusPhrase = await readCountedStringAsync(socket, timeout)
    result.value.statusPhrase = statusPhrase.value
    bytesRead += statusPhrase.bytesRead

  of htRequestUri:
    # Read format byte
    let formatData = await recvExact(socket, 1, timeout, "reading request URI format")
    bytesRead += 1

    let format = toEnum[HeaderDataFormat](formatData[0].byte)
    if format != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for request URI")

    let requestUri = await readCountedStringAsync(socket, timeout)
    result.value.requestUri = requestUri.value
    bytesRead += requestUri.bytesRead

  of htCloseConnection:
    # Read format byte
    let formatData = await recvExact(socket, 1, timeout, "reading close connection format")
    bytesRead += 1

    let format = toEnum[HeaderDataFormat](formatData[0].byte)
    if format != hdfVoid:
      raise newException(ValueError, "Expected hdfVoid for close connection")
    # No data to read

  of htContentType:
    # Read format byte
    let formatData = await recvExact(socket, 1, timeout, "reading content type format")
    bytesRead += 1

    let format = toEnum[HeaderDataFormat](formatData[0].byte)
    if format != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for content type")

    let contentType = await readCountedStringAsync(socket, timeout)
    result.value.contentType = contentType.value
    bytesRead += contentType.bytesRead

  result.bytesRead = bytesRead


proc readMessageFrameRest(socket: AsyncSocket, timeout: int,
                          maxContentLength: int): Future[tuple[value: MessageFrame, bytesRead: int]] {.async.} =
  ## Reads the remainder of a MessageFrame after the 4-byte protocol
  ## identifier has already been consumed and validated.
  var bytesRead = 0
  var frame = MessageFrame(protocolId: ProtocolId)

  # Read major and minor version (1 byte each)
  let versionData = await recvExact(socket, 2, timeout, "reading version")
  frame.majorVersion = versionData[0].byte
  frame.minorVersion = versionData[1].byte
  if frame.majorVersion != MajorVersion or frame.minorVersion != MinorVersion:
    raise newException(IOError, "Unsupported version: " & $frame.majorVersion & "." & $frame.minorVersion)
  bytesRead += 2

  # Read operation type (2 bytes)
  let opTypeData = await recvExact(socket, 2, timeout, "reading operation type")
  frame.operationType = toEnum[OperationType](cast[ptr uint16](unsafeAddr opTypeData[0])[])
  bytesRead += 2
  
  # Read content length
  let contentLength = await readContentLengthAsync(socket, timeout, maxContentLength)
  frame.contentLength = contentLength.value
  bytesRead += contentLength.bytesRead
  
  # Read headers until EndHeaders
  while true:
    let header = await readFrameHeaderAsync(socket, timeout)
    bytesRead += header.bytesRead
    if header.value.token == htEndHeaders:
      break
    frame.headers.add(header.value)
  
  # Read message content based on contentLength.distribution
  if frame.contentLength.distribution == cdNotChunked:
    let contentLength = int(frame.contentLength.length)
    let data = await recvExact(socket, contentLength, timeout, "reading message content")
    frame.messageContent = newSeq[byte](contentLength)
    for i in 0..<data.len:
      frame.messageContent[i] = byte(data[i])
    bytesRead += contentLength
  else: # cdChunked
    frame.messageContent = await readChunkedContentAsync(socket, timeout, maxContentLength)
    # Note: bytesRead is not incremented here as we don't track exact bytes in chunked content
  
  result.value = frame
  result.bytesRead = bytesRead

proc checkProtocolId(protocolData: string) =
  if cast[ptr int32](unsafeAddr protocolData[0])[] != ProtocolId:
    raise newException(IOError, "Invalid protocol identifier; expected 'NET.' (0x54454E2E)")

proc readMessageFrameAsync*(socket: AsyncSocket, timeout: int = 10000,
                            maxContentLength: int = DefaultMaxContentLength): Future[tuple[value: MessageFrame, bytesRead: int]] {.async.} =
  ## Reads a MessageFrame from the async socket, including its content, returning the value and bytes read.
  ## Follows MS-NRTP section 2.2.3.3 for message frame structure.
  let protocolData = await recvExact(socket, 4, timeout, "reading protocol identifier")
  checkProtocolId(protocolData)
  let rest = await readMessageFrameRest(socket, timeout, maxContentLength)
  result.value = rest.value
  result.bytesRead = 4 + rest.bytesRead

proc tryReadMessageFrameAsync*(socket: AsyncSocket, timeout: int = 10000,
                               maxContentLength: int = DefaultMaxContentLength): Future[tuple[value: MessageFrame, bytesRead: int, eof: bool]] {.async.} =
  ## Like readMessageFrameAsync, but waits without a timeout for the start of
  ## the next frame and sets eof instead of raising when the peer closes the
  ## connection at a frame boundary. Lets servers keep a connection alive
  ## between requests; the timeout still applies once a frame has started.
  var protocolData = await socket.recv(4)
  if protocolData.len == 0:
    result.eof = true
    return
  if protocolData.len < 4:
    protocolData.add(await recvExact(socket, 4 - protocolData.len, timeout, "reading protocol identifier"))
  checkProtocolId(protocolData)
  let rest = await readMessageFrameRest(socket, timeout, maxContentLength)
  result.value = rest.value
  result.bytesRead = 4 + rest.bytesRead

# Writing functions
proc writeCountedString*(outp: OutputStream, cs: CountedString) =
  ## Write a CountedString to the output stream
  outp.write(byte(cs.encoding))
  writeValue[int32](outp, int32(cs.value.len))
  if cs.value.len > 0:
    outp.write(cs.value)

proc writeContentLength*(outp: OutputStream, cl: ContentLength) =
  ## Write a ContentLength to the output stream
  writeValue[uint16](outp, uint16(cl.distribution))
  if cl.distribution == cdNotChunked:
    writeValue[int32](outp, cl.length)
  

proc writeFrameHeader*(outp: OutputStream, header: FrameHeader) =
  ## Writes a FrameHeader to the output stream per section 2.2.3.3.3
  writeValue[uint16](outp, uint16(header.token))
  case header.token
  of htEndHeaders:
    # No data
    discard
  of htCustom:
    outp.write(byte(hdfCountedString))
    writeCountedString(outp, header.headerName)
    outp.write(byte(hdfCountedString))
    writeCountedString(outp, header.headerValue)
  of htStatusCode:
    outp.write(byte(hdfByte))
    outp.write(byte(header.statusCode))
  of htStatusPhrase:
    outp.write(byte(hdfCountedString))
    writeCountedString(outp, header.statusPhrase)
  of htRequestUri:
    outp.write(byte(hdfCountedString))
    writeCountedString(outp, header.requestUri)
  of htCloseConnection:
    outp.write(byte(hdfVoid))
  of htContentType:
    outp.write(byte(hdfCountedString))
    writeCountedString(outp, header.contentType)

proc writeMessageFrame*(outp: OutputStream, frame: MessageFrame) =
  ## Writes a MessageFrame to the output stream per section 2.2.3.3
  if frame.protocolId != ProtocolId:
    raise newException(ValueError, "Protocol identifier must be 'NET.' (0x54454E2E)")
  if frame.majorVersion != MajorVersion or frame.minorVersion != MinorVersion:
    raise newException(ValueError, "Version must be 1.0")

  writeValue[int32](outp, frame.protocolId)
  outp.write(frame.majorVersion)
  outp.write(frame.minorVersion)
  writeValue[uint16](outp, uint16(frame.operationType))
  writeContentLength(outp, frame.contentLength)
  for header in frame.headers:
    writeFrameHeader(outp, header)
  writeValue[uint16](outp, uint16(htEndHeaders))
  if frame.contentLength.distribution == cdNotChunked:
    for b in frame.messageContent:
      outp.write(b)
  else: # cdChunked
    for b in frame.messageContent:
      writeValue[int32](outp, 1) # very bad, but done just so chunked content support is there
      outp.write(b)
      outp.write(ChunkDelimiterBytes)
    writeValue[int32](outp, 0'i32)
    outp.write(ChunkDelimiterBytes)