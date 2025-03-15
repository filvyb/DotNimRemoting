import faststreams/[inputs, outputs]
import options
from ../msnrbf/types import readValueWithContext, readValue, writeValue

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

# Reading functions
proc readCountedString*(inp: InputStream): CountedString =
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

proc readContentLength*(inp: InputStream): ContentLength =
  ## Read a ContentLength from the input stream
  result.distribution = ContentDistribution(readValue[uint16](inp))
  if result.distribution == cdNotChunked:
    result.length = readValue[int32](inp)

proc readFrameHeader*(inp: InputStream): FrameHeader =
  ## Reads a FrameHeader from the input stream per section 2.2.3.3.3
  if not inp.readable:
    raise newException(IOError, "End of stream while reading FrameHeader")
  let tokenByte = inp.read

  try:
    result.token = HeaderToken(tokenByte)
  except ValueError:
    raise newException(ValueError, "Invalid HeaderToken value")

  case result.token
  of htEndHeaders:
    # No data follows
    discard
  of htCustom:
    let format1 = HeaderDataFormat(inp.read)
    if format1 != hdfCountedString:
      raise newException(IOError, "Expected hdfCountedString for custom header name")
    result.headerName = readCountedString(inp)
    let format2 = HeaderDataFormat(inp.read)
    if format2 != hdfCountedString:
      raise newException(IOError, "Expected hdfCountedString for custom header value")
    result.headerValue = readCountedString(inp)
  of htStatusCode:
    let format = HeaderDataFormat(inp.read)
    if format != hdfByte:
      raise newException(IOError, "Expected hdfByte for status code")
    result.statusCode = TCPStatusCode(inp.read)
  of htStatusPhrase:
    let format = HeaderDataFormat(inp.read)
    if format != hdfCountedString:
      raise newException(IOError, "Expected hdfCountedString for status phrase")
    result.statusPhrase = readCountedString(inp)
  of htRequestUri:
    let format = HeaderDataFormat(inp.read)
    if format != hdfCountedString:
      raise newException(IOError, "Expected hdfCountedString for request URI")
    result.requestUri = readCountedString(inp)
  of htCloseConnection:
    let format = HeaderDataFormat(inp.read)
    if format != hdfVoid:
      raise newException(IOError, "Expected hdfVoid for close connection")
    # No data to read
  of htContentType:
    let format = HeaderDataFormat(inp.read)
    if format != hdfCountedString:
      raise newException(IOError, "Expected hdfCountedString for content type")
    result.contentType = readCountedString(inp)

proc readMessageFrame*(inp: InputStream): MessageFrame =
  ## Reads a MessageFrame from the input stream per section 2.2.3.3
  result.protocolId = readValue[int32](inp)
  if result.protocolId != 0x54454E2E:
    raise newException(IOError, "Invalid protocol identifier; expected 'NET.' (0x54454E2E)")

  result.majorVersion = inp.read
  result.minorVersion = inp.read
  if result.majorVersion != 1 or result.minorVersion != 0:
    raise newException(IOError, "Unsupported version: " & $result.majorVersion & "." & $result.minorVersion)

  result.operationType = OperationType(readValue[uint16](inp))
  result.contentLength = readContentLength(inp)

  # Read headers until EndHeaders
  while true:
    let header = readFrameHeader(inp)
    if header.token == htEndHeaders:
      break
    result.headers.add(header)

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
  if frame.protocolId != 0x54454E2E:
    raise newException(ValueError, "Protocol identifier must be 'NET.' (0x54454E2E)")
  if frame.majorVersion != 1 or frame.minorVersion != 0:
    raise newException(ValueError, "Version must be 1.0")

  writeValue[int32](outp, frame.protocolId)
  outp.write(frame.majorVersion)
  outp.write(frame.minorVersion)
  writeValue[uint16](outp, uint16(frame.operationType))
  writeContentLength(outp, frame.contentLength)
  for header in frame.headers:
    writeFrameHeader(outp, header)
  outp.write(byte(htEndHeaders))