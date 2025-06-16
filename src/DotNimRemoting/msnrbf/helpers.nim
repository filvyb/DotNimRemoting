import faststreams/[inputs, outputs]
import options, unicode, sequtils
import enums, types, grammar, context
import records/[arrays, class, member, methodinv]

#
# PrimitiveValue creation helpers
#

proc boolValue*(value: bool): PrimitiveValue =
  ## Create a boolean primitive value
  PrimitiveValue(kind: ptBoolean, boolVal: value)

proc byteValue*(value: uint8): PrimitiveValue =
  ## Create a byte primitive value
  PrimitiveValue(kind: ptByte, byteVal: value)

proc sbyteValue*(value: int8): PrimitiveValue =
  ## Create a signed byte primitive value
  PrimitiveValue(kind: ptSByte, sbyteVal: value)

proc int16Value*(value: int16): PrimitiveValue =
  ## Create an int16 primitive value
  PrimitiveValue(kind: ptInt16, int16Val: value)

proc int32Value*(value: int32): PrimitiveValue =
  ## Create an int32 primitive value
  PrimitiveValue(kind: ptInt32, int32Val: value)

proc int64Value*(value: int64): PrimitiveValue =
  ## Create an int64 primitive value
  PrimitiveValue(kind: ptInt64, int64Val: value)

proc uint16Value*(value: uint16): PrimitiveValue =
  ## Create a uint16 primitive value
  PrimitiveValue(kind: ptUInt16, uint16Val: value)
  
proc uint32Value*(value: uint32): PrimitiveValue =
  ## Create a uint32 primitive value
  PrimitiveValue(kind: ptUInt32, uint32Val: value)

proc uint64Value*(value: uint64): PrimitiveValue =
  ## Create a uint64 primitive value
  PrimitiveValue(kind: ptUInt64, uint64Val: value)

proc doubleValue*(value: float64): PrimitiveValue =
  ## Create a double primitive value
  PrimitiveValue(kind: ptDouble, doubleVal: value)

proc singleValue*(value: float32): PrimitiveValue =
  ## Create a single (float32) primitive value
  PrimitiveValue(kind: ptSingle, singleVal: value)

proc decimalValue*(value: string): PrimitiveValue =
  ## Create a decimal primitive value
  if not types.validateDecimalFormat(value):
    raise newException(ValueError, "Invalid decimal format: " & value)
    
  PrimitiveValue(
    kind: ptDecimal, 
    decimalVal: Decimal(LengthPrefixedString(value: value))
  )

proc charValue*(value: string): PrimitiveValue =
  ## Create a char primitive value
  if value.runeLen != 1:
    raise newException(ValueError, "Char must be exactly one Unicode character")
    
  PrimitiveValue(kind: ptChar, charVal: value)

proc timeSpanValue*(value: int64): PrimitiveValue =
  ## Create a timespan primitive value
  PrimitiveValue(kind: ptTimeSpan, timeSpanVal: value)

proc dateTimeValue*(ticks: int64, kind: uint8 = 0): PrimitiveValue =
  ## Create a datetime primitive value
  if kind > 2:
    raise newException(ValueError, "Invalid DateTime kind value (0-2)")
    
  PrimitiveValue(
    kind: ptDateTime, 
    dateTimeVal: DateTime(ticks: ticks, kind: kind)
  )

proc stringValue*(value: string): PrimitiveValue =
  ## Create a string primitive value
  PrimitiveValue(kind: ptString, stringVal: LengthPrefixedString(value: value))

#
# Value conversion helpers
#

converter toValueWithCode*(value: PrimitiveValue): ValueWithCode =
  ## Convert PrimitiveValue to ValueWithCode
  result.primitiveType = value.kind
  result.value = value

converter toValueWithCode*(strVal: StringValueWithCode): ValueWithCode =
  ## Converts StringValueWithCode to ValueWithCode
  ## (not sure if this is needed since StringValueWithCode inherits from ValueWithCode)
  result.primitiveType = strVal.primitiveType
  result.value = strVal.value

#
# Method call/return creation helpers
#

proc methodCallBasic*(methodName, typeName: string, argsInline: seq[PrimitiveValue] = @[]): BinaryMethodCall =
  ## Create a simple method call with inline arguments
  var flags: MessageFlags = {MessageFlag.NoContext}
  
  if argsInline.len > 0:
    flags.incl(MessageFlag.ArgsInline)
  else:
    flags.incl(MessageFlag.NoArgs)
    
  result = BinaryMethodCall(
    recordType: rtMethodCall,
    messageEnum: flags,
    methodName: newStringValueWithCode(methodName),
    typeName: newStringValueWithCode(typeName)
  )
  
  if argsInline.len > 0:
    var args: seq[ValueWithCode]
    for arg in argsInline:
      args.add(toValueWithCode(arg))
    result.args = args

proc methodCallArrayArgs*(methodName, typeName: string): (BinaryMethodCall, seq[ValueWithCode]) =
  ## Create a method call with arguments in array (returns the call and empty array for populating)
  let flags: MessageFlags = {MessageFlag.NoContext, MessageFlag.ArgsInArray}
  
  result[0] = BinaryMethodCall(
    recordType: rtMethodCall,
    messageEnum: flags,
    methodName: newStringValueWithCode(methodName),
    typeName: newStringValueWithCode(typeName)
  )
  
  # Return empty array for caller to populate
  result[1] = @[]

proc methodReturnBasic*(returnValue: PrimitiveValue = PrimitiveValue(kind: ptNull)): BinaryMethodReturn =
  ## Create a simple method return with inline return value
  var flags: MessageFlags = {MessageFlag.NoContext, MessageFlag.NoArgs}
  
  if returnValue.kind == ptNull:
    flags.incl(MessageFlag.NoReturnValue)
  else:
    flags.incl(MessageFlag.ReturnValueInline)
    
  result = BinaryMethodReturn(
    recordType: rtMethodReturn,
    messageEnum: flags
  )
  
  if returnValue.kind != ptNull:
    result.returnValue = toValueWithCode(returnValue)

proc methodReturnVoid*(): BinaryMethodReturn =
  ## Create a method return with void result (no return value)
  BinaryMethodReturn(
    recordType: rtMethodReturn,
    messageEnum: {MessageFlag.NoContext, MessageFlag.NoArgs, MessageFlag.ReturnValueVoid}
  )

proc methodReturnArrayValue*(): (BinaryMethodReturn, seq[ValueWithCode]) =
  ## Create a method return with return value in array
  let flags: MessageFlags = {MessageFlag.NoContext, MessageFlag.NoArgs, MessageFlag.ReturnValueInArray}
  
  result[0] = BinaryMethodReturn(
    recordType: rtMethodReturn,
    messageEnum: flags
  )
  
  # Return empty array for caller to populate with the return value
  result[1] = @[]

proc methodReturnException*(exceptionValue: ValueWithCode): (BinaryMethodReturn, seq[ValueWithCode]) =
  ## Create a method return with exception
  let flags: MessageFlags = {MessageFlag.NoContext, MessageFlag.ExceptionInArray}
  
  result[0] = BinaryMethodReturn(
    recordType: rtMethodReturn,
    messageEnum: flags
  )
  
  # Array with exception
  result[1] = @[exceptionValue]

#
# Complete message creation helpers 
#

proc createMethodCallMessage*(methodName, typeName: string, argsInline: seq[PrimitiveValue] = @[]): RemotingMessage =
  ## Create a complete method call message with inline arguments
  let ctx = newSerializationContext()
  let call = methodCallBasic(methodName, typeName, argsInline)
  newRemotingMessage(ctx, methodCall = some(call))

proc createMethodReturnMessage*(returnValue: PrimitiveValue = PrimitiveValue(kind: ptNull)): RemotingMessage =
  ## Create a complete method return message
  let ctx = newSerializationContext()
  let ret = methodReturnBasic(returnValue)
  newRemotingMessage(ctx, methodReturn = some(ret))

proc createMethodReturnVoidMessage*(): RemotingMessage =
  ## Create a complete method return message with void result
  let ctx = newSerializationContext()
  let ret = methodReturnVoid()
  newRemotingMessage(ctx, methodReturn = some(ret))

#
# Serialization/Deserialization convenience functions
#

proc serializeRemotingMessage*(msg: RemotingMessage): seq[byte] =
  ## Serialize a RemotingMessage to bytes using a new SerializationContext.
  ## This uses a fresh context and is appropriate when no object reference tracking is needed.
  let ctx = newSerializationContext()
  var output = memoryOutput()
  writeRemotingMessage(output, msg, ctx)
  return output.getOutput(seq[byte])
  
proc serializeRemotingMessage*(msg: RemotingMessage, ctx: SerializationContext): seq[byte] =
  ## Serialize a RemotingMessage to bytes using the provided SerializationContext
  var output = memoryOutput()
  writeRemotingMessage(output, msg, ctx)
  return output.getOutput(seq[byte])

proc deserializeRemotingMessage*(data: openArray[byte]): RemotingMessage =
  ## Deserialize bytes to RemotingMessage
  var input = memoryInput(data)
  return readRemotingMessage(input)

#
# Class construction helpers
#

proc classInfo*(name: string, memberNames: seq[string]): ClassInfo =
  ## Create a ClassInfo structure without setting objectId
  ## The objectId will be set when the containing class record is written to the stream.
  ClassInfo(
    name: LengthPrefixedString(value: name),
    memberCount: memberNames.len.int32,
    memberNames: memberNames.mapIt(LengthPrefixedString(value: it))
  )


proc classWithMembersAndTypes*(className: string, libraryId: int32,
                                    members: seq[(string, BinaryType, AdditionalTypeInfo)]): ClassWithMembersAndTypes =
  ## Create a ClassWithMembersAndTypes record
  
  # Create member names list and type info
  var memberNames: seq[string]
  var binaryTypes: seq[BinaryType]
  var additionalInfos: seq[AdditionalTypeInfo]
  
  for (name, btype, addInfo) in members:
    memberNames.add(name)
    binaryTypes.add(btype)
    additionalInfos.add(addInfo)
  
  result = ClassWithMembersAndTypes(
    recordType: rtClassWithMembersAndTypes,
    classInfo: classInfo(name = className, memberNames = memberNames),
    memberTypeInfo: MemberTypeInfo(
      binaryTypes: binaryTypes,
      additionalInfos: additionalInfos
    ),
    libraryId: libraryId
  )


proc systemClassWithMembersAndTypes*(className: string, members: seq[(string, BinaryType, AdditionalTypeInfo)]): SystemClassWithMembersAndTypes =
  ## Create a SystemClassWithMembersAndTypes record
  ## For system library classes, so no library ID needed
  
  # Create member names list and type info
  var memberNames: seq[string]
  var binaryTypes: seq[BinaryType]
  var additionalInfos: seq[AdditionalTypeInfo]
  
  for (name, btype, addInfo) in members:
    memberNames.add(name)
    binaryTypes.add(btype)
    additionalInfos.add(addInfo)
  
  result = SystemClassWithMembersAndTypes(
    recordType: rtSystemClassWithMembersAndTypes,
    classInfo: classInfo(name = className, memberNames = memberNames),
    memberTypeInfo: MemberTypeInfo(
      binaryTypes: binaryTypes,
      additionalInfos: additionalInfos
    )
  )


proc classWithMembersAndTypesToSystemClass*(value: RemotingValue, newClassName: string = ""): RemotingValue =
  ## Converts a RemotingValue containing rtClassWithMembersAndTypes to rtSystemClassWithMembersAndTypes
  ## This removes the library reference, making it a system class
  ## If newClassName is provided, the class name will be changed to the new value
  
  # Validate input
  if value.kind != rvClass:
    raise newException(ValueError, "Input must be a class RemotingValue")
    
  if value.classVal.record.kind != rtClassWithMembersAndTypes:
    raise newException(ValueError, "Input must contain rtClassWithMembersAndTypes record")
  
  let sourceRecord = value.classVal.record.classWithMembersAndTypes
  
  # Determine the class name to use
  var classInfoToUse = sourceRecord.classInfo
  if newClassName.len > 0:
    classInfoToUse = ClassInfo(
      objectId: sourceRecord.classInfo.objectId,
      name: LengthPrefixedString(value: newClassName),
      memberCount: sourceRecord.classInfo.memberCount,
      memberNames: sourceRecord.classInfo.memberNames
    )
  
  # Create SystemClassWithMembersAndTypes from the source
  let systemClassRecord = SystemClassWithMembersAndTypes(
    recordType: rtSystemClassWithMembersAndTypes,
    classInfo: classInfoToUse,  # Use potentially modified class info
    memberTypeInfo: sourceRecord.memberTypeInfo  # Copy member type info as-is
  )
  
  # Create new ClassRecord wrapper
  let classRecordWrapper = ClassRecord(
    kind: rtSystemClassWithMembersAndTypes,
    systemClassWithMembersAndTypes: systemClassRecord
  )
  
  # Create new ClassValue with same members
  let classValue = ClassValue(
    record: classRecordWrapper,
    members: value.classVal.members  # Copy members as-is
  )
  
  # Return new RemotingValue
  result = RemotingValue(
    kind: rvClass,
    classVal: classValue
  )


proc objectToClass*[T: object](obj: T, className: string = "", libraryId: int32 = 0): RemotingValue =
  ## Converts a Nim object to a RemotingValue containing ClassWithMembersAndTypes
  ## Only supports primitive types and strings for now.
  ## If className is not provided, uses the type name
  ## 
  ## Example:
  ##   type Person = object
  ##     name: string
  ##     age: int32
  ##   
  ##   let person = Person(name: "John", age: 30)
  ##   let remoteValue = objectToClass(person, "MyNamespace.Person", 1)
  
  # Determine class name
  let actualClassName = if className.len > 0: className else: $T
  
  # Build member info and values
  var memberInfos: seq[(string, BinaryType, AdditionalTypeInfo)]
  var memberValues: seq[RemotingValue]
  
  # Iterate through object fields
  for fieldName, fieldValue in fieldPairs(obj):
    # Determine binary type and create RemotingValue based on field type
    when fieldValue is string:
      memberInfos.add((fieldName, btString, AdditionalTypeInfo()))
      memberValues.add(RemotingValue(kind: rvString, stringVal: LengthPrefixedString(value: fieldValue)))
    elif fieldValue is int32:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptInt32)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: int32Value(fieldValue)))
    elif fieldValue is int64:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptInt64)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: int64Value(fieldValue)))
    elif fieldValue is float32:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptSingle)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: singleValue(fieldValue)))
    elif fieldValue is float64:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptDouble)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: doubleValue(fieldValue)))
    elif fieldValue is bool:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptBoolean)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: boolValue(fieldValue)))
    elif fieldValue is DateTime:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptDateTime)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: dateTimeValue(fieldValue)))
    elif fieldValue is char:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptChar)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: charValue(fieldValue)))
    elif fieldValue is int8:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptSByte)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: sbyteValue(fieldValue)))
    elif fieldValue is uint8:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptByte)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: byteValue(fieldValue)))
    elif fieldValue is int16:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptInt16)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: int16Value(fieldValue)))
    elif fieldValue is uint16:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptUInt16)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: uint16Value(fieldValue)))
    elif fieldValue is uint32:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptUInt32)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: uint32Value(fieldValue)))
    elif fieldValue is uint64:
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptUInt64)))
      memberValues.add(RemotingValue(kind: rvPrimitive, primitiveVal: uint64Value(fieldValue)))
    else:
      # For unsupported types, use null
      memberInfos.add((fieldName, btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptNull)))
      memberValues.add(RemotingValue(kind: rvNull))
  
  # Create the ClassWithMembersAndTypes record
  let classRecord = classWithMembersAndTypes(actualClassName, libraryId, memberInfos)
  
  # Create ClassRecord wrapper
  let classRecordWrapper = ClassRecord(
    kind: rtClassWithMembersAndTypes,
    classWithMembersAndTypes: classRecord
  )
  
  # Create ClassValue with members
  let classValue = ClassValue(
    record: classRecordWrapper,
    members: memberValues
  )
  
  # Return complete RemotingValue
  result = RemotingValue(
    kind: rvClass,
    classVal: classValue
  )

#
# Array construction helpers
#

proc arraySingleObject*(length: int): ArraySingleObject =
  ## Create a single-dimensional object array
  result = ArraySingleObject(
    recordType: rtArraySingleObject,
    arrayInfo: ArrayInfo(
      length: length.int32
    )
  )


proc arraySinglePrimitive*(length: int,
                               primitiveType: PrimitiveType): ArraySinglePrimitive =
  ## Create a single-dimensional primitive array
  if primitiveType in {ptNull, ptString}:
    raise newException(ValueError, "Invalid primitive array type: " & $primitiveType)
    
  result = ArraySinglePrimitive(
    recordType: rtArraySinglePrimitive,
    arrayInfo: ArrayInfo(
      length: length.int32
    ),
    primitiveType: primitiveType
  )


proc arraySingleString*(length: int): ArraySingleString =
  ## Create a single-dimensional string array
  result = ArraySingleString(
    recordType: rtArraySingleString,
    arrayInfo: ArrayInfo(
      length: length.int32
    )
  )


#
# Object construction helpers
#

proc binaryObjectString*(value: string): BinaryObjectString =
  ## Create a BinaryObjectString record
  result = BinaryObjectString(
    recordType: rtBinaryObjectString,
    value: LengthPrefixedString(value: value)
  )
