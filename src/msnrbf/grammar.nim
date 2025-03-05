import faststreams/[inputs, outputs]
import enums
import types
import records/[arrays, class, member, methodinv, serialization]
import tables
import options
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
    referencedRecords*: seq[ReferenceableRecord] # Optional referenced records
    methodCall*: Option[BinaryMethodCall]        # Required method call
    methodReturn*: Option[BinaryMethodReturn]    # Or method return
    methodCallArray*: seq[ValueWithCode]   # Optional method call array
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
  let lib = readRecord(inp)
  if lib == rtBinaryLibrary:
    let library = readBinaryLibrary(inp)
    ctx.addLibrary(library)

  # Read the record type
  let recordType = readRecord(inp) 
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

proc readMethodCall*(inp: InputStream, ctx: ReferenceContext): tuple[call: BinaryMethodCall, array: seq[ValueWithCode]] =
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
     MessageFlag.ContextInArray in result.call.messageEnum:
    
    if not inp.readable:
      raise newException(IOError, "End of stream while reading call array")
      
    let arrayRecord = RecordType(inp.peek)
    if arrayRecord != rtArraySingleObject:
      raise newException(IOError, "Expected ArraySingleObject for call array, got " & $arrayRecord)

    # Read the array object
    let arrayObj = readArraySingleObject(inp)
    # Read array values
    for i in 0..<arrayObj.arrayInfo.length:
      result.array.add(readValueWithCode(inp))

proc readMethodReturn*(inp: InputStream, ctx: ReferenceContext): tuple[ret: BinaryMethodReturn, array: seq[ValueWithCode]] =
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
    # Read array values
    for i in 0..<arrayObj.arrayInfo.length:
      result.array.add(readValueWithCode(inp))

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

proc writeMethodCall*(outp: OutputStream, call: BinaryMethodCall, array: seq[ValueWithCode], ctx: SerializationContext) =
  ## Writes a method call + optional array, assigning IDs via context
  writeBinaryMethodCall(outp, call)

  # Write call array if specified in flags
  if MessageFlag.ArgsInArray in call.messageEnum or 
     MessageFlag.ContextInArray in call.messageEnum:
    if array.len == 0:
      raise newException(ValueError, "Call array expected but none provided")
    
    # Create and assign ID to ArraySingleObject
    let arrayRecord = ArrayRecord(
      kind: rtArraySingleObject,
      arraySingleObject: ArraySingleObject(
        recordType: rtArraySingleObject,
        arrayInfo: ArrayInfo(length: array.len.int32)  # objectId set by assignId
      )
    )
    let refRecord = ReferenceableRecord(kind: rtArraySingleObject, arrayRecord: arrayRecord)
    discard ctx.assignId(refRecord)  # Assigns and sets arrayInfo.objectId
    writeReferenceable(outp, refRecord)
    
    # Write array values (assumed to be primitives for now)
    for value in array:
      writeValueWithCode(outp, value)

proc writeMethodReturn*(outp: OutputStream, ret: BinaryMethodReturn, array: seq[ValueWithCode], ctx: SerializationContext) =
  ## Writes a method return + optional array, assigning IDs via context
  writeBinaryMethodReturn(outp, ret)

  # Write return array if specified in flags
  if MessageFlag.ReturnValueInArray in ret.messageEnum or
     MessageFlag.ArgsInArray in ret.messageEnum or
     MessageFlag.ContextInArray in ret.messageEnum or
     MessageFlag.ExceptionInArray in ret.messageEnum:
    if array.len == 0:
      raise newException(ValueError, "Return array expected but none provided")
    
    # Create and assign ID to ArraySingleObject
    let arrayRecord = ArrayRecord(
      kind: rtArraySingleObject,
      arraySingleObject: ArraySingleObject(
        recordType: rtArraySingleObject,
        arrayInfo: ArrayInfo(length: array.len.int32)  # objectId set by assignId
      )
    )
    let refRecord = ReferenceableRecord(kind: rtArraySingleObject, arrayRecord: arrayRecord)
    discard ctx.assignId(refRecord)  # Assigns and sets arrayInfo.objectId
    writeReferenceable(outp, refRecord)
    
    # Write array values (assumed to be primitives for now)
    for value in array:
      writeValueWithCode(outp, value)

proc writeRemotingMessage*(outp: OutputStream, msg: RemotingMessage, ctx: SerializationContext) =
  ## Writes complete remoting message, using context for ID management
  # Validate message
  if msg.header.recordType != rtSerializedStreamHeader:
    raise newException(ValueError, "Invalid header record type")
  if msg.tail.recordType != rtMessageEnd:
    raise newException(ValueError, "Invalid tail record type")
  if msg.methodCall.isNone and msg.methodReturn.isNone:
    raise newException(ValueError, "Message must have either method call or return")
  if msg.methodCall.isSome and msg.methodReturn.isSome:
    raise newException(ValueError, "Message cannot have both method call and return")

  # Write header (rootId adjusted based on callArray ID if present)
  var header = msg.header
  if msg.methodCall.isSome and (MessageFlag.ArgsInArray in msg.methodCall.get.messageEnum or
                                MessageFlag.ContextInArray in msg.methodCall.get.messageEnum):
    # Don't try to access last element if referencedRecords is empty
    if msg.referencedRecords.len > 0:
      header.rootId = ctx.recordToId.getOrDefault(msg.referencedRecords[^1], 1)  # Last ID or default
  elif msg.methodReturn.isSome and (MessageFlag.ReturnValueInArray in msg.methodReturn.get.messageEnum or
                                    MessageFlag.ArgsInArray in msg.methodReturn.get.messageEnum or
                                    MessageFlag.ContextInArray in msg.methodReturn.get.messageEnum or
                                    MessageFlag.ExceptionInArray in msg.methodReturn.get.messageEnum):
    # Don't try to access last element if referencedRecords is empty
    if msg.referencedRecords.len > 0:
      header.rootId = ctx.recordToId.getOrDefault(msg.referencedRecords[^1], 1)  # Last ID or default
  writeSerializationHeader(outp, header)

  # Write referenced records (IDs already assigned)
  for record in msg.referencedRecords:
    writeReferenceable(outp, record)

  # Write method call or return with array
  if msg.methodCall.isSome:
    writeMethodCall(outp, msg.methodCall.get, msg.methodCallArray, ctx)
  else:
    writeMethodReturn(outp, msg.methodReturn.get, msg.methodCallArray, ctx)

  # Write tail
  writeMessageEnd(outp, msg.tail)

# Keep backward compatibility
proc writeMethodCall*(outp: OutputStream, call: BinaryMethodCall, array: seq[ValueWithCode] = @[]) =
  ## Backward compatibility wrapper
  let ctx = newSerializationContext()
  writeMethodCall(outp, call, array, ctx)

proc writeMethodReturn*(outp: OutputStream, ret: BinaryMethodReturn, array: seq[ValueWithCode] = @[]) =
  ## Backward compatibility wrapper
  let ctx = newSerializationContext()
  writeMethodReturn(outp, ret, array, ctx)

proc writeRemotingMessage*(outp: OutputStream, msg: RemotingMessage) =
  ## Backward compatibility wrapper
  let ctx = newSerializationContext()
  writeRemotingMessage(outp, msg, ctx)

proc newRemotingMessage*(ctx: SerializationContext,
                        methodCall: Option[BinaryMethodCall] = none(BinaryMethodCall),
                        methodReturn: Option[BinaryMethodReturn] = none(BinaryMethodReturn),
                        callArray: seq[ValueWithCode] = @[],
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

  result = RemotingMessage(
    header: SerializationHeaderRecord(
      recordType: rtSerializedStreamHeader,
      rootId: 0,        # Default, adjusted below
      headerId: 0,      # Default, adjusted below
      majorVersion: 1,
      minorVersion: 0
    ),
    methodCall: methodCall,
    methodReturn: methodReturn,
    methodCallArray: callArray,
    referencedRecords: refs,
    tail: MessageEnd(recordType: rtMessageEnd)
  )

  # Adjust rootId and headerId based on flags
  if methodCall.isSome:
    let call = methodCall.get
    if MessageFlag.ArgsInArray in call.messageEnum or MessageFlag.ContextInArray in call.messageEnum:
      if callArray.len == 0:
        raise newException(ValueError, "Call array expected but none provided")
      result.header.rootId = 1    # Will be updated in writeMethodCall
      result.header.headerId = -1
    else:
      result.header.rootId = 0
      result.header.headerId = 0
  elif methodReturn.isSome:
    let ret = methodReturn.get
    if MessageFlag.ReturnValueInArray in ret.messageEnum or
       MessageFlag.ArgsInArray in ret.messageEnum or
       MessageFlag.ContextInArray in ret.messageEnum or
       MessageFlag.ExceptionInArray in ret.messageEnum:
      if callArray.len == 0:
        raise newException(ValueError, "Return array expected but none provided")
      result.header.rootId = 1    # Will be updated in writeMethodReturn
      result.header.headerId = -1
    else:
      result.header.rootId = 0
      result.header.headerId = 0

# Backward compatibility constructor
proc newRemotingMessage*(methodCall: Option[BinaryMethodCall] = none(BinaryMethodCall),
                        methodReturn: Option[BinaryMethodReturn] = none(BinaryMethodReturn),
                        callArray: seq[ValueWithCode] = @[],
                        refs: seq[ReferenceableRecord] = @[]): RemotingMessage =
  ## Backward compatibility constructor that creates its own SerializationContext
  let ctx = newSerializationContext()
  newRemotingMessage(ctx, methodCall, methodReturn, callArray, refs)
