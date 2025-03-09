import faststreams/[inputs, outputs]
import enums
import records/[arrays, class, member, methodinv, serialization]
import tables
import options, strutils
import hashes

type
  SerializationContext* = ref object
    ## Manages object ID assignment during serialization, tracking records and IDs
    nextId*: int32                               # Counter for generating new IDs, starts at 1
    recordToId*: Table[ReferenceableRecord, int32]  # Maps records to their assigned IDs

  RemotingMessage* = ref object
    ## Represents a complete remoting message that follows MS-NRBF grammar
    ## This is a root object for a complete message exchange
    header*: SerializationHeaderRecord     # Required start header
    methodCall*: Option[BinaryMethodCall]        # Required method call
    methodReturn*: Option[BinaryMethodReturn]    # Or method return
    methodCallArray*: seq[RemotingValue]   # Optional method call array
    referencedRecords*: seq[ReferenceableRecord] # Optional referenced records
    callArrayRecord*: Option[ReferenceableRecord] # Optional call array record
    tail*: MessageEnd                      # Required message end marker

  ReferenceableRecord* = ref object
    ## Base type for records that can be referenced
    ## Classes/Arrays/BinaryObjectString
    case kind*: RecordType
    of rtClassWithId..rtClassWithMembersAndTypes:
      classRecord*: ClassRecord # Any class record variant
    of rtBinaryArray..rtArraySingleString:  
      arrayRecord*: ArrayRecord # Any array record variant
    of rtBinaryObjectString:
      stringRecord*: BinaryObjectString
    else:
      discard

  ClassRecord* = ref object
    ## Union of all possible class records
    case kind*: RecordType
    of rtClassWithId:
      classWithId*: ClassWithId
    of rtSystemClassWithMembers:
      systemClassWithMembers*: SystemClassWithMembers 
    of rtClassWithMembers:
      classWithMembers*: ClassWithMembers
    of rtSystemClassWithMembersAndTypes:
      systemClassWithMembersAndTypes*: SystemClassWithMembersAndTypes
    of rtClassWithMembersAndTypes:  
      classWithMembersAndTypes*: ClassWithMembersAndTypes
    else:
      discard

  ArrayRecord* = ref object
    ## Union of all possible array records  
    case kind*: RecordType
    of rtBinaryArray:
      binaryArray*: BinaryArray
    of rtArraySinglePrimitive:
      arraySinglePrimitive*: ArraySinglePrimitive
    of rtArraySingleObject:  
      arraySingleObject*: ArraySingleObject
    of rtArraySingleString:
      arraySingleString*: ArraySingleString
    else:
      discard

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

# Reference tracking during deserialization
type
  ReferenceContext* = ref object
    ## Tracks object references during deserialization
    objects: Table[int32, ReferenceableRecord] # Maps object IDs to records
    libraries: Table[int32, BinaryLibrary]     # Maps library IDs to libraries

proc addReference*(ctx: ReferenceContext, id: int32, record: ReferenceableRecord) =
  ## Track a new object reference
  if id in ctx.objects:
    raise newException(IOError, "Duplicate object ID: " & $id)
  ctx.objects[id] = record

proc addLibrary*(ctx: ReferenceContext, lib: BinaryLibrary) =
  ## Track a new library reference
  if lib.libraryId in ctx.libraries:
    raise newException(IOError, "Duplicate library ID: " & $lib.libraryId)
  ctx.libraries[lib.libraryId] = lib

proc getReference*(ctx: ReferenceContext, id: int32): ReferenceableRecord =
  ## Look up referenced object 
  if id notin ctx.objects:
    raise newException(IOError, "Missing object reference: " & $id)
  result = ctx.objects[id]

proc getLibrary*(ctx: ReferenceContext, id: int32): BinaryLibrary =
  ## Look up referenced library
  if id notin ctx.libraries:
    raise newException(IOError, "Missing library reference: " & $id)
  result = ctx.libraries[id]

proc newReferenceContext*(): ReferenceContext =
  ReferenceContext(
    objects: initTable[int32, ReferenceableRecord](),
    libraries: initTable[int32, BinaryLibrary]()
  )

proc hash*(x: ReferenceableRecord): Hash =
  ## Custom hash function for ReferenceableRecord.
  ## Using the object's memory address as hash allows us to compare
  ## records by reference identity rather than content
  result = hash(cast[pointer](x))

proc newSerializationContext*(): SerializationContext =
  ## Creates a new SerializationContext with an initial ID of 1
  SerializationContext(
    nextId: 1,
    recordToId: initTable[ReferenceableRecord, int32]()
  )

proc assignId*(ctx: SerializationContext, record: ReferenceableRecord): int32 =
  ## Assigns a unique ID to a ReferenceableRecord and sets its inner objectId.
  ## Returns the assigned or existing ID.
  if record in ctx.recordToId:
    return ctx.recordToId[record]
  
  # Assign new ID and increment counter
  let id = ctx.nextId
  ctx.nextId += 1
  ctx.recordToId[record] = id
  
  # Set the objectId in the inner record based on kind
  case record.kind
  of rtClassWithId..rtClassWithMembersAndTypes:
    case record.classRecord.kind
    of rtClassWithId:
      record.classRecord.classWithId.objectId = id
    of rtSystemClassWithMembers:
      record.classRecord.systemClassWithMembers.classInfo.objectId = id
    of rtClassWithMembers:
      record.classRecord.classWithMembers.classInfo.objectId = id
    of rtSystemClassWithMembersAndTypes:
      record.classRecord.systemClassWithMembersAndTypes.classInfo.objectId = id
    of rtClassWithMembersAndTypes:
      record.classRecord.classWithMembersAndTypes.classInfo.objectId = id
    else:
      discard  # Unreachable due to outer case constraint
  of rtBinaryArray..rtArraySingleString:
    case record.arrayRecord.kind
    of rtBinaryArray:
      record.arrayRecord.binaryArray.objectId = id
    of rtArraySinglePrimitive:
      record.arrayRecord.arraySinglePrimitive.arrayInfo.objectId = id
    of rtArraySingleObject:
      record.arrayRecord.arraySingleObject.arrayInfo.objectId = id
    of rtArraySingleString:
      record.arrayRecord.arraySingleString.arrayInfo.objectId = id
    else:
      discard  # Unreachable due to outer case constraint
  of rtBinaryObjectString:
    record.stringRecord.objectId = id
  else:
    raise newException(ValueError, "Invalid ReferenceableRecord kind: " & $record.kind)
  
  return id

proc readReferenceable*(inp: InputStream, ctx: ReferenceContext): ReferenceableRecord =
  ## Reads a referenceable record (Classes/Arrays/BinaryObjectString)
  ## Section 2.7 grammar: referenceable = Classes/Arrays/BinaryObjectString

  # First try reading library reference that may precede any referenceable
  let recordType = peekRecord(inp)
  if recordType == rtBinaryLibrary:
    let library = readBinaryLibrary(inp)
    ctx.addLibrary(library)

  result = ReferenceableRecord(kind: recordType)

  # Handle based on record type following grammar rules
  case recordType:
  of rtClassWithId..rtClassWithMembersAndTypes:
    result.classRecord = ClassRecord(kind: recordType)
    case recordType:
    of rtClassWithId:
      result.classRecord.classWithId = readClassWithId(inp)
      ctx.addReference(result.classRecord.classWithId.objectId, result)
    of rtSystemClassWithMembers:
      result.classRecord.systemClassWithMembers = readSystemClassWithMembers(inp)
      ctx.addReference(result.classRecord.systemClassWithMembers.classInfo.objectId, result)  
    of rtClassWithMembers:
      result.classRecord.classWithMembers = readClassWithMembers(inp)
      ctx.addReference(result.classRecord.classWithMembers.classInfo.objectId, result)
    of rtSystemClassWithMembersAndTypes:
      result.classRecord.systemClassWithMembersAndTypes = readSystemClassWithMembersAndTypes(inp)
      ctx.addReference(result.classRecord.systemClassWithMembersAndTypes.classInfo.objectId, result)
    of rtClassWithMembersAndTypes:
      result.classRecord.classWithMembersAndTypes = readClassWithMembersAndTypes(inp)
      ctx.addReference(result.classRecord.classWithMembersAndTypes.classInfo.objectId, result)
    else: discard

  of rtBinaryArray..rtArraySingleString:
    result.arrayRecord = ArrayRecord(kind: recordType)
    case recordType:
    of rtBinaryArray:
      result.arrayRecord.binaryArray = readBinaryArray(inp)
      ctx.addReference(result.arrayRecord.binaryArray.objectId, result)
    of rtArraySinglePrimitive:  
      result.arrayRecord.arraySinglePrimitive = readArraySinglePrimitive(inp)
      ctx.addReference(result.arrayRecord.arraySinglePrimitive.arrayInfo.objectId, result)
    of rtArraySingleObject:
      result.arrayRecord.arraySingleObject = readArraySingleObject(inp)
      ctx.addReference(result.arrayRecord.arraySingleObject.arrayInfo.objectId, result)
    of rtArraySingleString:
      result.arrayRecord.arraySingleString = readArraySingleString(inp) 
      ctx.addReference(result.arrayRecord.arraySingleString.arrayInfo.objectId, result)
    else: discard

  of rtBinaryObjectString:
    result.stringRecord = readBinaryObjectString(inp)
    ctx.addReference(result.stringRecord.objectId, result)

  else:
    raise newException(IOError, "Invalid referenceable record type: " & $recordType)

proc readMethodCall*(inp: InputStream, ctx: ReferenceContext): tuple[call: BinaryMethodCall, array: seq[RemotingValue]] =
  ## Reads a method call + optional array
  ## Section 2.7: methodCall = 0*1(BinaryLibrary) BinaryMethodCall 0*1(callArray)

  if not inp.readable:
    raise newException(IOError, "End of stream while reading method call")

  # Check for optional library
  let nextRecord = RecordType(inp.peek)
  if nextRecord == rtBinaryLibrary:
    # Consume the peeked byte and read library
    discard inp.read 
    let library = readBinaryLibrary(inp)
    ctx.addLibrary(library)
    
    # Read method call after library
    result.call = readBinaryMethodCall(inp)
  elif nextRecord == rtMethodCall:
    result.call = readBinaryMethodCall(inp)
  else:
    raise newException(IOError, "Expected BinaryLibrary or BinaryMethodCall, got " & $nextRecord)

  # Handle optional call array based on flags
  if MessageFlag.ArgsInArray in result.call.messageEnum or
     MessageFlag.ContextInArray in result.call.messageEnum or
     MessageFlag.MethodSignatureInArray in result.call.messageEnum or
     MessageFlag.GenericMethod in result.call.messageEnum:
    
    if not inp.readable:
      raise newException(IOError, "End of stream while reading call array")
      
    let arrayRecord = RecordType(inp.peek)
    if arrayRecord != rtArraySingleObject:
      raise newException(IOError, "Expected ArraySingleObject for call array, got " & $arrayRecord)

    # Read the array object
    let arrayObj = readArraySingleObject(inp)
    # Read array values as RemotingValue objects
    for i in 0..<arrayObj.arrayInfo.length:
      result.array.add(readRemotingValue(inp))
    # The array contains additional information based on the flags:
    # - If MethodSignatureInArray is set, the array includes the method signature
    # - If GenericMethod is set, the array includes the generic type arguments
    # - If ArgsInArray is set, the array contains the arguments
    # - If ContextInArray is set, the array contains the call context

proc readMethodReturn*(inp: InputStream, ctx: ReferenceContext): tuple[ret: BinaryMethodReturn, array: seq[RemotingValue]] =
  ## Reads a method return + optional array
  ## Section 2.7: methodReturn = 0*1(BinaryLibrary) BinaryMethodReturn 0*1(callArray)
  
  if not inp.readable:
    raise newException(IOError, "End of stream while reading method return")

  # Check for optional library
  let nextRecord = RecordType(inp.peek)
  if nextRecord == rtBinaryLibrary:
    # Consume the peeked byte and read library
    discard inp.read
    let library = readBinaryLibrary(inp)
    ctx.addLibrary(library)
    
    # Read method return after library
    result.ret = readBinaryMethodReturn(inp)
  elif nextRecord == rtMethodReturn:
    result.ret = readBinaryMethodReturn(inp)
  else:
    raise newException(IOError, "Expected BinaryLibrary or BinaryMethodReturn, got " & $nextRecord)

  # Handle optional return array based on flags  
  if MessageFlag.ReturnValueInArray in result.ret.messageEnum or
     MessageFlag.ArgsInArray in result.ret.messageEnum or
     MessageFlag.ContextInArray in result.ret.messageEnum or
     MessageFlag.ExceptionInArray in result.ret.messageEnum:
     
    if not inp.readable:
      raise newException(IOError, "End of stream while reading return array")
      
    let arrayRecord = RecordType(inp.peek)
    if arrayRecord != rtArraySingleObject:
      raise newException(IOError, "Expected ArraySingleObject for return array, got " & $arrayRecord)

    # Read the array object
    let arrayObj = readArraySingleObject(inp)
    # Read array values as RemotingValue objects
    for i in 0..<arrayObj.arrayInfo.length:
      result.array.add(readRemotingValue(inp))

proc readRemotingMessage*(inp: InputStream): RemotingMessage =
  ## Reads a complete remoting message following MS-NRBF grammar
  ## Section 2.7: remotingMessage = SerializationHeader *(referenceable) 
  ##                                (methodCall/methodReturn) *(referenceable) MessageEnd
  
  result = new RemotingMessage
  let ctx = newReferenceContext()

  # Read required header
  if not inp.readable:
    raise newException(IOError, "Empty stream")
    
  let headerType = RecordType(inp.peek)
  if headerType != rtSerializedStreamHeader:
    raise newException(IOError, "Expected SerializationHeader, got " & $headerType)
  result.header = readSerializationHeader(inp)

  # Read preceding referenceable records until we hit method call/return
  while inp.readable:
    let nextType = RecordType(inp.peek)
    
    # Found method - break loop
    if nextType in {rtMethodCall, rtMethodReturn}:
      break
      
    # Unexpected end
    if nextType == rtMessageEnd:
      raise newException(IOError, "Unexpected MessageEnd before method")
      
    # Read referenceable record
    result.referencedRecords.add(readReferenceable(inp, ctx))

  # Read required method call or return
  if not inp.readable:
    raise newException(IOError, "End of stream before method")
    
  let methodType = RecordType(inp.peek)
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
    let nextType = RecordType(inp.peek)

    # Found end marker
    if nextType == rtMessageEnd:
      discard inp.read # Consume the record type
      result.tail = MessageEnd(recordType: rtMessageEnd)
      return
    # Read referenceable record
    result.referencedRecords.add(readReferenceable(inp, ctx))

  raise newException(IOError, "Missing MessageEnd")

proc writeReferenceable*(outp: OutputStream, record: ReferenceableRecord) = 
  ## Writes a referenceable record (Classes/Arrays/BinaryObjectString)
  ## Section 2.7 grammar: referenceable = Classes/Arrays/BinaryObjectString

  case record.kind:
  of rtClassWithId..rtClassWithMembersAndTypes:
    case record.classRecord.kind:
    of rtClassWithId:
      writeClassWithId(outp, record.classRecord.classWithId)
    of rtSystemClassWithMembers:
      writeSystemClassWithMembers(outp, record.classRecord.systemClassWithMembers)
    of rtClassWithMembers:
      writeClassWithMembers(outp, record.classRecord.classWithMembers)
    of rtSystemClassWithMembersAndTypes:
      writeSystemClassWithMembersAndTypes(outp, record.classRecord.systemClassWithMembersAndTypes)
    of rtClassWithMembersAndTypes:
      writeClassWithMembersAndTypes(outp, record.classRecord.classWithMembersAndTypes)
    else: discard

  of rtBinaryArray..rtArraySingleString:
    case record.arrayRecord.kind:
    of rtBinaryArray:
      writeBinaryArray(outp, record.arrayRecord.binaryArray)
    of rtArraySinglePrimitive:
      writeArraySinglePrimitive(outp, record.arrayRecord.arraySinglePrimitive)
    of rtArraySingleObject:
      writeArraySingleObject(outp, record.arrayRecord.arraySingleObject)
    of rtArraySingleString:
      writeArraySingleString(outp, record.arrayRecord.arraySingleString)
    else: discard

  of rtBinaryObjectString:
    writeBinaryObjectString(outp, record.stringRecord)

  else:
    raise newException(ValueError, "Invalid referenceable record type: " & $record.kind)

proc writeMethodCall*(outp: OutputStream, call: BinaryMethodCall, array: seq[RemotingValue], callArrayRecord: Option[ReferenceableRecord], ctx: SerializationContext) =
  ## Writes a method call and its optional call array, using the provided callArrayRecord if needed
  # Write the BinaryMethodCall record to the output stream
  writeBinaryMethodCall(outp, call)

  # Determine if a call array is required based on the messageEnum flags
  if MessageFlag.ArgsInArray in call.messageEnum or 
     MessageFlag.ContextInArray in call.messageEnum or
     MessageFlag.MethodSignatureInArray in call.messageEnum or
     MessageFlag.GenericMethod in call.messageEnum:
    # Validate that a call array record and elements are provided
    if callArrayRecord.isNone or array.len == 0:
      raise newException(ValueError, "Call array expected but none provided")
    
    # Write the call array record (e.g., ArraySingleObject)
    writeReferenceable(outp, callArrayRecord.get)
    
    # Serialize each element in the call array
    for value in array:
      writeRemotingValue(outp, value)

proc writeMethodReturn*(outp: OutputStream, ret: BinaryMethodReturn, array: seq[RemotingValue], callArrayRecord: Option[ReferenceableRecord], ctx: SerializationContext) =
  ## Writes a BinaryMethodReturn record and its optional call array to the output stream
  writeBinaryMethodReturn(outp, ret)

  # Write return array if specified in flags
  if MessageFlag.ReturnValueInArray in ret.messageEnum or 
     MessageFlag.ArgsInArray in ret.messageEnum or 
     MessageFlag.ContextInArray in ret.messageEnum or 
     MessageFlag.ExceptionInArray in ret.messageEnum:
    # Validate that a call array is provided when expected
    if callArrayRecord.isNone or array.len == 0:
      raise newException(ValueError, "Call array expected but none provided")
    
    # Write the call array record (e.g., ArraySingleObject)
    writeReferenceable(outp, callArrayRecord.get)
    
    # Write each RemotingValue in the array
    for value in array:
      writeRemotingValue(outp, value)

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

  # Write referenced records (e.g., classes, arrays, strings)
  for record in msg.referencedRecords:
    writeReferenceable(outp, record)

  # Write method call or method return, including the call array if present
  if msg.methodCall.isSome:
    writeMethodCall(outp, msg.methodCall.get, msg.methodCallArray, msg.callArrayRecord, ctx)
  elif msg.methodReturn.isSome:
    writeMethodReturn(outp, msg.methodReturn.get, msg.methodCallArray, msg.callArrayRecord, ctx)

  # Write the message end
  writeMessageEnd(outp, msg.tail)

proc newRemotingMessage*(ctx: SerializationContext,
                        methodCall: Option[BinaryMethodCall] = none(BinaryMethodCall),
                        methodReturn: Option[BinaryMethodReturn] = none(BinaryMethodReturn),
                        callArray: seq[RemotingValue] = @[],
                        refs: seq[ReferenceableRecord] = @[]): RemotingMessage =
  ## Creates a new RemotingMessage, assigning IDs to referencedRecords using the context
  # Validate that exactly one of methodCall or methodReturn is provided
  if methodCall.isNone and methodReturn.isNone:
    raise newException(ValueError, "Must provide either method call or return")
  if methodCall.isSome and methodReturn.isSome:
    raise newException(ValueError, "Cannot have both method call and return")

  # Assign IDs to all referenced records
  for r in refs:
    discard ctx.assignId(r)

  # Determine if a call array is needed based on message flags
  var needsCallArray = false
  if methodCall.isSome:
    let call = methodCall.get
    needsCallArray = MessageFlag.ArgsInArray in call.messageEnum or
                     MessageFlag.ContextInArray in call.messageEnum or
                     MessageFlag.MethodSignatureInArray in call.messageEnum or
                     MessageFlag.GenericMethod in call.messageEnum
  elif methodReturn.isSome:
    let ret = methodReturn.get
    needsCallArray = MessageFlag.ReturnValueInArray in ret.messageEnum or
                     MessageFlag.ArgsInArray in ret.messageEnum or
                     MessageFlag.ContextInArray in ret.messageEnum or
                     MessageFlag.ExceptionInArray in ret.messageEnum

  # Create call array record if needed
  var callArrayRef = none(ReferenceableRecord)
  var rootId: int32 = 0
  if needsCallArray:
    if callArray.len == 0:
      raise newException(ValueError, "Call array expected but none provided")
    let arrayRecord = ArrayRecord(
      kind: rtArraySingleObject,
      arraySingleObject: ArraySingleObject(
        recordType: rtArraySingleObject,
        arrayInfo: ArrayInfo(length: callArray.len.int32)
      )
    )
    var refRecord = ReferenceableRecord(kind: rtArraySingleObject, arrayRecord: arrayRecord)
    rootId = ctx.assignId(refRecord)
    refRecord.arrayRecord.arraySingleObject.arrayInfo.objectId = rootId
    callArrayRef = some(refRecord)

  # Create header with appropriate rootId and headerId
  let header = SerializationHeaderRecord(
    recordType: rtSerializedStreamHeader,
    rootId: rootId,
    headerId: if needsCallArray: -1 else: 0,
    majorVersion: 1,
    minorVersion: 0
  )

  # Construct and return the RemotingMessage
  result = RemotingMessage(
    header: header,
    methodCall: methodCall,
    methodReturn: methodReturn,
    methodCallArray: callArray,
    callArrayRecord: callArrayRef,
    referencedRecords: refs,
    tail: MessageEnd(recordType: rtMessageEnd)
  )
