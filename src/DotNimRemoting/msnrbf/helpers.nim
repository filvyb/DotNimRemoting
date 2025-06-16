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
  ## The objectId will be set when the containing class record is processed by SerializationContext
  ClassInfo(
    name: LengthPrefixedString(value: name),
    memberCount: memberNames.len.int32,
    memberNames: memberNames.mapIt(LengthPrefixedString(value: it))
  )


proc classWithMembersAndTypes*(ctx: SerializationContext, className: string, 
                                    libraryId: int32,
                                    members: seq[(string, BinaryType, AdditionalTypeInfo)]): ClassWithMembersAndTypes =
  ## Create a ClassWithMembersAndTypes record using context for ID assignment
  
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
  
  # Assign ID directly to the class record
  result.classInfo.objectId = ctx.nextId
  ctx.nextId += 1


proc systemClassWithMembersAndTypes*(ctx: SerializationContext, className: string,
                                           members: seq[(string, BinaryType, AdditionalTypeInfo)]): SystemClassWithMembersAndTypes =
  ## Create a SystemClassWithMembersAndTypes record using context for ID assignment
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
  
  # Assign ID directly to the class record
  result.classInfo.objectId = ctx.nextId
  ctx.nextId += 1


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

#
# Array construction helpers
#

proc arraySingleObject*(ctx: SerializationContext, length: int): ArraySingleObject =
  ## Create a single-dimensional object array, using context for ID assignment
  result = ArraySingleObject(
    recordType: rtArraySingleObject,
    arrayInfo: ArrayInfo(
      length: length.int32
    )
  )
  
  # Assign ID directly to the array record
  result.arrayInfo.objectId = ctx.nextId
  ctx.nextId += 1


proc arraySinglePrimitive*(ctx: SerializationContext, length: int,
                               primitiveType: PrimitiveType): ArraySinglePrimitive =
  ## Create a single-dimensional primitive array using context for ID assignment
  if primitiveType in {ptNull, ptString}:
    raise newException(ValueError, "Invalid primitive array type: " & $primitiveType)
    
  result = ArraySinglePrimitive(
    recordType: rtArraySinglePrimitive,
    arrayInfo: ArrayInfo(
      length: length.int32
    ),
    primitiveType: primitiveType
  )
  
  # Assign ID directly to the array record
  result.arrayInfo.objectId = ctx.nextId
  ctx.nextId += 1


proc arraySingleString*(ctx: SerializationContext, length: int): ArraySingleString =
  ## Create a single-dimensional string array using context for ID assignment
  result = ArraySingleString(
    recordType: rtArraySingleString,
    arrayInfo: ArrayInfo(
      length: length.int32
    )
  )
  
  # Assign ID directly to the array record
  result.arrayInfo.objectId = ctx.nextId
  ctx.nextId += 1


#
# Object construction helpers
#

proc binaryObjectString*(ctx: SerializationContext, value: string): BinaryObjectString =
  ## Create a BinaryObjectString record using context for ID assignment
  result = BinaryObjectString(
    recordType: rtBinaryObjectString,
    value: LengthPrefixedString(value: value)
  )
  
  # Assign ID directly to the string record
  result.objectId = ctx.nextId
  ctx.nextId += 1