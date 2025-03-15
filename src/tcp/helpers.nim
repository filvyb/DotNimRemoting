import types

proc newCountedString*(encoding: StringEncoding, value: string): CountedString =
  ## Create a new CountedString object
  result.encoding = encoding
  result.value = value

proc newRequestUriHeader*(uri: string): FrameHeader =
  ## Create a new RequestUriHeader object
  result.token = htRequestUri
  result.headerValue = newCountedString(seUTF8, uri)

proc newContentTypeHeader*(contentType: string): FrameHeader =
  ## Create a new ContentTypeHeader object
  result.token = htContentType
  result.headerValue = newCountedString(seUTF8, contentType)

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
