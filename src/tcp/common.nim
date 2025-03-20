import faststreams/[inputs]
import ../msnrbf/[grammar, context, enums, types, helpers]
import ../msnrbf/records/[methodinv, member]
import asyncnet, asyncdispatch

const 
  DefaultTimeout* = 20000 # 20 seconds default timeout

proc readChunkedContentAsync*(socket: AsyncSocket, timeout: int): Future[seq[byte]] {.async.} =
  ## Reads chunked content from an async socket until a chunk size of 0 is encountered.
  ## Returns the complete message content as a sequence of bytes.
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
    if chunkSize == 0:
      # Read final delimiter
      var delimiterF = socket.recv(2)
      if not await withTimeout(delimiterF, timeout):
        raise newException(IOError, "Timeout while reading final chunk delimiter")
      let delimiter = await delimiterF
      if delimiter != "\r\n":
        raise newException(IOError, "Invalid final chunk delimiter")
      break
    if chunkSize < 0:
      raise newException(ValueError, "Negative chunk size")
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
      for i in 0..<data.len:
        chunkData[bytesRead + i] = data[i].byte
      bytesRead += data.len
    content.add(chunkData)
    # Read delimiter
    var delimiterF = socket.recv(2)
    if not await withTimeout(delimiterF, timeout):
      raise newException(IOError, "Timeout while reading chunk delimiter")
    let delimiter = await delimiterF
    if delimiter != "\r\n":
      raise newException(IOError, "Invalid chunk delimiter")
  return content

proc createMethodCallRequest*(methodName, typeName: string, args: seq[PrimitiveValue] = @[]): seq[byte] =
  ## Creates a binary-formatted method call request
  ## This will create a RemotingMessage with a BinaryMethodCall record
  
  # Create serialization context
  let ctx = newSerializationContext()
  
  # Create a method call with inline arguments
  var flags: MessageFlags = {MessageFlag.NoContext}
  
  if args.len > 0:
    flags.incl(MessageFlag.ArgsInline)
  else:
    flags.incl(MessageFlag.NoArgs)
  
  var call = BinaryMethodCall(
    recordType: rtMethodCall,
    messageEnum: flags,
    methodName: newStringValueWithCode(methodName),
    typeName: newStringValueWithCode(typeName)
  )
  
  if args.len > 0:
    var valueWithCodes: seq[ValueWithCode]
    for arg in args:
      valueWithCodes.add(toValueWithCode(arg))
    call.args = valueWithCodes
  
  # Create a complete message
  let msg = newRemotingMessage(ctx, methodCall = some(call))
  
  # Serialize to bytes
  return serializeRemotingMessage(msg)

proc extractMethodCallInfo*(data: seq[byte]): tuple[methodName, typeName: string, isOneWay: bool] =
  ## Extracts method name and type name from serialized message content
  
  try:
    # Deserialize the message
    var input = memoryInput(data)
    let msg = readRemotingMessage(input)
    
    # Extract method call info
    if msg.methodCall.isSome:
      let call = msg.methodCall.get
      let methodName = call.methodName.value.stringVal.value
      let typeName = call.typeName.value.stringVal.value
      return (methodName, typeName, false)
    else:
      # No method call found
      return ("", "", false)
  except:
    # Failed to extract method call info
    return ("", "", false)

proc createMethodReturnResponse*(returnValue: PrimitiveValue = PrimitiveValue(kind: ptNull)): seq[byte] =
  ## Creates a binary-formatted method return response
  
  # Create serialization context
  let ctx = newSerializationContext()
  
  # Create the method return
  var flags: MessageFlags = {MessageFlag.NoContext, MessageFlag.NoArgs}
  
  if returnValue.kind == ptNull:
    flags.incl(MessageFlag.NoReturnValue)
  else:
    flags.incl(MessageFlag.ReturnValueInline)
  
  var ret = BinaryMethodReturn(
    recordType: rtMethodReturn,
    messageEnum: flags
  )
  
  if returnValue.kind != ptNull:
    ret.returnValue = toValueWithCode(returnValue)
  
  # Create a complete message
  let msg = newRemotingMessage(ctx, methodReturn = some(ret))
  
  # Serialize to bytes
  return serializeRemotingMessage(msg)