import unittest
import faststreams/inputs
import options
import DotNimRemoting/msnrbf/[enums, types, helpers, grammar, context]
import DotNimRemoting/msnrbf/records/[arrays, class, member, methodinv, serialization]

suite "MSNRBF Helpers":
  test "PrimitiveValue creation":
    # Test various primitive value creators
    let bv = boolValue(true)
    check(bv.kind == ptBoolean)
    check(bv.boolVal == true)
    
    let iv = int32Value(42)
    check(iv.kind == ptInt32)
    check(iv.int32Val == 42)
    
    let dv = doubleValue(3.14)
    check(dv.kind == ptDouble)
    check(dv.doubleVal == 3.14)
    
    let cv = charValue("A")
    check(cv.kind == ptChar)
    check(cv.charVal == "A")
    
    expect ValueError:
      discard charValue("AB") # Should fail - more than one character
    
    let tsv = timeSpanValue(10000000) # 1 second in ticks
    check(tsv.kind == ptTimeSpan)
    check(tsv.timeSpanVal == 10000000)
    
    let dtv = dateTimeValue(630822816000000000'i64) # Jan 1, 2000
    check(dtv.kind == ptDateTime)
    check(dtv.dateTimeVal.ticks == 630822816000000000'i64)
    check(dtv.dateTimeVal.kind == 0)
  
  test "ValueWithCode conversion":
    # Test conversion from PrimitiveValue to ValueWithCode
    let pv = int32Value(42)
    let vc: ValueWithCode = pv
    
    check(vc.primitiveType == ptInt32)
    check(vc.value.int32Val == 42)
    
    # Test StringValueWithCode
    let sv = newStringValueWithCode("test string")
    check(sv.primitiveType == ptString)
    check(sv.value.stringVal.value == "test string")
    
    # Test conversion from StringValueWithCode to ValueWithCode
    let vcFromString: ValueWithCode = sv
    check(vcFromString.primitiveType == ptString)
    check(vcFromString.value.stringVal.value == "test string")
  
  test "Method call creation":
    # Test simple method call with no args
    let call1 = methodCallBasic("TestMethod", "TestType.Server")
    check(call1.recordType == rtMethodCall)
    check(call1.methodName.value.stringVal.value == "TestMethod")
    check(call1.typeName.value.stringVal.value == "TestType.Server")
    check(MessageFlag.NoArgs in call1.messageEnum)
    check(MessageFlag.NoContext in call1.messageEnum)
    
    # Test method call with inline args
    let call2 = methodCallBasic("TestMethod", "TestType.Server", @[int32Value(1), boolValue(true)])
    check(call2.recordType == rtMethodCall)
    check(MessageFlag.ArgsInline in call2.messageEnum)
    check(MessageFlag.NoContext in call2.messageEnum)
    check(call2.args.len == 2)
    check(call2.args[0].value.int32Val == 1)
    check(call2.args[1].value.boolVal == true)
    
    # Test method call with array args
    let (call3, arr) = methodCallArrayArgs("TestMethod", "TestType.Server")
    check(call3.recordType == rtMethodCall)
    check(MessageFlag.ArgsInArray in call3.messageEnum)
    check(MessageFlag.NoContext in call3.messageEnum)
    check(arr.len == 0) # Empty array to be populated by caller
  
  test "Method return creation":
    # Test method return with no value
    let ret1 = methodReturnBasic()
    check(ret1.recordType == rtMethodReturn)
    check(MessageFlag.NoReturnValue in ret1.messageEnum)
    check(MessageFlag.NoContext in ret1.messageEnum)
    check(MessageFlag.NoArgs in ret1.messageEnum)
    
    # Test method return with inline value
    let ret2 = methodReturnBasic(int32Value(42))
    check(ret2.recordType == rtMethodReturn)
    check(MessageFlag.ReturnValueInline in ret2.messageEnum)
    check(ret2.returnValue.value.int32Val == 42)
    
    # Test void method return
    let ret3 = methodReturnVoid()
    check(ret3.recordType == rtMethodReturn)
    check(MessageFlag.ReturnValueVoid in ret3.messageEnum)
    
    # Test method return with array value
    let (ret4, arr) = methodReturnArrayValue()
    check(ret4.recordType == rtMethodReturn)
    check(MessageFlag.ReturnValueInArray in ret4.messageEnum)
    check(arr.len == 0) # Empty array to be populated by caller
    
    # Test exception return
    let exValue = toValueWithCode(newStringValueWithCode("Test exception"))
    let (ret5, arr5) = methodReturnException(exValue)
    check(ret5.recordType == rtMethodReturn)
    check(MessageFlag.ExceptionInArray in ret5.messageEnum)
    check(arr5.len == 1)
    check(arr5[0].value.stringVal.value == "Test exception")
  
  test "Complete message creation":
    # Test method call message
    let msg1 = createMethodCallMessage("TestMethod", "TestType.Server")
    check(msg1.methodCall.isSome)
    check(msg1.methodReturn.isNone)
    check(msg1.methodCall.get().methodName.value.stringVal.value == "TestMethod")
    check(msg1.header.recordType == rtSerializedStreamHeader)
    check(msg1.tail.recordType == rtMessageEnd)
    
    # Test method return message
    let msg2 = createMethodReturnMessage(int32Value(42))
    check(msg2.methodCall.isNone)
    check(msg2.methodReturn.isSome)
    check(msg2.methodReturn.get().returnValue.value.int32Val == 42)
    
    # Test void return message
    let msg3 = createMethodReturnVoidMessage()
    check(msg3.methodCall.isNone)
    check(msg3.methodReturn.isSome)
    check(MessageFlag.ReturnValueVoid in msg3.methodReturn.get().messageEnum)
  
  test "Serialization/Deserialization roundtrip":
    # Create a simple message
    let original = createMethodCallMessage("TestMethod", "TestType.Server", 
                                          @[int32Value(42), doubleValue(3.14)])
    
    # Serialize
    let bytes = serializeRemotingMessage(original)
    check(bytes.len > 0)
    
    # Deserialize
    let deserialized = deserializeRemotingMessage(bytes)
    
    # Check message structure
    check(deserialized.methodCall.isSome)
    check(deserialized.methodReturn.isNone)
    
    let originalCall = original.methodCall.get()
    let deserializedCall = deserialized.methodCall.get()
    
    # Check method details match
    check(deserializedCall.methodName.value.stringVal.value == originalCall.methodName.value.stringVal.value)
    check(deserializedCall.typeName.value.stringVal.value == originalCall.typeName.value.stringVal.value)
    
    # Check arguments match
    check(deserializedCall.args.len == 2)
    check(deserializedCall.args[0].value.int32Val == 42)
    check(deserializedCall.args[1].value.doubleVal == 3.14)

  test "Class construction helpers":
    let ctx = newSerializationContext()
    
    # Create member info
    let memberInfos = @[
      ("Street", btString, AdditionalTypeInfo(kind: btString)),
      ("City", btString, AdditionalTypeInfo(kind: btString)),
      ("State", btString, AdditionalTypeInfo(kind: btString)),
      ("Zip", btString, AdditionalTypeInfo(kind: btString))
    ]
    
    let cls = classWithMembersAndTypes(ctx, "TestNamespace.Address", 1, memberInfos)
    
    check(cls.recordType == rtClassWithMembersAndTypes)
    check(cls.classInfo.memberCount == 4)
    check(cls.classInfo.memberNames[0].value == "Street")
    check(cls.classInfo.memberNames[1].value == "City")
    check(cls.classInfo.memberNames[2].value == "State")
    check(cls.classInfo.memberNames[3].value == "Zip")
    
    check(cls.memberTypeInfo.binaryTypes.len == 4)
    check(cls.memberTypeInfo.binaryTypes[0] == btString)
    check(cls.classInfo.name.value == "TestNamespace.Address")

  test "Array construction helpers":
    let ctx = newSerializationContext()
    
    # Test single object array
    let objArray = arraySingleObject(ctx, 5)
    check(objArray.recordType == rtArraySingleObject)
    check(objArray.arrayInfo.length == 5)
    
    # Test single primitive array
    let primArray = arraySinglePrimitive(ctx, 10, ptInt32)
    check(primArray.recordType == rtArraySinglePrimitive)
    check(primArray.arrayInfo.length == 10)
    check(primArray.primitiveType == ptInt32)
    
    # Test single string array
    let strArray = arraySingleString(ctx, 3)
    check(strArray.recordType == rtArraySingleString)
    check(strArray.arrayInfo.length == 3)
    
    # Should throw when creating primitive array with invalid type
    expect ValueError:
      discard arraySinglePrimitive(ctx, 5, ptString)
    
    expect ValueError:
      discard arraySinglePrimitive(ctx, 5, ptNull)

  test "Object construction helpers":
    let ctx = newSerializationContext()
    
    # Test BinaryObjectString
    let str = binaryObjectString(ctx, "Test string")
    check(str.recordType == rtBinaryObjectString)
    check(str.value.value == "Test string")

  test "objectToClass helper":
    # Test converting a simple object
    type Person = object
      name: string
      age: int32
      height: float64
      isActive: bool
    
    let ctx = newSerializationContext()
    let person = Person(
      name: "John Doe",
      age: 30,
      height: 175.5,
      isActive: true
    )
    
    let remoteValue = ctx.objectToClass(person, "TestNamespace.Person", 1)
    
    # Verify it's a class RemotingValue
    check(remoteValue.kind == rvClass)
    
    # Verify the record type
    check(remoteValue.classVal.record.kind == rtClassWithMembersAndTypes)
    
    # Verify class name and library ID
    let classRecord = remoteValue.classVal.record.classWithMembersAndTypes
    check(classRecord.classInfo.name.value == "TestNamespace.Person")
    check(classRecord.libraryId == 1)
    
    # Verify member count
    check(classRecord.classInfo.memberCount == 4)
    check(remoteValue.classVal.members.len == 4)
    
    # Verify member names
    check(classRecord.classInfo.memberNames[0].value == "name")
    check(classRecord.classInfo.memberNames[1].value == "age")
    check(classRecord.classInfo.memberNames[2].value == "height")
    check(classRecord.classInfo.memberNames[3].value == "isActive")
    
    # Verify member types
    check(classRecord.memberTypeInfo.binaryTypes[0] == btString)
    check(classRecord.memberTypeInfo.binaryTypes[1] == btPrimitive)
    check(classRecord.memberTypeInfo.binaryTypes[2] == btPrimitive)
    check(classRecord.memberTypeInfo.binaryTypes[3] == btPrimitive)
    
    # Verify additional info for primitives
    check(classRecord.memberTypeInfo.additionalInfos[1].primitiveType == ptInt32)
    check(classRecord.memberTypeInfo.additionalInfos[2].primitiveType == ptDouble)
    check(classRecord.memberTypeInfo.additionalInfos[3].primitiveType == ptBoolean)
    
    # Verify member values
    check(remoteValue.classVal.members[0].kind == rvString)
    check(remoteValue.classVal.members[0].stringVal.value == "John Doe")
    
    check(remoteValue.classVal.members[1].kind == rvPrimitive)
    check(remoteValue.classVal.members[1].primitiveVal.int32Val == 30)
    
    check(remoteValue.classVal.members[2].kind == rvPrimitive)
    check(remoteValue.classVal.members[2].primitiveVal.doubleVal == 175.5)
    
    check(remoteValue.classVal.members[3].kind == rvPrimitive)
    check(remoteValue.classVal.members[3].primitiveVal.boolVal == true)
    
  test "objectToClass with default namespace and library ID":
    # Test objectToClass with default namespace and library ID
    let ctx = newSerializationContext()
    type MyCustomType = object
      value: int32
    
    let obj = MyCustomType(value: 42)
    let rv = ctx.objectToClass(obj)
    
    let cr = rv.classVal.record.classWithMembersAndTypes
    check(cr.classInfo.name.value == "MyCustomType")
    check(cr.libraryId == 0)  # Default library ID
    check(cr.classInfo.memberCount == 1)
    check(cr.classInfo.memberNames[0].value == "value")
    check(cr.memberTypeInfo.binaryTypes[0] == btPrimitive)
    check(cr.memberTypeInfo.additionalInfos[0].primitiveType == ptInt32)

  test "objectToClass with various numeric types":
    # Test objectToClass with various numeric types
    let ctx = newSerializationContext()
    type Numbers = object
      i8: int8
      u8: uint8
      i16: int16
      u16: uint16
      i32: int32
      u32: uint32
      i64: int64
      u64: uint64
      f32: float32
      f64: float64
    
    let numbers = Numbers(
      i8: -128,
      u8: 255,
      i16: -32768,
      u16: 65535,
      i32: -2147483648,
      u32: 4294967295'u32,
      i64: 9223372036854775807,
      u64: 18446744073709551615'u64,
      f32: 3.14159'f32,
      f64: 2.718281828
    )
    
    let rvNum = ctx.objectToClass(numbers, "Numbers", 2)
    
    # Verify member count
    check(rvNum.classVal.members.len == 10)
    
    # Verify all are primitive values
    for member in rvNum.classVal.members:
      check(member.kind == rvPrimitive)
