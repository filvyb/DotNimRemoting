import faststreams/[inputs, outputs]
import enums
import types
import records/[arrays, class, member, methodinv, serialization]
import tables
import options

type
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

proc writeMethodCall*(outp: OutputStream, call: BinaryMethodCall, array: seq[ValueWithCode] = @[]) =
  ## Writes a method call + optional array
  ## Section 2.7: methodCall = 0*1(BinaryLibrary) BinaryMethodCall 0*1(callArray)
  
  writeBinaryMethodCall(outp, call)

  # Write call array if specified in flags
  if MessageFlag.ArgsInArray in call.messageEnum or 
     MessageFlag.ContextInArray in call.messageEnum:
    if array.len == 0:
      raise newException(ValueError, "Call array expected but none provided")
      
    let arrayInfo = ArrayInfo(
      objectId: 1, # Object ID should be managed by a context
      length: array.len.int32
    )
    let arrayObj = ArraySingleObject(
      recordType: rtArraySingleObject,
      arrayInfo: arrayInfo
    )
    writeArraySingleObject(outp, arrayObj)
    
    # Write array values
    for value in array:
      writeValueWithCode(outp, value)

proc writeMethodReturn*(outp: OutputStream, ret: BinaryMethodReturn, array: seq[ValueWithCode] = @[]) =
  ## Writes a method return + optional array
  ## Section 2.7: methodReturn = 0*1(BinaryLibrary) BinaryMethodReturn 0*1(callArray)

  writeBinaryMethodReturn(outp, ret)

  # Write return array if specified in flags
  if MessageFlag.ReturnValueInArray in ret.messageEnum or
     MessageFlag.ArgsInArray in ret.messageEnum or
     MessageFlag.ContextInArray in ret.messageEnum or
     MessageFlag.ExceptionInArray in ret.messageEnum:
    if array.len == 0:
      raise newException(ValueError, "Return array expected but none provided")
      
    let arrayInfo = ArrayInfo(
      objectId: 1, # TODO: Object ID should be managed by a context
      length: array.len.int32
    )
    let arrayObj = ArraySingleObject(
      recordType: rtArraySingleObject,
      arrayInfo: arrayInfo
    )
    writeArraySingleObject(outp, arrayObj)
    
    # Write array values
    for value in array:
      writeValueWithCode(outp, value)

proc writeRemotingMessage*(outp: OutputStream, msg: RemotingMessage) =
  ## Writes complete remoting message following MS-NRBF grammar
  ## Section 2.7: remotingMessage = SerializationHeader *(referenceable) 
  ##                                (methodCall/methodReturn) *(referenceable) MessageEnd

  # Validate message
  if msg.header.recordType != rtSerializedStreamHeader:
    raise newException(ValueError, "Invalid header record type")

  if msg.tail.recordType != rtMessageEnd:
    raise newException(ValueError, "Invalid tail record type")

  if msg.methodCall.isNone and msg.methodReturn.isNone:
    raise newException(ValueError, "Message must have either method call or return")

  if msg.methodCall.isSome and msg.methodReturn.isSome:
    raise newException(ValueError, "Message cannot have both method call and return")

  # Write header
  writeSerializationHeader(outp, msg.header)

  # Write preceding referenceable records
  for record in msg.referencedRecords:
    writeReferenceable(outp, record)

  # Write method call or return with array
  if msg.methodCall.isSome:
    writeMethodCall(outp, msg.methodCall.get, msg.methodCallArray)
  else:
    writeMethodReturn(outp, msg.methodReturn.get, msg.methodCallArray)

  # Write tail
  writeMessageEnd(outp, msg.tail)

proc newRemotingMessage*(methodCall: Option[BinaryMethodCall] = none(BinaryMethodCall),
                        methodReturn: Option[BinaryMethodReturn] = none(BinaryMethodReturn),
                        callArray: seq[ValueWithCode] = @[],
                        refs: seq[ReferenceableRecord] = @[]): RemotingMessage =
  # Validate that exactly one of methodCall or methodReturn is provided
  if methodCall.isNone and methodReturn.isNone:
    raise newException(ValueError, "Must provide either method call or return")
  if methodCall.isSome and methodReturn.isSome:
    raise newException(ValueError, "Cannot have both method call and return")

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
      result.header.rootId = 1    # ObjectId of the ArraySingleObject
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
      result.header.rootId = 1    # ObjectId of the ArraySingleObject
      result.header.headerId = -1
    else:
      result.header.rootId = 0
      result.header.headerId = 0
