import strutils, math
import ../../src/DotNimRemoting
import interop

# Direction 1: Nim client -> .NET (Mono) server. Exercises every IEchoService
# method, exiting non-zero on the first mismatch. The first blocks use the
# lower-level callMethod API to keep it covered; the rest use call.

const typename = "DotNimTester.Lib.IEchoService, Lib"

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
    let r = await client.call("Echo", typename, "")
    echo "Echo(\"\") -> ", r.getString
    doAssert r.getString == ""

  block echoUnicode:
    # Multi-byte UTF-8 chars plus an astral-plane emoji (surrogate pair in UTF-16)
    let unicode = "Příliš žluťoučký kůň 🐎"
    let r = await client.call("Echo", typename, unicode)
    echo "Echo(unicode) -> ", r.getString
    doAssert r.getString == unicode

  block echoLong:
    # Long enough that the length prefix needs multiple 7-bit-encoded bytes
    let longStr = repeat('x', 20000)
    let r = await client.call("Echo", typename, longStr)
    echo "Echo(20000 chars) -> ", r.getString.len, " chars"
    doAssert r.getString == longStr

  block echoDecimal:
    let r = await client.call("EchoDecimal", typename, decimalValue("123.45"))
    echo "EchoDecimal -> ", r.getDecimal
    doAssert r.getDecimal == "123.45"

  block echoDecimalNegative:
    let r = await client.call("EchoDecimal", typename, decimalValue("-0.001"))
    echo "EchoDecimal(-0.001) -> ", r.getDecimal
    doAssert r.getDecimal == "-0.001"

  block echoDateTime:
    # 2021-03-19 ticks, kind 1 = UTC; both must survive the round-trip
    let ticks = 637_500_000_000_000_000'i64
    let r = await client.call("EchoDateTime", typename, dateTimeValue(ticks, 1))
    echo "EchoDateTime -> ticks ", r.getDateTime.ticks, " kind ", r.getDateTime.kind
    doAssert r.getDateTime.ticks == ticks
    doAssert r.getDateTime.kind == 1

  block echoTimeSpan:
    let r = await client.call("EchoTimeSpan", typename, timeSpanValue(123_456_789'i64))
    echo "EchoTimeSpan -> ", r.getTimeSpan
    doAssert r.getTimeSpan == 123_456_789'i64

  block multiplyFloat:
    let r = await client.call("MultiplyFloat", typename, 2.5'f32, 4.0'f32)
    echo "MultiplyFloat -> ", r.getSingle
    doAssert r.getSingle == 10.0'f32

  block echoChar:
    # Two-byte UTF-8 character
    let r = await client.call("EchoChar", typename, charValue("Ω"))
    echo "EchoChar -> ", r.getChar
    doAssert r.getChar == "Ω"

  block incrementByte:
    let r = await client.call("IncrementByte", typename, 41'u8)
    echo "IncrementByte -> ", r.getByte
    doAssert r.getByte == 42'u8

  block negateSByte:
    let r = await client.call("NegateSByte", typename, -42'i8)
    echo "NegateSByte -> ", r.getSByte
    doAssert r.getSByte == 42'i8

  block negateShort:
    let r = await client.call("NegateShort", typename, 12345'i16)
    echo "NegateShort -> ", r.getInt16
    doAssert r.getInt16 == -12345'i16

  block echoUInt16:
    let r = await client.call("EchoUInt16", typename, high(uint16))
    echo "EchoUInt16 -> ", r.getUInt16
    doAssert r.getUInt16 == high(uint16)

  block echoUInt32:
    let r = await client.call("EchoUInt32", typename, high(uint32))
    echo "EchoUInt32 -> ", r.getUInt32
    doAssert r.getUInt32 == high(uint32)

  block echoUInt64:
    let r = await client.call("EchoUInt64", typename, high(uint64))
    echo "EchoUInt64 -> ", r.getUInt64
    doAssert r.getUInt64 == high(uint64)

  block ping:
    let r = await client.call("Ping", typename)
    echo "Ping -> ", r.kind
    doAssert r.isNull, "Ping: expected null (void), got " & $r.kind

  block echoDoubleNaN:
    let r = await client.call("EchoDouble", typename, NaN)
    echo "EchoDouble(NaN) -> ", r.getDouble
    doAssert r.getDouble.isNaN, "EchoDouble(NaN): expected NaN, got " & $r.getDouble

  block echoDoubleInf:
    let r = await client.call("EchoDouble", typename, Inf)
    echo "EchoDouble(+Inf) -> ", r.getDouble
    doAssert r.getDouble == Inf

  block echoDoubleNegInf:
    let r = await client.call("EchoDouble", typename, -Inf)
    echo "EchoDouble(-Inf) -> ", r.getDouble
    doAssert r.getDouble == -Inf

  block echoIntArray:
    let sent = @[1'i32, 2, 3, -4]
    let r = await client.call("EchoIntArray", typename, sent)
    doAssert r.kind == rvArray, "EchoIntArray: expected array, got " & $r.kind
    echo "EchoIntArray -> ", r.len, " elements"
    doAssert r.len == sent.len
    for i, v in sent:
      doAssert r[i].getInt32 == v,
        "EchoIntArray[" & $i & "]: expected " & $v & ", got " & $r[i].getInt32

  block echoIntArrayEmpty:
    let r = await client.call("EchoIntArray", typename, newSeq[int32]())
    doAssert r.kind == rvArray, "EchoIntArray(empty): expected array, got " & $r.kind
    echo "EchoIntArray(empty) -> ", r.len, " elements"
    doAssert r.len == 0

  block echoDoubleArray:
    let sent = @[1.5'f64, -2.25, 0.0]
    let r = await client.call("EchoDoubleArray", typename, sent)
    doAssert r.kind == rvArray, "EchoDoubleArray: expected array, got " & $r.kind
    echo "EchoDoubleArray -> ", r.len, " elements"
    doAssert r.len == sent.len
    for i, v in sent:
      doAssert r[i].getDouble == v, "EchoDoubleArray[" & $i & "]: expected " & $v

  block echoByteArray:
    let sent = @[0'u8, 1, 127, 128, 255]
    let r = await client.call("EchoByteArray", typename, sent)
    doAssert r.kind == rvArray, "EchoByteArray: expected array, got " & $r.kind
    echo "EchoByteArray -> ", r.len, " elements"
    doAssert r.len == sent.len
    for i, v in sent:
      doAssert r[i].getByte == v,
        "EchoByteArray[" & $i & "]: expected " & $v & ", got " & $r[i].getByte

  block sumIntArray:
    let r = await client.call("SumIntArray", typename, @[1'i32, 2, 3, 4, 5])
    echo "SumIntArray -> ", r.getInt32
    doAssert r.getInt32 == 15

  block echoStringArray:
    let sent = @[some("alpha"), none(string), some("gamma")]
    let r = await client.call("EchoStringArray", typename, sent)
    doAssert r.kind == rvArray, "EchoStringArray: expected array, got " & $r.kind
    echo "EchoStringArray -> ", r.len, " elements"
    doAssert r.len == sent.len
    for i, v in sent:
      if v.isSome:
        doAssert r[i].getString == v.get, "EchoStringArray[" & $i & "]: expected " & v.get
      else:
        doAssert r[i].isNull, "EchoStringArray[" & $i & "]: expected null"

  block echoStringArrayNullRun:
    # Consecutive nulls travel as ObjectNullMultiple256 records
    let sent = @[some("x"), none(string), none(string), none(string),
                 some("y"), none(string), none(string)]
    let r = await client.call("EchoStringArray", typename, sent)
    doAssert r.kind == rvArray, "EchoStringArray(null run): expected array, got " & $r.kind
    echo "EchoStringArray(null run) -> ", r.len, " elements"
    doAssert r.len == sent.len
    for i, v in sent:
      if v.isSome:
        doAssert r[i].getString == v.get,
          "EchoStringArray(null run)[" & $i & "]: expected " & v.get
      else:
        doAssert r[i].isNull, "EchoStringArray(null run)[" & $i & "]: expected null"

  block makeNulls:
    # 300 nulls force the 32-bit ObjectNullMultiple record
    let r = await client.call("MakeNulls", typename, 300)
    doAssert r.kind == rvArray, "MakeNulls: expected array, got " & $r.kind
    echo "MakeNulls(300) -> ", r.len, " elements"
    doAssert r.len == 300
    for i, elem in r.elements:
      doAssert elem.isNull, "MakeNulls[" & $i & "]: expected null, got " & $elem.kind

  block joinStrings:
    let r = await client.call("JoinStrings", typename,
      @[some("a"), some("b"), some("c")], "-")
    echo "JoinStrings -> ", r.getString
    doAssert r.getString == "a-b-c"

  block makeRange:
    let r = await client.call("MakeRange", typename, 5, 4)
    doAssert r.kind == rvArray, "MakeRange: expected array, got " & $r.kind
    echo "MakeRange -> ", r.len, " elements"
    doAssert r.len == 4
    for i in 0..<4:
      doAssert r[i].getInt32 == int32(5 + i), "MakeRange[" & $i & "]: expected " & $(5 + i)

  block echoPerson:
    let sent = Person(Name: "Ada", Age: 36, Score: 99.5)
    let r = await client.call("EchoPerson", typename,
      @[toRemotingValue(sent)], @[personLibrary()])
    doAssert r.kind == rvClass, "EchoPerson: expected class, got " & $r.kind
    let p = classToObject[Person](r)
    echo "EchoPerson -> ", p.Name, "/", p.Age, "/", p.Score
    doAssert p == sent

  block describePerson:
    let r = await client.call("DescribePerson", typename,
      @[toRemotingValue(Person(Name: "Bob", Age: 25, Score: 1.0))], @[personLibrary()])
    echo "DescribePerson -> ", r.getString
    doAssert r.getString == "Bob:25"

  block makePerson:
    let r = await client.call("MakePerson", typename, "Carol", 30)
    doAssert r.kind == rvClass, "MakePerson: expected class, got " & $r.kind
    let p = classToObject[Person](r)
    echo "MakePerson -> ", p.Name, "/", p.Age, "/", p.Score
    doAssert p == Person(Name: "Carol", Age: 30, Score: 15.0)

  block echoPersonArray:
    let dan = Person(Name: "Dan", Age: 1, Score: 0.5)
    let eve = Person(Name: "Eve", Age: 2, Score: 1.5)
    let r = await client.call("EchoPersonArray", typename,
      @[personArrayValue(@[toRemotingValue(dan), toRemotingValue(eve)])],
      @[personLibrary()])
    doAssert r.kind == rvArray, "EchoPersonArray: expected array, got " & $r.kind
    echo "EchoPersonArray -> ", r.len, " elements"
    doAssert r.len == 2
    doAssert classToObject[Person](r[0]) == dan
    doAssert classToObject[Person](r[1]) == eve

  block makeTwins:
    # The server returns the same Person twice; the second array element
    # arrives as a MemberReference
    let r = await client.call("MakeTwins", typename, "Gemini", 9)
    doAssert r.kind == rvArray, "MakeTwins: expected array, got " & $r.kind
    echo "MakeTwins -> ", r.len, " elements"
    doAssert r.len == 2
    for i in 0..1:
      let p = classToObject[Person](r[i])
      doAssert p == Person(Name: "Gemini", Age: 9, Score: 18.0),
        "MakeTwins[" & $i & "]: got " & p.Name & "/" & $p.Age & "/" & $p.Score

  block echoPersonNull:
    let r = await client.call("EchoPerson", typename, @[nullValue()])
    echo "EchoPerson(null) -> ", r.kind
    doAssert r.isNull, "EchoPerson(null): expected null, got " & $r.kind

  block echoEmployee:
    let sent = Employee(Name: "Frank", Home: Address(Street: "Main 5", City: "Brno"))
    let r = await client.call("EchoEmployee", typename,
      @[toRemotingValue(sent)], @[personLibrary()])
    doAssert r.kind == rvClass, "EchoEmployee: expected class, got " & $r.kind
    let e = classToObject[Employee](r)
    echo "EchoEmployee -> ", e.Name, "/", e.Home.Street, "/", e.Home.City
    doAssert e == sent

  block describeEmployee:
    let grace = Employee(Name: "Grace", Home: Address(Street: "Side 9", City: "Praha"))
    let r = await client.call("DescribeEmployee", typename,
      @[toRemotingValue(grace)], @[personLibrary()])
    echo "DescribeEmployee -> ", r.getString
    doAssert r.getString == "Grace@Praha"

  block homesShared:
    # Diamond graph: array -> two Employees -> one shared Address value. The
    # writer must emit the Address once plus a MemberReference, and .NET must
    # answer ReferenceEquals = true on the materialized graph
    let home = toRemotingValue(Address(Street: "Diamond 7", City: "Ostrava"))
    let r = await client.call("HomesShared", typename,
      @[employeeArrayValue(@[employeeValue("Hana", home), employeeValue("Ivan", home)])],
      @[personLibrary()])
    echo "HomesShared(diamond) -> ", r.getBool
    doAssert r.getBool == true, "HomesShared(diamond): expected shared instance"

  block homesSharedDistinct:
    # Control: equal-valued but distinct Address values must stay two objects
    let r = await client.call("HomesShared", typename,
      @[employeeArrayValue(@[
        employeeValue("Hana", toRemotingValue(Address(Street: "Diamond 7", City: "Ostrava"))),
        employeeValue("Ivan", toRemotingValue(Address(Street: "Diamond 7", City: "Ostrava")))])],
      @[personLibrary()])
    echo "HomesShared(distinct) -> ", r.getBool
    doAssert r.getBool == false, "HomesShared(distinct): expected distinct instances"

  block makeCoworkers:
    # The server returns the diamond: the second Home arrives as a
    # MemberReference and must resolve to the same instance
    let r = await client.call("MakeCoworkers", typename, "Jana", "Karel", "Plzen")
    doAssert r.kind == rvArray, "MakeCoworkers: expected array, got " & $r.kind
    doAssert r.len == 2
    let e0 = classToObject[Employee](r[0])
    let e1 = classToObject[Employee](r[1])
    echo "MakeCoworkers -> ", e0.Name, "&", e1.Name, "@", e0.Home.City
    doAssert e0 == Employee(Name: "Jana", Home: Address(Street: "Shared 1", City: "Plzen"))
    doAssert e1 == Employee(Name: "Karel", Home: Address(Street: "Shared 1", City: "Plzen"))
    doAssert getMember(r[0], "Home", EmployeeLayout) == getMember(r[1], "Home", EmployeeLayout),
      "MakeCoworkers: expected both Home members to resolve to one instance"

  block echoObjectInt:
    # object-typed parameter: the value is typed by its runtime type on the
    # wire, so a boxed Int32 must round-trip through .NET's object handling
    let r = await client.call("EchoObject", typename, 42)
    echo "EchoObject(int) -> ", r.getInt32
    doAssert r.getInt32 == 42

  block echoObjectString:
    let r = await client.call("EchoObject", typename, "boxed")
    echo "EchoObject(string) -> ", r.getString
    doAssert r.getString == "boxed"

  block echoObjectNull:
    let r = await client.call("EchoObject", typename, @[nullValue()])
    echo "EchoObject(null) -> ", r.kind
    doAssert r.isNull, "EchoObject(null): expected null, got " & $r.kind

  block echoObjectPerson:
    let sent = Person(Name: "Olga", Age: 5, Score: 7.5)
    let r = await client.call("EchoObject", typename,
      @[toRemotingValue(sent)], @[personLibrary()])
    doAssert r.kind == rvClass, "EchoObject(Person): expected class, got " & $r.kind
    let p = classToObject[Person](r)
    echo "EchoObject(Person) -> ", p.Name, "/", p.Age, "/", p.Score
    doAssert p == sent

  block echoObjectArray:
    # Heterogeneous object[]: ArraySingleObject on the wire; boxed primitives
    # travel as MemberPrimitiveTyped records alongside string, null and class
    # elements
    let pia = Person(Name: "Pia", Age: 6, Score: 8.5)
    let sent = objectArrayValue(@[
      toRemotingValue(42'i32), toRemotingValue("text"), nullValue(),
      toRemotingValue(2.5'f64), toRemotingValue(true), toRemotingValue(pia)])
    let r = await client.call("EchoObjectArray", typename, @[sent], @[personLibrary()])
    doAssert r.kind == rvArray, "EchoObjectArray: expected array, got " & $r.kind
    echo "EchoObjectArray -> ", r.len, " elements"
    doAssert r.len == 6
    doAssert r[0].getInt32 == 42, "EchoObjectArray[0]: expected 42"
    doAssert r[1].getString == "text", "EchoObjectArray[1]: expected \"text\""
    doAssert r[2].isNull, "EchoObjectArray[2]: expected null, got " & $r[2].kind
    doAssert r[3].getDouble == 2.5, "EchoObjectArray[3]: expected 2.5"
    doAssert r[4].getBool == true, "EchoObjectArray[4]: expected true"
    doAssert classToObject[Person](r[5]) == pia,
      "EchoObjectArray[5]: Person mismatch"

  block fireAndForget:
    # One-way call: OneWayRequest operation type and no reply frame; the same
    # connection must stay usable for the next two-way call. .NET dispatches
    # one-way calls asynchronously, so poll for the side effect.
    await client.callOneWay("FireAndForget", typename, "one-way from Nim")
    var last = ""
    for attempt in 0..<50:
      let r = await client.call("GetLastOneWayMessage", typename)
      last = r.getString
      if last == "one-way from Nim":
        break
      await sleepAsync(100)
    echo "FireAndForget(one-way) -> ", last
    doAssert last == "one-way from Nim", "FireAndForget: expected message, got \"" & last & "\""

  block throwError:
    # The server throws; call surfaces the serialized exception as RemoteException
    var caught = false
    try:
      discard await client.call("ThrowError", typename, "boom from Nim")
    except RemoteException as e:
      caught = true
      echo "ThrowError -> ", e.className, ": ", e.msg
      doAssert "Exception" in e.className,
        "ThrowError: unexpected exception type " & e.className
      doAssert "boom from Nim" in e.msg, "ThrowError: exception message mismatch"
    doAssert caught, "ThrowError: expected RemoteException"

  await client.close()
  echo "All Nim client calls passed."

waitFor main()
