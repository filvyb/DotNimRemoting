import faststreams/[inputs, outputs]
import ../enums
import ../types
import ../context
import member
import class
import arrays
import strutils, sequtils

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
    record*: ClassRecord          # Tracks the specific class record type
    members*: seq[RemotingValue]  # Member values

  ArrayValue* = object
    record*: ArrayRecord          # Tracks the specific array record type
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
  of rtClassWithMembersAndTypes:
    let classRecord = readClassWithMembersAndTypes(inp)
    result = RemotingValue(kind: rvClass, classVal: ClassValue(
      record: ClassRecord(kind: rtClassWithMembersAndTypes, classWithMembersAndTypes: classRecord),
      members: @[]
    ))
    for i in 0..<classRecord.classInfo.memberCount:
      result.classVal.members.add(readRemotingValue(inp))
  of rtClassWithId:
    let classRecord = readClassWithId(inp)
    result = RemotingValue(kind: rvClass, classVal: ClassValue(
      record: ClassRecord(kind: rtClassWithId, classWithId: classRecord),
      members: @[]
    ))
  of rtArraySinglePrimitive:
    # Read ArraySinglePrimitive record (Section 2.4.3.3)
    let arrayRecord = readArraySinglePrimitive(inp)
    let primitiveType = arrayRecord.primitiveType  # Type of all elements
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

    for i in 0..<length:
      let value = readLengthPrefixedString(inp)
      let rv = RemotingValue(kind: rvString, stringVal: value)
      elements.add(rv)

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
  of rtBinaryArray:
    # Read the BinaryArray record metadata
    let arrayRecord = readBinaryArray(inp)
    
    # Compute total number of elements as product of lengths
    let totalElements = arrayRecord.lengths.foldl(a * b, 1'i32)
    if totalElements < 0:
      raise newException(IOError, "Total elements cannot be negative")
    
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
        let nextType = peekRecordType(inp)
        if nextType == rtObjectNullMultiple:
          let nullRecord = readObjectNullMultiple(inp)
          let nullsToAdd = min(nullRecord.nullCount, totalElements - count)
          for i in 0..<nullsToAdd:
            elements.add(RemotingValue(kind: rvNull))
          count += nullsToAdd
        elif nextType == rtObjectNullMultiple256:
          let nullRecord = readObjectNullMultiple256(inp)
          let nullsToAdd = min(nullRecord.nullCount.int32, totalElements - count)
          for i in 0..<nullsToAdd:
            elements.add(RemotingValue(kind: rvNull))
          count += nullsToAdd
        else:
          elements.add(readRemotingValue(inp))
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

proc writeRemotingValue*(outp: OutputStream, value: RemotingValue, ctx: SerializationContext) =
  ## Writes a RemotingValue to the output stream.
  ## Uses the SerializationContext to track previously serialized objects and write
  ## MemberReference records instead of full records for objects that have been 
  ## serialized before, improving space efficiency.
  case value.kind
  of rvPrimitive:
    writeMemberPrimitiveTyped(outp, MemberPrimitiveTyped(
      recordType: rtMemberPrimitiveTyped,
      value: value.primitiveVal
    ))
  of rvString:
    let valuePtr = cast[pointer](addr value)
    if ctx.hasWrittenObject(valuePtr):
      # Object was previously serialized, write a reference instead
      let id = ctx.getWrittenObjectId(valuePtr)
      writeMemberReference(outp, MemberReference(
        recordType: rtMemberReference,
        idRef: id
      ))
    else:
      # For compatibility with the tests, use ID 1 for string objects
      # This matches the expected test outputs
      let id = ctx.nextId
      ctx.nextId += 1
      ctx.setWrittenObjectId(valuePtr, id)
      
      let strRecord = BinaryObjectString(
        recordType: rtBinaryObjectString,
        objectId: id,
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
    let classPtr = cast[pointer](addr value.classVal)
    if ctx.hasWrittenObject(classPtr):
      # Class was previously serialized, write a reference instead
      let id = ctx.getWrittenObjectId(classPtr)
      writeMemberReference(outp, MemberReference(
        recordType: rtMemberReference,
        idRef: id
      ))
    else:
      # Assign a new ID and write the full class record
      let id = ctx.nextId
      ctx.nextId += 1
      ctx.setWrittenObjectId(classPtr, id)
      
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
      
      # Get the class record from the value
      let classRecord = value.classVal.record.classWithMembersAndTypes
      
      # Create a new ClassWithMembersAndTypes with our id
      let newClassRecord = ClassWithMembersAndTypes(
        recordType: rtClassWithMembersAndTypes,
        classInfo: ClassInfo(
          objectId: id,
          name: classRecord.classInfo.name,
          memberCount: classRecord.classInfo.memberCount,
          memberNames: classRecord.classInfo.memberNames
        ),
        memberTypeInfo: memberTypeInfo,
        libraryId: classRecord.libraryId
      )
      writeClassWithMembersAndTypes(outp, newClassRecord)
      
      # Write the member values
      for member in value.classVal.members:
        writeRemotingValue(outp, member, ctx)
  of rvArray:
    let arrayPtr = cast[pointer](addr value.arrayVal)
    if ctx.hasWrittenObject(arrayPtr):
      # Array was previously serialized, write a reference instead
      let id = ctx.getWrittenObjectId(arrayPtr)
      writeMemberReference(outp, MemberReference(
        recordType: rtMemberReference,
        idRef: id
      ))
    else:
      # Assign a new ID and write the full array record
      let id = ctx.nextId
      ctx.nextId += 1
      ctx.setWrittenObjectId(arrayPtr, id)
      
      let arrayRecordVariant = value.arrayVal.record # This holds the specific record type
      let elements = value.arrayVal.elements

      # --- Write the appropriate Array Record Header ---
      # Update the objectId/arrayInfo.objectId before writing
      case arrayRecordVariant.kind
      of rtArraySingleObject:
        var recordToWrite = arrayRecordVariant.arraySingleObject
        recordToWrite.arrayInfo.objectId = id # Assign the new ID
        recordToWrite.arrayInfo.length = elements.len.int32 # Ensure length matches
        writeArraySingleObject(outp, recordToWrite)

        # Write elements recursively (handles all types: primitive, string, null, ref, class, array)
        for elem in elements:
          writeRemotingValue(outp, elem, ctx)

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

        for elem in elements:
          if elem.kind notin {rvString, rvNull, rvReference}:
             raise newException(ValueError, "Invalid element type for ArraySingleString: " & $elem.kind)
          writeRemotingValue(outp, elem, ctx)

      of rtBinaryArray:
        var recordToWrite = arrayRecordVariant.binaryArray
        recordToWrite.objectId = id # Assign the new ID
        # Ensure lengths product matches element count (caller responsibility to construct correctly)
        let totalElements = recordToWrite.lengths.foldl(a * b, 1'i32)
        if totalElements != elements.len.int32:
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
          # TODO: Implement ObjectNullMultiple optimization here
          for elem in elements:
            writeRemotingValue(outp, elem, ctx)
      else:
        raise newException(ValueError, "Unsupported array record kind for writing: " & $arrayRecordVariant.kind)

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
  of rvString: "\"" & remVal.stringVal.value & "\""
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