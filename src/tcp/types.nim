import faststreams/[inputs, outputs]
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
proc readCountedString*(inp: InputStream): CountedString {.deprecated.} =
  ## Read a CountedString from the input stream
  if not inp.readable:
    raise newException(IOError, "End of stream while reading CountedString")

  result.encoding = StringEncoding(inp.read)

  let length = readValue[int32](inp)
  if length < 0:
    raise newException(ValueError, "Invalid CountedString length")

  if length == 0:
    result.value = ""
  else:
    if not inp.readable(length):
      raise newException(IOError, "End of stream while reading CountedString data")
    result.value = newString(length)
    if not inp.readInto(result.value.toOpenArrayByte(0, length-1)):
      raise newException(IOError, "Failed to read CountedString data")

proc readCountedStringAsync*(socket: AsyncSocket, timeout: int = 10000): Future[tuple[value: CountedString, bytesRead: int]] {.async.} =
  ## Read a CountedString from the async socket, returning the value and bytes read
  var bytesRead = 0
  
  # Read encoding byte
  var encodingF = socket.recv(1)
  if not await withTimeout(encodingF, timeout):
    raise newException(IOError, "Timeout while reading CountedString encoding")
  let encodingData = await encodingF
  bytesRead += 1
  
  result.value.encoding = StringEncoding(encodingData[0].byte)
  
  # Read length (4 bytes)
  var lengthF = socket.recv(4)
  if not await withTimeout(lengthF, timeout):
    raise newException(IOError, "Timeout while reading CountedString length")
  let lengthData = await lengthF
  bytesRead += 4
  
  let length = cast[ptr int32](unsafeAddr lengthData[0])[]
  if length < 0:
    raise newException(ValueError, "Invalid CountedString length")
  
  if length == 0:
    result.value.value = ""
  else:
    # Read string data
    var stringF = socket.recv(length)
    if not await withTimeout(stringF, timeout):
      raise newException(IOError, "Timeout while reading CountedString data")
    let stringData = await stringF
    bytesRead += length
    result.value.value = stringData
  
  result.bytesRead = bytesRead

proc readContentLength*(inp: InputStream): ContentLength {.deprecated.} =
  ## Read a ContentLength from the input stream
  result.distribution = ContentDistribution(readValue[uint16](inp))
  if result.distribution == cdNotChunked:
    result.length = readValue[int32](inp)
    
proc readContentLengthAsync*(socket: AsyncSocket, timeout: int = 10000): Future[tuple[value: ContentLength, bytesRead: int]] {.async.} =
  ## Read a ContentLength from the async socket, returning the value and bytes read
  var bytesRead = 0
  
  # Read distribution (2 bytes)
  var distributionF = socket.recv(2)
  if not await withTimeout(distributionF, timeout):
    raise newException(IOError, "Timeout while reading ContentDistribution")
  let distributionData = await distributionF
  bytesRead += 2
  
  result.value.distribution = ContentDistribution(cast[ptr uint16](unsafeAddr distributionData[0])[])
  
  if result.value.distribution == cdNotChunked:
    # Read length (4 bytes)
    var lengthF = socket.recv(4)
    if not await withTimeout(lengthF, timeout):
      raise newException(IOError, "Timeout while reading content length")
    let lengthData = await lengthF
    bytesRead += 4
    
    result.value.length = cast[ptr int32](unsafeAddr lengthData[0])[]
  
  result.bytesRead = bytesRead

proc readChunkedContentAsync*(socket: AsyncSocket, timeout: int): Future[seq[byte]] {.async.} =
  ## Reads chunked content from an async socket until a chunk size of 0 is encountered.
  ## Returns the complete message content as a sequence of bytes.
  ## Follows MS-NRTP section 2.2.3.3.2 for chunked message content.
  
  var content = newSeq[byte]()
  while true:
    # Read chunk size (4 bytes)
    var sizeF = socket.recv(4)
    if not await withTimeout(sizeF, timeout):
      raise newException(IOError, "Timeout while reading chunk size")
    let sizeData = await sizeF
    if sizeData.len != 4:
      raise newException(IOError, "Incomplete chunk size data")
    let chunkSize = cast[ptr int32](unsafeAddr sizeData[0])[]
    
    # Check for end of chunked content
    if chunkSize == 0:
      # Read final delimiter (2 bytes)
      var delimiterF = socket.recv(2)
      if not await withTimeout(delimiterF, timeout):
        raise newException(IOError, "Timeout while reading final chunk delimiter")
      let delimiter = await delimiterF
      if delimiter != "\r\n":
        raise newException(IOError, "Invalid final chunk delimiter; expected '\\r\\n'")
      break
    
    # Validate chunk size
    if chunkSize < 0:
      raise newException(ValueError, "Negative chunk size encountered")
    
    # Read chunk data
    var chunkData = newSeq[byte](chunkSize)
    var bytesRead = 0
    while bytesRead < chunkSize:
      let remaining = chunkSize - bytesRead
      var dataF = socket.recv(remaining)
      if not await withTimeout(dataF, timeout):
        raise newException(IOError, "Timeout while reading chunk data")
      let data = await dataF
      if data.len == 0:
        raise newException(IOError, "Connection closed while reading chunk data")
      let dataBytes = cast[seq[byte]](data)
      for i in 0..<data.len:
        chunkData[bytesRead + i] = dataBytes[i]
      bytesRead += data.len
    
    # Add chunk data to content
    content.add(chunkData)
    
    # Read delimiter (2 bytes)
    var delimiterF = socket.recv(2)
    if not await withTimeout(delimiterF, timeout):
      raise newException(IOError, "Timeout while reading chunk delimiter")
    let delimiter = await delimiterF
    if delimiter != "\r\n":
      raise newException(IOError, "Invalid chunk delimiter; expected '\\r\\n'")

  return content

proc readFrameHeader*(inp: InputStream): FrameHeader {.deprecated.} =
  ## Reads a FrameHeader from the input stream per section 2.2.3.3.3
  if not inp.readable:
    raise newException(IOError, "End of stream while reading FrameHeader")
  let tokenByte = inp.read

  try:
    result = FrameHeader(token: HeaderToken(tokenByte))
  except ValueError:
    raise newException(ValueError, "Invalid HeaderToken value")

  case result.token
  of htEndHeaders:
    # No data follows
    discard
  of htCustom:
    let format1 = HeaderDataFormat(inp.read)
    if format1 != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for custom header name")
    result.headerName = readCountedString(inp)
    let format2 = HeaderDataFormat(inp.read)
    if format2 != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for custom header value")
    result.headerValue = readCountedString(inp)
  of htStatusCode:
    let format = HeaderDataFormat(inp.read)
    if format != hdfByte:
      raise newException(ValueError, "Expected hdfByte for status code")
    result.statusCode = TCPStatusCode(inp.read)
  of htStatusPhrase:
    let format = HeaderDataFormat(inp.read)
    if format != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for status phrase")
    result.statusPhrase = readCountedString(inp)
  of htRequestUri:
    let format = HeaderDataFormat(inp.read)
    if format != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for request URI")
    result.requestUri = readCountedString(inp)
  of htCloseConnection:
    let format = HeaderDataFormat(inp.read)
    if format != hdfVoid:
      raise newException(ValueError, "Expected hdfVoid for close connection")
    # No data to read
  of htContentType:
    let format = HeaderDataFormat(inp.read)
    if format != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for content type")
    result.contentType = readCountedString(inp)

proc readFrameHeaderAsync*(socket: AsyncSocket, timeout: int = 10000): Future[tuple[value: FrameHeader, bytesRead: int]] {.async.} =
  ## Reads a FrameHeader from the async socket, returning the value and bytes read
  var bytesRead = 0
  
  # Read token byte
  var tokenF = socket.recv(1)
  if not await withTimeout(tokenF, timeout):
    raise newException(IOError, "Timeout while reading FrameHeader token")
  let tokenData = await tokenF
  bytesRead += 1
  
  let tokenByte = tokenData[0].byte
  
  try:
    result.value = FrameHeader(token: HeaderToken(tokenByte))
  except ValueError:
    raise newException(ValueError, "Invalid HeaderToken value: " & $tokenByte)
  
  case result.value.token
  of htEndHeaders:
    # No data follows
    discard
  of htCustom:
    # Read format byte for header name
    var format1F = socket.recv(1)
    if not await withTimeout(format1F, timeout):
      raise newException(IOError, "Timeout while reading custom header format")
    let format1Data = await format1F
    bytesRead += 1
    
    let format1 = HeaderDataFormat(format1Data[0].byte)
    if format1 != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for custom header name")
    
    let headerName = await readCountedStringAsync(socket, timeout)
    result.value.headerName = headerName.value
    bytesRead += headerName.bytesRead
    
    # Read format byte for header value
    var format2F = socket.recv(1)
    if not await withTimeout(format2F, timeout):
      raise newException(IOError, "Timeout while reading custom header value format")
    let format2Data = await format2F
    bytesRead += 1
    
    let format2 = HeaderDataFormat(format2Data[0].byte)
    if format2 != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for custom header value")
    
    let headerValue = await readCountedStringAsync(socket, timeout)
    result.value.headerValue = headerValue.value
    bytesRead += headerValue.bytesRead
  
  of htStatusCode:
    # Read format byte
    var formatF = socket.recv(1)
    if not await withTimeout(formatF, timeout):
      raise newException(IOError, "Timeout while reading status code format")
    let formatData = await formatF
    bytesRead += 1
    
    let format = HeaderDataFormat(formatData[0].byte)
    if format != hdfByte:
      raise newException(ValueError, "Expected hdfByte for status code")
    
    # Read status code byte
    var statusF = socket.recv(1)
    if not await withTimeout(statusF, timeout):
      raise newException(IOError, "Timeout while reading status code")
    let statusData = await statusF
    bytesRead += 1
    
    result.value.statusCode = TCPStatusCode(statusData[0].byte)
  
  of htStatusPhrase:
    # Read format byte
    var formatF = socket.recv(1)
    if not await withTimeout(formatF, timeout):
      raise newException(IOError, "Timeout while reading status phrase format")
    let formatData = await formatF
    bytesRead += 1
    
    let format = HeaderDataFormat(formatData[0].byte)
    if format != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for status phrase")
    
    let statusPhrase = await readCountedStringAsync(socket, timeout)
    result.value.statusPhrase = statusPhrase.value
    bytesRead += statusPhrase.bytesRead
  
  of htRequestUri:
    # Read format byte
    var formatF = socket.recv(1)
    if not await withTimeout(formatF, timeout):
      raise newException(IOError, "Timeout while reading request URI format")
    let formatData = await formatF
    bytesRead += 1
    
    let format = HeaderDataFormat(formatData[0].byte)
    if format != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for request URI")
    
    let requestUri = await readCountedStringAsync(socket, timeout)
    result.value.requestUri = requestUri.value
    bytesRead += requestUri.bytesRead
  
  of htCloseConnection:
    # Read format byte
    var formatF = socket.recv(1)
    if not await withTimeout(formatF, timeout):
      raise newException(IOError, "Timeout while reading close connection format")
    let formatData = await formatF
    bytesRead += 1
    
    let format = HeaderDataFormat(formatData[0].byte)
    if format != hdfVoid:
      raise newException(ValueError, "Expected hdfVoid for close connection")
    # No data to read
  
  of htContentType:
    # Read format byte
    var formatF = socket.recv(1)
    if not await withTimeout(formatF, timeout):
      raise newException(IOError, "Timeout while reading content type format")
    let formatData = await formatF
    bytesRead += 1
    
    let format = HeaderDataFormat(formatData[0].byte)
    if format != hdfCountedString:
      raise newException(ValueError, "Expected hdfCountedString for content type")
    
    let contentType = await readCountedStringAsync(socket, timeout)
    result.value.contentType = contentType.value
    bytesRead += contentType.bytesRead
  
  result.bytesRead = bytesRead

proc readMessageFrame*(inp: InputStream): MessageFrame {.deprecated.} =
  ## Reads a MessageFrame from the input stream per section 2.2.3.3
  result.protocolId = readValue[int32](inp)
  if result.protocolId != ProtocolId:
    raise newException(IOError, "Invalid protocol identifier; expected 'NET.' (0x54454E2E)")

  result.majorVersion = inp.read
  result.minorVersion = inp.read
  if result.majorVersion != MajorVersion or result.minorVersion != MinorVersion:
    raise newException(IOError, "Unsupported version: " & $result.majorVersion & "." & $result.minorVersion)

  result.operationType = OperationType(readValue[uint16](inp))
  result.contentLength = readContentLength(inp)

  # Read headers until EndHeaders
  while true:
    let header = readFrameHeader(inp)
    if header.token == htEndHeaders:
      break
    result.headers.add(header)

proc readMessageFrameAsync*(socket: AsyncSocket, timeout: int = 10000): Future[tuple[value: MessageFrame, bytesRead: int]] {.async.} =
  ## Reads a MessageFrame from the async socket, including its content, returning the value and bytes read.
  ## Follows MS-NRTP section 2.2.3.3 for message frame structure.
  var bytesRead = 0
  var frame = MessageFrame()
  
  # Read protocol ID (4 bytes)
  var protocolF = socket.recv(4)
  if not await withTimeout(protocolF, timeout):
    raise newException(IOError, "Timeout while reading protocol identifier")
  let protocolData = await protocolF
  frame.protocolId = cast[ptr int32](unsafeAddr protocolData[0])[]
  if frame.protocolId != ProtocolId:
    raise newException(IOError, "Invalid protocol identifier; expected 'NET.' (0x54454E2E)")
  bytesRead += 4
  
  # Read major and minor version (1 byte each)
  var versionF = socket.recv(2)
  if not await withTimeout(versionF, timeout):
    raise newException(IOError, "Timeout while reading version")
  let versionData = await versionF
  frame.majorVersion = versionData[0].byte
  frame.minorVersion = versionData[1].byte
  if frame.majorVersion != MajorVersion or frame.minorVersion != MinorVersion:
    raise newException(IOError, "Unsupported version: " & $frame.majorVersion & "." & $frame.minorVersion)
  bytesRead += 2
  
  # Read operation type (2 bytes)
  var opTypeF = socket.recv(2)
  if not await withTimeout(opTypeF, timeout):
    raise newException(IOError, "Timeout while reading operation type")
  let opTypeData = await opTypeF
  frame.operationType = OperationType(cast[ptr uint16](unsafeAddr opTypeData[0])[])
  bytesRead += 2
  
  # Read content length
  let contentLength = await readContentLengthAsync(socket, timeout)
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
    let contentLength = frame.contentLength.length
    frame.messageContent = newSeq[byte](contentLength)
    var contentBytesRead = 0
    while contentBytesRead < contentLength:
      let chunkSize = min(1024, contentLength - contentBytesRead)
      var dataF = socket.recv(chunkSize)
      if not await withTimeout(dataF, timeout):
        raise newException(IOError, "Timeout while reading content")
      let data = await dataF
      if data.len == 0:
        raise newException(IOError, "Connection closed while reading content")
      let dataBytes = cast[seq[byte]](data)
      for i in 0..<data.len:
        frame.messageContent[contentBytesRead + i] = dataBytes[i]
      contentBytesRead += data.len
    bytesRead += contentBytesRead
  elif frame.contentLength.distribution == cdChunked:
    frame.messageContent = await readChunkedContentAsync(socket, timeout)
    # Note: bytesRead is not incremented here as we don't track exact bytes in chunked content
  else:
    raise newException(ValueError, "Unknown content distribution: " & $frame.contentLength.distribution)
  
  result.value = frame
  result.bytesRead = bytesRead

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
  outp.write(byte(header.token))
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
  outp.write(byte(htEndHeaders))
  if frame.contentLength.distribution == cdNotChunked:
    for b in frame.messageContent:
      outp.write(b)
  else: # cdChunked
    #writeValue[int32](outp, int32(outp.messageContent.len))
    for b in frame.messageContent:
      writeValue[int32](outp, 1) # very bad, but not really needed
      outp.write(b)
      outp.write(ChunkDelimiterBytes)
    writeValue[int32](outp, 0'i32)
    outp.write(ChunkDelimiterBytes)