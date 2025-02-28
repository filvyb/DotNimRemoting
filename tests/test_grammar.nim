import unittest
import msnrbf/grammar
import msnrbf/helpers
import msnrbf/enums
import msnrbf/types
import msnrbf/records/methodinv
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

    # Create RemotingMessage
    var msg = newRemotingMessage(methodCall = some(binaryMethodCall))
    # Adjust header fields per spec: no callArray means rootId and headerId are 0
    msg.header.rootId = 0
    msg.header.headerId = 0

    # Serialize the message
    let serialized = serializeRemotingMessage(msg)

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
    check serialized.len == 39 # Total bytes: 17 + 21 + 1

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