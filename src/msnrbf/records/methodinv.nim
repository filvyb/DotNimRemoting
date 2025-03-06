import faststreams/[inputs, outputs]
import ../enums
import ../types
import member
import class
import arrays

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

  RemotingValue* = object
    case kind*: RemotingValueKind
    of rvPrimitive:
      primitiveVal*: PrimitiveValue
    of rvString:
      stringVal*: LengthPrefixedString
    of rvNull:
      discard
    of rvReference:
      idRef*: int32
    of rvClass:
      classVal*: ClassValue
    of rvArray:
      arrayVal*: ArrayValue

  ClassValue* = object
    classInfo*: ClassInfo        # From records/class.nim
    members*: seq[RemotingValue] # Member values
    libraryId*: int32            # Library reference, if applicable

  ArrayValue* = object
    arrayInfo*: ArrayInfo        # From records/arrays.nim
    elements*: seq[RemotingValue] # Array elements


proc peekRecordType*(inp: InputStream): RecordType =
  ## Peeks the next record type without consuming it
  if inp.readable:
    result = RecordType(inp.peek)

proc newStringValueWithCode*(value: string): StringValueWithCode =
  ## Creates new StringValueWithCode structure
  let strVal = PrimitiveValue(kind: ptString, stringVal: LengthPrefixedString(value: value))
  result = StringValueWithCode(primitiveType: ptString, value: strVal)

# Reading procedures
proc readValueWithCode*(inp: InputStream): ValueWithCode =
  ## Reads ValueWithCode structure from stream
  if not inp.readable:
    raise newException(IOError, "Missing primitive type")
    
  result.primitiveType = PrimitiveType(inp.read)
  result.value = readPrimitiveValue(inp, result.primitiveType)

proc readStringValueWithCode*(inp: InputStream): StringValueWithCode =
  ## Reads StringValueWithCode structure from stream
  if not inp.readable:
    raise newException(IOError, "Missing primitive type")
    
  result.primitiveType = PrimitiveType(inp.read)
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

proc readRemotingValue*(inp: InputStream): RemotingValue =
  ## Reads any serializable object from the input stream into a RemotingValue
  let recordType = peekRecordType(inp)
  case recordType
  of rtMemberPrimitiveTyped:
    let primTyped = readMemberPrimitiveTyped(inp)
    result = RemotingValue(kind: rvPrimitive, primitiveVal: primTyped.value)
  of rtBinaryObjectString:
    let strRecord = readBinaryObjectString(inp)
    result = RemotingValue(kind: rvString, stringVal: strRecord.value)
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
  of rtClassWithId..rtClassWithMembersAndTypes:
    # Simplified: assumes ClassWithMembersAndTypes; adjust for other types if needed
    let classRecord = readClassWithMembersAndTypes(inp)
    result = RemotingValue(kind: rvClass, classVal: ClassValue(
      classInfo: classRecord.classInfo,
      members: @[],
      libraryId: classRecord.libraryId
    ))
    for i in 0..<classRecord.classInfo.memberCount:
      result.classVal.members.add(readRemotingValue(inp))
  of rtArraySingleObject:
    let arrayRecord = readArraySingleObject(inp)
    result = RemotingValue(kind: rvArray, arrayVal: ArrayValue(
      arrayInfo: arrayRecord.arrayInfo,
      elements: @[]
    ))
    
    var count = 0
    while count < arrayRecord.arrayInfo.length:
      let nextType = peekRecordType(inp)
      if nextType == rtObjectNullMultiple:
        let nullRecord = readObjectNullMultiple(inp)
        for i in 0..<nullRecord.nullCount:
          result.arrayVal.elements.add(RemotingValue(kind: rvNull))
          count += 1
          if count >= arrayRecord.arrayInfo.length:
            break
      elif nextType == rtObjectNullMultiple256:
        let nullRecord = readObjectNullMultiple256(inp)
        for i in 0..<nullRecord.nullCount.int32:
          result.arrayVal.elements.add(RemotingValue(kind: rvNull))
          count += 1
          if count >= arrayRecord.arrayInfo.length:
            break
      else:
        result.arrayVal.elements.add(readRemotingValue(inp))
        count += 1
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

proc writeRemotingValue*(outp: OutputStream, value: RemotingValue) =
  ## Writes a RemotingValue to the output stream
  case value.kind
  of rvPrimitive:
    writeMemberPrimitiveTyped(outp, MemberPrimitiveTyped(
      recordType: rtMemberPrimitiveTyped,
      value: value.primitiveVal
    ))
  of rvString:
    let strRecord = BinaryObjectString(
      recordType: rtBinaryObjectString,
      objectId: 1, # Set a positive ID (will be overwritten by context if used with refs)
      value: value.stringVal
    )
    writeBinaryObjectString(outp, strRecord)
  of rvNull:
    writeObjectNull(outp, ObjectNull(recordType: rtObjectNull))
  of rvReference:
    writeMemberReference(outp, MemberReference(
      recordType: rtMemberReference,
      idRef: value.idRef
    ))
  of rvClass:
    # First gather the member type information
    var binaryTypes: seq[BinaryType] = @[]
    var additionalInfos: seq[AdditionalTypeInfo] = @[]
    
    # Create type info for each member based on RemotingValue kind
    for member in value.classVal.members:
      case member.kind
      of rvPrimitive:
        binaryTypes.add(btPrimitive)
        additionalInfos.add(AdditionalTypeInfo(
          kind: btPrimitive, 
          primitiveType: member.primitiveVal.kind
        ))
      of rvString:
        binaryTypes.add(btString)
        additionalInfos.add(AdditionalTypeInfo(kind: btString))
      of rvNull:
        binaryTypes.add(btObject)
        additionalInfos.add(AdditionalTypeInfo(kind: btObject))
      of rvReference:
        binaryTypes.add(btObject)
        additionalInfos.add(AdditionalTypeInfo(kind: btObject))
      of rvClass, rvArray:
        binaryTypes.add(btObject)
        additionalInfos.add(AdditionalTypeInfo(kind: btObject))
    
    let memberTypeInfo = MemberTypeInfo(
      binaryTypes: binaryTypes,
      additionalInfos: additionalInfos
    )
    
    let classRecord = ClassWithMembersAndTypes(
      recordType: rtClassWithMembersAndTypes,
      classInfo: value.classVal.classInfo,
      memberTypeInfo: memberTypeInfo,
      libraryId: value.classVal.libraryId
    )
    writeClassWithMembersAndTypes(outp, classRecord)
    
    # Write the member values
    for member in value.classVal.members:
      writeRemotingValue(outp, member)
  of rvArray:
    let arrayRecord = ArraySingleObject(
      recordType: rtArraySingleObject,
      arrayInfo: value.arrayVal.arrayInfo
    )
    writeArraySingleObject(outp, arrayRecord)
    for elem in value.arrayVal.elements:
      writeRemotingValue(outp, elem)
