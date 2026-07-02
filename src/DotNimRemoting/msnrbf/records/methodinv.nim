import faststreams/[inputs, outputs]
import ../enums
import ../types
import ../context
import member
import class
import arrays
import serialization
import strutils

type
  ValueWithCode* = object
    ## Section 2.2.2.1 ValueWithCode structure
    ## Associates a Primitive Value with its type
    primitiveType*: PrimitiveType  # Identifies the type of data
    value*: PrimitiveValue        # The actual primitive value

  StringValueWithCode* = ValueWithCode
    ## Section 2.2.2.2 StringValueWithCode structure
    ## ValueWithCode specifically for String type

  ArrayOfValueWithCode* = seq[ValueWithCode]
    ## Section 2.2.2.3 ArrayOfValueWithCode structure
    ## Contains list of ValueWithCode records prefixed with length

  BinaryMethodCall* = object
    ## Section 2.2.3.1 BinaryMethodCall record 
    ## Contains info needed for Remote Method invocation
    recordType*: RecordType  # Must be rtMethodCall
    messageEnum*: MessageFlags  # Flags about args/context
    methodName*: StringValueWithCode  # Remote Method name
    typeName*: StringValueWithCode  # Server Type name
    callContext*: StringValueWithCode # Optional Logical Call ID
    args*: ArrayOfValueWithCode  # Optional input arguments

  BinaryMethodReturn* = object
    ## Section 2.2.3.3 BinaryMethodReturn record
    ## Contains info returned by Remote Method
    recordType*: RecordType  # Must be rtMethodReturn
    messageEnum*: MessageFlags  # Flags about return value/args/context
    returnValue*: ValueWithCode  # Optional Return Value 
    callContext*: StringValueWithCode  # Optional Logical Call ID
    args*: ArrayOfValueWithCode  # Optional output arguments

  RemotingValue* = ref object
    case kind*: RemotingValueKind
    of rvPrimitive:
      primitiveVal*: PrimitiveValue
    of rvString:
      stringRecord*: BinaryObjectString
    of rvNull:
      discard
    of rvReference:
      idRef*: int32
    of rvClass:
      classVal*: ClassValue
    of rvArray:
      arrayVal*: ArrayValue


  ClassValue* = ref object
    record*: ClassRecord          # Tracks the specific class record type
    members*: seq[RemotingValue]  # Member values

  ArrayValue* = ref object
    record*: ArrayRecord          # Tracks the specific array record type
    elements*: seq[RemotingValue] # Array elements


proc newStringValueWithCode*(value: string): StringValueWithCode =
  ## Creates new StringValueWithCode structure
  let strVal = PrimitiveValue(kind: ptString, stringVal: LengthPrefixedString(value: value))
  result = StringValueWithCode(primitiveType: ptString, value: strVal)

proc determineMemberTypeInfo*(members: seq[RemotingValue]): MemberTypeInfo =
  ## Dynamically determines the MemberTypeInfo based on a sequence of RemotingValues.
  ## This is used during serialization of ClassWithMembersAndTypes records.
  ## Raises ValueError for invalid member types (e.g., Primitive Null/String).

  var binaryTypes: seq[BinaryType] = @[]
  var additionalInfos: seq[AdditionalTypeInfo] = @[]

  for member in members:
    # Determine BinaryType and AdditionalInfo based on member's RemotingValue kind
    case member.kind
    of rvPrimitive:
      let primType = member.primitiveVal.kind
      if primType in {ptString, ptNull, ptUnused}: # Validation (Section 2.3.1.2)
         raise newException(ValueError, "Invalid primitive type for class member: " & $primType)
      binaryTypes.add(btPrimitive)
      # PrimitiveTypeEnum needed (Section 2.3.1.2)
      additionalInfos.add(AdditionalTypeInfo(
        kind: btPrimitive,
        primitiveType: primType
      ))
    of rvString:
      binaryTypes.add(btString)
      additionalInfos.add(AdditionalTypeInfo(kind: btString)) # No extra info needed
    of rvNull:
      # Nulls are generally represented as 'Object' type in metadata
      binaryTypes.add(btObject)
      additionalInfos.add(AdditionalTypeInfo(kind: btObject)) # No extra info needed
    of rvReference:
      # References imply the target type, often represented as 'Object' if unknown
      binaryTypes.add(btObject)
      additionalInfos.add(AdditionalTypeInfo(kind: btObject)) # No extra info needed
    of rvClass:
      # Need ClassTypeInfo (name, libraryId) or just name for SystemClass (Section 2.3.1.2)
      let classRec = member.classVal.record
      var className: LengthPrefixedString
      var libraryId: int32 = 0
      var isSystemClass = false

      case classRec.kind
      of rtClassWithId:
         # Cannot reliably determine full type info from ClassWithId alone during serialization build phase.
         # The caller constructing the RemotingValue should ideally provide a more complete record type
         # if this member's type needs to be included in MemberTypeInfo.
         raise newException(ValueError, "Cannot determine MemberTypeInfo for a ClassWithId member.")
      of rtSystemClassWithMembers:
         className = classRec.systemClassWithMembers.classInfo.name
         isSystemClass = true
      of rtClassWithMembers:
         className = classRec.classWithMembers.classInfo.name
         libraryId = classRec.classWithMembers.libraryId
      of rtSystemClassWithMembersAndTypes:
         className = classRec.systemClassWithMembersAndTypes.classInfo.name
         isSystemClass = true
      of rtClassWithMembersAndTypes:
         className = classRec.classWithMembersAndTypes.classInfo.name
         libraryId = classRec.classWithMembersAndTypes.libraryId
      else:
         raise newException(ValueError, "Unexpected class record kind for member type determination: " & $classRec.kind)

      if isSystemClass:
        binaryTypes.add(btSystemClass)
        additionalInfos.add(AdditionalTypeInfo(kind: btSystemClass, className: className))
      else:
        binaryTypes.add(btClass)
        additionalInfos.add(AdditionalTypeInfo(kind: btClass, classInfo: ClassTypeInfo(typeName: className, libraryId: libraryId)))

    of rvArray:
      # Arrays are generally represented as 'Object' unless specific (StringArray, etc.)
      let arrayRec = member.arrayVal.record
      case arrayRec.kind:
        of rtArraySingleString: binaryTypes.add(btStringArray)
        of rtArraySingleObject: binaryTypes.add(btObjectArray)
        of rtArraySinglePrimitive: binaryTypes.add(btPrimitiveArray)
        of rtBinaryArray:
          # Use the type info from the BinaryArray record itself (Section 2.4.3.1 TypeEnum)
          case arrayRec.binaryArray.typeEnum
          of btPrimitive: binaryTypes.add(btPrimitiveArray)
          of btString: binaryTypes.add(btStringArray)
          of btObject: binaryTypes.add(btObjectArray)
          of btSystemClass: binaryTypes.add(btSystemClass) # Representing array of system class
          of btClass: binaryTypes.add(btClass) # Representing array of class
          of btObjectArray: binaryTypes.add(btObjectArray) # Array of array of object
          of btStringArray: binaryTypes.add(btStringArray) # Array of array of string
          of btPrimitiveArray: binaryTypes.add(btPrimitiveArray) # Array of array of primitive
        else: binaryTypes.add(btObject) # Default fallback for unknown/unexpected array types

      # Add corresponding additional info if needed (Section 2.3.1.2)
      case binaryTypes[^1] # Check the type we just added
      of btPrimitiveArray:
         let primType = if arrayRec.kind == rtArraySinglePrimitive: arrayRec.arraySinglePrimitive.primitiveType
                        elif arrayRec.kind == rtBinaryArray: arrayRec.binaryArray.additionalTypeInfo.primitiveType
                        else: raise newException(ValueError, "Cannot determine primitive type for array member") # Should not happen
         if primType in {ptString, ptNull, ptUnused}: # Validation
            raise newException(ValueError, "Invalid primitive type for array member: " & $primType)
         additionalInfos.add(AdditionalTypeInfo(kind: btPrimitiveArray, primitiveType: primType))
      of btSystemClass:
         # Assuming BinaryArray of SystemClass
         if arrayRec.kind != rtBinaryArray or arrayRec.binaryArray.typeEnum != btSystemClass:
            raise newException(ValueError, "Inconsistent state determining SystemClass array member type")
         let className = arrayRec.binaryArray.additionalTypeInfo.className
         additionalInfos.add(AdditionalTypeInfo(kind: btSystemClass, className: className))
      of btClass:
         # Assuming BinaryArray of Class
         if arrayRec.kind != rtBinaryArray or arrayRec.binaryArray.typeEnum != btClass:
            raise newException(ValueError, "Inconsistent state determining Class array member type")
         let classInfo = arrayRec.binaryArray.additionalTypeInfo.classInfo
         additionalInfos.add(AdditionalTypeInfo(kind: btClass, classInfo: classInfo))
      else:
         # No additional info needed for btString, btObject, btObjectArray, btStringArray
         additionalInfos.add(AdditionalTypeInfo(kind: binaryTypes[^1]))

  # Construct the final MemberTypeInfo
  result = MemberTypeInfo(
    binaryTypes: binaryTypes,
    additionalInfos: additionalInfos
  )

  # Final validation
  if result.binaryTypes.len != members.len or result.additionalInfos.len != members.len:
     raise newException(ValueError, "Internal error: MemberTypeInfo size mismatch after determination")


# Reading procedures
proc readOptimizedNulls*(inp: InputStream, recordType: RecordType): int32 =
  ## Reads ObjectNullMultiple or ObjectNullMultiple256 and returns the null count
  ## The recordType parameter should be the peeked record type
  case recordType
  of rtObjectNullMultiple:
    let nullRecord = readObjectNullMultiple(inp)
    return nullRecord.nullCount
  of rtObjectNullMultiple256:
    let nullRecord = readObjectNullMultiple256(inp)
    return nullRecord.nullCount.int32
  else:
    raise newException(IOError, "Expected ObjectNullMultiple or ObjectNullMultiple256 record type, got: " & $recordType)

proc readValueWithCode*(inp: InputStream): ValueWithCode =
  ## Reads ValueWithCode structure from stream
  result.primitiveType = readPrimitiveType(inp)
  result.value = readPrimitiveValue(inp, result.primitiveType)

proc readStringValueWithCode*(inp: InputStream): StringValueWithCode =
  ## Reads StringValueWithCode structure from stream
  result.primitiveType = readPrimitiveType(inp)
  if result.primitiveType != ptString:
    raise newException(IOError, "Expected String primitive type (18)")
    
  let strVal = PrimitiveValue(kind: ptString, stringVal: readLengthPrefixedString(inp))
  result.value = strVal

proc readArrayOfValueWithCode*(inp: InputStream): ArrayOfValueWithCode =
  ## Reads array of ValueWithCode from stream
  let length = readValueWithContext[int32](inp, "reading value array length")
  if length < 0:
    raise newException(IOError, "Array length cannot be negative")
  
  for i in 0..<length:
    result.add(readValueWithCode(inp))

proc readBinaryMethodCall*(inp: InputStream): BinaryMethodCall =
  ## Reads BinaryMethodCall record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtMethodCall:
    raise newException(IOError, "Invalid method call record type")
    
  result.messageEnum = readMessageFlags(inp)
  result.methodName = readStringValueWithCode(inp) 
  result.typeName = readStringValueWithCode(inp)
  
  if MessageFlag.ContextInline in result.messageEnum:
    result.callContext = readStringValueWithCode(inp)
    
  if MessageFlag.ArgsInline in result.messageEnum:
    result.args = readArrayOfValueWithCode(inp)

proc readBinaryMethodReturn*(inp: InputStream): BinaryMethodReturn =
  ## Reads BinaryMethodReturn record from stream  
  result.recordType = readRecord(inp)
  if result.recordType != rtMethodReturn:
    raise newException(IOError, "Invalid method return record type")
    
  result.messageEnum = readMessageFlags(inp)
  
  # Method signature and generic flags not allowed here
  if MessageFlag.MethodSignatureInArray in result.messageEnum or
     MessageFlag.GenericMethod in result.messageEnum:
    raise newException(IOError, "Invalid flags for method return")
    
  if MessageFlag.ReturnValueInline in result.messageEnum:
    result.returnValue = readValueWithCode(inp)
    
  if MessageFlag.ContextInline in result.messageEnum:
    result.callContext = readStringValueWithCode(inp)
    
  if MessageFlag.ArgsInline in result.messageEnum:
    result.args = readArrayOfValueWithCode(inp)

proc readRemotingValue*(inp: InputStream, ctx: ReferenceContext): RemotingValue =
  ## Reads any member reference and referenceables from the input stream into a RemotingValue.
  ## The ReferenceContext tracks class metadata across records so ClassWithId
  ## records can resolve their MetadataId.
  proc readClassMembers(inp: InputStream, ctx: ReferenceContext, info: ClassMetadataInfo): seq[RemotingValue] =
    ## Reads class member values following a class record
    ## Members declared btPrimitive are read as MemberPrimitiveUnTyped (Section 2.3.2);
    ## all other members are full records. A single ObjectNullMultiple(256)
    ## record may cover several consecutive null members (Section 2.5.5).
    var i: int32 = 0
    while i < info.memberCount:
      if info.hasTypeInfo and info.memberTypeInfo.binaryTypes[i] == btPrimitive:
        let primValue = readMemberPrimitiveUnTyped(inp, info.memberTypeInfo.additionalInfos[i].primitiveType)
        result.add(RemotingValue(kind: rvPrimitive, primitiveVal: primValue.value))
        inc i
      else:
        let nextType = peekRecord(inp)
        if nextType in {rtObjectNullMultiple, rtObjectNullMultiple256}:
          var nulls = readOptimizedNulls(inp, nextType)
          while nulls > 0 and i < info.memberCount:
            if info.hasTypeInfo and info.memberTypeInfo.binaryTypes[i] == btPrimitive:
              raise newException(IOError, "Null record spans a primitive class member")
            result.add(RemotingValue(kind: rvNull))
            dec nulls
            inc i
          if nulls > 0:
            raise newException(IOError, "Null record count exceeds remaining class members")
        else:
          result.add(readRemotingValue(inp, ctx))
          inc i

  # A BinaryLibrary record may precede the record in any member position
  var recordType = peekRecord(inp)
  while recordType == rtBinaryLibrary:
    ctx.addLibrary(readBinaryLibrary(inp))
    recordType = peekRecord(inp)
  case recordType
  of rtMemberPrimitiveTyped:
    let primTyped = readMemberPrimitiveTyped(inp)
    result = RemotingValue(kind: rvPrimitive, primitiveVal: primTyped.value)
  of rtBinaryObjectString:
    let strRecord = readBinaryObjectString(inp)
    result = RemotingValue(kind: rvString, stringRecord: strRecord)
  of rtObjectNull:
    discard readObjectNull(inp)
    result = RemotingValue(kind: rvNull)
  of rtObjectNullMultiple:
    # Handle multiple nulls in a single record
    # Note: This should only be handled at array element reading level
    let nullRecord = readObjectNullMultiple(inp)
    # Just return a single null - the array reading logic will handle repetition
    result = RemotingValue(kind: rvNull)
  of rtObjectNullMultiple256:
    # Handle multiple nulls in a single record (compact form)
    # Note: This should only be handled at array element reading level
    let nullRecord = readObjectNullMultiple256(inp)
    # Just return a single null - the array reading logic will handle repetition
    result = RemotingValue(kind: rvNull)
  of rtMemberReference:
    let refRecord = readMemberReference(inp)
    result = RemotingValue(kind: rvReference, idRef: refRecord.idRef)
  of rtClassWithMembersAndTypes:
    let classRecord = readClassWithMembersAndTypes(inp)
    # Section 2.3.2: Member values follow the class header and are read according to BinaryType
    let info = ClassMetadataInfo(
      memberCount: classRecord.classInfo.memberCount,
      hasTypeInfo: true,
      memberTypeInfo: classRecord.memberTypeInfo
    )
    ctx.addClassMetadata(classRecord.classInfo.objectId, info)
    result = RemotingValue(kind: rvClass, classVal: ClassValue(
      record: ClassRecord(kind: rtClassWithMembersAndTypes, classWithMembersAndTypes: classRecord),
      members: readClassMembers(inp, ctx, info)
    ))
  of rtClassWithId:
    let classRecord = readClassWithId(inp)
    # Member values follow, laid out according to the metadata record referenced
    # by MetadataId, which must appear earlier in the stream (Section 2.3.2.5)
    let info = ctx.getClassMetadata(classRecord.metadataId)
    result = RemotingValue(kind: rvClass, classVal: ClassValue(
      record: ClassRecord(kind: rtClassWithId, classWithId: classRecord),
      members: readClassMembers(inp, ctx, info)
    ))
  of rtSystemClassWithMembersAndTypes:
    let classRecord = readSystemClassWithMembersAndTypes(inp)
    # Section 2.3.2: Member values follow the class header and are read according to BinaryType
    let info = ClassMetadataInfo(
      memberCount: classRecord.classInfo.memberCount,
      hasTypeInfo: true,
      memberTypeInfo: classRecord.memberTypeInfo
    )
    ctx.addClassMetadata(classRecord.classInfo.objectId, info)
    result = RemotingValue(kind: rvClass, classVal: ClassValue(
      record: ClassRecord(kind: rtSystemClassWithMembersAndTypes, systemClassWithMembersAndTypes: classRecord),
      members: readClassMembers(inp, ctx, info)
    ))
  of rtSystemClassWithMembers:
    let classRecord = readSystemClassWithMembers(inp)
    # No member type info, so each member is read as a full record
    let info = ClassMetadataInfo(
      memberCount: classRecord.classInfo.memberCount,
      hasTypeInfo: false
    )
    ctx.addClassMetadata(classRecord.classInfo.objectId, info)
    result = RemotingValue(kind: rvClass, classVal: ClassValue(
      record: ClassRecord(kind: rtSystemClassWithMembers, systemClassWithMembers: classRecord),
      members: readClassMembers(inp, ctx, info)
    ))
  of rtClassWithMembers:
    let classRecord = readClassWithMembers(inp)
    # No member type info, so each member is read as a full record
    let info = ClassMetadataInfo(
      memberCount: classRecord.classInfo.memberCount,
      hasTypeInfo: false
    )
    ctx.addClassMetadata(classRecord.classInfo.objectId, info)
    result = RemotingValue(kind: rvClass, classVal: ClassValue(
      record: ClassRecord(kind: rtClassWithMembers, classWithMembers: classRecord),
      members: readClassMembers(inp, ctx, info)
    ))
  of rtArraySinglePrimitive:
    # Read ArraySinglePrimitive record (Section 2.4.3.3)
    let arrayRecord = readArraySinglePrimitive(inp)
    let length = arrayRecord.arrayInfo.length     # Number of elements to read
    var elements = newSeq[RemotingValue](length)  # Pre-allocate sequence

    for i in 0..<length:
      let value = readMemberPrimitiveUnTyped(inp, arrayRecord.primitiveType)
      elements[i] = RemotingValue(kind: rvPrimitive, primitiveVal: value.value)

    result = RemotingValue(kind: rvArray, arrayVal: ArrayValue(
      record: ArrayRecord(kind: rtArraySinglePrimitive, arraySinglePrimitive: arrayRecord),
      elements: elements
    ))
  of rtArraySingleString:
    let arrayRecord = readArraySingleString(inp)
    let length = arrayRecord.arrayInfo.length
    var elements = newSeq[RemotingValue]()    # Initialize empty sequence

    var count = 0
    while count < length:
      let nextType = peekRecord(inp)
      if nextType in {rtObjectNullMultiple, rtObjectNullMultiple256}:
        let nullsToRead = readOptimizedNulls(inp, nextType)
        let nullsToAdd = min(nullsToRead, length - count)
        for i in 0..<nullsToAdd:
          elements.add(RemotingValue(kind: rvNull))
        count += nullsToAdd
      else:
        # Read the element as a full record (BinaryObjectString, MemberReference, or ObjectNull)
        elements.add(readRemotingValue(inp, ctx))
        count += 1

    # Construct array result
    result = RemotingValue(kind: rvArray, arrayVal: ArrayValue(
      record: ArrayRecord(kind: rtArraySingleString, arraySingleString: arrayRecord),
      elements: elements
    ))
  of rtArraySingleObject:
    let arrayRecord = readArraySingleObject(inp)
    result = RemotingValue(kind: rvArray, arrayVal: ArrayValue(
      record: ArrayRecord(kind: rtArraySingleObject, arraySingleObject: arrayRecord),
      elements: @[]
    ))
    
    var count = 0
    while count < arrayRecord.arrayInfo.length:
      let nextType = peekRecord(inp)
      if nextType in {rtObjectNullMultiple, rtObjectNullMultiple256}:
        let nullsToRead = readOptimizedNulls(inp, nextType)
        let nullsToAdd = min(nullsToRead, arrayRecord.arrayInfo.length - count)
        for i in 0..<nullsToAdd:
          result.arrayVal.elements.add(RemotingValue(kind: rvNull))
        count += nullsToAdd
      else:
        result.arrayVal.elements.add(readRemotingValue(inp, ctx))
        count += 1
  of rtBinaryArray:
    # Read the BinaryArray record metadata
    let arrayRecord = readBinaryArray(inp)
    
    var product: int64 = 1
    for length in arrayRecord.lengths:
      product *= length.int64
      if product > int32.high.int64:
        raise newException(IOError, "Array element count exceeds maximum")
    let totalElements = product.int32
    
    var elements: seq[RemotingValue] = @[]
    
    # Check if elements are primitives for optimized reading
    if arrayRecord.typeEnum == btPrimitive:
      let primType = arrayRecord.additionalTypeInfo.primitiveType
      for i in 0..<totalElements:
        let value = readMemberPrimitiveUnTyped(inp, primType)
        elements.add(RemotingValue(kind: rvPrimitive, primitiveVal: value.value))
    else:
      # General case: elements can be any memberReference, including nulls
      var count = 0
      while count < totalElements:
        let nextType = peekRecord(inp)
        if nextType in {rtObjectNullMultiple, rtObjectNullMultiple256}:
          let nullsToRead = readOptimizedNulls(inp, nextType)
          let nullsToAdd = min(nullsToRead, totalElements - count)
          for i in 0..<nullsToAdd:
            elements.add(RemotingValue(kind: rvNull))
          count += nullsToAdd
        else:
          elements.add(readRemotingValue(inp, ctx))
          count += 1
    
    # Construct the result
    result = RemotingValue(
      kind: rvArray,
      arrayVal: ArrayValue(
        record: ArrayRecord(kind: rtBinaryArray, binaryArray: arrayRecord),
        elements: elements
      )
    )
  else:
    raise newException(IOError, "Unsupported record type for RemotingValue: " & $recordType)

# Writing procedures
proc writeValueWithCode*(outp: OutputStream, value: ValueWithCode) =
  ## Writes ValueWithCode structure to stream
  outp.write(byte(value.primitiveType))
  writePrimitiveValue(outp, value.value)

proc writeStringValueWithCode*(outp: OutputStream, value: StringValueWithCode) =
  ## Writes StringValueWithCode structure to stream
  if value.primitiveType != ptString:
    raise newException(ValueError, "Expected String primitive type (18)")
  
  outp.write(byte(value.primitiveType))
  writeLengthPrefixedString(outp, value.value.stringVal.value)

proc writeArrayOfValueWithCode*(outp: OutputStream, values: seq[ValueWithCode]) =
  ## Writes array of ValueWithCode to stream prefixed with length
  outp.write(cast[array[4, byte]](int32(values.len)))
  for value in values:
    writeValueWithCode(outp, value)

proc writeBinaryMethodCall*(outp: OutputStream, call: BinaryMethodCall) = 
  ## Writes BinaryMethodCall record to stream
  if call.recordType != rtMethodCall:
    raise newException(ValueError, "Invalid method call record type")
  
  writeRecord(outp, call.recordType)
  writeMessageFlags(outp, call.messageEnum)
  writeStringValueWithCode(outp, call.methodName)
  writeStringValueWithCode(outp, call.typeName)

  # Write optional fields based on flags  
  if MessageFlag.ContextInline in call.messageEnum:
    writeStringValueWithCode(outp, call.callContext)
    
  if MessageFlag.ArgsInline in call.messageEnum:
    writeArrayOfValueWithCode(outp, call.args)

proc writeBinaryMethodReturn*(outp: OutputStream, ret: BinaryMethodReturn) =
  ## Writes BinaryMethodReturn record to stream
  if ret.recordType != rtMethodReturn:
    raise newException(ValueError, "Invalid method return record type")
    
  # Method signature and generic flags not allowed
  if MessageFlag.MethodSignatureInArray in ret.messageEnum or 
     MessageFlag.GenericMethod in ret.messageEnum:
    raise newException(ValueError, "Invalid flags for method return")

  writeRecord(outp, ret.recordType)
  writeMessageFlags(outp, ret.messageEnum)

  # Write optional fields based on flags
  if MessageFlag.ReturnValueInline in ret.messageEnum:
    writeValueWithCode(outp, ret.returnValue)
    
  if MessageFlag.ContextInline in ret.messageEnum:
    writeStringValueWithCode(outp, ret.callContext)
    
  if MessageFlag.ArgsInline in ret.messageEnum:
    writeArrayOfValueWithCode(outp, ret.args)

proc writeRemotingValue(outp: OutputStream, value: RemotingValue,
                            ctx: SerializationContext,
                            deferred: var seq[RemotingValue]) =
  ## Writes one RemotingValue record in referenceable (top-level) position.
  ## Already-serialized objects are written as MemberReference records instead
  ## of full ones. Nested arrays in member positions are appended to `deferred`
  ## for the caller to write at top level.
  proc writeNestedValue(outp: OutputStream, value: RemotingValue,
                        ctx: SerializationContext,
                        deferred: var seq[RemotingValue]) =
    ## Writes a value in memberReference position (class member or array
    ## element). The grammar forbids Arrays records there, so an
    ## array is written as a MemberReference and its record deferred to the top
    ## level.
    if value.kind == rvArray:
      let valuePtr = cast[pointer](value)
      var id: int32
      if ctx.hasWrittenObject(valuePtr):
        id = ctx.getWrittenObjectId(valuePtr)
      elif ctx.hasAssignedId(valuePtr):
        # Already queued for deferred writing
        id = ctx.getAssignedId(valuePtr)
      else:
        id = ctx.reserveIdForPointer(valuePtr)
        deferred.add(value)
      writeMemberReference(outp, MemberReference(
        recordType: rtMemberReference,
        idRef: id
      ))
    else:
      writeRemotingValue(outp, value, ctx, deferred)

  proc writeClassMembers(outp: OutputStream, members: seq[RemotingValue],
                         info: ClassMetadataInfo, ctx: SerializationContext,
                         deferred: var seq[RemotingValue]) =
    ## Writes class member values following a class record, according to the
    ## class metadata (Section 2.7: Classes = ... *(memberReference)).
    ## Members declared btPrimitive are written as MemberPrimitiveUnTyped (Section 2.3.2);
    ## all other members are full records.
    if members.len.int32 != info.memberCount:
      raise newException(ValueError, "Class member count mismatch: metadata declares " &
                         $info.memberCount & " members, got " & $members.len)
    for i, member in members:
      if info.hasTypeInfo and info.memberTypeInfo.binaryTypes[i] == btPrimitive:
        if member.kind != rvPrimitive:
          raise newException(ValueError, "Expected primitive member for btPrimitive type, got " & $member.kind)
        writeMemberPrimitiveUnTyped(outp, MemberPrimitiveUnTyped(value: member.primitiveVal))
      else:
        writeNestedValue(outp, member, ctx, deferred)

  let valuePtr = cast[pointer](value)
  
  case value.kind
  of rvPrimitive:
    writeMemberPrimitiveTyped(outp, MemberPrimitiveTyped(
      recordType: rtMemberPrimitiveTyped,
      value: value.primitiveVal
    ))
  of rvString:
    if ctx.hasWrittenObject(valuePtr):
      # Object was previously serialized, write a reference instead
      let id = ctx.getWrittenObjectId(valuePtr)
      writeMemberReference(outp, MemberReference(
        recordType: rtMemberReference,
        idRef: id
      ))
    else:
      let id = assignIdForPointer(ctx, valuePtr)

      # Ids are reassigned on write, so overwrite whatever the record carried
      var strRecord = value.stringRecord
      strRecord.recordType = rtBinaryObjectString
      strRecord.objectId = id
      writeBinaryObjectString(outp, strRecord)
  of rvNull:
    writeObjectNull(outp, ObjectNull(recordType: rtObjectNull))
  of rvReference:
    writeMemberReference(outp, MemberReference(
      recordType: rtMemberReference,
      idRef: value.idRef
    ))
  of rvClass:
    if ctx.hasWrittenObject(valuePtr):
      # Class was previously serialized, write a reference instead
      let id = ctx.getWrittenObjectId(valuePtr)
      writeMemberReference(outp, MemberReference(
        recordType: rtMemberReference,
        idRef: id
      ))
    else:
      let id = assignIdForPointer(ctx, valuePtr)

      # Write the correct class record header using the new ID and derived MemberTypeInfo
      case value.classVal.record.kind
      of rtClassWithId:
        var recordToWrite = value.classVal.record.classWithId
        recordToWrite.objectId = id # Assign the new ID
        # The referenced metadata record must appear earlier in the stream
        # (Section 2.3.2.5); remap MetadataId to its newly assigned ID
        if not ctx.hasWrittenClassMetadata(recordToWrite.metadataId):
          raise newException(ValueError, "ClassWithId references class metadata " &
                             $recordToWrite.metadataId & " that has not been written to the stream")
        let (metadataId, info) = ctx.getWrittenClassMetadata(recordToWrite.metadataId)
        recordToWrite.metadataId = metadataId
        writeClassWithId(outp, recordToWrite)
        # Member values follow, laid out per the referenced metadata
        writeClassMembers(outp, value.classVal.members, info, ctx, deferred)

      of rtSystemClassWithMembers:
        var recordToWrite = value.classVal.record.systemClassWithMembers
        let originalId = recordToWrite.classInfo.objectId
        recordToWrite.classInfo.objectId = id # Assign the new ID
        recordToWrite.classInfo.memberCount = value.classVal.members.len.int32 # Use actual count
        writeSystemClassWithMembers(outp, recordToWrite)
        let info = ClassMetadataInfo(
          memberCount: recordToWrite.classInfo.memberCount,
          hasTypeInfo: false
        )
        ctx.registerWrittenClassMetadata(originalId, id, info)
        # Write members following the header
        writeClassMembers(outp, value.classVal.members, info, ctx, deferred)

      of rtClassWithMembers:
        var recordToWrite = value.classVal.record.classWithMembers
        let originalId = recordToWrite.classInfo.objectId
        recordToWrite.classInfo.objectId = id # Assign the new ID
        recordToWrite.classInfo.memberCount = value.classVal.members.len.int32 # Use actual count
        writeClassWithMembers(outp, recordToWrite)
        let info = ClassMetadataInfo(
          memberCount: recordToWrite.classInfo.memberCount,
          hasTypeInfo: false
        )
        ctx.registerWrittenClassMetadata(originalId, id, info)
        # Write members following the header
        writeClassMembers(outp, value.classVal.members, info, ctx, deferred)

      of rtSystemClassWithMembersAndTypes:
        var recordToWrite = value.classVal.record.systemClassWithMembersAndTypes
        let originalId = recordToWrite.classInfo.objectId
        recordToWrite.classInfo.objectId = id # Assign the new ID
        recordToWrite.classInfo.memberCount = value.classVal.members.len.int32 # Use actual count
        if recordToWrite.memberTypeInfo.binaryTypes.len == 0 and recordToWrite.classInfo.memberCount != 0: # Check if populated
          recordToWrite.memberTypeInfo = determineMemberTypeInfo(value.classVal.members) # Fallback

        writeSystemClassWithMembersAndTypes(outp, recordToWrite)
        let info = ClassMetadataInfo(
          memberCount: recordToWrite.classInfo.memberCount,
          hasTypeInfo: true,
          memberTypeInfo: recordToWrite.memberTypeInfo
        )
        ctx.registerWrittenClassMetadata(originalId, id, info)
        # Write members according to their declared types in MemberTypeInfo
        writeClassMembers(outp, value.classVal.members, info, ctx, deferred)

      of rtClassWithMembersAndTypes:
        var recordToWrite = value.classVal.record.classWithMembersAndTypes
        let originalId = recordToWrite.classInfo.objectId
        recordToWrite.classInfo.objectId = id # Assign the new ID
        recordToWrite.classInfo.memberCount = value.classVal.members.len.int32 # Use actual count
        if recordToWrite.memberTypeInfo.binaryTypes.len == 0 and recordToWrite.classInfo.memberCount != 0: # Check if populated
          recordToWrite.memberTypeInfo = determineMemberTypeInfo(value.classVal.members) # Fallback
        writeClassWithMembersAndTypes(outp, recordToWrite)
        let info = ClassMetadataInfo(
          memberCount: recordToWrite.classInfo.memberCount,
          hasTypeInfo: true,
          memberTypeInfo: recordToWrite.memberTypeInfo
        )
        ctx.registerWrittenClassMetadata(originalId, id, info)
        # Write members according to their declared types in MemberTypeInfo
        # Section 2.3.2: Member values follow the class header and are written according to BinaryType
        writeClassMembers(outp, value.classVal.members, info, ctx, deferred)
      else:
        raise newException(ValueError, "Unsupported class record kind for writing: " & $value.classVal.record.kind)
  of rvArray:
    if ctx.hasWrittenObject(valuePtr):
      # Array was previously serialized, write a reference instead
      let id = ctx.getWrittenObjectId(valuePtr)
      writeMemberReference(outp, MemberReference(
        recordType: rtMemberReference,
        idRef: id
      ))
    else:
      # Assign a new ID and write the full array record
      let id = assignIdForPointer(ctx, valuePtr)
      
      let arrayRecordVariant = value.arrayVal.record # This holds the specific record type
      let elements = value.arrayVal.elements

      case arrayRecordVariant.kind
      of rtArraySingleObject:
        var recordToWrite = arrayRecordVariant.arraySingleObject
        recordToWrite.arrayInfo.objectId = id # Assign the new ID
        recordToWrite.arrayInfo.length = elements.len.int32 # Ensure length matches
        writeArraySingleObject(outp, recordToWrite)

        # Write elements recursively (handles all types: primitive, string, null, ref, class, array)
        var nullCount: int32 = 0
        for elem in elements:
          if elem.kind == rvNull:
            nullCount += 1
          else:
            # Write any pending nulls
            if nullCount > 0:
              writeOptimizedNulls(outp, nullCount)
              nullCount = 0
            # Write the non-null element
            writeNestedValue(outp, elem, ctx, deferred)
        # Write any trailing nulls
        if nullCount > 0:
          writeOptimizedNulls(outp, nullCount)

      of rtArraySinglePrimitive:
        var recordToWrite = arrayRecordVariant.arraySinglePrimitive
        recordToWrite.arrayInfo.objectId = id # Assign the new ID
        recordToWrite.arrayInfo.length = elements.len.int32 # Ensure length matches
        let expectedPrimitiveType = recordToWrite.primitiveType
        writeArraySinglePrimitive(outp, recordToWrite)

        # Write elements as MemberPrimitiveUnTyped (Spec 2.4.3.3)
        for elem in elements:
          if elem.kind != rvPrimitive or elem.primitiveVal.kind != expectedPrimitiveType:
            raise newException(ValueError, "Element type mismatch in ArraySinglePrimitive. Expected " &
                               $expectedPrimitiveType & ", got " & $elem.kind)
          # Write only the value, without type info or record enum prefix
          writeMemberPrimitiveUnTyped(outp, MemberPrimitiveUnTyped(value: elem.primitiveVal))

      of rtArraySingleString:
        var recordToWrite = arrayRecordVariant.arraySingleString
        recordToWrite.arrayInfo.objectId = id # Assign the new ID
        recordToWrite.arrayInfo.length = elements.len.int32 # Ensure length matches
        writeArraySingleString(outp, recordToWrite)

        var nullCount: int32 = 0
        for elem in elements:
           if elem.kind == rvNull:
             nullCount += 1
           else:
             # Write any pending nulls
             if nullCount > 0:
               writeOptimizedNulls(outp, nullCount)
               nullCount = 0
             # Write the non-null element (String or Reference)
             if elem.kind notin {rvString, rvReference, rvNull}:
                raise newException(ValueError, "Invalid element type for ArraySingleString: " & $elem.kind)
             writeNestedValue(outp, elem, ctx, deferred)
        # Write any trailing nulls
        if nullCount > 0:
          writeOptimizedNulls(outp, nullCount)

      of rtBinaryArray:
        var recordToWrite = arrayRecordVariant.binaryArray
        recordToWrite.objectId = id # Assign the new ID
        # Ensure lengths product matches element count
        var product: int64 = 1
        for length in recordToWrite.lengths:
          if length < 0:
            raise newException(ValueError, "Array dimension length cannot be negative")
          product *= length.int64
          if product > int32.high.int64:
            raise newException(ValueError, "BinaryArray lengths product exceeds maximum")
        if product != elements.len.int64:
           raise newException(ValueError, "BinaryArray lengths product mismatch with element count")
        writeBinaryArray(outp, recordToWrite)

        # Write elements based on the array's declared type info
        let arrayItemType = recordToWrite.typeEnum
        if arrayItemType == btPrimitive:
          # Optimization: Write as MemberPrimitiveUnTyped
          let expectedPrimitiveType = recordToWrite.additionalTypeInfo.primitiveType
          for elem in elements:
            if elem.kind != rvPrimitive or elem.primitiveVal.kind != expectedPrimitiveType:
              raise newException(ValueError, "Element type mismatch in BinaryArray (Primitive). Expected " &
                                 $expectedPrimitiveType & ", got " & $elem.kind)
            writeMemberPrimitiveUnTyped(outp, MemberPrimitiveUnTyped(value: elem.primitiveVal))
        else:
          # General case: Write elements recursively (handles all memberReference types)
          var nullCount: int32 = 0
          for elem in elements:
            if elem.kind == rvNull:
              nullCount += 1
            else:
              # Write any pending nulls
              if nullCount > 0:
                writeOptimizedNulls(outp, nullCount)
                nullCount = 0
              # Write the non-null element
              writeNestedValue(outp, elem, ctx, deferred)
          # Write any trailing nulls
          if nullCount > 0:
            writeOptimizedNulls(outp, nullCount)
      else:
        raise newException(ValueError, "Unsupported array record kind for writing: " & $arrayRecordVariant.kind)

proc writeRemotingValue*(outp: OutputStream, value: RemotingValue, ctx: SerializationContext) =
  ## Writes a RemotingValue as a top-level referenceable record. Arrays nested
  ## in member positions, disallowed inline by the grammar (Section 2.7), are
  ## written as MemberReferences with their full records appended after this one.
  var deferred: seq[RemotingValue]
  writeRemotingValue(outp, value, ctx, deferred)
  # Draining can defer more arrays (arrays of arrays), growing the queue
  var i = 0
  while i < deferred.len:
    writeRemotingValue(outp, deferred[i], ctx, deferred)
    inc i

proc objectIdOf*(value: RemotingValue): int32 =
  ## Object id of a class/array/string record; 0 for kinds that don't keep
  ## one (primitives, nulls, references)
  case value.kind
  of rvString: value.stringRecord.objectId
  of rvClass:
    let rec = value.classVal.record
    case rec.kind
    of rtClassWithMembersAndTypes: rec.classWithMembersAndTypes.classInfo.objectId
    of rtSystemClassWithMembersAndTypes: rec.systemClassWithMembersAndTypes.classInfo.objectId
    of rtClassWithMembers: rec.classWithMembers.classInfo.objectId
    of rtSystemClassWithMembers: rec.systemClassWithMembers.classInfo.objectId
    of rtClassWithId: rec.classWithId.objectId
    else: 0
  of rvArray:
    let rec = value.arrayVal.record
    case rec.kind
    of rtArraySingleObject: rec.arraySingleObject.arrayInfo.objectId
    of rtArraySinglePrimitive: rec.arraySinglePrimitive.arrayInfo.objectId
    of rtArraySingleString: rec.arraySingleString.arrayInfo.objectId
    of rtBinaryArray: rec.binaryArray.objectId
    else: 0
  else: 0

# String representation
proc `$`*(valueWithCode: ValueWithCode): string =
  ## Convert a ValueWithCode to string representation
  return $valueWithCode.value

proc `$`*(arrayValues: ArrayOfValueWithCode): string =
  ## Convert an ArrayOfValueWithCode to string representation
  var values: seq[string] = @[]
  for val in arrayValues:
    values.add($val)
  return "[" & values.join(", ") & "]"

proc `$`*(call: BinaryMethodCall): string =
  ## Convert a BinaryMethodCall to string representation
  var parts = @[
    "MethodCall:",
    "  Method: " & call.methodName.value.stringVal.value,
    "  Type: " & call.typeName.value.stringVal.value,
    "  Flags: " & $call.messageEnum
  ]
  
  if MessageFlag.ContextInline in call.messageEnum:
    parts.add("  Context: " & call.callContext.value.stringVal.value)
    
  if MessageFlag.ArgsInline in call.messageEnum:
    parts.add("  Args: " & $call.args)
  
  return parts.join("\n")

proc `$`*(ret: BinaryMethodReturn): string =
  ## Convert a BinaryMethodReturn to string representation
  var parts = @[
    "MethodReturn:",
    "  Flags: " & $ret.messageEnum
  ]
  
  if MessageFlag.ReturnValueInline in ret.messageEnum:
    parts.add("  ReturnValue: " & $ret.returnValue)
    
  if MessageFlag.ContextInline in ret.messageEnum:
    parts.add("  Context: " & ret.callContext.value.stringVal.value)
    
  if MessageFlag.ArgsInline in ret.messageEnum:
    parts.add("  Args: " & $ret.args)
  
  return parts.join("\n")

proc `$`*(remVal: RemotingValue): string =
  ## Convert a RemotingValue to string representation
  case remVal.kind
  of rvPrimitive: $remVal.primitiveVal
  of rvString: "\"" & remVal.stringRecord.value.value & "\""
  of rvNull: "null"
  of rvReference: "Reference(id=" & $remVal.idRef & ")"
  of rvClass:
    var parts = @[
      "Class:",
      "  Members:"
    ]
    for i, member in remVal.classVal.members:
      parts.add("    [" & $i & "]: " & $member)
    parts.join("\n")
  of rvArray:
    var elements: seq[string] = @[]
    for elem in remVal.arrayVal.elements:
      elements.add($elem)
    "Array(length=" & $remVal.arrayVal.elements.len & "): [" & elements.join(", ") & "]"