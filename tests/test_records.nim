import unittest
import faststreams/[inputs, outputs]
import msnrbf/[enums, types, records/class, records/serialization]

suite "Class Records Tests":
  test "Basic ClassInfo serialization/deserialization":
    let info = ClassInfo(
      objectId: 2,
      name: LengthPrefixedString(value: "DOJRemotingMetadata.Address"),
      memberCount: 4,
      memberNames: @[
        LengthPrefixedString(value: "Street"),  
        LengthPrefixedString(value: "City"),
        LengthPrefixedString(value: "State"),
        LengthPrefixedString(value: "Zip")
      ]
    )
    
    var outStream = memoryOutput()
    writeClassInfo(outStream, info)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readClassInfo(inStream)
    
    check decoded.objectId == 2
    check decoded.name.value == "DOJRemotingMetadata.Address"
    check decoded.memberCount == 4
    check decoded.memberNames.len == 4
    check decoded.memberNames[0].value == "Street"
    check decoded.memberNames[1].value == "City"
    check decoded.memberNames[2].value == "State" 
    check decoded.memberNames[3].value == "Zip"

  test "MemberTypeInfo with Primitive types":
    let memberTypes = MemberTypeInfo(
      binaryTypes: @[btPrimitive, btPrimitive],
      additionalInfos: @[
        AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptString),
        AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptInt32)
      ]
    )

    var outStream = memoryOutput()
    writeMemberTypeInfo(outStream, memberTypes)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readMemberTypeInfo(inStream, 2)

    check decoded.binaryTypes.len == 2
    check decoded.binaryTypes[0] == btPrimitive
    check decoded.binaryTypes[1] == btPrimitive
    check decoded.additionalInfos[0].kind == btPrimitive
    check decoded.additionalInfos[0].primitiveType == ptString
    check decoded.additionalInfos[1].kind == btPrimitive
    check decoded.additionalInfos[1].primitiveType == ptInt32

  test "MemberTypeInfo with mixed types":
    let memberTypes = MemberTypeInfo(
      binaryTypes: @[btPrimitive, btString, btSystemClass, btClass],
      additionalInfos: @[
        AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptInt32),
        AdditionalTypeInfo(kind: btString),
        AdditionalTypeInfo(
          kind: btSystemClass, 
          className: LengthPrefixedString(value: "System.String")
        ),
        AdditionalTypeInfo(
          kind: btClass,
          classInfo: ClassTypeInfo(
            typeName: LengthPrefixedString(value: "TestClass"),
            libraryId: 1
          )
        )
      ]
    )

    var outStream = memoryOutput()
    writeMemberTypeInfo(outStream, memberTypes)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readMemberTypeInfo(inStream, 4)

    check decoded.binaryTypes.len == 4
    check decoded.binaryTypes == @[btPrimitive, btString, btSystemClass, btClass]
    
    check decoded.additionalInfos[0].kind == btPrimitive
    check decoded.additionalInfos[0].primitiveType == ptInt32
    
    check decoded.additionalInfos[1].kind == btString
    
    check decoded.additionalInfos[2].kind == btSystemClass
    check decoded.additionalInfos[2].className.value == "System.String"
    
    check decoded.additionalInfos[3].kind == btClass
    check decoded.additionalInfos[3].classInfo.typeName.value == "TestClass"
    check decoded.additionalInfos[3].classInfo.libraryId == 1

  test "PrimitiveArray type info":
    let memberTypes = MemberTypeInfo(
      binaryTypes: @[btPrimitiveArray],
      additionalInfos: @[
        AdditionalTypeInfo(kind: btPrimitiveArray, primitiveType: ptInt32)
      ]
    )

    var outStream = memoryOutput()
    writeMemberTypeInfo(outStream, memberTypes)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readMemberTypeInfo(inStream, 1)

    check decoded.binaryTypes[0] == btPrimitiveArray
    check decoded.additionalInfos[0].kind == btPrimitiveArray
    check decoded.additionalInfos[0].primitiveType == ptInt32

  test "Full class serialization with complex member types":
    let cls = ClassWithMembersAndTypes(
      recordType: rtClassWithMembersAndTypes,
      classInfo: ClassInfo(
        objectId: 2,
        name: LengthPrefixedString(value: "ComplexClass"),
        memberCount: 4,
        memberNames: @[
          LengthPrefixedString(value: "primitiveField"),
          LengthPrefixedString(value: "stringField"),
          LengthPrefixedString(value: "systemClassField"),
          LengthPrefixedString(value: "customClassField")
        ]
      ),
      memberTypeInfo: MemberTypeInfo(
        binaryTypes: @[btPrimitive, btString, btSystemClass, btClass],
        additionalInfos: @[
          AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptInt32),
          AdditionalTypeInfo(kind: btString),
          AdditionalTypeInfo(
            kind: btSystemClass,
            className: LengthPrefixedString(value: "System.DateTime")
          ),
          AdditionalTypeInfo(
            kind: btClass,
            classInfo: ClassTypeInfo(
              typeName: LengthPrefixedString(value: "CustomType"),
              libraryId: 3
            )
          )
        ]
      ),
      libraryId: 3
    )

    var outStream = memoryOutput()
    writeClassWithMembersAndTypes(outStream, cls)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readClassWithMembersAndTypes(inStream)

    check decoded.classInfo.memberCount == 4
    check decoded.memberTypeInfo.binaryTypes.len == 4
    
    # Verify complex member type info was preserved
    check decoded.memberTypeInfo.additionalInfos[0].primitiveType == ptInt32
    check decoded.memberTypeInfo.additionalInfos[2].className.value == "System.DateTime"
    check decoded.memberTypeInfo.additionalInfos[3].classInfo.typeName.value == "CustomType"

  test "Basic class without type info":
    let cls = ClassWithMembers(
      recordType: rtClassWithMembers,
      classInfo: ClassInfo(
        objectId: 1,
        name: LengthPrefixedString(value: "SimpleClass"),
        memberCount: 2,
        memberNames: @[
          LengthPrefixedString(value: "field1"),
          LengthPrefixedString(value: "field2")
        ]
      ),
      libraryId: 1
    )

    var outStream = memoryOutput()
    writeClassWithMembers(outStream, cls)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readClassWithMembers(inStream)

    check decoded.recordType == rtClassWithMembers
    check decoded.classInfo.objectId == 1
    check decoded.classInfo.name.value == "SimpleClass"
    check decoded.classInfo.memberCount == 2
    check decoded.libraryId == 1

  test "Class reference serialization":
    let cls = ClassWithId(
      recordType: rtClassWithId,
      objectId: 5,
      metadataId: 2  # References previous class metadata
    )

    var outStream = memoryOutput()
    writeClassWithId(outStream, cls)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized) 
    let decoded = readClassWithId(inStream)

    check decoded.recordType == rtClassWithId
    check decoded.objectId == 5
    check decoded.metadataId == 2

  test "Invalid record type":
    let cls = ClassWithId(
      recordType: rtMessageEnd,  # Wrong record type
      objectId: 1,
      metadataId: 1
    )

    var outStream = memoryOutput()
    writeClassWithId(outStream, cls)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    expect IOError:
      discard readClassWithId(inStream)

  test "Incomplete ClassInfo data":
    var outStream = memoryOutput()
    outStream.write([1'u8, 0, 0])  # Not enough bytes for objectId
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    expect IOError:
      discard readClassInfo(inStream)

suite "Other Records Tests":
  test "Basic header serialization/deserialization":
    # Example from MS-NRBF 3. Structure Examples:
    # First few bytes: 00 01 00 00 00 FF FF FF FF 01 00 00 00 00 00 00 00
    # 00 - SerializedStreamHeader record type
    # 01 00 00 00 - rootId = 1
    # FF FF FF FF - headerId = -1
    # 01 00 00 00 - majorVersion = 1  
    # 00 00 00 00 - minorVersion = 0
    
    let header = SerializationHeaderRecord(
      recordType: rtSerializedStreamHeader,
      rootId: 1,
      headerId: -1,
      majorVersion: 1,
      minorVersion: 0
    )
    
    # Serialize
    var outStream = memoryOutput()
    writeSerializationHeader(outStream, header)
    let serialized = outStream.getOutput(seq[byte])

    # Verify against expected bytes
    check serialized.len == 17
    check serialized[0] == 0x00'u8  # rtSerializedStreamHeader
    check serialized[1] == 0x01'u8  # rootId LSB
    check serialized[2] == 0x00'u8
    check serialized[3] == 0x00'u8
    check serialized[4] == 0x00'u8  # rootId MSB
    check serialized[5] == 0xFF'u8  # headerId LSB
    check serialized[6] == 0xFF'u8
    check serialized[7] == 0xFF'u8
    check serialized[8] == 0xFF'u8  # headerId MSB
    check serialized[9] == 0x01'u8  # majorVersion LSB
    check serialized[13] == 0x00'u8 # minorVersion LSB

    # Deserialize and verify
    let inStream = memoryInput(serialized)
    let decoded = readSerializationHeader(inStream)
    
    check decoded.recordType == rtSerializedStreamHeader
    check decoded.rootId == 1
    check decoded.headerId == -1 
    check decoded.majorVersion == 1
    check decoded.minorVersion == 0

  test "Invalid version numbers":
    let header = SerializationHeaderRecord(
      recordType: rtSerializedStreamHeader,
      rootId: 0,
      headerId: 0, 
      majorVersion: 2,  # Invalid - must be 1
      minorVersion: 1   # Invalid - must be 0
    )

    var outStream = memoryOutput()
    writeSerializationHeader(outStream, header)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    expect IOError:
      discard readSerializationHeader(inStream)

  test "Basic library serialization/deserialization":
    # Example from MS-NRBF docs:
    # 0C 03 00 00 00 51 44 4F 4A...
    # 0C - BinaryLibrary record
    # 03 00 00 00 - libraryId = 3
    # 51 - String length = 81
    # Rest is library name
    
    let lib = BinaryLibrary(
      recordType: rtBinaryLibrary,
      libraryId: 3,
      libraryName: LengthPrefixedString(
        value: "DOJRemotingMetadata, Version=1.0.2622.31326, Culture=neutral, PublicKeyToken=null"
      )
    )

    # Serialize
    var outStream = memoryOutput() 
    writeBinaryLibrary(outStream, lib)
    let serialized = outStream.getOutput(seq[byte])

    # Basic byte checks
    check serialized[0] == 0x0C'u8  # rtBinaryLibrary
    check serialized[1] == 0x03'u8  # libraryId LSB
    check serialized[2] == 0x00'u8
    check serialized[3] == 0x00'u8
    check serialized[4] == 0x00'u8  # libraryId MSB

    # Deserialize and verify
    let inStream = memoryInput(serialized)
    let decoded = readBinaryLibrary(inStream)
    
    check decoded.recordType == rtBinaryLibrary
    check decoded.libraryId == 3
    check decoded.libraryName.value == lib.libraryName.value

  test "Valid flag combinations":
    let flags = {
      MessageFlag.NoArgs,
      MessageFlag.NoContext, 
      MessageFlag.NoReturnValue
    }

    var outStream = memoryOutput()
    writeMessageFlags(outStream, flags)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readMessageFlags(inStream)

    check decoded == flags

  test "Mutually exclusive flags should raise error":
    let invalidFlags = {
      MessageFlag.NoArgs,
      MessageFlag.ArgsInline  # Can't have both NoArgs and ArgsInline
    }

    var outStream = memoryOutput()
    expect ValueError:
      writeMessageFlags(outStream, invalidFlags)

  test "Multiple flags from same category should raise error":
    let invalidFlags = {
      MessageFlag.ReturnValueVoid,
      MessageFlag.ReturnValueInline,  # Can't have multiple return flags
      MessageFlag.ReturnValueInArray
    }

    var outStream = memoryOutput()
    expect ValueError:
      writeMessageFlags(outStream, invalidFlags)

  test "Args and Exception flags are mutually exclusive":
    let invalidFlags = {
      MessageFlag.ArgsInArray,
      MessageFlag.ExceptionInArray
    }

    var outStream = memoryOutput()
    expect ValueError:
      writeMessageFlags(outStream, invalidFlags)

  test "Return and Exception flags are mutually exclusive":
    let invalidFlags = {
      MessageFlag.ReturnValueInline,
      MessageFlag.ExceptionInArray
    }

    var outStream = memoryOutput()
    expect ValueError:
      writeMessageFlags(outStream, invalidFlags)

  test "Return and Signature flags are mutually exclusive":
    let invalidFlags = {
      MessageFlag.ReturnValueInline,
      MessageFlag.MethodSignatureInArray
    }

    var outStream = memoryOutput()
    expect ValueError: 
      writeMessageFlags(outStream, invalidFlags)