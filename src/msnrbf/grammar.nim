import faststreams/[inputs, outputs]
import enums
import types
import records/[arrays, class, member, methodinv, serialization]
import tables

type
  RemotingMessage* = ref object
    ## Represents a complete remoting message that follows MS-NRBF grammar
    ## This is a root object for a complete message exchange
    header*: SerializationHeaderRecord     # Required start header
    referencedRecords*: seq[ReferenceableRecord] # Optional referenced records
    methodCall*: BinaryMethodCall          # Required method call
    methodReturn*: BinaryMethodReturn      # Or method return
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
     MessageFlag.ContextInArray in result.ret.messageEnum:
     
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
    result.methodCall = call
    result.methodCallArray = array
  of rtMethodReturn:
    let (ret, array) = readMethodReturn(inp, ctx)
    result.methodReturn = ret
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