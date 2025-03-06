import unittest
import msnrbf/grammar
import msnrbf/helpers
import msnrbf/enums
import msnrbf/types
import msnrbf/records/methodinv
import msnrbf/records/member # For PrimitiveValue
import options

suite "RemotingMessage serialization and deserialization":
  test "simple method call with no arguments":
    # Create methodName and typeName as StringValueWithCode
    let methodName = newStringValueWithCode("Ping")
    let typeName = newStringValueWithCode("MyServer")

    # Create BinaryMethodCall with NoArgs and NoContext flags
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {NoArgs, NoContext}, # Bit 0 (1) + Bit 4 (16) = 17
      methodName: methodName,
      typeName: typeName
    )

    # Create RemotingMessage with context
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall))
    # Adjust header fields per spec: no callArray means rootId and headerId are 0
    msg.header.rootId = 0
    msg.header.headerId = 0

    # Serialize the message
    let serialized = serializeRemotingMessage(msg, ctx)

    # Define expected byte sequence based on MS-NRBF spec
    let expected: seq[byte] = @[
      # SerializationHeaderRecord (17 bytes)
      0x00,                   # RecordTypeEnum: rtSerializedStreamHeader
      0x00, 0x00, 0x00, 0x00, # rootId: 0
      0x00, 0x00, 0x00, 0x00, # headerId: 0
      0x01, 0x00, 0x00, 0x00, # majorVersion: 1
      0x00, 0x00, 0x00, 0x00, # minorVersion: 0
      # BinaryMethodCall (21 bytes)
      0x15,                   # RecordTypeEnum: rtMethodCall (21)
      0x11, 0x00, 0x00, 0x00, # messageEnum: 17 (NoArgs=1, NoContext=16)
      0x12,                   # methodName PrimitiveTypeEnum: ptString
      0x04,                   # LengthPrefixedString length: 4 ("Ping")
      0x50, 0x69, 0x6E, 0x67, # "Ping" in UTF-8
      0x12,                   # typeName PrimitiveTypeEnum: ptString
      0x08,                   # LengthPrefixedString length: 8 ("MyServer")
      0x4D, 0x79, 0x53, 0x65, 0x72, 0x76, 0x65, 0x72, # "MyServer" in UTF-8
      # MessageEnd (1 byte)
      0x0B                    # RecordTypeEnum: rtMessageEnd (11)
    ]

    # Verify serialization
    check serialized == expected

    # Deserialize the byte sequence
    let deserialized = deserializeRemotingMessage(expected)

    # Verify deserialized message fields
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
    check methodCall.args.len == 0 # NoArgs flag set
    check methodCall.callContext.primitiveType == PrimitiveType(0) # NoContext flag set, default value

    check deserialized.methodCallArray.len == 0
    check deserialized.referencedRecords.len == 0
    check deserialized.tail.recordType == rtMessageEnd

  test "method call with inline primitive arguments":
    # Create methodName and typeName
    let methodName = newStringValueWithCode("Add")
    let typeName = newStringValueWithCode("MathService")

    # Create inline arguments: integers 3 and 5
    let arg1 = ValueWithCode(primitiveType: ptInt32, value: int32Value(3))
    let arg2 = ValueWithCode(primitiveType: ptInt32, value: int32Value(5))

    # Create BinaryMethodCall with ArgsInline and NoContext
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {ArgsInline, NoContext},  # 2 + 16 = 18
      methodName: methodName,
      typeName: typeName,
      args: @[arg1, arg2]
    )

    # Create RemotingMessage with context
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall))

    # Serialize the message
    let serialized = serializeRemotingMessage(msg, ctx)

    # Define expected byte sequence
    let expected: seq[byte] = @[
      # SerializationHeaderRecord (17 bytes)
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      # BinaryMethodCall (37 bytes)
      0x15, 0x12, 0x00, 0x00, 0x00,  # recordType=21, messageEnum=18
      0x12, 0x03, 0x41, 0x64, 0x64,  # methodName: ptString, len=3, "Add"
      0x12, 0x0B, 0x4D, 0x61, 0x74, 0x68, 0x53, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65,  # typeName: ptString, len=11, "MathService"
      0x02, 0x00, 0x00, 0x00,  # args length=2
      0x08, 0x03, 0x00, 0x00, 0x00,  # arg1: ptInt32, value=3
      0x08, 0x05, 0x00, 0x00, 0x00,  # arg2: ptInt32, value=5
      # MessageEnd (1 byte)
      0x0B
    ]

    # Verify serialization
    check serialized == expected

    # Deserialize the byte sequence
    let deserialized = deserializeRemotingMessage(expected)

    # Verify deserialized message
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
    # Create methodName and typeName
    let methodName = newStringValueWithCode("Foo")
    let typeName = newStringValueWithCode("Bar")

    # Create BinaryMethodCall with ArgsInArray and NoContext
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {ArgsInArray, NoContext},  # 8 + 16 = 24
      methodName: methodName,
      typeName: typeName
    )

    # Create callArray with one argument using RemotingValue for primitive
    let value = RemotingValue(
      kind: rvPrimitive,
      primitiveVal: PrimitiveValue(
        kind: ptInt32,
        int32Val: 10
      )
    )

    # Create a context and RemotingMessage
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall), callArray = @[value])

    # Serialize the message
    let serialized = serializeRemotingMessage(msg, ctx)

    # Deserialize the byte sequence
    let deserialized = deserializeRemotingMessage(serialized)

    # Verify deserialized message
    check deserialized.header.rootId == 1
    check deserialized.header.headerId == -1
    check deserialized.methodCall.isSome
    let methodCall = deserialized.methodCall.get()
    check methodCall.messageEnum == {ArgsInArray, NoContext}
    check methodCall.methodName.value.stringVal.value == "Foo"
    check methodCall.typeName.value.stringVal.value == "Bar"
    check methodCall.args.len == 0  # ArgsInArray, so no inline args
    check deserialized.methodCallArray.len == 1
    check deserialized.methodCallArray[0].kind == rvPrimitive
    check deserialized.methodCallArray[0].primitiveVal.kind == ptInt32
    check deserialized.methodCallArray[0].primitiveVal.int32Val == 10
    check deserialized.tail.recordType == rtMessageEnd

  test "method return with inline primitive return value":
    # Create BinaryMethodReturn with ReturnValueInline, NoArgs, NoContext
    let returnValue = ValueWithCode(primitiveType: ptInt32, value: int32Value(8))
    let binaryMethodReturn = BinaryMethodReturn(
      recordType: rtMethodReturn,
      messageEnum: {NoArgs, NoContext, ReturnValueInline},  # 1 + 16 + 2048 = 2065
      returnValue: returnValue
    )

    # Create RemotingMessage with context
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodReturn = some(binaryMethodReturn))

    # Serialize the message
    let serialized = serializeRemotingMessage(msg, ctx)

    # Define expected byte sequence
    let expected: seq[byte] = @[
      # SerializationHeaderRecord (17 bytes)
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      # BinaryMethodReturn (10 bytes)
      0x16, 0x11, 0x08, 0x00, 0x00,  # recordType=22, messageEnum=2065 (0x0811)
      0x08, 0x08, 0x00, 0x00, 0x00,  # returnValue: ptInt32, value=8
      # MessageEnd (1 byte)
      0x0B
    ]

    # Verify serialization
    check serialized == expected

    # Deserialize the byte sequence
    let deserialized = deserializeRemotingMessage(expected)

    # Verify deserialized message
    check deserialized.header.rootId == 0
    check deserialized.header.headerId == 0
    check deserialized.methodReturn.isSome
    let methodReturn = deserialized.methodReturn.get()
    check methodReturn.messageEnum == {NoArgs, NoContext, ReturnValueInline}
    check methodReturn.returnValue.primitiveType == ptInt32
    check methodReturn.returnValue.value.int32Val == 8
    check deserialized.tail.recordType == rtMessageEnd

  test "method return with return value in separate call array":
    # Create BinaryMethodReturn with ReturnValueInArray, NoArgs, NoContext
    let binaryMethodReturn = BinaryMethodReturn(
      recordType: rtMethodReturn,
      messageEnum: {NoArgs, NoContext, ReturnValueInArray},  # 1 + 16 + 4096 = 4113
    )

    # Create callArray with one return value using RemotingValue
    let value = RemotingValue(
      kind: rvPrimitive,
      primitiveVal: PrimitiveValue(
        kind: ptInt32,
        int32Val: 42
      )
    )

    # Create a context and RemotingMessage 
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodReturn = some(binaryMethodReturn), callArray = @[value])

    # Serialize the message
    let serialized = serializeRemotingMessage(msg, ctx)

    # Deserialize the byte sequence
    let deserialized = deserializeRemotingMessage(serialized)

    # Verify deserialized message
    check deserialized.header.rootId == 1
    check deserialized.header.headerId == -1
    check deserialized.methodReturn.isSome
    let methodReturn = deserialized.methodReturn.get()
    check methodReturn.messageEnum == {NoArgs, NoContext, ReturnValueInArray}
    check methodReturn.returnValue.primitiveType == PrimitiveType(0)  # No inline return value
    check deserialized.methodCallArray.len == 1
    check deserialized.methodCallArray[0].kind == rvPrimitive
    check deserialized.methodCallArray[0].primitiveVal.kind == ptInt32
    check deserialized.methodCallArray[0].primitiveVal.int32Val == 42
    check deserialized.tail.recordType == rtMessageEnd

  test "method call with no arguments":
    # Create methodName and typeName
    let methodName = newStringValueWithCode("Ping")
    let typeName = newStringValueWithCode("MyServer")

    # Create BinaryMethodCall with NoArgs and NoContext
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {NoArgs, NoContext},  # 1 + 16 = 17
      methodName: methodName,
      typeName: typeName
    )

    # Create RemotingMessage with context
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall))

    # Serialize the message
    let serialized = serializeRemotingMessage(msg, ctx)

    # Define expected byte sequence
    let expected: seq[byte] = @[
      # SerializationHeaderRecord (17 bytes)
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      # BinaryMethodCall (31 bytes)
      0x15, 0x11, 0x00, 0x00, 0x00,  # recordType=21, messageEnum=17
      0x12, 0x04, 0x50, 0x69, 0x6E, 0x67,  # methodName: ptString, len=4, "Ping"
      0x12, 0x08, 0x4D, 0x79, 0x53, 0x65, 0x72, 0x76, 0x65, 0x72,  # typeName: ptString, len=8, "MyServer"
      # MessageEnd (1 byte)
      0x0B
    ]

    # Verify serialization
    check serialized == expected

    # Deserialize the byte sequence
    let deserialized = deserializeRemotingMessage(expected)

    # Verify deserialized message
    check deserialized.methodCall.isSome
    let methodCall = deserialized.methodCall.get()
    check methodCall.messageEnum == {NoArgs, NoContext}
    check methodCall.methodName.value.stringVal.value == "Ping"
    check methodCall.typeName.value.stringVal.value == "MyServer"
    check methodCall.args.len == 0
    check deserialized.tail.recordType == rtMessageEnd

  test "method return with no return value (void)":
    # Create BinaryMethodReturn with NoArgs, NoContext, ReturnValueVoid
    let binaryMethodReturn = BinaryMethodReturn(
      recordType: rtMethodReturn,
      messageEnum: {NoArgs, NoContext, ReturnValueVoid},  # 1 + 16 + 1024 = 1041
    )

    # Create RemotingMessage with context
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodReturn = some(binaryMethodReturn))

    # Serialize the message
    let serialized = serializeRemotingMessage(msg, ctx)

    # Define expected byte sequence
    let expected: seq[byte] = @[
      # SerializationHeaderRecord (17 bytes)
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      # BinaryMethodReturn (5 bytes)
      0x16, 0x11, 0x04, 0x00, 0x00,  # recordType=22, messageEnum=1041 (0x0411)
      # MessageEnd (1 byte)
      0x0B
    ]

    # Verify serialization
    check serialized == expected

    # Deserialize the byte sequence
    let deserialized = deserializeRemotingMessage(expected)

    # Verify deserialized message
    check deserialized.methodReturn.isSome
    let methodReturn = deserialized.methodReturn.get()
    check methodReturn.messageEnum == {NoArgs, NoContext, ReturnValueVoid}
    check methodReturn.returnValue.primitiveType == PrimitiveType(0)  # No return value
    check deserialized.tail.recordType == rtMessageEnd

  test "method call with call context":
    # Create methodName, typeName, and callContext
    let methodName = newStringValueWithCode("SecureMethod")
    let typeName = newStringValueWithCode("SecureServer")
    let callContext = newStringValueWithCode("authToken123")

    # Create BinaryMethodCall with ContextInline and NoArgs
    let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {ContextInline, NoArgs},  # 32 + 1 = 33
      methodName: methodName,
      typeName: typeName,
      callContext: callContext
    )

    # Create RemotingMessage with context
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall))

    # Serialize the message
    let serialized = serializeRemotingMessage(msg, ctx)

    # Define expected byte sequence
    let expected: seq[byte] = @[
      # SerializationHeaderRecord (17 bytes)
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      # BinaryMethodCall (43 bytes)
      0x15, 0x21, 0x00, 0x00, 0x00,  # recordType=21, messageEnum=33 (0x0021)
      0x12, 0x0C, 0x53, 0x65, 0x63, 0x75, 0x72, 0x65, 0x4D, 0x65, 0x74, 0x68, 0x6F, 0x64,  # methodName: ptString, len=12, "SecureMethod"
      0x12, 0x0C, 0x53, 0x65, 0x63, 0x75, 0x72, 0x65, 0x53, 0x65, 0x72, 0x76, 0x65, 0x72,  # typeName: ptString, len=12, "SecureServer"
      0x12, 0x0C, 0x61, 0x75, 0x74, 0x68, 0x54, 0x6F, 0x6B, 0x65, 0x6E, 0x31, 0x32, 0x33,  # callContext: ptString, len=12, "authToken123"
      # MessageEnd (1 byte)
      0x0B
    ]

    # Verify serialization
    check serialized == expected

    # Deserialize the byte sequence
    let deserialized = deserializeRemotingMessage(expected)

    # Verify deserialized message
    check deserialized.methodCall.isSome
    let methodCall = deserialized.methodCall.get()
    check methodCall.messageEnum == {ContextInline, NoArgs}
    check methodCall.methodName.value.stringVal.value == "SecureMethod"
    check methodCall.typeName.value.stringVal.value == "SecureServer"
    check methodCall.callContext.value.stringVal.value == "authToken123"
    check methodCall.args.len == 0
    check deserialized.tail.recordType == rtMessageEnd

  test "method return with exception":
    # Define an exception value as a RemotingValue
    let exceptionValue = RemotingValue(
      kind: rvString,
      stringVal: "DivideByZeroException"
    )

    # Create BinaryMethodReturn with valid flags: NoContext and ExceptionInArray
    let binaryMethodReturn = BinaryMethodReturn(
      recordType: rtMethodReturn,
      messageEnum: {NoContext, ExceptionInArray}  # 16 + 8192 = 8208
    )

    # Create the message with the exception in the call array
    let ctx = newSerializationContext()
    var msg = newRemotingMessage(
      ctx,
      methodReturn = some(binaryMethodReturn),
      callArray = @[exceptionValue]
    )

    # Serialize the message
    let serialized = serializeRemotingMessage(msg, ctx)

    # Deserialize and verify
    let deserialized = deserializeRemotingMessage(serialized)
    check deserialized.methodReturn.isSome
    let methodReturn = deserialized.methodReturn.get()
    check methodReturn.messageEnum == {NoContext, ExceptionInArray}
    check deserialized.methodCallArray.len == 1
    check deserialized.methodCallArray[0].kind == rvString
    check deserialized.methodCallArray[0].stringVal == "DivideByZeroException"
