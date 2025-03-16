import faststreams/inputs
import types

proc newCountedString*(encoding: StringEncoding, value: string): CountedString =
  ## Create a new CountedString object
  result.encoding = encoding
  result.value = value

proc newRequestUriHeader*(uri: string): FrameHeader =
  ## Create a new RequestUriHeader object
  result = FrameHeader(token: htRequestUri, requestUri: newCountedString(seUtf8, uri))

proc newContentTypeHeader*(contentType: string): FrameHeader =
  ## Create a new ContentTypeHeader object
  result = FrameHeader(token: htContentType, contentType: newCountedString(seUTF8, contentType))

proc createMessageFrame*(operationType: OperationType, requestUri: string, 
                       contentType: string, messageContent: seq[byte],
                       closeConnection: bool = false): MessageFrame =
  ## Create a message frame as specified in section 2.2.3.3 of MS-NRTP
  
  # Create headers
  var headers: seq[FrameHeader] = @[
    newRequestUriHeader(requestUri),
    newContentTypeHeader(contentType)
  ]

  # Add close connection header if needed
  if closeConnection:
    headers.add(FrameHeader(token: htCloseConnection))

  # Create message frame
  result = MessageFrame(
    protocolId: ProtocolId,
    majorVersion: MajorVersion,
    minorVersion: MinorVersion,
    operationType: operationType,
    contentLength: ContentLength(
      distribution: cdNotChunked,
      length: messageContent.len.int32
    ),
    headers: headers
  )

proc peekMessageFrame*(data: openArray[byte]): tuple[frame: MessageFrame, bytesRead: int] =
  ## Attempts to parse a MessageFrame from the provided data without consuming it
  ## Returns the parsed frame and the number of bytes read if successful
  ## Raises IOError if there's not enough data
  
  var inp = memoryInput(data)
  
  # Save the current position
  let startPos = inp.pos()
  
  # Try to parse the message frame
  try:
    let frame = readMessageFrame(inp)
    let endPos = inp.pos()
    return (frame, endPos - startPos)
  except IOError:
    # Not enough data or invalid format
    raise
