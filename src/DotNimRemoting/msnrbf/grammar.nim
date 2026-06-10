import faststreams/[inputs, outputs]
import enums
import records/[arrays, methodinv, serialization]
import options, strutils
import context

type
  RemotingMessage* = ref object
    ## Represents a complete remoting message that follows MS-NRBF grammar
    ## This is a root object for a complete message exchange
    header*: SerializationHeaderRecord     # Required start header
    libraries*: seq[BinaryLibrary]         # Binary libraries needed by the message
    methodCall*: Option[BinaryMethodCall]        # Required method call
    methodReturn*: Option[BinaryMethodReturn]    # Or method return
    methodCallArray*: seq[RemotingValue]   # Optional method call array
    referencedRecords*: seq[RemotingValue] # Optional referenced records
    tail*: MessageEnd                      # Required message end marker

# String representations
proc `$`*(msg: RemotingMessage): string =
  ## Convert a RemotingMessage to string representation
  var parts = @[
    "RemotingMessage:",
    "  Header:",
    "    RootId: " & $msg.header.rootId,
    "    HeaderId: " & $msg.header.headerId,
    "    Version: " & $msg.header.majorVersion & "." & $msg.header.minorVersion
  ]
  
  if msg.methodCall.isSome:
    let callStr = $msg.methodCall.get
    parts.add("  " & callStr.replace("\n", "\n  "))
  
  if msg.methodReturn.isSome:
    let retStr = $msg.methodReturn.get
    parts.add("  " & retStr.replace("\n", "\n  "))
  
  if msg.methodCallArray.len > 0:
    var elements: seq[string] = @[]
    for elem in msg.methodCallArray:
      elements.add($elem)
    parts.add("  CallArray: [" & elements.join(", ") & "]")
  
  if msg.referencedRecords.len > 0:
    parts.add("  ReferencedRecords: " & $msg.referencedRecords.len & " records")
    for i, record in msg.referencedRecords:
      parts.add("    Record[" & $i & "]: kind=" & $record.kind)
  
  parts.add("  End of RemotingMessage " & $msg.tail.recordType)

  return parts.join("\n")


proc resolveReference*(msg: RemotingMessage, value: RemotingValue): RemotingValue =
  ## Follows a MemberReference to its record, searching referencedRecords and
  ## the call array. Non-reference values pass through unchanged.
  if value == nil or value.kind != rvReference:
    return value
  for rec in msg.referencedRecords:
    if objectIdOf(rec) == value.idRef:
      return rec
  for rec in msg.methodCallArray:
    if objectIdOf(rec) == value.idRef:
      return rec
  raise newException(ValueError, "Unresolved member reference id " & $value.idRef)

const
  callArrayFlags = {MessageFlag.ArgsIsArray, MessageFlag.ArgsInArray,
                    MessageFlag.ContextInArray, MessageFlag.MethodSignatureInArray,
                    MessageFlag.PropertyInArray, MessageFlag.GenericMethod}
    ## Flags that indicate a MethodCallArray record follows the
    ## BinaryMethodCall record (sections 2.2.1.1, 2.2.3.2)
  returnArrayFlags = {MessageFlag.ReturnValueInArray, MessageFlag.ArgsIsArray,
                      MessageFlag.ArgsInArray, MessageFlag.ContextInArray,
                      MessageFlag.ExceptionInArray, MessageFlag.PropertyInArray}
    ## Flags that indicate a MethodReturnCallArray record follows the
    ## BinaryMethodReturn record (sections 2.2.1.1, 2.2.3.4)

proc needsCallArray*(call: BinaryMethodCall): bool =
  ## Whether the message flags require a MethodCallArray record
  call.messageEnum * callArrayFlags != {}

proc needsCallArray*(ret: BinaryMethodReturn): bool =
  ## Whether the message flags require a MethodReturnCallArray record
  ret.messageEnum * returnArrayFlags != {}

proc readMethodCall*(inp: InputStream, ctx: ReferenceContext): tuple[call: BinaryMethodCall, array: seq[RemotingValue]] =
  ## Reads a method call + optional array
  ## Section 2.7: methodCall = 0*1(BinaryLibrary) BinaryMethodCall 0*1(callArray)

  if not inp.readable:
    raise newException(IOError, "End of stream while reading method call")

  # Check for optional library
  let nextRecord = peekRecord(inp)
  if nextRecord == rtBinaryLibrary:
    let library = readBinaryLibrary(inp)
    ctx.addLibrary(library)
    
    # Read method call after library
    result.call = readBinaryMethodCall(inp)
  elif nextRecord == rtMethodCall:
    result.call = readBinaryMethodCall(inp)
  else:
    raise newException(IOError, "Expected BinaryLibrary or BinaryMethodCall, got " & $nextRecord)

  # Handle optional call array based on flags
  if needsCallArray(result.call):
    if not inp.readable:
      raise newException(IOError, "End of stream while reading call array")
      
    let arrayRecord = peekRecord(inp)
    if arrayRecord != rtArraySingleObject:
      raise newException(IOError, "Expected ArraySingleObject for call array, got " & $arrayRecord)

    # Read the array object
    let arrayObj = readArraySingleObject(inp)
    # Read array values as RemotingValue objects
    # Kinda crude, but works for now
    var count = 0
    while count < arrayObj.arrayInfo.length:
      let nextType = peekRecord(inp)
      if nextType in {rtObjectNullMultiple, rtObjectNullMultiple256}:
        let nullsToRead = readOptimizedNulls(inp, nextType)
        let nullsToAdd = min(nullsToRead, arrayObj.arrayInfo.length - count)
        for i in 0..<nullsToAdd:
          result.array.add(RemotingValue(kind: rvNull))
        count += nullsToAdd
      else:
        result.array.add(readRemotingValue(inp, ctx))
        count += 1

proc readMethodReturn*(inp: InputStream, ctx: ReferenceContext): tuple[ret: BinaryMethodReturn, array: seq[RemotingValue]] =
  ## Reads a method return + optional array
  ## Section 2.7: methodReturn = 0*1(BinaryLibrary) BinaryMethodReturn 0*1(callArray)
  
  if not inp.readable:
    raise newException(IOError, "End of stream while reading method return")

  # Check for optional library
  let nextRecord = peekRecord(inp)
  if nextRecord == rtBinaryLibrary:
    let library = readBinaryLibrary(inp)
    ctx.addLibrary(library)
    
    # Read method return after library
    result.ret = readBinaryMethodReturn(inp)
  elif nextRecord == rtMethodReturn:
    result.ret = readBinaryMethodReturn(inp)
  else:
    raise newException(IOError, "Expected BinaryLibrary or BinaryMethodReturn, got " & $nextRecord)

  # Handle optional return array based on flags
  if needsCallArray(result.ret):
    if not inp.readable:
      raise newException(IOError, "End of stream while reading return array")
      
    let arrayRecord = peekRecord(inp)
    if arrayRecord != rtArraySingleObject:
      raise newException(IOError, "Expected ArraySingleObject for return array, got " & $arrayRecord)

    # Read the array object
    let arrayObj = readArraySingleObject(inp)
    # Read array values as RemotingValue objects
    # Kinda crude, but works for now
    var count = 0
    while count < arrayObj.arrayInfo.length:
      let nextType = peekRecord(inp)
      if nextType in {rtObjectNullMultiple, rtObjectNullMultiple256}:
        let nullsToRead = readOptimizedNulls(inp, nextType)
        let nullsToAdd = min(nullsToRead, arrayObj.arrayInfo.length - count)
        for i in 0..<nullsToAdd:
          result.array.add(RemotingValue(kind: rvNull))
        count += nullsToAdd
      else:
        result.array.add(readRemotingValue(inp, ctx))
        count += 1

proc readRemotingMessage*(inp: InputStream): RemotingMessage =
  ## Reads a complete remoting message following MS-NRBF grammar
  ## Section 2.7: remotingMessage = SerializationHeader *(referenceable) 
  ##                                (methodCall/methodReturn) *(referenceable) MessageEnd
  
  result = new RemotingMessage
  let ctx = newReferenceContext()

  # Read required header
  if not inp.readable:
    raise newException(IOError, "Empty stream")
    
  let headerType = peekRecord(inp)
  if headerType != rtSerializedStreamHeader:
    raise newException(IOError, "Expected SerializationHeader, got " & $headerType)
  result.header = readSerializationHeader(inp)

  # Read preceding referenceable records until we hit method call/return
  while inp.readable:
    let nextType = peekRecord(inp)
    
    # Found method - break loop
    if nextType in {rtMethodCall, rtMethodReturn}:
      break
      
    # Handle BinaryLibrary records
    if nextType == rtBinaryLibrary:
      let library = readBinaryLibrary(inp)
      ctx.addLibrary(library)
      result.libraries.add(library)
      continue
      
    # Unexpected end
    if nextType == rtMessageEnd:
      raise newException(IOError, "Unexpected MessageEnd before method")
      
    # Read referenceable record as RemotingValue
    result.referencedRecords.add(readRemotingValue(inp, ctx))

  # Read required method call or return
  if not inp.readable:
    raise newException(IOError, "End of stream before method")
    
  let methodType = peekRecord(inp)
  case methodType:
  of rtMethodCall:
    let (call, array) = readMethodCall(inp, ctx)
    result.methodCall = some(call)
    result.methodCallArray = array
  of rtMethodReturn:
    let (ret, array) = readMethodReturn(inp, ctx)
    result.methodReturn = some(ret)
    result.methodCallArray = array
  else:
    raise newException(IOError, "Expected MethodCall or MethodReturn, got " & $methodType)

  # Read trailing referenceable records until MessageEnd
  while inp.readable:
    let nextType = peekRecord(inp)

    # Found end marker
    if nextType == rtMessageEnd:
      discard inp.read # Consume the record type
      result.tail = MessageEnd(recordType: rtMessageEnd)
      
      # Libraries are already added to result.libraries directly during reading
      
      return
      
    # Handle BinaryLibrary records
    if nextType == rtBinaryLibrary:
      let library = readBinaryLibrary(inp)
      ctx.addLibrary(library)
      result.libraries.add(library)
      continue
      
    # Read referenceable record as RemotingValue
    result.referencedRecords.add(readRemotingValue(inp, ctx))

  raise newException(IOError, "Missing MessageEnd")


proc writeMethodCall*(outp: OutputStream, call: BinaryMethodCall, array: seq[RemotingValue], ctx: SerializationContext) =
  ## Writes a method call and its optional call array, using the provided callArrayRecord if needed
  # Write the BinaryMethodCall record to the output stream
  writeBinaryMethodCall(outp, call)

  # Determine if a call array is required based on the messageEnum flags
  if needsCallArray(call):
    # Validate that array elements are provided
    if array.len == 0:
      raise newException(ValueError, "Call array expected but none provided")
    
    # Create and write the array record containing the elements
    let arrayRecord = RemotingValue(kind: rvArray, arrayVal: ArrayValue(
      record: ArrayRecord(
        kind: rtArraySingleObject,
        arraySingleObject: ArraySingleObject(
          recordType: rtArraySingleObject,
          arrayInfo: ArrayInfo(length: array.len.int32)
        )
      ),
      elements: array
    ))
    writeRemotingValue(outp, arrayRecord, ctx)

proc writeMethodReturn*(outp: OutputStream, ret: BinaryMethodReturn, array: seq[RemotingValue], ctx: SerializationContext) =
  ## Writes a BinaryMethodReturn record and its optional call array to the output stream
  writeBinaryMethodReturn(outp, ret)

  # Write return array if specified in flags
  if needsCallArray(ret):
    # Validate that array elements are provided
    if array.len == 0:
      raise newException(ValueError, "Call array expected but none provided")
    
    # Create and write the array record containing the elements
    let arrayRecord = RemotingValue(kind: rvArray, arrayVal: ArrayValue(
      record: ArrayRecord(
        kind: rtArraySingleObject,
        arraySingleObject: ArraySingleObject(
          recordType: rtArraySingleObject,
          arrayInfo: ArrayInfo(length: array.len.int32)
        )
      ),
      elements: array
    ))
    writeRemotingValue(outp, arrayRecord, ctx)

proc writeRemotingMessage*(outp: OutputStream, msg: RemotingMessage, ctx: SerializationContext) =
  ## Writes a complete remoting message, using the context for ID management.
  
  # Validate message structure
  if msg.header.recordType != rtSerializedStreamHeader:
    raise newException(ValueError, "Invalid header record type")
  if msg.tail.recordType != rtMessageEnd:
    raise newException(ValueError, "Invalid tail record type")
  if msg.methodCall.isNone and msg.methodReturn.isNone:
    raise newException(ValueError, "Message must have either method call or return")
  if msg.methodCall.isSome and msg.methodReturn.isSome:
    raise newException(ValueError, "Message cannot have both method call and return")

  # Write the header with pre-set rootId
  writeSerializationHeader(outp, msg.header)

  # Write all BinaryLibrary records
  for lib in msg.libraries:
    writeBinaryLibrary(outp, lib)


  # Write method call or method return, including the call array if present
  if msg.methodCall.isSome:
    writeMethodCall(outp, msg.methodCall.get, msg.methodCallArray, ctx)
  elif msg.methodReturn.isSome:
    writeMethodReturn(outp, msg.methodReturn.get, msg.methodCallArray, ctx)
  
  # Write referenced records (classes, arrays, strings). Skip any already
  # emitted while writing the call/return (a deferred or shared record):
  # re-writing would emit a top-level MemberReference, not a valid
  # referenceable record (Section 2.7).
  for record in msg.referencedRecords:
    if not ctx.hasWrittenObject(cast[pointer](record)):
      writeRemotingValue(outp, record, ctx)

  # Write the message end
  writeMessageEnd(outp, msg.tail)

proc newRemotingMessage*(ctx: SerializationContext,
                        methodCall: Option[BinaryMethodCall] = none(BinaryMethodCall),
                        methodReturn: Option[BinaryMethodReturn] = none(BinaryMethodReturn),
                        callArray: seq[RemotingValue] = @[],
                        refs: seq[RemotingValue] = @[],
                        libraries: seq[BinaryLibrary] = @[]): RemotingMessage =
  ## Creates a new RemotingMessage. IDs will be assigned during serialization.
  # Validate that exactly one of methodCall or methodReturn is provided
  if methodCall.isNone and methodReturn.isNone:
    raise newException(ValueError, "Must provide either method call or return")
  if methodCall.isSome and methodReturn.isSome:
    raise newException(ValueError, "Cannot have both method call and return")

  # Determine if a call array is needed based on message flags
  let hasCallArray =
    if methodCall.isSome: needsCallArray(methodCall.get)
    else: needsCallArray(methodReturn.get)

  # Determine rootId based on whether we need a call array
  var rootId: int32 = 0
  if hasCallArray:
    if callArray.len == 0:
      raise newException(ValueError, "Call array expected but none provided")
    # Use first available ID for rootId
    rootId = 1

  # Create header with appropriate rootId and headerId
  let header = SerializationHeaderRecord(
    recordType: rtSerializedStreamHeader,
    rootId: rootId,
    headerId: if hasCallArray: -1 else: 0,
    majorVersion: 1,
    minorVersion: 0
  )

  # Construct and return the RemotingMessage
  result = RemotingMessage(
    header: header,
    libraries: libraries,
    methodCall: methodCall,
    methodReturn: methodReturn,
    methodCallArray: callArray,
    referencedRecords: refs,
    tail: MessageEnd(recordType: rtMessageEnd)
  )
