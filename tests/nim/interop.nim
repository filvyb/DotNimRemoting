import options
import ../../src/DotNimRemoting/msnrbf/[grammar, enums, types, helpers, context]
import ../../src/DotNimRemoting/msnrbf/records/[methodinv, class, arrays, serialization]

# Shared helpers for the class/array interop tests. Both the Nim test client and
# server construct and pick apart RemotingValue graphs for the IEchoService
# methods that exchange Person objects and arrays with the .NET side.

const
  PersonClassName* = "DotNimTester.Lib.Person"
  AddressClassName* = "DotNimTester.Lib.Address"
  EmployeeClassName* = "DotNimTester.Lib.Employee"
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

proc byteArrayValue*(values: seq[byte]): RemotingValue =
  ## byte[] as ArraySinglePrimitive
  var elements: seq[RemotingValue]
  for v in values:
    elements.add(RemotingValue(kind: rvPrimitive, primitiveVal: byteValue(v)))
  RemotingValue(kind: rvArray, arrayVal: ArrayValue(
    record: ArrayRecord(kind: rtArraySinglePrimitive,
                        arraySinglePrimitive: arraySinglePrimitive(values.len, ptByte)),
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

proc addressValue*(street, city: string): RemotingValue =
  ## DotNimTester.Lib.Address as ClassWithMembersAndTypes
  let record = classWithMembersAndTypes(AddressClassName, PersonLibraryId, @[
    ("Street", btString, AdditionalTypeInfo(kind: btString)),
    ("City", btString, AdditionalTypeInfo(kind: btString))
  ])
  RemotingValue(kind: rvClass, classVal: ClassValue(
    record: ClassRecord(kind: rtClassWithMembersAndTypes, classWithMembersAndTypes: record),
    members: @[stringRV(street), stringRV(city)]
  ))

proc employeeValue*(name: string, address: RemotingValue): RemotingValue =
  ## DotNimTester.Lib.Employee with a class-typed Home member; the nested
  ## Address record is written inline in member position
  let record = classWithMembersAndTypes(EmployeeClassName, PersonLibraryId, @[
    ("Name", btString, AdditionalTypeInfo(kind: btString)),
    ("Home", btClass, AdditionalTypeInfo(kind: btClass, classInfo: ClassTypeInfo(
      typeName: LengthPrefixedString(value: AddressClassName),
      libraryId: PersonLibraryId
    )))
  ])
  RemotingValue(kind: rvClass, classVal: ClassValue(
    record: ClassRecord(kind: rtClassWithMembersAndTypes, classWithMembersAndTypes: record),
    members: @[stringRV(name), address]
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
# Value extraction
#

proc resolvedElements*(msg: RemotingMessage, rv: RemotingValue): seq[RemotingValue] =
  ## Array elements with any references resolved
  doAssert rv.kind == rvArray, "expected array, got " & $rv.kind
  for elem in rv.arrayVal.elements:
    result.add(resolveReference(msg, elem))

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
      elif arg.primitiveType == ptNull:
        # .NET inlines a null object argument as a Null-typed ValueWithCode
        result.add(RemotingValue(kind: rvNull))
      else:
        result.add(RemotingValue(kind: rvPrimitive, primitiveVal: arg.value))
  elif MessageFlag.ArgsIsArray in call.messageEnum:
    for elem in msg.methodCallArray:
      result.add(resolveReference(msg, elem))
  elif MessageFlag.ArgsInArray in call.messageEnum:
    if msg.methodCallArray.len > 0:
      let argsArray = resolveReference(msg, msg.methodCallArray[0])
      doAssert argsArray.kind == rvArray, "args-in-array element is not an array"
      for elem in argsArray.arrayVal.elements:
        result.add(resolveReference(msg, elem))

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
      return resolveReference(msg, msg.methodCallArray[0])
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

  let nameVal = resolveReference(msg, rv.classVal.members[names.indexOf("Name")])
  doAssert nameVal.kind == rvString, "Person.Name: expected string, got " & $nameVal.kind
  result.name = nameVal.stringVal.value

  let ageVal = resolveReference(msg, rv.classVal.members[names.indexOf("Age")])
  doAssert ageVal.kind == rvPrimitive and ageVal.primitiveVal.kind == ptInt32,
    "Person.Age: expected int32"
  result.age = ageVal.primitiveVal.int32Val

  let scoreVal = resolveReference(msg, rv.classVal.members[names.indexOf("Score")])
  doAssert scoreVal.kind == rvPrimitive and scoreVal.primitiveVal.kind == ptDouble,
    "Person.Score: expected double"
  result.score = scoreVal.primitiveVal.doubleVal

proc classNameOf*(rv: RemotingValue): string =
  ## Class name of a class value, empty for ClassWithId records
  doAssert rv.kind == rvClass, "expected class value, got " & $rv.kind
  let rec = rv.classVal.record
  case rec.kind
  of rtClassWithMembersAndTypes: rec.classWithMembersAndTypes.classInfo.name.value
  of rtSystemClassWithMembersAndTypes: rec.systemClassWithMembersAndTypes.classInfo.name.value
  of rtClassWithMembers: rec.classWithMembers.classInfo.name.value
  of rtSystemClassWithMembers: rec.systemClassWithMembers.classInfo.name.value
  else: ""

proc classMember*(msg: RemotingMessage, rv: RemotingValue, name: string,
                  fallbackNames: seq[string] = @[]): RemotingValue =
  ## Member of a class value looked up by name, references resolved.
  ## fallbackNames supplies the member layout for ClassWithId records.
  doAssert rv.kind == rvClass, "expected class value, got " & $rv.kind
  var names = memberNamesOf(rv)
  if names.len == 0:
    names = fallbackNames
  let idx = names.indexOf(name)
  doAssert idx >= 0, "class has no member '" & name & "'"
  resolveReference(msg, rv.classVal.members[idx])

proc addressFields*(msg: RemotingMessage, rv: RemotingValue): tuple[street, city: string] =
  let streetVal = classMember(msg, rv, "Street", @["Street", "City"])
  doAssert streetVal.kind == rvString, "Address.Street: expected string, got " & $streetVal.kind
  result.street = streetVal.stringVal.value
  let cityVal = classMember(msg, rv, "City", @["Street", "City"])
  doAssert cityVal.kind == rvString, "Address.City: expected string, got " & $cityVal.kind
  result.city = cityVal.stringVal.value

proc employeeFields*(msg: RemotingMessage, rv: RemotingValue): tuple[name, street, city: string] =
  ## Extracts an Employee value including its nested Address member
  let nameVal = classMember(msg, rv, "Name", @["Name", "Home"])
  doAssert nameVal.kind == rvString, "Employee.Name: expected string, got " & $nameVal.kind
  result.name = nameVal.stringVal.value
  let homeVal = classMember(msg, rv, "Home", @["Name", "Home"])
  doAssert homeVal.kind == rvClass, "Employee.Home: expected class, got " & $homeVal.kind
  let (street, city) = addressFields(msg, homeVal)
  result.street = street
  result.city = city

#
# Message construction
#

proc createComplexMethodCallRequest*(methodName, typeName: string,
                                     args: seq[RemotingValue],
                                     libraries: seq[BinaryLibrary] = @[]): seq[byte] =
  ## Method call request with arguments in the call array (ArgsIsArray), the
  ## layout .NET uses for non-inline-able primitives. The writer defers nested
  ## array records to top level per the grammar (Section 2.7).
  let fullTypeName = typeName & ", Version=1.0.0.0, Culture=neutral, PublicKeyToken=null"
  let call = BinaryMethodCall(
    recordType: rtMethodCall,
    messageEnum: {MessageFlag.NoContext, MessageFlag.ArgsIsArray},
    methodName: newStringValueWithCode(methodName),
    typeName: newStringValueWithCode(fullTypeName)
  )
  let ctx = newSerializationContext()
  let msg = newRemotingMessage(ctx, methodCall = some(call), callArray = args,
                               libraries = libraries)
  serializeRemotingMessage(msg, ctx)

proc createComplexReturnResponse*(value: RemotingValue,
                                  libraries: seq[BinaryLibrary] = @[]): seq[byte] =
  ## Method return response with the return value carried in the call array
  ## (ReturnValueInArray), the layout .NET uses for class/array return values
  let ret = BinaryMethodReturn(
    recordType: rtMethodReturn,
    messageEnum: {MessageFlag.NoContext, MessageFlag.NoArgs, MessageFlag.ReturnValueInArray}
  )
  let ctx = newSerializationContext()
  let msg = newRemotingMessage(ctx, methodReturn = some(ret), callArray = @[value],
                               libraries = libraries)
  serializeRemotingMessage(msg, ctx)
