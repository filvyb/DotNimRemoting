import unittest
import faststreams/[inputs, outputs]
import msnrbf/[enums, types, helpers, grammar, records/class, records/serialization, records/arrays, records/member]
import options

# Export these for use in tests
export helpers, grammar

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
        AdditionalTypeInfo(kind: btPrimitive, primitiveType: ptInt64),
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
    check decoded.additionalInfos[0].primitiveType == ptInt64
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

suite "Array Records Tests":
  test "Basic ArrayInfo serialization/deserialization":
    let info = ArrayInfo(
      objectId: 1,
      length: 4
    )
    
    var outStream = memoryOutput()
    writeArrayInfo(outStream, info)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readArrayInfo(inStream)
    
    check decoded.objectId == 1
    check decoded.length == 4

  test "ArraySingleObject serialization/deserialization":
    # From docs example:
    # ArraySingleObject record with length 1
    let arr = ArraySingleObject(
      recordType: rtArraySingleObject,
      arrayInfo: ArrayInfo(
        objectId: 1,
        length: 1
      )
    )
    
    var outStream = memoryOutput()
    writeArraySingleObject(outStream, arr)
    let serialized = outStream.getOutput(seq[byte])

    # Verify against expected bytes
    check serialized.len == 9  # 1 byte type + 8 bytes array info
    check serialized[0] == byte(rtArraySingleObject)  # Record type
    
    let inStream = memoryInput(serialized)
    let decoded = readArraySingleObject(inStream)
    
    check decoded.recordType == rtArraySingleObject
    check decoded.arrayInfo.objectId == 1
    check decoded.arrayInfo.length == 1

  test "ArraySinglePrimitive serialization/deserialization":
    let arr = ArraySinglePrimitive(
      recordType: rtArraySinglePrimitive,
      arrayInfo: ArrayInfo(
        objectId: 1,
        length: 3
      ),
      primitiveType: ptInt32
    )
    
    var outStream = memoryOutput()
    writeArraySinglePrimitive(outStream, arr)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readArraySinglePrimitive(inStream)
    
    check decoded.recordType == rtArraySinglePrimitive
    check decoded.arrayInfo.objectId == 1
    check decoded.arrayInfo.length == 3
    check decoded.primitiveType == ptInt32

  test "Invalid primitive type for ArraySinglePrimitive":
    let arr = ArraySinglePrimitive(
      recordType: rtArraySinglePrimitive,
      arrayInfo: ArrayInfo(objectId: 1, length: 1),
      primitiveType: ptString  # String not allowed
    )
    
    var outStream = memoryOutput()
    expect ValueError:
      writeArraySinglePrimitive(outStream, arr)

  test "ArraySingleString serialization/deserialization":
    let arr = ArraySingleString(
      recordType: rtArraySingleString,
      arrayInfo: ArrayInfo(
        objectId: 1,
        length: 2
      )
    )
    
    var outStream = memoryOutput()
    writeArraySingleString(outStream, arr)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readArraySingleString(inStream)
    
    check decoded.recordType == rtArraySingleString
    check decoded.arrayInfo.objectId == 1
    check decoded.arrayInfo.length == 2

  test "BinaryArray single-dimensional serialization/deserialization":
    let arr = BinaryArray(
      recordType: rtBinaryArray,
      objectId: 1,
      binaryArrayType: batSingle,
      rank: 1,
      lengths: @[int32(3)],
      typeEnum: btPrimitive,
      additionalTypeInfo: AdditionalTypeInfo(
        kind: btPrimitive,
        primitiveType: ptInt32
      )
    )
    
    var outStream = memoryOutput()
    writeBinaryArray(outStream, arr)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readBinaryArray(inStream)
    
    check decoded.recordType == rtBinaryArray
    check decoded.objectId == 1
    check decoded.binaryArrayType == batSingle
    check decoded.rank == 1
    check decoded.lengths == @[int32(3)]
    check decoded.typeEnum == btPrimitive
    check decoded.additionalTypeInfo.kind == btPrimitive
    check decoded.additionalTypeInfo.primitiveType == ptInt32

  test "BinaryArray with lower bounds":
    let arr = BinaryArray(
      recordType: rtBinaryArray,
      objectId: 1,
      binaryArrayType: batSingleOffset,
      rank: 2,
      lengths: @[int32(2), int32(3)],
      lowerBounds: @[int32(1), int32(1)],
      typeEnum: btString,
      additionalTypeInfo: AdditionalTypeInfo(kind: btString)
    )
    
    var outStream = memoryOutput()
    writeBinaryArray(outStream, arr)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readBinaryArray(inStream)
    
    check decoded.recordType == rtBinaryArray
    check decoded.binaryArrayType == batSingleOffset
    check decoded.rank == 2
    check decoded.lengths == @[int32(2), int32(3)]
    check decoded.lowerBounds == @[int32(1), int32(1)]
    check decoded.typeEnum == btString

  test "BinaryArray with system class type":
    let arr = BinaryArray(
      recordType: rtBinaryArray,
      objectId: 1,
      binaryArrayType: batSingle,
      rank: 1,
      lengths: @[int32(2)],
      typeEnum: btSystemClass,
      additionalTypeInfo: AdditionalTypeInfo(
        kind: btSystemClass,
        className: LengthPrefixedString(value: "System.String")
      )
    )
    
    var outStream = memoryOutput()
    writeBinaryArray(outStream, arr)
    let serialized = outStream.getOutput(seq[byte])

    let inStream = memoryInput(serialized)
    let decoded = readBinaryArray(inStream)
    
    check decoded.recordType == rtBinaryArray
    check decoded.typeEnum == btSystemClass
    check decoded.additionalTypeInfo.kind == btSystemClass
    check decoded.additionalTypeInfo.className.value == "System.String"

  test "Invalid array rank":
    let arr = BinaryArray(
      recordType: rtBinaryArray,
      objectId: 1,
      binaryArrayType: batSingle,
      rank: -1,  # Invalid - must be non-negative
      lengths: @[],
      typeEnum: btString,
      additionalTypeInfo: AdditionalTypeInfo(kind: btString)
    )
    
    var outStream = memoryOutput()
    expect ValueError:
      writeBinaryArray(outStream, arr)

  test "Mismatched lengths and rank":
    let arr = BinaryArray(
      recordType: rtBinaryArray,
      objectId: 1,
      binaryArrayType: batSingle,
      rank: 2,
      lengths: @[int32(1)],  # Should have 2 lengths for rank 2
      typeEnum: btString,
      additionalTypeInfo: AdditionalTypeInfo(kind: btString)
    )
    
    var outStream = memoryOutput()
    expect ValueError:
      writeBinaryArray(outStream, arr)

  test "Missing lower bounds for offset array":
    let arr = BinaryArray(
      recordType: rtBinaryArray,
      objectId: 1,
      binaryArrayType: batSingleOffset,
      rank: 1,
      lengths: @[int32(1)],
      # Missing lowerBounds
      typeEnum: btString,
      additionalTypeInfo: AdditionalTypeInfo(kind: btString)
    )
    
    var outStream = memoryOutput()
    expect ValueError:
      writeBinaryArray(outStream, arr)

suite "Member Reference Records Tests":
  test "MemberPrimitiveTyped serialization/deserialization":
    let member = MemberPrimitiveTyped(
      recordType: rtMemberPrimitiveTyped,
      value: PrimitiveValue(
        kind: ptInt32,
        int32Val: 42
      )
    )

    var outStream = memoryOutput()
    writeMemberPrimitiveTyped(outStream, member) 
    let serialized = outStream.getOutput(seq[byte])

    # Basic byte checks - record type, primitive type, 4 byte int32 value
    check serialized.len == 6
    check serialized[0] == byte(rtMemberPrimitiveTyped)
    check serialized[1] == byte(ptInt32)
    # 42 in little endian: 2A 00 00 00
    check serialized[2] == 0x2A'u8
    check serialized[3] == 0x00'u8
    check serialized[4] == 0x00'u8
    check serialized[5] == 0x00'u8

    let inStream = memoryInput(serialized)
    let decoded = readMemberPrimitiveTyped(inStream)

    check decoded.recordType == rtMemberPrimitiveTyped
    check decoded.value.kind == ptInt32
    check decoded.value.int32Val == 42

  test "MemberPrimitiveUnTyped serialization/deserialization":
    let member = MemberPrimitiveUnTyped(
      value: PrimitiveValue(
        kind: ptInt32,
        int32Val: 42
      )
    )

    var outStream = memoryOutput()
    writeMemberPrimitiveUnTyped(outStream, member)
    let serialized = outStream.getOutput(seq[byte])

    # Only contains value bytes, no type info
    check serialized.len == 4
    # 42 in little endian: 2A 00 00 00
    check serialized[0] == 0x2A'u8
    check serialized[1] == 0x00'u8
    check serialized[2] == 0x00'u8
    check serialized[3] == 0x00'u8

    let inStream = memoryInput(serialized)
    let decoded = readMemberPrimitiveUnTyped(inStream, ptInt32)

    check decoded.value.kind == ptInt32
    check decoded.value.int32Val == 42

  test "MemberReference serialization/deserialization":
    # Example from MS-NRBF docs:
    # 09 02 00 00 00
    # 09 - MemberReference record
    # 02 00 00 00 - idRef = 2
    let reference = MemberReference(
      recordType: rtMemberReference,
      idRef: 2
    )

    var outStream = memoryOutput()
    writeMemberReference(outStream, reference)
    let serialized = outStream.getOutput(seq[byte])

    check serialized.len == 5
    check serialized[0] == 0x09'u8  # rtMemberReference
    check serialized[1] == 0x02'u8  # idRef LSB
    check serialized[2] == 0x00'u8
    check serialized[3] == 0x00'u8
    check serialized[4] == 0x00'u8  # idRef MSB

    let inStream = memoryInput(serialized)
    let decoded = readMemberReference(inStream)

    check decoded.recordType == rtMemberReference
    check decoded.idRef == 2

  test "ObjectNull serialization/deserialization":
    # Example from MS-NRBF docs:
    # 0A - Single ObjectNull record
    let nullObj = ObjectNull(recordType: rtObjectNull)

    var outStream = memoryOutput()
    writeObjectNull(outStream, nullObj)
    let serialized = outStream.getOutput(seq[byte])

    check serialized.len == 1
    check serialized[0] == 0x0A'u8  # rtObjectNull

    let inStream = memoryInput(serialized)
    let decoded = readObjectNull(inStream)

    check decoded.recordType == rtObjectNull

  test "ObjectNullMultiple serialization/deserialization":
    # Example from MS-NRBF docs:
    # 0E 03 00 00 00 - Three consecutive nulls
    let nullMultiple = ObjectNullMultiple(
      recordType: rtObjectNullMultiple,
      nullCount: 3
    )

    var outStream = memoryOutput()
    writeObjectNullMultiple(outStream, nullMultiple)
    let serialized = outStream.getOutput(seq[byte])

    check serialized.len == 5
    check serialized[0] == 0x0E'u8  # rtObjectNullMultiple
    check serialized[1] == 0x03'u8  # nullCount LSB
    check serialized[2] == 0x00'u8
    check serialized[3] == 0x00'u8
    check serialized[4] == 0x00'u8  # nullCount MSB

    let inStream = memoryInput(serialized)
    let decoded = readObjectNullMultiple(inStream)

    check decoded.recordType == rtObjectNullMultiple
    check decoded.nullCount == 3

  test "ObjectNullMultiple256 serialization/deserialization":
    # Example from MS-NRBF docs:
    # 0D FF - 255 consecutive nulls
    let nullMultiple256 = ObjectNullMultiple256(
      recordType: rtObjectNullMultiple256,
      nullCount: 255
    )

    var outStream = memoryOutput()
    writeObjectNullMultiple256(outStream, nullMultiple256)
    let serialized = outStream.getOutput(seq[byte])

    check serialized.len == 2
    check serialized[0] == 0x0D'u8  # rtObjectNullMultiple256
    check serialized[1] == 0xFF'u8  # nullCount

    let inStream = memoryInput(serialized)
    let decoded = readObjectNullMultiple256(inStream)

    check decoded.recordType == rtObjectNullMultiple256
    check decoded.nullCount == 255

  test "BinaryObjectString serialization/deserialization":
    # Example from MS-NRBF docs:
    # 06 04 00 00 00 11 4F 6E 65 20 4D 69 63 72 6F 73 6F 66 74 20 57 61 79
    # 06 - BinaryObjectString record
    # 04 00 00 00 - objectId = 4
    # 11 - String length = 17
    # Rest is "One Microsoft Way"
    let stringObj = BinaryObjectString(
      recordType: rtBinaryObjectString,
      objectId: 4,
      value: LengthPrefixedString(value: "One Microsoft Way")
    )

    var outStream = memoryOutput()
    writeBinaryObjectString(outStream, stringObj)
    let serialized = outStream.getOutput(seq[byte])

    # Basic validation of the record structure
    check serialized[0] == 0x06'u8  # rtBinaryObjectString
    check serialized[1] == 0x04'u8  # objectId LSB
    check serialized[2] == 0x00'u8
    check serialized[3] == 0x00'u8
    check serialized[4] == 0x00'u8  # objectId MSB 
    check serialized[5] == 0x11'u8  # String length 17

    let inStream = memoryInput(serialized)
    let decoded = readBinaryObjectString(inStream)

    check decoded.recordType == rtBinaryObjectString
    check decoded.objectId == 4
    check decoded.value.value == "One Microsoft Way"

  test "Invalid MemberReference ID":
    let reference = MemberReference(
      recordType: rtMemberReference,
      idRef: 0  # Invalid - must be positive
    )

    var outStream = memoryOutput()
    expect ValueError:
      writeMemberReference(outStream, reference)

  test "Invalid primitive types":
    let invalidMember = MemberPrimitiveTyped(
      recordType: rtMemberPrimitiveTyped,
      value: PrimitiveValue(kind: ptString)  # String not allowed
    )

    var outStream = memoryOutput()
    expect ValueError:
      writeMemberPrimitiveTyped(outStream, invalidMember)

  test "Complex primitive values":
    let testCases = [
      PrimitiveValue(kind: ptBoolean, boolVal: true),
      PrimitiveValue(kind: ptByte, byteVal: 255),
      PrimitiveValue(kind: ptInt64, int64Val: 1234567890),
      PrimitiveValue(kind: ptSingle, singleVal: 3.14'f32),
      PrimitiveValue(kind: ptDouble, doubleVal: 2.71828),
      PrimitiveValue(kind: ptTimeSpan, timeSpanVal: 36000000000) # 1 hour
    ]

    for testValue in testCases:
      let member = MemberPrimitiveTyped(
        recordType: rtMemberPrimitiveTyped,
        value: testValue
      )

      var outStream = memoryOutput()
      writeMemberPrimitiveTyped(outStream, member)
      let serialized = outStream.getOutput(seq[byte])

      let inStream = memoryInput(serialized)
      let decoded = readMemberPrimitiveTyped(inStream)

      check decoded.recordType == rtMemberPrimitiveTyped
      check decoded.value.kind == testValue.kind

      # Compare actual values based on type
      case testValue.kind
      of ptBoolean: check decoded.value.boolVal == testValue.boolVal
      of ptByte: check decoded.value.byteVal == testValue.byteVal
      of ptInt64: check decoded.value.int64Val == testValue.int64Val
      of ptSingle: check decoded.value.singleVal == testValue.singleVal
      of ptDouble: check decoded.value.doubleVal == testValue.doubleVal
      of ptTimeSpan: check decoded.value.timeSpanVal == testValue.timeSpanVal
      else: discard

suite "SerializationContext Tests":
  test "SerializationContext assigns unique IDs":
    let ctx = newSerializationContext()
    
    # Create two different records as BinaryObjectString
    let str1 = BinaryObjectString(
      recordType: rtBinaryObjectString,
      value: LengthPrefixedString(value: "String 1")
    )
    let record1 = ReferenceableRecord(kind: rtBinaryObjectString, stringRecord: str1)
    let id1 = ctx.assignId(record1)
    
    let str2 = BinaryObjectString(
      recordType: rtBinaryObjectString,
      value: LengthPrefixedString(value: "String 2")
    )
    let record2 = ReferenceableRecord(kind: rtBinaryObjectString, stringRecord: str2)
    let id2 = ctx.assignId(record2)
    
    check:
      id1 != id2
      id1 > 0
      id2 > 0
  
  test "SerializationContext ensures consistent IDs for same record":
    let ctx = newSerializationContext()
    
    # Create a record and wrap it
    let array = ArraySingleObject(
      recordType: rtArraySingleObject,
      arrayInfo: ArrayInfo(length: 3)
    )
    let arrayRecord = ArrayRecord(
      kind: rtArraySingleObject, 
      arraySingleObject: array
    )
    let record = ReferenceableRecord(
      kind: rtArraySingleObject, 
      arrayRecord: arrayRecord
    )
    
    # First assign ID
    let id1 = ctx.assignId(record)
    
    # Request ID again - should return the same ID
    let id2 = ctx.assignId(record)
    
    check:
      id1 == id2
      id1 > 0
  
  test "Message serialization with context works":
    let ctx = newSerializationContext()
    
    # Create a message
    let call = methodCallBasic("TestMethod", "TestClass")
    let msg = newRemotingMessage(ctx, methodCall = some(call))
    
    # Serializing should not raise exceptions
    let bytes = serializeRemotingMessage(msg, ctx)
    check bytes.len > 0
    
    # Try to deserialize (should succeed)
    let result = deserializeRemotingMessage(bytes)
    check result.methodCall.isSome