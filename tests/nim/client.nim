import ../../src/DotNimRemoting/tcp/[client]
import ../../src/DotNimRemoting/msnrbf/[grammar, helpers, enums, types]
import ../../src/DotNimRemoting/msnrbf/records/[methodinv, serialization]
import asyncdispatch, strutils, options, math
import interop

# Direction 1: Nim client -> .NET (Mono) server.
# Exercises every IEchoService method and verifies the typed return value,
# exiting non-zero on the first mismatch so the runner script reports failure.

const typename = "DotNimTester.Lib.IEchoService, Lib"

proc callComplex(client: NrtpTcpClient, methodName: string,
                 args: seq[RemotingValue],
                 libraries: seq[BinaryLibrary] = @[]): Future[RemotingMessage] {.async.} =
  ## Invokes a method whose arguments or return value are classes/arrays and
  ## returns the parsed response message for the caller to pick apart
  let requestData = createComplexMethodCallRequest(methodName, typename, args, libraries)
  let responseData = await client.invoke(methodName, typename, false, requestData)
  return deserializeRemotingMessage(responseData)

proc main() {.async.} =
  let client = newNrtpTcpClient("tcp://127.0.0.1:8080/EchoService")
  await client.connect()

  block echo:
    let r = await client.callMethod("Echo", typename, @[stringValue("Hello from Nim")])
    echo "Echo -> ", r.stringVal.value
    doAssert r.kind == ptString, "Echo: expected string, got " & $r.kind
    doAssert r.stringVal.value == "Hello from Nim"

  block concat:
    let r = await client.callMethod("Concat", typename,
      @[stringValue("foo"), stringValue("bar")])
    echo "Concat -> ", r.stringVal.value
    doAssert r.kind == ptString, "Concat: expected string, got " & $r.kind
    doAssert r.stringVal.value == "foobar"

  block add:
    let r = await client.callMethod("Add", typename,
      @[int32Value(40), int32Value(2)])
    echo "Add -> ", r.int32Val
    doAssert r.kind == ptInt32, "Add: expected int32, got " & $r.kind
    doAssert r.int32Val == 42

  block sum:
    let r = await client.callMethod("Sum", typename,
      @[int64Value(2_000_000_000'i64), int64Value(1_000_000_000'i64)])
    echo "Sum -> ", r.int64Val
    doAssert r.kind == ptInt64, "Sum: expected int64, got " & $r.kind
    doAssert r.int64Val == 3_000_000_000'i64

  block multiply:
    let r = await client.callMethod("Multiply", typename,
      @[doubleValue(2.5), doubleValue(4.0)])
    echo "Multiply -> ", r.doubleVal
    doAssert r.kind == ptDouble, "Multiply: expected double, got " & $r.kind
    doAssert r.doubleVal == 10.0

  block isPositiveFalse:
    let r = await client.callMethod("IsPositive", typename, @[int32Value(-5)])
    echo "IsPositive(-5) -> ", r.boolVal
    doAssert r.kind == ptBoolean, "IsPositive: expected bool, got " & $r.kind
    doAssert r.boolVal == false

  block isPositiveTrue:
    let r = await client.callMethod("IsPositive", typename, @[int32Value(7)])
    echo "IsPositive(7) -> ", r.boolVal
    doAssert r.kind == ptBoolean, "IsPositive: expected bool, got " & $r.kind
    doAssert r.boolVal == true

  block addNegative:
    let r = await client.callMethod("Add", typename,
      @[int32Value(-40), int32Value(-2)])
    echo "Add(-40, -2) -> ", r.int32Val
    doAssert r.kind == ptInt32, "Add(negative): expected int32, got " & $r.kind
    doAssert r.int32Val == -42

  block sumNegative:
    let r = await client.callMethod("Sum", typename,
      @[int64Value(-2_000_000_000'i64), int64Value(-1_000_000_000'i64)])
    echo "Sum(negative) -> ", r.int64Val
    doAssert r.kind == ptInt64, "Sum(negative): expected int64, got " & $r.kind
    doAssert r.int64Val == -3_000_000_000'i64

  block echoEmpty:
    let r = await client.callMethod("Echo", typename, @[stringValue("")])
    echo "Echo(\"\") -> ", r.stringVal.value
    doAssert r.kind == ptString, "Echo(empty): expected string, got " & $r.kind
    doAssert r.stringVal.value == ""

  block echoUnicode:
    # Multi-byte UTF-8 chars plus an astral-plane emoji (surrogate pair in UTF-16)
    let unicode = "Příliš žluťoučký kůň 🐎"
    let r = await client.callMethod("Echo", typename, @[stringValue(unicode)])
    echo "Echo(unicode) -> ", r.stringVal.value
    doAssert r.kind == ptString, "Echo(unicode): expected string, got " & $r.kind
    doAssert r.stringVal.value == unicode

  block echoLong:
    # Long enough that the length prefix needs multiple 7-bit-encoded bytes
    let longStr = repeat('x', 20000)
    let r = await client.callMethod("Echo", typename, @[stringValue(longStr)])
    echo "Echo(20000 chars) -> ", r.stringVal.value.len, " chars"
    doAssert r.kind == ptString, "Echo(long): expected string, got " & $r.kind
    doAssert r.stringVal.value == longStr

  block echoDecimal:
    let r = await client.callMethod("EchoDecimal", typename,
      @[decimalValue("123.45")])
    echo "EchoDecimal -> ", r.decimalVal.value
    doAssert r.kind == ptDecimal, "EchoDecimal: expected decimal, got " & $r.kind
    doAssert r.decimalVal.value == "123.45"

  block echoDecimalNegative:
    let r = await client.callMethod("EchoDecimal", typename,
      @[decimalValue("-0.001")])
    echo "EchoDecimal(-0.001) -> ", r.decimalVal.value
    doAssert r.kind == ptDecimal, "EchoDecimal(negative): expected decimal, got " & $r.kind
    doAssert r.decimalVal.value == "-0.001"

  block echoDateTime:
    # 2021-03-19 ticks, kind 1 = UTC; both must survive the round-trip
    let ticks = 637_500_000_000_000_000'i64
    let r = await client.callMethod("EchoDateTime", typename,
      @[dateTimeValue(ticks, 1)])
    echo "EchoDateTime -> ticks ", r.dateTimeVal.ticks, " kind ", r.dateTimeVal.kind
    doAssert r.kind == ptDateTime, "EchoDateTime: expected datetime, got " & $r.kind
    doAssert r.dateTimeVal.ticks == ticks
    doAssert r.dateTimeVal.kind == 1

  block echoTimeSpan:
    let r = await client.callMethod("EchoTimeSpan", typename,
      @[timeSpanValue(123_456_789'i64)])
    echo "EchoTimeSpan -> ", r.timeSpanVal
    doAssert r.kind == ptTimeSpan, "EchoTimeSpan: expected timespan, got " & $r.kind
    doAssert r.timeSpanVal == 123_456_789'i64

  block multiplyFloat:
    let r = await client.callMethod("MultiplyFloat", typename,
      @[singleValue(2.5'f32), singleValue(4.0'f32)])
    echo "MultiplyFloat -> ", r.singleVal
    doAssert r.kind == ptSingle, "MultiplyFloat: expected single, got " & $r.kind
    doAssert r.singleVal == 10.0'f32

  block echoChar:
    # Two-byte UTF-8 character
    let r = await client.callMethod("EchoChar", typename, @[charValue("Ω")])
    echo "EchoChar -> ", r.charVal
    doAssert r.kind == ptChar, "EchoChar: expected char, got " & $r.kind
    doAssert r.charVal == "Ω"

  block incrementByte:
    let r = await client.callMethod("IncrementByte", typename,
      @[byteValue(41'u8)])
    echo "IncrementByte -> ", r.byteVal
    doAssert r.kind == ptByte, "IncrementByte: expected byte, got " & $r.kind
    doAssert r.byteVal == 42'u8

  block negateSByte:
    let r = await client.callMethod("NegateSByte", typename,
      @[sbyteValue(-42'i8)])
    echo "NegateSByte -> ", r.sbyteVal
    doAssert r.kind == ptSByte, "NegateSByte: expected sbyte, got " & $r.kind
    doAssert r.sbyteVal == 42'i8

  block negateShort:
    let r = await client.callMethod("NegateShort", typename,
      @[int16Value(12345'i16)])
    echo "NegateShort -> ", r.int16Val
    doAssert r.kind == ptInt16, "NegateShort: expected int16, got " & $r.kind
    doAssert r.int16Val == -12345'i16

  block echoUInt16:
    let r = await client.callMethod("EchoUInt16", typename,
      @[uint16Value(high(uint16))])
    echo "EchoUInt16 -> ", r.uint16Val
    doAssert r.kind == ptUInt16, "EchoUInt16: expected uint16, got " & $r.kind
    doAssert r.uint16Val == high(uint16)

  block echoUInt32:
    let r = await client.callMethod("EchoUInt32", typename,
      @[uint32Value(high(uint32))])
    echo "EchoUInt32 -> ", r.uint32Val
    doAssert r.kind == ptUInt32, "EchoUInt32: expected uint32, got " & $r.kind
    doAssert r.uint32Val == high(uint32)

  block echoUInt64:
    let r = await client.callMethod("EchoUInt64", typename,
      @[uint64Value(high(uint64))])
    echo "EchoUInt64 -> ", r.uint64Val
    doAssert r.kind == ptUInt64, "EchoUInt64: expected uint64, got " & $r.kind
    doAssert r.uint64Val == high(uint64)

  block ping:
    let r = await client.callMethod("Ping", typename)
    echo "Ping -> ", r.kind
    doAssert r.kind == ptNull, "Ping: expected null (void), got " & $r.kind

  block echoDoubleNaN:
    let r = await client.callMethod("EchoDouble", typename, @[doubleValue(NaN)])
    echo "EchoDouble(NaN) -> ", r.doubleVal
    doAssert r.kind == ptDouble, "EchoDouble(NaN): expected double, got " & $r.kind
    doAssert r.doubleVal.isNaN, "EchoDouble(NaN): expected NaN, got " & $r.doubleVal

  block echoDoubleInf:
    let r = await client.callMethod("EchoDouble", typename, @[doubleValue(Inf)])
    echo "EchoDouble(+Inf) -> ", r.doubleVal
    doAssert r.kind == ptDouble, "EchoDouble(+Inf): expected double, got " & $r.kind
    doAssert r.doubleVal == Inf

  block echoDoubleNegInf:
    let r = await client.callMethod("EchoDouble", typename, @[doubleValue(-Inf)])
    echo "EchoDouble(-Inf) -> ", r.doubleVal
    doAssert r.kind == ptDouble, "EchoDouble(-Inf): expected double, got " & $r.kind
    doAssert r.doubleVal == -Inf

  block echoIntArray:
    let sent = @[1'i32, 2, 3, -4]
    let msg = await client.callComplex("EchoIntArray", @[int32ArrayValue(sent)])
    let r = returnValueOf(msg)
    doAssert r.kind == rvArray, "EchoIntArray: expected array, got " & $r.kind
    let elems = resolvedElements(msg, r)
    echo "EchoIntArray -> ", elems.len, " elements"
    doAssert elems.len == sent.len
    for i, v in sent:
      doAssert elems[i].kind == rvPrimitive and elems[i].primitiveVal.kind == ptInt32
      doAssert elems[i].primitiveVal.int32Val == v,
        "EchoIntArray[" & $i & "]: expected " & $v & ", got " & $elems[i].primitiveVal.int32Val

  block echoIntArrayEmpty:
    let msg = await client.callComplex("EchoIntArray", @[int32ArrayValue(@[])])
    let r = returnValueOf(msg)
    doAssert r.kind == rvArray, "EchoIntArray(empty): expected array, got " & $r.kind
    echo "EchoIntArray(empty) -> ", r.arrayVal.elements.len, " elements"
    doAssert r.arrayVal.elements.len == 0

  block echoDoubleArray:
    let sent = @[1.5'f64, -2.25, 0.0]
    let msg = await client.callComplex("EchoDoubleArray", @[doubleArrayValue(sent)])
    let r = returnValueOf(msg)
    doAssert r.kind == rvArray, "EchoDoubleArray: expected array, got " & $r.kind
    let elems = resolvedElements(msg, r)
    echo "EchoDoubleArray -> ", elems.len, " elements"
    doAssert elems.len == sent.len
    for i, v in sent:
      doAssert elems[i].kind == rvPrimitive and elems[i].primitiveVal.kind == ptDouble
      doAssert elems[i].primitiveVal.doubleVal == v,
        "EchoDoubleArray[" & $i & "]: expected " & $v

  block echoByteArray:
    let sent = @[0'u8, 1, 127, 128, 255]
    let msg = await client.callComplex("EchoByteArray", @[byteArrayValue(sent)])
    let r = returnValueOf(msg)
    doAssert r.kind == rvArray, "EchoByteArray: expected array, got " & $r.kind
    let elems = resolvedElements(msg, r)
    echo "EchoByteArray -> ", elems.len, " elements"
    doAssert elems.len == sent.len
    for i, v in sent:
      doAssert elems[i].kind == rvPrimitive and elems[i].primitiveVal.kind == ptByte
      doAssert elems[i].primitiveVal.byteVal == v,
        "EchoByteArray[" & $i & "]: expected " & $v & ", got " & $elems[i].primitiveVal.byteVal

  block sumIntArray:
    let msg = await client.callComplex("SumIntArray",
      @[int32ArrayValue(@[1'i32, 2, 3, 4, 5])])
    let r = returnValueOf(msg)
    doAssert r.kind == rvPrimitive and r.primitiveVal.kind == ptInt32,
      "SumIntArray: expected int32 return"
    echo "SumIntArray -> ", r.primitiveVal.int32Val
    doAssert r.primitiveVal.int32Val == 15

  block echoStringArray:
    let sent = @[some("alpha"), none(string), some("gamma")]
    let msg = await client.callComplex("EchoStringArray", @[stringArrayValue(sent)])
    let r = returnValueOf(msg)
    doAssert r.kind == rvArray, "EchoStringArray: expected array, got " & $r.kind
    let elems = resolvedElements(msg, r)
    echo "EchoStringArray -> ", elems.len, " elements"
    doAssert elems.len == sent.len
    for i, v in sent:
      if v.isSome:
        doAssert elems[i].kind == rvString, "EchoStringArray[" & $i & "]: expected string"
        doAssert elems[i].stringVal.value == v.get
      else:
        doAssert elems[i].kind == rvNull, "EchoStringArray[" & $i & "]: expected null"

  block echoStringArrayNullRun:
    # Consecutive nulls travel as ObjectNullMultiple256 records
    let sent = @[some("x"), none(string), none(string), none(string),
                 some("y"), none(string), none(string)]
    let msg = await client.callComplex("EchoStringArray", @[stringArrayValue(sent)])
    let r = returnValueOf(msg)
    doAssert r.kind == rvArray, "EchoStringArray(null run): expected array, got " & $r.kind
    let elems = resolvedElements(msg, r)
    echo "EchoStringArray(null run) -> ", elems.len, " elements"
    doAssert elems.len == sent.len
    for i, v in sent:
      if v.isSome:
        doAssert elems[i].kind == rvString and elems[i].stringVal.value == v.get,
          "EchoStringArray(null run)[" & $i & "]: expected " & v.get
      else:
        doAssert elems[i].kind == rvNull, "EchoStringArray(null run)[" & $i & "]: expected null"

  block makeNulls:
    # 300 nulls force the 32-bit ObjectNullMultiple record
    let msg = await client.callComplex("MakeNulls", @[int32RV(300)])
    let r = returnValueOf(msg)
    doAssert r.kind == rvArray, "MakeNulls: expected array, got " & $r.kind
    let elems = resolvedElements(msg, r)
    echo "MakeNulls(300) -> ", elems.len, " elements"
    doAssert elems.len == 300
    for i, elem in elems:
      doAssert elem.kind == rvNull, "MakeNulls[" & $i & "]: expected null, got " & $elem.kind

  block joinStrings:
    let msg = await client.callComplex("JoinStrings",
      @[stringArrayValue(@[some("a"), some("b"), some("c")]), stringRV("-")])
    let r = returnValueOf(msg)
    doAssert r.kind == rvString, "JoinStrings: expected string, got " & $r.kind
    echo "JoinStrings -> ", r.stringVal.value
    doAssert r.stringVal.value == "a-b-c"

  block makeRange:
    let msg = await client.callComplex("MakeRange", @[int32RV(5), int32RV(4)])
    let r = returnValueOf(msg)
    doAssert r.kind == rvArray, "MakeRange: expected array, got " & $r.kind
    let elems = resolvedElements(msg, r)
    echo "MakeRange -> ", elems.len, " elements"
    doAssert elems.len == 4
    for i in 0..<4:
      doAssert elems[i].primitiveVal.int32Val == int32(5 + i),
        "MakeRange[" & $i & "]: expected " & $(5 + i)

  block echoPerson:
    let msg = await client.callComplex("EchoPerson",
      @[personValue("Ada", 36, 99.5)], @[personLibrary()])
    let r = returnValueOf(msg)
    doAssert r.kind == rvClass, "EchoPerson: expected class, got " & $r.kind
    let (name, age, score) = personFields(msg, r)
    echo "EchoPerson -> ", name, "/", age, "/", score
    doAssert name == "Ada" and age == 36 and score == 99.5

  block describePerson:
    let msg = await client.callComplex("DescribePerson",
      @[personValue("Bob", 25, 1.0)], @[personLibrary()])
    let r = returnValueOf(msg)
    doAssert r.kind == rvString, "DescribePerson: expected string, got " & $r.kind
    echo "DescribePerson -> ", r.stringVal.value
    doAssert r.stringVal.value == "Bob:25"

  block makePerson:
    let msg = await client.callComplex("MakePerson", @[stringRV("Carol"), int32RV(30)])
    let r = returnValueOf(msg)
    doAssert r.kind == rvClass, "MakePerson: expected class, got " & $r.kind
    let (name, age, score) = personFields(msg, r)
    echo "MakePerson -> ", name, "/", age, "/", score
    doAssert name == "Carol" and age == 30 and score == 15.0

  block echoPersonArray:
    let msg = await client.callComplex("EchoPersonArray",
      @[personArrayValue(@[personValue("Dan", 1, 0.5), personValue("Eve", 2, 1.5)])],
      @[personLibrary()])
    let r = returnValueOf(msg)
    doAssert r.kind == rvArray, "EchoPersonArray: expected array, got " & $r.kind
    let elems = resolvedElements(msg, r)
    echo "EchoPersonArray -> ", elems.len, " elements"
    doAssert elems.len == 2
    let (name0, age0, score0) = personFields(msg, elems[0])
    doAssert name0 == "Dan" and age0 == 1'i32 and score0 == 0.5
    let (name1, age1, score1) = personFields(msg, elems[1])
    doAssert name1 == "Eve" and age1 == 2'i32 and score1 == 1.5

  block makeTwins:
    # The server returns the same Person instance twice; the second array
    # element arrives as a MemberReference that must resolve to the first
    let msg = await client.callComplex("MakeTwins", @[stringRV("Gemini"), int32RV(9)])
    let r = returnValueOf(msg)
    doAssert r.kind == rvArray, "MakeTwins: expected array, got " & $r.kind
    let elems = resolvedElements(msg, r)
    echo "MakeTwins -> ", elems.len, " elements"
    doAssert elems.len == 2
    for i in 0..1:
      let (name, age, score) = personFields(msg, elems[i])
      doAssert name == "Gemini" and age == 9'i32 and score == 18.0,
        "MakeTwins[" & $i & "]: got " & name & "/" & $age & "/" & $score

  block echoPersonNull:
    let msg = await client.callComplex("EchoPerson", @[RemotingValue(kind: rvNull)])
    let r = returnValueOf(msg)
    echo "EchoPerson(null) -> ", r.kind
    doAssert r.kind == rvNull, "EchoPerson(null): expected null, got " & $r.kind

  block echoEmployee:
    let msg = await client.callComplex("EchoEmployee",
      @[employeeValue("Frank", addressValue("Main 5", "Brno"))], @[personLibrary()])
    let r = returnValueOf(msg)
    doAssert r.kind == rvClass, "EchoEmployee: expected class, got " & $r.kind
    let (name, street, city) = employeeFields(msg, r)
    echo "EchoEmployee -> ", name, "/", street, "/", city
    doAssert name == "Frank" and street == "Main 5" and city == "Brno"

  block describeEmployee:
    let msg = await client.callComplex("DescribeEmployee",
      @[employeeValue("Grace", addressValue("Side 9", "Praha"))], @[personLibrary()])
    let r = returnValueOf(msg)
    doAssert r.kind == rvString, "DescribeEmployee: expected string, got " & $r.kind
    echo "DescribeEmployee -> ", r.stringVal.value
    doAssert r.stringVal.value == "Grace@Praha"

  block throwError:
    # The server throws; the reply is a method return whose call array carries
    # the serialized exception object instead of a return value
    let msg = await client.callComplex("ThrowError", @[stringRV("boom from Nim")])
    doAssert msg.methodReturn.isSome, "ThrowError: expected a method return"
    let ret = msg.methodReturn.get
    doAssert MessageFlag.ExceptionInArray in ret.messageEnum,
      "ThrowError: expected ExceptionInArray flag, got " & $ret.messageEnum
    doAssert msg.methodCallArray.len == 1, "ThrowError: expected one exception record"
    let exc = resolveReference(msg, msg.methodCallArray[0])
    doAssert exc.kind == rvClass, "ThrowError: expected exception class, got " & $exc.kind
    echo "ThrowError -> ", classNameOf(exc)
    doAssert "Exception" in classNameOf(exc),
      "ThrowError: unexpected exception type " & classNameOf(exc)
    let msgVal = classMember(msg, exc, "Message")
    doAssert msgVal.kind == rvString and "boom from Nim" in msgVal.stringVal.value,
      "ThrowError: exception message mismatch"

  await client.close()
  echo "All Nim client calls passed."

waitFor main()
