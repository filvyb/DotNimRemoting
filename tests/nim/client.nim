import ../../src/DotNimRemoting/tcp/[client]
import ../../src/DotNimRemoting/msnrbf/[helpers, enums, types]
import asyncdispatch

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

  await client.close()
  echo "All Nim client calls passed."

waitFor main()
