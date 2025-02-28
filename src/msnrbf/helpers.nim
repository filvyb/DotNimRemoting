import faststreams/[inputs, outputs]
import options, tables, unicode, sequtils
import enums, types, grammar
import records/[arrays, class, member, methodinv, serialization]

type
  IdGenerator* = ref object
    ## Helper to manage object IDs for serialization
    nextId*: int32
    libraries*: Table[string, int32]  # Maps library names to IDs
    objects*: Table[int, int32]       # Maps object hash to IDs

proc newIdGenerator*(): IdGenerator =
  ## Creates a new ID generator with initial state
  IdGenerator(
    nextId: 1,
    libraries: initTable[string, int32](),
    objects: initTable[int, int32]()
  )

proc getNextId*(gen: IdGenerator): int32 =
  ## Get next available ID and increment counter
  result = gen.nextId
  inc gen.nextId

proc getLibraryId*(gen: IdGenerator, name: string): int32 =
  ## Get or create ID for library
  if name in gen.libraries:
    return gen.libraries[name]
  
  result = gen.getNextId()
  gen.libraries[name] = result

#
# PrimitiveValue creation helpers
#

proc boolValue*(value: bool): PrimitiveValue =
  ## Create a boolean primitive value
  PrimitiveValue(kind: ptBoolean, boolVal: value)

proc byteValue*(value: uint8): PrimitiveValue =
  ## Create a byte primitive value
  PrimitiveValue(kind: ptByte, byteVal: value)

proc int32Value*(value: int32): PrimitiveValue =
  ## Create an int32 primitive value
  PrimitiveValue(kind: ptInt32, int32Val: value)

proc int64Value*(value: int64): PrimitiveValue =
  ## Create an int64 primitive value
  PrimitiveValue(kind: ptInt64, int64Val: value)

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

proc createMethodCallMessage*(methodName, typeName: string, 
                             argsInline: seq[PrimitiveValue] = @[]): RemotingMessage =
  ## Create a complete method call message with inline arguments
  let call = methodCallBasic(methodName, typeName, argsInline)
  newRemotingMessage(methodCall = some(call))

proc createMethodReturnMessage*(returnValue: PrimitiveValue = PrimitiveValue(kind: ptNull)): RemotingMessage =
  ## Create a complete method return message
  let ret = methodReturnBasic(returnValue)
  newRemotingMessage(methodReturn = some(ret))

proc createMethodReturnVoidMessage*(): RemotingMessage =
  ## Create a complete method return message with void result
  let ret = methodReturnVoid()
  newRemotingMessage(methodReturn = some(ret))

#
# Serialization/Deserialization convenience functions
#

proc serializeRemotingMessage*(msg: RemotingMessage): seq[byte] =
  ## Serialize a RemotingMessage to bytes
  var output = memoryOutput()
  writeRemotingMessage(output, msg)
  return output.getOutput(seq[byte])

proc deserializeRemotingMessage*(data: openArray[byte]): RemotingMessage =
  ## Deserialize bytes to RemotingMessage
  var input = memoryInput(data)
  return readRemotingMessage(input)

#
# Class construction helpers
#

proc classInfo*(idGen: IdGenerator, name: string, memberNames: seq[string]): ClassInfo =
  ## Create a ClassInfo structure
  ClassInfo(
    objectId: idGen.getNextId(),
    name: LengthPrefixedString(value: name),
    memberCount: memberNames.len.int32,
    memberNames: memberNames.mapIt(LengthPrefixedString(value: it))
  )

proc classWithMembersAndTypes*(idGen: IdGenerator, className: string, 
                                    libraryName: string,
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
    
  let libraryId = idGen.getLibraryId(libraryName)
  
  result = ClassWithMembersAndTypes(
    recordType: rtClassWithMembersAndTypes,
    classInfo: classInfo(idGen, className, memberNames),
    memberTypeInfo: MemberTypeInfo(
      binaryTypes: binaryTypes,
      additionalInfos: additionalInfos
    ),
    libraryId: libraryId
  )

#
# Array construction helpers
#

proc arraySingleObject*(idGen: IdGenerator, length: int): ArraySingleObject =
  ## Create a single-dimensional object array
  ArraySingleObject(
    recordType: rtArraySingleObject,
    arrayInfo: ArrayInfo(
      objectId: idGen.getNextId(),
      length: length.int32
    )
  )

proc arraySinglePrimitive*(idGen: IdGenerator, length: int, 
                               primitiveType: PrimitiveType): ArraySinglePrimitive =
  ## Create a single-dimensional primitive array
  if primitiveType in {ptNull, ptString}:
    raise newException(ValueError, "Invalid primitive array type: " & $primitiveType)
    
  ArraySinglePrimitive(
    recordType: rtArraySinglePrimitive,
    arrayInfo: ArrayInfo(
      objectId: idGen.getNextId(),
      length: length.int32
    ),
    primitiveType: primitiveType
  )

proc arraySingleString*(idGen: IdGenerator, length: int): ArraySingleString =
  ## Create a single-dimensional string array
  ArraySingleString(
    recordType: rtArraySingleString,
    arrayInfo: ArrayInfo(
      objectId: idGen.getNextId(),
      length: length.int32
    )
  )

#
# Object construction helpers
#

proc binaryObjectString*(idGen: IdGenerator, value: string): BinaryObjectString =
  ## Create a BinaryObjectString record
  BinaryObjectString(
    recordType: rtBinaryObjectString,
    objectId: idGen.getNextId(),
    value: LengthPrefixedString(value: value)
  )

proc binaryLibrary*(idGen: IdGenerator, name: string): BinaryLibrary =
  ## Create a BinaryLibrary record
  let libId = idGen.getLibraryId(name)
  BinaryLibrary(
    recordType: rtBinaryLibrary,
    libraryId: libId,
    libraryName: LengthPrefixedString(value: name)
  )