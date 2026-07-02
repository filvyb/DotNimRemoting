import faststreams/[inputs, outputs]
import options, unicode, sequtils, sets, tables, strutils
import enums, types, grammar, context
import records/[arrays, class, member, methodinv, serialization]

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
  ## Create a ClassWithMembersAndTypes record from explicit type info
  ## (low-level; classValue derives the type info from the values)
  
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

#
# RemotingValue inspection
#
# Accessors over parsed values; they raise ValueError on kind mismatches.

proc expectKind(value: RemotingValue, kind: RemotingValueKind) =
  if value.kind != kind:
    raise newException(ValueError, "expected " & $kind & " value, got " & $value.kind)

proc expectPrimitive(value: RemotingValue, primitiveType: PrimitiveType): PrimitiveValue =
  expectKind(value, rvPrimitive)
  if value.primitiveVal.kind != primitiveType:
    raise newException(ValueError,
      "expected " & $primitiveType & " primitive, got " & $value.primitiveVal.kind)
  value.primitiveVal

proc isNull*(value: RemotingValue): bool =
  ## True for null values (a .NET null reference)
  value.kind == rvNull

proc getString*(value: RemotingValue): string =
  expectKind(value, rvString)
  value.stringVal.value

proc getBool*(value: RemotingValue): bool = expectPrimitive(value, ptBoolean).boolVal
proc getByte*(value: RemotingValue): uint8 = expectPrimitive(value, ptByte).byteVal
proc getSByte*(value: RemotingValue): int8 = expectPrimitive(value, ptSByte).sbyteVal
proc getInt16*(value: RemotingValue): int16 = expectPrimitive(value, ptInt16).int16Val
proc getUInt16*(value: RemotingValue): uint16 = expectPrimitive(value, ptUInt16).uint16Val
proc getInt32*(value: RemotingValue): int32 = expectPrimitive(value, ptInt32).int32Val
proc getUInt32*(value: RemotingValue): uint32 = expectPrimitive(value, ptUInt32).uint32Val
proc getInt64*(value: RemotingValue): int64 = expectPrimitive(value, ptInt64).int64Val
proc getUInt64*(value: RemotingValue): uint64 = expectPrimitive(value, ptUInt64).uint64Val
proc getSingle*(value: RemotingValue): float32 = expectPrimitive(value, ptSingle).singleVal
proc getDouble*(value: RemotingValue): float64 = expectPrimitive(value, ptDouble).doubleVal

proc getChar*(value: RemotingValue): string =
  ## A .NET char as a UTF-8 string holding one Unicode character
  expectPrimitive(value, ptChar).charVal

proc getDecimal*(value: RemotingValue): string =
  ## Decimal in its string form, e.g. "123.45"
  expectPrimitive(value, ptDecimal).decimalVal.value

proc getDateTime*(value: RemotingValue): types.DateTime =
  expectPrimitive(value, ptDateTime).dateTimeVal

proc getTimeSpan*(value: RemotingValue): TimeSpan =
  expectPrimitive(value, ptTimeSpan).timeSpanVal

proc elements*(value: RemotingValue): seq[RemotingValue] =
  ## Elements of an array value
  expectKind(value, rvArray)
  value.arrayVal.elements

proc len*(value: RemotingValue): int =
  ## Number of elements of an array value or members of a class value
  case value.kind
  of rvArray: value.arrayVal.elements.len
  of rvClass: value.classVal.members.len
  else:
    raise newException(ValueError, "expected array or class value, got " & $value.kind)

proc `[]`*(value: RemotingValue, index: int): RemotingValue =
  ## Element of an array value
  expectKind(value, rvArray)
  value.arrayVal.elements[index]

proc className*(value: RemotingValue): string =
  ## Class name; empty for ClassWithId records, which carry no metadata
  expectKind(value, rvClass)
  let rec = value.classVal.record
  case rec.kind
  of rtClassWithMembersAndTypes: rec.classWithMembersAndTypes.classInfo.name.value
  of rtSystemClassWithMembersAndTypes: rec.systemClassWithMembersAndTypes.classInfo.name.value
  of rtClassWithMembers: rec.classWithMembers.classInfo.name.value
  of rtSystemClassWithMembers: rec.systemClassWithMembers.classInfo.name.value
  else: ""

proc libraryIdOf*(value: RemotingValue): int32 =
  ## Library id of a class value; 0 for system classes and ClassWithId records
  expectKind(value, rvClass)
  let rec = value.classVal.record
  case rec.kind
  of rtClassWithMembersAndTypes: rec.classWithMembersAndTypes.libraryId
  of rtClassWithMembers: rec.classWithMembers.libraryId
  else: 0

proc memberNames*(value: RemotingValue): seq[string] =
  ## Member names of a class value, empty for ClassWithId records
  expectKind(value, rvClass)
  var names: seq[LengthPrefixedString]
  let rec = value.classVal.record
  case rec.kind
  of rtClassWithMembersAndTypes: names = rec.classWithMembersAndTypes.classInfo.memberNames
  of rtSystemClassWithMembersAndTypes: names = rec.systemClassWithMembersAndTypes.classInfo.memberNames
  of rtClassWithMembers: names = rec.classWithMembers.classInfo.memberNames
  of rtSystemClassWithMembers: names = rec.systemClassWithMembers.classInfo.memberNames
  else: discard
  for n in names:
    result.add(n.value)

proc getMember*(value: RemotingValue, name: string,
                fallbackNames: openArray[string] = []): RemotingValue =
  ## Member looked up by name; fallbackNames supplies the layout for
  ## ClassWithId records
  expectKind(value, rvClass)
  var names = memberNames(value)
  if names.len == 0:
    names = @fallbackNames
  for i, n in names:
    if n == name:
      if i >= value.classVal.members.len:
        break
      return value.classVal.members[i]
  raise newException(KeyError, "class " & className(value) & " has no member '" & name & "'")

proc `[]`*(value: RemotingValue, name: string): RemotingValue =
  ## Shorthand for getMember
  getMember(value, name)

#
# RemotingValue construction
#

proc nullValue*(): RemotingValue =
  ## A .NET null reference
  RemotingValue(kind: rvNull)

proc toRemotingValue*(value: RemotingValue): RemotingValue =
  ## Identity overload for varargs conversion
  value

proc toRemotingValue*(value: PrimitiveValue): RemotingValue =
  ## Strings map to rvString and nulls to rvNull, matching parsed values
  case value.kind
  of ptString: RemotingValue(kind: rvString, stringVal: value.stringVal)
  of ptNull: RemotingValue(kind: rvNull)
  else: RemotingValue(kind: rvPrimitive, primitiveVal: value)

proc toRemotingValue*(value: string): RemotingValue =
  RemotingValue(kind: rvString, stringVal: LengthPrefixedString(value: value))

proc toRemotingValue*(value: bool): RemotingValue = toRemotingValue(boolValue(value))
proc toRemotingValue*(value: int8): RemotingValue = toRemotingValue(sbyteValue(value))
proc toRemotingValue*(value: uint8): RemotingValue = toRemotingValue(byteValue(value))
proc toRemotingValue*(value: int16): RemotingValue = toRemotingValue(int16Value(value))
proc toRemotingValue*(value: uint16): RemotingValue = toRemotingValue(uint16Value(value))
proc toRemotingValue*(value: int32): RemotingValue = toRemotingValue(int32Value(value))
proc toRemotingValue*(value: uint32): RemotingValue = toRemotingValue(uint32Value(value))
proc toRemotingValue*(value: int64): RemotingValue = toRemotingValue(int64Value(value))
proc toRemotingValue*(value: uint64): RemotingValue = toRemotingValue(uint64Value(value))
proc toRemotingValue*(value: float32): RemotingValue = toRemotingValue(singleValue(value))
proc toRemotingValue*(value: float64): RemotingValue = toRemotingValue(doubleValue(value))
proc toRemotingValue*(value: char): RemotingValue = toRemotingValue(charValue($value))

proc toRemotingValue*(value: types.DateTime): RemotingValue =
  toRemotingValue(dateTimeValue(value.ticks, value.kind))

proc toRemotingValue*(value: int): RemotingValue =
  ## Plain ints map to .NET Int32; out-of-range values raise ValueError
  if value < int32.low.int or value > int32.high.int:
    raise newException(ValueError, "int argument out of Int32 range: " & $value)
  toRemotingValue(int32(value))

template primitiveTypeFor(T: typedesc): PrimitiveType =
  when T is bool: ptBoolean
  elif T is int8: ptSByte
  elif T is uint8: ptByte
  elif T is int16: ptInt16
  elif T is uint16: ptUInt16
  elif T is int32 or T is int: ptInt32
  elif T is uint32: ptUInt32
  elif T is int64: ptInt64
  elif T is uint64: ptUInt64
  elif T is float32: ptSingle
  elif T is float64: ptDouble
  else: {.error: "no .NET primitive type for " & $T.}

proc toRemotingValue*[T: bool|int8|uint8|int16|uint16|int32|uint32|int64|uint64|float32|float64|int](
    values: seq[T]): RemotingValue =
  ## A seq of primitives becomes a single-dimensional .NET primitive array
  var elements: seq[RemotingValue]
  for v in values:
    elements.add(toRemotingValue(v))
  RemotingValue(kind: rvArray, arrayVal: ArrayValue(
    record: ArrayRecord(kind: rtArraySinglePrimitive,
                        arraySinglePrimitive: arraySinglePrimitive(values.len, primitiveTypeFor(T))),
    elements: elements
  ))

proc stringArrayValue(elements: seq[RemotingValue]): RemotingValue =
  RemotingValue(kind: rvArray, arrayVal: ArrayValue(
    record: ArrayRecord(kind: rtArraySingleString,
                        arraySingleString: arraySingleString(elements.len)),
    elements: elements
  ))

proc toRemotingValue*(values: seq[string]): RemotingValue =
  ## .NET string array; use seq[Option[string]] when elements can be null
  stringArrayValue(values.mapIt(toRemotingValue(it)))

proc toRemotingValue*(values: seq[Option[string]]): RemotingValue =
  ## A .NET string array where none() elements become nulls
  stringArrayValue(values.mapIt(if it.isSome: toRemotingValue(it.get) else: nullValue()))

proc objectArrayValue*(elements: seq[RemotingValue]): RemotingValue =
  ## A single-dimensional object[] holding arbitrary values
  RemotingValue(kind: rvArray, arrayVal: ArrayValue(
    record: ArrayRecord(kind: rtArraySingleObject,
                        arraySingleObject: arraySingleObject(elements.len)),
    elements: elements
  ))

proc classArrayValue*(className: string, libraryId: int32,
                      elements: seq[RemotingValue]): RemotingValue =
  ## Typed array of class instances (e.g. Person[]) rather than object[]
  RemotingValue(kind: rvArray, arrayVal: ArrayValue(
    record: ArrayRecord(kind: rtBinaryArray, binaryArray: BinaryArray(
      recordType: rtBinaryArray,
      binaryArrayType: batSingle,
      rank: 1,
      lengths: @[elements.len.int32],
      typeEnum: btClass,
      additionalTypeInfo: AdditionalTypeInfo(kind: btClass, classInfo: ClassTypeInfo(
        typeName: LengthPrefixedString(value: className),
        libraryId: libraryId
      ))
    )),
    elements: elements
  ))

proc binaryLibrary*(name: string, id: int32): BinaryLibrary =
  ## Library (assembly) record referenced by class values. Pick a high id
  ## (100+) so it cannot collide with serialization-assigned object ids.
  BinaryLibrary(
    recordType: rtBinaryLibrary,
    libraryId: id,
    libraryName: LengthPrefixedString(value: name)
  )

proc classValue*(className: string, libraryId: int32,
                 members: openArray[(string, RemotingValue)]): RemotingValue =
  ## Class instance from named members; libraryId must match a binaryLibrary
  ## record passed along when the message is created
  var names: seq[string]
  var values: seq[RemotingValue]
  for (name, value) in members:
    names.add(name)
    values.add(value)
  let record = ClassWithMembersAndTypes(
    recordType: rtClassWithMembersAndTypes,
    classInfo: classInfo(name = className, memberNames = names),
    memberTypeInfo: determineMemberTypeInfo(values),
    libraryId: libraryId
  )
  RemotingValue(kind: rvClass, classVal: ClassValue(
    record: ClassRecord(kind: rtClassWithMembersAndTypes, classWithMembersAndTypes: record),
    members: values
  ))

proc systemClassValue*(className: string,
                       members: openArray[(string, RemotingValue)]): RemotingValue =
  ## Class instance from the system library (mscorlib); no library record needed
  var names: seq[string]
  var values: seq[RemotingValue]
  for (name, value) in members:
    names.add(name)
    values.add(value)
  let record = SystemClassWithMembersAndTypes(
    recordType: rtSystemClassWithMembersAndTypes,
    classInfo: classInfo(name = className, memberNames = names),
    memberTypeInfo: determineMemberTypeInfo(values)
  )
  RemotingValue(kind: rvClass, classVal: ClassValue(
    record: ClassRecord(kind: rtSystemClassWithMembersAndTypes, systemClassWithMembersAndTypes: record),
    members: values
  ))

proc objectToClass*[T: object](obj: T, className: string = "", libraryId: int32 = 0): RemotingValue =
  ## Converts a Nim object to a class value; fields must be convertible with
  ## toRemotingValue. For nested class-typed fields, define a toRemotingValue
  ## overload for the field type. className defaults to the Nim type name.
  mixin toRemotingValue
  var members: seq[(string, RemotingValue)]
  for fieldName, fieldValue in fieldPairs(obj):
    when compiles(toRemotingValue(fieldValue)):
      members.add((fieldName, toRemotingValue(fieldValue)))
    else:
      {.error: "objectToClass: unsupported field type " & $typeof(fieldValue) &
               " for field '" & fieldName & "' in " & $T &
               " (define a toRemotingValue overload for it)".}
  classValue(if className.len > 0: className else: $T, libraryId, members)

proc classToObject*[T: object](value: RemotingValue): T =
  ## Inverse of objectToClass: fills a Nim object from a class value by member
  ## name; the declared field order is the fallback layout for ClassWithId
  ## records
  var layout: seq[string]
  for fieldName, _ in fieldPairs(result):
    layout.add(fieldName)
  for fieldName, fieldValue in fieldPairs(result):
    let m = getMember(value, fieldName, layout)
    when fieldValue is string: fieldValue = m.getString
    elif fieldValue is bool: fieldValue = m.getBool
    elif fieldValue is char:
      let c = m.getChar
      if c.len != 1:
        raise newException(ValueError, "char member '" & fieldName & "' is not a single byte")
      fieldValue = c[0]
    elif fieldValue is int8: fieldValue = m.getSByte
    elif fieldValue is uint8: fieldValue = m.getByte
    elif fieldValue is int16: fieldValue = m.getInt16
    elif fieldValue is uint16: fieldValue = m.getUInt16
    elif fieldValue is int32: fieldValue = m.getInt32
    elif fieldValue is uint32: fieldValue = m.getUInt32
    elif fieldValue is int64: fieldValue = m.getInt64
    elif fieldValue is uint64: fieldValue = m.getUInt64
    elif fieldValue is int: fieldValue = int(m.getInt32)
    elif fieldValue is float32: fieldValue = m.getSingle
    elif fieldValue is float64: fieldValue = m.getDouble
    elif fieldValue is types.DateTime: fieldValue = m.getDateTime
    elif fieldValue is object: fieldValue = classToObject[typeof(fieldValue)](m)
    else:
      {.error: "classToObject: unsupported field type " & $typeof(fieldValue) &
               " for field '" & fieldName & "' in " & $T.}

#
# Library bookkeeping
#

proc collectLibraryIds(value: RemotingValue, ids: var HashSet[int32],
                       seen: var HashSet[pointer]) =
  if value == nil:
    return
  case value.kind
  of rvClass:
    let key = cast[pointer](value.classVal)
    if seen.containsOrIncl(key):
      return
    let rec = value.classVal.record
    case rec.kind
    of rtClassWithMembersAndTypes:
      if rec.classWithMembersAndTypes.libraryId != 0:
        ids.incl(rec.classWithMembersAndTypes.libraryId)
      for info in rec.classWithMembersAndTypes.memberTypeInfo.additionalInfos:
        if info.kind == btClass and info.classInfo.libraryId != 0:
          ids.incl(info.classInfo.libraryId)
    of rtClassWithMembers:
      if rec.classWithMembers.libraryId != 0:
        ids.incl(rec.classWithMembers.libraryId)
    else: discard
    for member in value.classVal.members:
      collectLibraryIds(member, ids, seen)
  of rvArray:
    let key = cast[pointer](value.arrayVal)
    if seen.containsOrIncl(key):
      return
    let rec = value.arrayVal.record
    if rec.kind == rtBinaryArray and rec.binaryArray.typeEnum == btClass and
       rec.binaryArray.additionalTypeInfo.classInfo.libraryId != 0:
      ids.incl(rec.binaryArray.additionalTypeInfo.classInfo.libraryId)
    for elem in value.arrayVal.elements:
      collectLibraryIds(elem, ids, seen)
  else: discard

proc collectLibraryIds*(value: RemotingValue): HashSet[int32] =
  ## Library ids referenced anywhere in the value graph
  var seen = initHashSet[pointer]()
  collectLibraryIds(value, result, seen)

proc requiredLibraries*(values: seq[RemotingValue],
                        libraries: seq[BinaryLibrary]): seq[BinaryLibrary] =
  ## Keeps only the libraries the values reference; raises ValueError when a
  ## referenced library id is left undefined
  var ids = initHashSet[int32]()
  var seen = initHashSet[pointer]()
  for value in values:
    collectLibraryIds(value, ids, seen)
  for lib in libraries:
    if lib.libraryId in ids:
      result.add(lib)
      ids.excl(lib.libraryId)
  if ids.len > 0:
    var missing: seq[string]
    for id in ids:
      missing.add($id)
    raise newException(ValueError,
      "values reference library ids with no matching BinaryLibrary: " & missing.join(", ") &
      " (pass the binaryLibrary(...) records used to build the class values)")

#
# Message-level value extraction
#

type
  RemoteException* = object of CatchableError
    ## Raised when a method return carries a serialized .NET exception
    className*: string  # e.g. "System.Exception"

proc methodNameOf*(msg: RemotingMessage): string =
  ## Method name of a method call message, "" when the message holds no call
  if msg.methodCall.isSome:
    msg.methodCall.get.methodName.value.stringVal.value
  else:
    ""

proc typeNameOf*(msg: RemotingMessage): string =
  ## Server type name of a method call message, "" when the message holds no call
  if msg.methodCall.isSome:
    msg.methodCall.get.typeName.value.stringVal.value
  else:
    ""

proc resolveReferences*(msg: RemotingMessage) =
  ## Replaces every MemberReference in the value graphs with its record, in
  ## place. Idempotent; callArgs and returnValueOf call it for you.
  var byId = initTable[int32, RemotingValue]()
  var indexed = initHashSet[pointer]()
  proc index(value: RemotingValue) =
    # Records with ids can sit anywhere in the graph, so collect recursively
    if value == nil:
      return
    case value.kind
    of rvClass:
      if indexed.containsOrIncl(cast[pointer](value.classVal)):
        return
      let id = objectIdOf(value)
      if id != 0:
        byId[id] = value
      for member in value.classVal.members:
        index(member)
    of rvArray:
      if indexed.containsOrIncl(cast[pointer](value.arrayVal)):
        return
      let id = objectIdOf(value)
      if id != 0:
        byId[id] = value
      for elem in value.arrayVal.elements:
        index(elem)
    else: discard
  for rec in msg.referencedRecords:
    index(rec)
  for rec in msg.methodCallArray:
    index(rec)

  proc resolved(value: RemotingValue): RemotingValue =
    if value == nil or value.kind != rvReference:
      return value
    if value.idRef notin byId:
      raise newException(ValueError, "Unresolved member reference id " & $value.idRef)
    byId[value.idRef]

  var seen = initHashSet[pointer]()
  proc walk(value: RemotingValue) =
    if value == nil:
      return
    case value.kind
    of rvClass:
      if seen.containsOrIncl(cast[pointer](value.classVal)):
        return
      for member in value.classVal.members.mitems:
        member = resolved(member)
        walk(member)
    of rvArray:
      if seen.containsOrIncl(cast[pointer](value.arrayVal)):
        return
      for elem in value.arrayVal.elements.mitems:
        elem = resolved(elem)
        walk(elem)
    else: discard

  for rec in msg.methodCallArray.mitems:
    rec = resolved(rec)
    walk(rec)
  for rec in msg.referencedRecords.mitems:
    rec = resolved(rec)
    walk(rec)

proc callArgs*(msg: RemotingMessage): seq[RemotingValue] =
  ## Method call arguments with references resolved, regardless of wire layout
  resolveReferences(msg)
  if msg.methodCall.isNone:
    return @[]
  let call = msg.methodCall.get
  if MessageFlag.ArgsInline in call.messageEnum:
    for arg in call.args:
      result.add(toRemotingValue(arg.value))
  elif MessageFlag.ArgsIsArray in call.messageEnum:
    result = msg.methodCallArray
  elif MessageFlag.ArgsInArray in call.messageEnum:
    if msg.methodCallArray.len > 0:
      let argsArray = msg.methodCallArray[0]
      if argsArray.kind != rvArray:
        raise newException(ValueError, "args-in-array element is not an array")
      result = argsArray.arrayVal.elements

proc raiseRemoteException(msg: RemotingMessage) =
  var excClassName = ""
  var excMessage = "remote method raised an exception"
  if msg.methodCallArray.len > 0:
    let exc = msg.methodCallArray[0]
    if exc != nil and exc.kind == rvClass:
      excClassName = className(exc)
      try:
        let m = getMember(exc, "Message")
        if m.kind == rvString:
          excMessage = m.stringVal.value
      except CatchableError:
        discard
  raise (ref RemoteException)(msg: excMessage, className: excClassName)

proc returnValueOf*(msg: RemotingMessage): RemotingValue =
  ## Return value with references resolved; void and null come back as rvNull.
  ## Raises RemoteException for serialized .NET exceptions.
  resolveReferences(msg)
  if msg.methodReturn.isNone:
    return nullValue()
  let ret = msg.methodReturn.get
  if MessageFlag.ExceptionInArray in ret.messageEnum:
    raiseRemoteException(msg)
  if MessageFlag.ReturnValueInline in ret.messageEnum:
    return toRemotingValue(ret.returnValue.value)
  if MessageFlag.ReturnValueInArray in ret.messageEnum and msg.methodCallArray.len > 0:
    return msg.methodCallArray[0]
  nullValue()
