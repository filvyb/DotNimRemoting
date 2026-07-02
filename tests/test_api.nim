import unittest
import std/[sets, strutils]
import DotNimRemoting
import DotNimRemoting/msnrbf/context

# High-level API tests; everything round-trips through real serialized bytes.

suite "RemotingValue construction and inspection":
  test "primitive and string conversion":
    check toRemotingValue(true).getBool == true
    check toRemotingValue(42'i8).getSByte == 42'i8
    check toRemotingValue(42'u8).getByte == 42'u8
    check toRemotingValue(-1234'i16).getInt16 == -1234'i16
    check toRemotingValue(1234'u16).getUInt16 == 1234'u16
    check toRemotingValue(42'i32).getInt32 == 42'i32
    check toRemotingValue(42'u32).getUInt32 == 42'u32
    check toRemotingValue(high(int64)).getInt64 == high(int64)
    check toRemotingValue(high(uint64)).getUInt64 == high(uint64)
    check toRemotingValue(2.5'f32).getSingle == 2.5'f32
    check toRemotingValue(2.5'f64).getDouble == 2.5
    check toRemotingValue("hello").getString == "hello"
    check toRemotingValue("hello").kind == rvString

  test "plain int maps to Int32 with range check":
    check toRemotingValue(42).getInt32 == 42'i32
    expect ValueError:
      discard toRemotingValue(int(high(int32)) + 1)

  test "PrimitiveValue conversion mirrors parsed shapes":
    check toRemotingValue(stringValue("x")).kind == rvString
    check toRemotingValue(PrimitiveValue(kind: ptNull)).kind == rvNull
    check toRemotingValue(int32Value(7)).kind == rvPrimitive

  test "kind mismatches raise ValueError with both kinds named":
    expect ValueError:
      discard toRemotingValue("text").getInt32
    expect ValueError:
      discard toRemotingValue(1'i32).getInt64

  test "primitive seq becomes a primitive array":
    let arr = toRemotingValue(@[1'i32, 2, 3])
    check arr.kind == rvArray
    check arr.len == 3
    check arr[1].getInt32 == 2
    check arr.arrayVal.record.kind == rtArraySinglePrimitive
    check arr.arrayVal.record.arraySinglePrimitive.primitiveType == ptInt32

  test "string seq becomes a string array, options map to nulls":
    let arr = toRemotingValue(@[some("a"), none(string)])
    check arr.kind == rvArray
    check arr.arrayVal.record.kind == rtArraySingleString
    check arr[0].getString == "a"
    check arr[1].isNull

  test "classValue derives member metadata":
    let person = classValue("Ns.Person", 100, {
      "Name": toRemotingValue("Ada"),
      "Age": toRemotingValue(36'i32),
    })
    check person.kind == rvClass
    check person.className == "Ns.Person"
    check person.libraryIdOf == 100
    check person.memberNames == @["Name", "Age"]
    check person["Name"].getString == "Ada"
    check person.getMember("Age").getInt32 == 36'i32
    expect KeyError:
      discard person["Missing"]

  test "objectToClass and classToObject round-trip":
    type Person = object
      Name: string
      Age: int32
      Score: float64
    let original = Person(Name: "Ada", Age: 36, Score: 99.5)
    let rv = objectToClass(original, "Ns.Person", 100)
    check rv.className == "Ns.Person"
    check rv["Age"].getInt32 == 36'i32
    let lib = binaryLibrary("Asm", 100)
    let data = createMethodReturnResponse(rv, libraries = @[lib])
    let back = returnValueOf(deserializeRemotingMessage(data))
    check classToObject[Person](back) == original

  test "collectLibraryIds walks nested values":
    let employee = classValue("Ns.Employee", 100, {
      "Home": classValue("Ns.Address", 100, {"City": toRemotingValue("Brno")}),
    })
    check 100'i32 in collectLibraryIds(employee)
    let arr = classArrayValue("Ns.Person", 200, @[])
    check 200'i32 in collectLibraryIds(arr)

suite "Wire layout and round trips":
  test "primitive args travel inline":
    let data = createMethodCallRequest("Add", "Ns.ISvc", @[
      toRemotingValue(40'i32), toRemotingValue("x")])
    let msg = deserializeRemotingMessage(data)
    check msg.methodNameOf == "Add"
    check "Version=" in msg.typeNameOf
    check MessageFlag.ArgsInline in msg.methodCall.get.messageEnum
    let args = callArgs(msg)
    check args.len == 2
    check args[0].getInt32 == 40'i32
    check args[1].getString == "x"

  test "already qualified type names are not double-qualified":
    let data = createMethodCallRequest("M", "Ns.ISvc, Asm, Version=2.0.0.0", @[])
    let msg = deserializeRemotingMessage(data)
    check msg.typeNameOf == "Ns.ISvc, Asm, Version=2.0.0.0"

  test "complex args move the argument list into the call array":
    let lib = binaryLibrary("Asm, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null", 100)
    let person = classValue("Ns.Person", 100, {"Name": toRemotingValue("Ada")})
    let data = createMethodCallRequest("Describe", "Ns.ISvc",
      @[person, toRemotingValue(1'i32)], libraries = @[lib])
    let msg = deserializeRemotingMessage(data)
    check MessageFlag.ArgsIsArray in msg.methodCall.get.messageEnum
    let args = callArgs(msg)
    check args.len == 2
    check args[0].className == "Ns.Person"
    check args[0]["Name"].getString == "Ada"
    check args[1].getInt32 == 1'i32

  test "missing library raises before anything is sent":
    let person = classValue("Ns.Person", 100, {"Name": toRemotingValue("Ada")})
    expect ValueError:
      discard createMethodCallRequest("Describe", "Ns.ISvc", @[person])

  test "unreferenced libraries are dropped":
    let lib = binaryLibrary("Asm", 100)
    let data = createMethodCallRequest("Add", "Ns.ISvc",
      @[toRemotingValue(1'i32)], libraries = @[lib])
    let msg = deserializeRemotingMessage(data)
    check msg.libraries.len == 0

  test "null return value means no return value":
    let msg = deserializeRemotingMessage(createMethodReturnResponse(nullValue()))
    check MessageFlag.NoReturnValue in msg.methodReturn.get.messageEnum
    check returnValueOf(msg).isNull

  test "string return travels inline":
    let msg = deserializeRemotingMessage(createMethodReturnResponse(toRemotingValue("ok")))
    check MessageFlag.ReturnValueInline in msg.methodReturn.get.messageEnum
    check returnValueOf(msg).getString == "ok"

  test "array return goes through the call array":
    let data = createMethodReturnResponse(toRemotingValue(@[1.5'f64, -2.0]))
    let msg = deserializeRemotingMessage(data)
    check MessageFlag.ReturnValueInArray in msg.methodReturn.get.messageEnum
    let r = returnValueOf(msg)
    check r.kind == rvArray
    check r[0].getDouble == 1.5
    check r[1].getDouble == -2.0

  test "shared values come back as resolved references":
    # The writer emits a MemberReference for the second element
    let lib = binaryLibrary("Asm", 100)
    let p = classValue("Ns.Person", 100, {"Name": toRemotingValue("Gemini")})
    let data = createMethodReturnResponse(
      classArrayValue("Ns.Person", 100, @[p, p]), libraries = @[lib])
    let msg = deserializeRemotingMessage(data)
    let r = returnValueOf(msg)
    check r.len == 2
    check r[0].kind == rvClass
    check r[1].kind == rvClass
    check r[1]["Name"].getString == "Gemini"

suite "Remote exceptions":
  test "exception responses raise RemoteException":
    # Build a return message carrying a serialized exception the way .NET does
    let exc = systemClassValue("System.Exception", {
      "Message": toRemotingValue("boom"),
    })
    let ret = BinaryMethodReturn(
      recordType: rtMethodReturn,
      messageEnum: {MessageFlag.NoContext, MessageFlag.ExceptionInArray})
    let ctx = newSerializationContext()
    let msg = newRemotingMessage(ctx, methodReturn = some(ret), callArray = @[exc])
    let parsed = deserializeRemotingMessage(serializeRemotingMessage(msg, ctx))
    try:
      discard returnValueOf(parsed)
      check false
    except RemoteException as e:
      check e.className == "System.Exception"
      check e.msg == "boom"
