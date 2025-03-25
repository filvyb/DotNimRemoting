import unittest
import DotNimRemoting/msnrbf/[grammar, helpers]
import DotNimRemoting/msnrbf/[enums, types, context]
import DotNimRemoting/msnrbf/records/[methodinv, member]
import options

suite "RemotingMessage serialization and deserialization":
  test "simple method call with no arguments":
    let methodName = newStringValueWithCode("Ping")
    let typeName = newStringValueWithCode("MyServer")
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {NoArgs, NoContext},
      methodName: methodName,
      typeName: typeName
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall))
    msg.header.rootId = 0
    msg.header.headerId = 0
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x15, 0x11, 0x00, 0x00, 0x00, 0x12, 0x04, 0x50, 0x69, 0x6E, 0x67, 0x12, 0x08, 0x4D, 0x79, 0x53, 0x65, 0x72, 0x76, 0x65, 0x72,
      0x0B
    ]
    check serialized == expected
    let deserialized = deserializeRemotingMessage(expected)
    check deserialized.header.recordType == rtSerializedStreamHeader
    check deserialized.header.rootId == 0
    check deserialized.header.headerId == 0
    check deserialized.header.majorVersion == 1
    check deserialized.header.minorVersion == 0
    check deserialized.methodCall.isSome
    check deserialized.methodReturn.isNone
    let methodCall = deserialized.methodCall.get()
    check methodCall.recordType == rtMethodCall
    check methodCall.messageEnum == {NoArgs, NoContext}
    check methodCall.methodName.value.stringVal.value == "Ping"
    check methodCall.typeName.value.stringVal.value == "MyServer"
    check methodCall.args.len == 0
    check methodCall.callContext.primitiveType == PrimitiveType(0)
    check deserialized.methodCallArray.len == 0
    check deserialized.referencedRecords.len == 0
    check deserialized.tail.recordType == rtMessageEnd

  test "method call with inline primitive arguments":
    let methodName = newStringValueWithCode("Add")
    let typeName = newStringValueWithCode("MathService")
    let arg1 = ValueWithCode(primitiveType: ptInt32, value: int32Value(3))
    let arg2 = ValueWithCode(primitiveType: ptInt32, value: int32Value(5))
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {ArgsInline, NoContext},
      methodName: methodName,
      typeName: typeName,
      args: @[arg1, arg2]
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall))
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x15, 0x12, 0x00, 0x00, 0x00, 0x12, 0x03, 0x41, 0x64, 0x64, 0x12, 0x0B, 0x4D, 0x61, 0x74, 0x68, 0x53, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65,
      0x02, 0x00, 0x00, 0x00, 0x08, 0x03, 0x00, 0x00, 0x00, 0x08, 0x05, 0x00, 0x00, 0x00,
      0x0B
    ]
    check serialized == expected
    let deserialized = deserializeRemotingMessage(expected)
    check deserialized.header.rootId == 0
    check deserialized.header.headerId == 0
    check deserialized.methodCall.isSome
    let methodCall = deserialized.methodCall.get()
    check methodCall.messageEnum == {ArgsInline, NoContext}
    check methodCall.methodName.value.stringVal.value == "Add"
    check methodCall.typeName.value.stringVal.value == "MathService"
    check methodCall.args.len == 2
    check methodCall.args[0].primitiveType == ptInt32
    check methodCall.args[0].value.int32Val == 3
    check methodCall.args[1].primitiveType == ptInt32
    check methodCall.args[1].value.int32Val == 5
    check deserialized.tail.recordType == rtMessageEnd

  test "method call with arguments in separate call array":
    let methodName = newStringValueWithCode("Foo")
    let typeName = newStringValueWithCode("Bar")
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {ArgsInArray, NoContext},
      methodName: methodName,
      typeName: typeName
    )
    let value = RemotingValue(
      kind: rvPrimitive,
      primitiveVal: PrimitiveValue(kind: ptInt32, int32Val: 10)
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall), callArray = @[value])
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x15, 0x18, 0x00, 0x00, 0x00, 0x12, 0x03, 0x46, 0x6F, 0x6F, 0x12, 0x03, 0x42, 0x61, 0x72,
      0x10, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
      0x08, 0x08, 0x0A, 0x00, 0x00, 0x00,
      0x0B
    ]
    check serialized.len == expected.len
    check serialized == expected
    let deserialized = deserializeRemotingMessage(serialized)
    check deserialized.header.rootId == 1
    check deserialized.header.headerId == -1
    check deserialized.methodCall.isSome
    let methodCall = deserialized.methodCall.get()
    check methodCall.messageEnum == {ArgsInArray, NoContext}
    check methodCall.methodName.value.stringVal.value == "Foo"
    check methodCall.typeName.value.stringVal.value == "Bar"
    check methodCall.args.len == 0
    check deserialized.methodCallArray.len == 1
    check deserialized.methodCallArray[0].kind == rvPrimitive
    check deserialized.methodCallArray[0].primitiveVal.kind == ptInt32
    check deserialized.methodCallArray[0].primitiveVal.int32Val == 10
    check deserialized.tail.recordType == rtMessageEnd

  test "method return with inline primitive return value":
    let returnValue = ValueWithCode(primitiveType: ptInt32, value: int32Value(8))
    let binaryMethodReturn = BinaryMethodReturn(
      recordType: rtMethodReturn,
      messageEnum: {NoArgs, NoContext, ReturnValueInline},
      returnValue: returnValue
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodReturn = some(binaryMethodReturn))
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x16, 0x11, 0x08, 0x00, 0x00, 0x08, 0x08, 0x00, 0x00, 0x00,
      0x0B
    ]
    check serialized == expected
    let deserialized = deserializeRemotingMessage(expected)
    check deserialized.header.rootId == 0
    check deserialized.header.headerId == 0
    check deserialized.methodReturn.isSome
    let methodReturn = deserialized.methodReturn.get()
    check methodReturn.messageEnum == {NoArgs, NoContext, ReturnValueInline}
    check methodReturn.returnValue.primitiveType == ptInt32
    check methodReturn.returnValue.value.int32Val == 8
    check deserialized.tail.recordType == rtMessageEnd

  test "method return with return value in separate call array":
    let binaryMethodReturn = BinaryMethodReturn(
      recordType: rtMethodReturn,
      messageEnum: {NoArgs, NoContext, ReturnValueInArray}
    )
    let value = RemotingValue(
      kind: rvPrimitive,
      primitiveVal: PrimitiveValue(kind: ptInt32, int32Val: 42)
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodReturn = some(binaryMethodReturn), callArray = @[value])
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x16, 0x11, 0x10, 0x00, 0x00,
      0x10, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
      0x08, 0x08, 0x2A, 0x00, 0x00, 0x00,
      0x0B
    ]
    check serialized.len == expected.len
    check serialized == expected
    let deserialized = deserializeRemotingMessage(serialized)
    check deserialized.header.rootId == 1
    check deserialized.header.headerId == -1
    check deserialized.methodReturn.isSome
    let methodReturn = deserialized.methodReturn.get()
    check methodReturn.messageEnum == {NoArgs, NoContext, ReturnValueInArray}
    check methodReturn.returnValue.primitiveType == PrimitiveType(0)
    check deserialized.methodCallArray.len == 1
    check deserialized.methodCallArray[0].kind == rvPrimitive
    check deserialized.methodCallArray[0].primitiveVal.kind == ptInt32
    check deserialized.methodCallArray[0].primitiveVal.int32Val == 42
    check deserialized.tail.recordType == rtMessageEnd

  test "method call with no arguments":
    let methodName = newStringValueWithCode("Ping")
    let typeName = newStringValueWithCode("MyServer")
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {NoArgs, NoContext},
      methodName: methodName,
      typeName: typeName
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall))
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x15, 0x11, 0x00, 0x00, 0x00, 0x12, 0x04, 0x50, 0x69, 0x6E, 0x67, 0x12, 0x08, 0x4D, 0x79, 0x53, 0x65, 0x72, 0x76, 0x65, 0x72,
      0x0B
    ]
    check serialized == expected
    let deserialized = deserializeRemotingMessage(expected)
    check deserialized.methodCall.isSome
    let methodCall = deserialized.methodCall.get()
    check methodCall.messageEnum == {NoArgs, NoContext}
    check methodCall.methodName.value.stringVal.value == "Ping"
    check methodCall.typeName.value.stringVal.value == "MyServer"
    check methodCall.args.len == 0
    check deserialized.tail.recordType == rtMessageEnd

  test "method return with no return value (void)":
    let binaryMethodReturn = BinaryMethodReturn(
      recordType: rtMethodReturn,
      messageEnum: {NoArgs, NoContext, ReturnValueVoid}
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodReturn = some(binaryMethodReturn))
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x16, 0x11, 0x04, 0x00, 0x00,
      0x0B
    ]
    check serialized == expected
    let deserialized = deserializeRemotingMessage(expected)
    check deserialized.methodReturn.isSome
    let methodReturn = deserialized.methodReturn.get()
    check methodReturn.messageEnum == {NoArgs, NoContext, ReturnValueVoid}
    check methodReturn.returnValue.primitiveType == PrimitiveType(0)
    check deserialized.tail.recordType == rtMessageEnd

  test "method call with call context":
    let methodName = newStringValueWithCode("SecureMethod")
    let typeName = newStringValueWithCode("SecureServer")
    let callContext = newStringValueWithCode("authToken123")
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {ContextInline, NoArgs},
      methodName: methodName,
      typeName: typeName,
      callContext: callContext
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall))
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x15, 0x21, 0x00, 0x00, 0x00, 0x12, 0x0C, 0x53, 0x65, 0x63, 0x75, 0x72, 0x65, 0x4D, 0x65, 0x74, 0x68, 0x6F, 0x64,
      0x12, 0x0C, 0x53, 0x65, 0x63, 0x75, 0x72, 0x65, 0x53, 0x65, 0x72, 0x76, 0x65, 0x72,
      0x12, 0x0C, 0x61, 0x75, 0x74, 0x68, 0x54, 0x6F, 0x6B, 0x65, 0x6E, 0x31, 0x32, 0x33,
      0x0B
    ]
    check serialized == expected
    let deserialized = deserializeRemotingMessage(expected)
    check deserialized.methodCall.isSome
    let methodCall = deserialized.methodCall.get()
    check methodCall.messageEnum == {ContextInline, NoArgs}
    check methodCall.methodName.value.stringVal.value == "SecureMethod"
    check methodCall.typeName.value.stringVal.value == "SecureServer"
    check methodCall.callContext.value.stringVal.value == "authToken123"
    check methodCall.args.len == 0
    check deserialized.tail.recordType == rtMessageEnd

  test "method return with exception":
    let exceptionValue = RemotingValue(
      kind: rvString,
      stringVal: LengthPrefixedString(value: "DivideByZeroException")
    )
    let binaryMethodReturn = BinaryMethodReturn(
      recordType: rtMethodReturn,
      messageEnum: {NoContext, ExceptionInArray}
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodReturn = some(binaryMethodReturn), callArray = @[exceptionValue])
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x16, 0x10, 0x20, 0x00, 0x00,
      0x10, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
      0x06, 0x02, 0x00, 0x00, 0x00, 0x15, 0x44, 0x69, 0x76, 0x69, 0x64, 0x65, 0x42, 0x79, 0x5A, 0x65, 0x72, 0x6F, 0x45, 0x78, 0x63, 0x65, 0x70, 0x74, 0x69, 0x6F, 0x6E,
      0x0B
    ]
    check serialized == expected
    let deserialized = deserializeRemotingMessage(serialized)
    check deserialized.methodReturn.isSome
    let methodReturn = deserialized.methodReturn.get()
    check methodReturn.messageEnum == {NoContext, ExceptionInArray}
    check deserialized.methodCallArray.len == 1
    check deserialized.methodCallArray[0].kind == rvString
    check deserialized.methodCallArray[0].stringVal.value == "DivideByZeroException"
    check deserialized.tail.recordType == rtMessageEnd

  test "method call with method signature in array":
    let methodName = newStringValueWithCode("GenericMethod")
    let typeName = newStringValueWithCode("GenericService")
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {MethodSignatureInArray, NoContext},
      methodName: methodName,
      typeName: typeName
    )
    let signatureValue = RemotingValue(
      kind: rvString,
      stringVal: LengthPrefixedString(value: "System.String, System.Int32")
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall), callArray = @[signatureValue])
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x15, 0x90, 0x00, 0x00, 0x00, 0x12, 0x0D, 0x47, 0x65, 0x6E, 0x65, 0x72, 0x69, 0x63, 0x4D, 0x65, 0x74, 0x68, 0x6F, 0x64,
      0x12, 0x0E, 0x47, 0x65, 0x6E, 0x65, 0x72, 0x69, 0x63, 0x53, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65,
      0x10, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
      0x06, 0x02, 0x00, 0x00, 0x00, 0x1B, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6D, 0x2E, 0x53, 0x74, 0x72, 0x69, 0x6E, 0x67, 0x2C, 0x20, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6D, 0x2E, 0x49, 0x6E, 0x74, 0x33, 0x32,
      0x0B
    ]
    check serialized == expected
    let deserialized = deserializeRemotingMessage(serialized)
    check deserialized.header.rootId == 1
    check deserialized.header.headerId == -1
    check deserialized.methodCall.isSome
    let methodCall = deserialized.methodCall.get()
    check methodCall.messageEnum == {MethodSignatureInArray, NoContext}
    check methodCall.methodName.value.stringVal.value == "GenericMethod"
    check methodCall.typeName.value.stringVal.value == "GenericService"
    check methodCall.args.len == 0
    check deserialized.methodCallArray.len == 1
    check deserialized.methodCallArray[0].kind == rvString
    check deserialized.methodCallArray[0].stringVal.value == "System.String, System.Int32"
    check deserialized.tail.recordType == rtMessageEnd

  test "method call with generic method":
    let methodName = newStringValueWithCode("GetCollection")
    let typeName = newStringValueWithCode("CollectionService")
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {GenericMethod, NoContext},
      methodName: methodName,
      typeName: typeName
    )
    let typeArgValue = RemotingValue(
      kind: rvString,
      stringVal: LengthPrefixedString(value: "System.Int32")
    )
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall), callArray = @[typeArgValue])
    let serialized = serializeRemotingMessage(msg, ctx)
    let expected: seq[byte] = @[
      0x00, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x15, 0x10, 0x40, 0x00, 0x00, 0x12, 0x0D, 0x47, 0x65, 0x74, 0x43, 0x6F, 0x6C, 0x6C, 0x65, 0x63, 0x74, 0x69, 0x6F, 0x6E,
      0x12, 0x11, 0x43, 0x6F, 0x6C, 0x6C, 0x65, 0x63, 0x74, 0x69, 0x6F, 0x6E, 0x53, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65,
      0x10, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
      0x06, 0x02, 0x00, 0x00, 0x00, 0x0C, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6D, 0x2E, 0x49, 0x6E, 0x74, 0x33, 0x32,
      0x0B
    ]
    check serialized == expected
    let deserialized = deserializeRemotingMessage(serialized)
    check deserialized.header.rootId == 1
    check deserialized.header.headerId == -1
    check deserialized.methodCall.isSome
    let methodCall = deserialized.methodCall.get()
    check methodCall.messageEnum == {GenericMethod, NoContext}
    check methodCall.methodName.value.stringVal.value == "GetCollection"
    check methodCall.typeName.value.stringVal.value == "CollectionService"
    check methodCall.args.len == 0
    check deserialized.methodCallArray.len == 1
    check deserialized.methodCallArray[0].kind == rvString
    check deserialized.methodCallArray[0].stringVal.value == "System.Int32"
    check deserialized.tail.recordType == rtMessageEnd
