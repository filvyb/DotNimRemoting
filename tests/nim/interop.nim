import options
import ../../src/DotNimRemoting/msnrbf/[grammar, enums, types, helpers, context]
import ../../src/DotNimRemoting/msnrbf/records/[methodinv, class, arrays, serialization]

# Shared helpers for the class/array interop tests. Both the Nim test client and
# server construct and pick apart RemotingValue graphs for the IEchoService
# methods that exchange Person objects and arrays with the .NET side.

const
  PersonClassName* = "DotNimTester.Lib.Person"
  LibAssemblyName* = "Lib, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null"
  PersonLibraryId* = 100'i32
    ## High id so it cannot collide with object ids handed out sequentially
    ## by the SerializationContext

proc personLibrary*(): BinaryLibrary =
  BinaryLibrary(
    recordType: rtBinaryLibrary,
    libraryId: PersonLibraryId,
    libraryName: LengthPrefixedString(value: LibAssemblyName)
  )

#
# RemotingValue constructors
#

proc int32RV*(value: int32): RemotingValue =
  RemotingValue(kind: rvPrimitive, primitiveVal: int32Value(value))

proc doubleRV*(value: float64): RemotingValue =
  RemotingValue(kind: rvPrimitive, primitiveVal: doubleValue(value))

proc stringRV*(value: string): RemotingValue =
  RemotingValue(kind: rvString, stringVal: LengthPrefixedString(value: value))

proc int32ArrayValue*(values: seq[int32]): RemotingValue =
  ## int[] as ArraySinglePrimitive
  var elements: seq[RemotingValue]
  for v in values:
    elements.add(int32RV(v))
  RemotingValue(kind: rvArray, arrayVal: ArrayValue(
    record: ArrayRecord(kind: rtArraySinglePrimitive,
                        arraySinglePrimitive: arraySinglePrimitive(values.len, ptInt32)),
    elements: elements
  ))

proc doubleArrayValue*(values: seq[float64]): RemotingValue =
  ## double[] as ArraySinglePrimitive
  var elements: seq[RemotingValue]
  for v in values:
    elements.add(doubleRV(v))
  RemotingValue(kind: rvArray, arrayVal: ArrayValue(
    record: ArrayRecord(kind: rtArraySinglePrimitive,
                        arraySinglePrimitive: arraySinglePrimitive(values.len, ptDouble)),
    elements: elements
  ))

proc stringArrayValue*(values: seq[Option[string]]): RemotingValue =
  ## string[] as ArraySingleString; none() elements become nulls
  var elements: seq[RemotingValue]
  for v in values:
    if v.isSome:
      elements.add(stringRV(v.get))
    else:
      elements.add(RemotingValue(kind: rvNull))
  RemotingValue(kind: rvArray, arrayVal: ArrayValue(
    record: ArrayRecord(kind: rtArraySingleString,
                        arraySingleString: arraySingleString(values.len)),
    elements: elements
  ))

proc personValue*(name: string, age: int32, score: float64): RemotingValue =
  ## DotNimTester.Lib.Person as ClassWithMembersAndTypes; member names must
  ## match the public fields of the C# class
  let record = classWithMembersAndTypes(PersonClassName, PersonLibraryId, @[
    ("Name", btString, AdditionalTypeInfo(kind: btString)),
    ("Age", btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptInt32)),
    ("Score", btPrimitive, AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptDouble))
  ])
  RemotingValue(kind: rvClass, classVal: ClassValue(
    record: ClassRecord(kind: rtClassWithMembersAndTypes, classWithMembersAndTypes: record),
    members: @[stringRV(name), int32RV(age), doubleRV(score)]
  ))

proc personArrayValue*(people: seq[RemotingValue]): RemotingValue =
  ## Person[] as BinaryArray of class type, so .NET materializes a typed array
  RemotingValue(kind: rvArray, arrayVal: ArrayValue(
    record: ArrayRecord(kind: rtBinaryArray, binaryArray: BinaryArray(
      recordType: rtBinaryArray,
      binaryArrayType: batSingle,
      rank: 1,
      lengths: @[people.len.int32],
      typeEnum: btClass,
      additionalTypeInfo: AdditionalTypeInfo(kind: btClass, classInfo: ClassTypeInfo(
        typeName: LengthPrefixedString(value: PersonClassName),
        libraryId: PersonLibraryId
      ))
    )),
    elements: people
  ))

#
# Reference resolution and value extraction
#

proc objectIdOf*(rv: RemotingValue): int32 =
  ## Object id a class/array record was read with; 0 for kinds that don't keep one
  case rv.kind
  of rvClass:
    let rec = rv.classVal.record
    case rec.kind
    of rtClassWithMembersAndTypes: rec.classWithMembersAndTypes.classInfo.objectId
    of rtSystemClassWithMembersAndTypes: rec.systemClassWithMembersAndTypes.classInfo.objectId
    of rtClassWithMembers: rec.classWithMembers.classInfo.objectId
    of rtSystemClassWithMembers: rec.systemClassWithMembers.classInfo.objectId
    of rtClassWithId: rec.classWithId.objectId
    else: 0
  of rvArray:
    let rec = rv.arrayVal.record
    case rec.kind
    of rtArraySingleObject: rec.arraySingleObject.arrayInfo.objectId
    of rtArraySinglePrimitive: rec.arraySinglePrimitive.arrayInfo.objectId
    of rtArraySingleString: rec.arraySingleString.arrayInfo.objectId
    of rtBinaryArray: rec.binaryArray.objectId
    else: 0
  else: 0

proc resolve*(msg: RemotingMessage, rv: RemotingValue): RemotingValue =
  ## Follows a MemberReference to the record it points at; non-references
  ## pass through unchanged. .NET serializes nested objects as references
  ## to records appended after the call array.
  if rv == nil or rv.kind != rvReference:
    return rv
  for rec in msg.referencedRecords:
    if objectIdOf(rec) == rv.idRef:
      return rec
  for rec in msg.methodCallArray:
    if objectIdOf(rec) == rv.idRef:
      return rec
  raise newException(ValueError, "Unresolved member reference id " & $rv.idRef)

proc resolvedElements*(msg: RemotingMessage, rv: RemotingValue): seq[RemotingValue] =
  ## Array elements with any references resolved
  doAssert rv.kind == rvArray, "expected array, got " & $rv.kind
  for elem in rv.arrayVal.elements:
    result.add(resolve(msg, elem))

proc callArgs*(msg: RemotingMessage): seq[RemotingValue] =
  ## Method call arguments as RemotingValues with references resolved,
  ## regardless of the wire layout chosen by the sender
  if msg.methodCall.isNone:
    return @[]
  let call = msg.methodCall.get
  if MessageFlag.ArgsInline in call.messageEnum:
    for arg in call.args:
      if arg.primitiveType == ptString:
        result.add(RemotingValue(kind: rvString, stringVal: arg.value.stringVal))
      else:
        result.add(RemotingValue(kind: rvPrimitive, primitiveVal: arg.value))
  elif MessageFlag.ArgsIsArray in call.messageEnum:
    for elem in msg.methodCallArray:
      result.add(resolve(msg, elem))
  elif MessageFlag.ArgsInArray in call.messageEnum:
    if msg.methodCallArray.len > 0:
      let argsArray = resolve(msg, msg.methodCallArray[0])
      doAssert argsArray.kind == rvArray, "args-in-array element is not an array"
      for elem in argsArray.arrayVal.elements:
        result.add(resolve(msg, elem))

proc returnValueOf*(msg: RemotingMessage): RemotingValue =
  ## Return value of a method return message with references resolved
  if msg.methodReturn.isNone:
    return RemotingValue(kind: rvNull)
  let ret = msg.methodReturn.get
  if MessageFlag.ReturnValueInline in ret.messageEnum:
    if ret.returnValue.primitiveType == ptString:
      return RemotingValue(kind: rvString, stringVal: ret.returnValue.value.stringVal)
    return RemotingValue(kind: rvPrimitive, primitiveVal: ret.returnValue.value)
  elif MessageFlag.ReturnValueInArray in ret.messageEnum:
    if msg.methodCallArray.len > 0:
      return resolve(msg, msg.methodCallArray[0])
  RemotingValue(kind: rvNull)

proc memberNamesOf(rv: RemotingValue): seq[string] =
  var names: seq[LengthPrefixedString]
  let rec = rv.classVal.record
  case rec.kind
  of rtClassWithMembersAndTypes: names = rec.classWithMembersAndTypes.classInfo.memberNames
  of rtSystemClassWithMembersAndTypes: names = rec.systemClassWithMembersAndTypes.classInfo.memberNames
  of rtClassWithMembers: names = rec.classWithMembers.classInfo.memberNames
  of rtSystemClassWithMembers: names = rec.systemClassWithMembers.classInfo.memberNames
  else: discard  # ClassWithId carries no metadata of its own
  for n in names:
    result.add(n.value)

proc indexOf(names: seq[string], name: string): int =
  for i, n in names:
    if n == name:
      return i
  -1

proc personFields*(msg: RemotingMessage, rv: RemotingValue): tuple[name: string, age: int32, score: float64] =
  ## Extracts the fields of a Person value, looking members up by name when the
  ## record carries metadata. ClassWithId records reference metadata defined
  ## elsewhere in the stream, so fall back to the declared field order.
  doAssert rv.kind == rvClass, "expected class value, got " & $rv.kind
  var names = memberNamesOf(rv)
  if names.len == 0:
    names = @["Name", "Age", "Score"]
  doAssert rv.classVal.members.len == names.len, "Person member count mismatch"

  let nameVal = resolve(msg, rv.classVal.members[names.indexOf("Name")])
  doAssert nameVal.kind == rvString, "Person.Name: expected string, got " & $nameVal.kind
  result.name = nameVal.stringVal.value

  let ageVal = resolve(msg, rv.classVal.members[names.indexOf("Age")])
  doAssert ageVal.kind == rvPrimitive and ageVal.primitiveVal.kind == ptInt32,
    "Person.Age: expected int32"
  result.age = ageVal.primitiveVal.int32Val

  let scoreVal = resolve(msg, rv.classVal.members[names.indexOf("Score")])
  doAssert scoreVal.kind == rvPrimitive and scoreVal.primitiveVal.kind == ptDouble,
    "Person.Score: expected double"
  result.score = scoreVal.primitiveVal.doubleVal

#
# Message construction
#
# .NET only accepts class/array values in the call array as MemberReference
# records pointing at records appended after it (inline array records inside
# the call array deserialize as null on Mono). The writer assigns object ids
# sequentially in depth-first write order, so the ids the deferred records
# will receive can be computed up front: the call array wrapper always takes
# id 1, and every string/class/array record takes the next id when written.

proc idsConsumed(rv: RemotingValue): int32 =
  ## Number of object ids the writer assigns when serializing this value
  ## (assumes no shared sub-objects, which holds for these test graphs)
  case rv.kind
  of rvString:
    1
  of rvPrimitive, rvNull, rvReference:
    0
  of rvClass:
    var n = 1'i32
    for m in rv.classVal.members:
      n += idsConsumed(m)
    n
  of rvArray:
    var n = 1'i32
    for e in rv.arrayVal.elements:
      n += idsConsumed(e)
    n

proc deferComplexValues(values: seq[RemotingValue]):
    tuple[callArray, refs: seq[RemotingValue]] =
  ## Replaces class/array values with MemberReferences to records that will be
  ## written after the call array, predicting the ids the writer will assign
  var nextId = 2'i32  # id 1 is the call array wrapper
  # Strings left inline in the call array are written (and take their ids)
  # before any deferred record
  for v in values:
    if v.kind notin {rvClass, rvArray}:
      nextId += idsConsumed(v)
  for v in values:
    if v.kind in {rvClass, rvArray}:
      result.callArray.add(RemotingValue(kind: rvReference, idRef: nextId))
      result.refs.add(v)
      nextId += idsConsumed(v)
    else:
      result.callArray.add(v)

proc createComplexMethodCallRequest*(methodName, typeName: string,
                                     args: seq[RemotingValue],
                                     libraries: seq[BinaryLibrary] = @[]): seq[byte] =
  ## Method call request with arguments carried in the call array (ArgsIsArray),
  ## the layout .NET uses when arguments are not inline-able primitives
  let fullTypeName = typeName & ", Version=1.0.0.0, Culture=neutral, PublicKeyToken=null"
  let call = BinaryMethodCall(
    recordType: rtMethodCall,
    messageEnum: {MessageFlag.NoContext, MessageFlag.ArgsIsArray},
    methodName: newStringValueWithCode(methodName),
    typeName: newStringValueWithCode(fullTypeName)
  )
  let (callArray, refs) = deferComplexValues(args)
  let ctx = newSerializationContext()
  let msg = newRemotingMessage(ctx, methodCall = some(call), callArray = callArray,
                               refs = refs, libraries = libraries)
  serializeRemotingMessage(msg, ctx)

proc createComplexReturnResponse*(value: RemotingValue,
                                  libraries: seq[BinaryLibrary] = @[]): seq[byte] =
  ## Method return response with the return value carried in the call array
  ## (ReturnValueInArray), the layout .NET uses for class/array return values
  let ret = BinaryMethodReturn(
    recordType: rtMethodReturn,
    messageEnum: {MessageFlag.NoContext, MessageFlag.NoArgs, MessageFlag.ReturnValueInArray}
  )
  let (callArray, refs) = deferComplexValues(@[value])
  let ctx = newSerializationContext()
  let msg = newRemotingMessage(ctx, methodReturn = some(ret), callArray = callArray,
                               refs = refs, libraries = libraries)
  serializeRemotingMessage(msg, ctx)
