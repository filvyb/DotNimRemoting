import ../../src/DotNimRemoting/tcp/[client]
import ../../src/DotNimRemoting/msnrbf/[helpers, enums, types]
import asyncdispatch, strutils

# Direction 1: Nim client -> .NET (Mono) server.
# Exercises every IEchoService method and verifies the typed return value,
# exiting non-zero on the first mismatch so the runner script reports failure.

proc main() {.async.} =
  let typename = "DotNimTester.Lib.IEchoService, Lib"
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

  await client.close()
  echo "All Nim client calls passed."

waitFor main()
