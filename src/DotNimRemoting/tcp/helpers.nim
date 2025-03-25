import types

# Define debug template for logging
template debugLog*(msg: varargs[string, `$`]) =
  when not defined(release) or not defined(danger):
    echo msg

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
                       closeConnection: bool = false, useChunked: bool = false): MessageFrame =
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
    contentLength: if useChunked:
                     ContentLength(distribution: cdChunked)
                   else:
                     ContentLength(distribution: cdNotChunked, length: messageContent.len.int32),
    headers: headers,
    messageContent: messageContent
  )
