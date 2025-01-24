import faststreams/[inputs, outputs]
import ../enums
import ../types

type
  MemberPrimitiveTyped* = object
    ## Section 2.5.1 MemberPrimitiveTyped record
    ## Contains a Primitive Type value other than String
    recordType*: RecordType   # Must be rtMemberPrimitiveTyped 
    primitiveType*: PrimitiveType  # Type of value
    value*: seq[byte]  # Raw bytes of the value

  MemberPrimitiveUnTyped* = object
    ## Section 2.5.2 MemberPrimitiveUnTyped record
    ## Most compact record for Primitive Types
    ## No record type enum needed as type is known from context
    value*: seq[byte]  # Raw value bytes

  MemberReference* = object
    ## Section 2.5.3 MemberReference record
    ## Contains reference to another record with actual value
    recordType*: RecordType  # Must be rtMemberReference
    idRef*: int32  # ID of referenced object, must be positive

  ObjectNull* = object
    ## Section 2.5.4 ObjectNull record
    ## Represents Null Object
    recordType*: RecordType  # Must be rtObjectNull

  ObjectNullMultiple* = object
    ## Section 2.5.5 ObjectNullMultiple record
    ## Compact form for multiple consecutive Null records
    recordType*: RecordType  # Must be rtObjectNullMultiple
    nullCount*: int32  # Number of consecutive nulls, must be positive

  ObjectNullMultiple256* = object
    ## Section 2.5.6 ObjectNullMultiple256 record
    ## Most compact form for multiple nulls < 256
    recordType*: RecordType  # Must be rtObjectNullMultiple256
    nullCount*: uint8  # Number of consecutive nulls

  BinaryObjectString* = object
    ## Section 2.5.7 BinaryObjectString record
    ## Identifies a String object
    recordType*: RecordType  # Must be rtBinaryObjectString
    objectId*: int32  # Unique positive ID
    value*: LengthPrefixedString  # String value

proc getPrimitiveTypeSize*(primitiveType: PrimitiveType): Natural =
  ## Returns the size in bytes for fixed-size primitive types
  ## Returns 0 for variable-length or unsupported types
  case primitiveType
  of ptBoolean: 1
  of ptByte: 1
  of ptChar: 1    # UTF-8 encoded char - actual size determined when reading
  of ptDouble: 8
  of ptInt16, ptUInt16: 2
  of ptInt32, ptUInt32: 4
  of ptInt64, ptUInt64: 8
  of ptSByte: 1
  of ptSingle: 4
  of ptTimeSpan: 8
  of ptDateTime: 8
  else: 0

# Reading procedures
proc readMemberPrimitiveTyped*(inp: InputStream): MemberPrimitiveTyped =
  ## Reads MemberPrimitiveTyped record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtMemberPrimitiveTyped:
    raise newException(IOError, "Invalid member primitive typed record type")

  if not inp.readable:
    raise newException(IOError, "Missing primitive type")
  result.primitiveType = PrimitiveType(inp.read)

  # Validate primitive type
  if result.primitiveType in {ptString, ptNull}:
    raise newException(IOError, "Invalid primitive type: " & $result.primitiveType)

  # Read raw value bytes based on primitive type size 
  let valueSize = getPrimitiveTypeSize(result.primitiveType)
  if valueSize > 0:
    result.value = newSeq[byte](valueSize)
    if not inp.readInto(result.value):
      raise newException(IOError, "Failed to read primitive value")

proc readMemberPrimitiveUnTyped*(inp: InputStream, primitiveType: PrimitiveType): MemberPrimitiveUnTyped =
  ## Reads MemberPrimitiveUnTyped record from stream
  ## Primitive type must be provided from context
  if primitiveType in {ptString, ptNull}:
    raise newException(IOError, "Invalid primitive type: " & $primitiveType)

  # Read raw value bytes based on primitive type size
  let valueSize = getPrimitiveTypeSize(primitiveType)
  if valueSize > 0:
    result.value = newSeq[byte](valueSize)
    if not inp.readInto(result.value):
      raise newException(IOError, "Failed to read primitive value")

proc readMemberReference*(inp: InputStream): MemberReference =
  ## Reads MemberReference record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtMemberReference:
    raise newException(IOError, "Invalid member reference record type")

  result.idRef = readValueWithContext[int32](inp, "reading member reference ID")
  if result.idRef <= 0:
    raise newException(IOError, "Member reference ID must be positive")

proc readObjectNull*(inp: InputStream): ObjectNull =
  ## Reads ObjectNull record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtObjectNull:
    raise newException(IOError, "Invalid object null record type")

proc readObjectNullMultiple*(inp: InputStream): ObjectNullMultiple =
  ## Reads ObjectNullMultiple record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtObjectNullMultiple:
    raise newException(IOError, "Invalid object null multiple record type")

  result.nullCount = readValueWithContext[int32](inp, "reading null count")
  if result.nullCount <= 0:
    raise newException(IOError, "Null count must be positive")

proc readObjectNullMultiple256*(inp: InputStream): ObjectNullMultiple256 =
  ## Reads ObjectNullMultiple256 record from stream  
  result.recordType = readRecord(inp)
  if result.recordType != rtObjectNullMultiple256:
    raise newException(IOError, "Invalid object null multiple 256 record type")

  if not inp.readable:
    raise newException(IOError, "Missing null count")
  result.nullCount = uint8(inp.read)

proc readBinaryObjectString*(inp: InputStream): BinaryObjectString =
  ## Reads BinaryObjectString record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtBinaryObjectString:
    raise newException(IOError, "Invalid binary object string record type") 

  result.objectId = readValueWithContext[int32](inp, "reading string object ID")
  if result.objectId <= 0:
    raise newException(IOError, "String object ID must be positive")

  result.value = readLengthPrefixedString(inp)

# Writing procedures
proc writeMemberPrimitiveTyped*(outp: OutputStream, member: MemberPrimitiveTyped) =
  ## Writes MemberPrimitiveTyped record to stream
  if member.recordType != rtMemberPrimitiveTyped:
    raise newException(ValueError, "Invalid member primitive typed record type")

  # Validate primitive type
  if member.primitiveType in {ptString, ptNull}:
    raise newException(ValueError, "Invalid primitive type: " & $member.primitiveType)

  # Validate value size matches primitive type
  let expectedSize = getPrimitiveTypeSize(member.primitiveType)
  if expectedSize > 0 and member.value.len != expectedSize:
    raise newException(ValueError, "Invalid value size for primitive type " & 
                      $member.primitiveType & ": expected " & $expectedSize & 
                      " bytes, got " & $member.value.len)

  writeRecord(outp, member.recordType)
  outp.write(byte(member.primitiveType))
  if member.value.len > 0:
    outp.write(member.value)

proc writeMemberPrimitiveUnTyped*(outp: OutputStream, member: MemberPrimitiveUnTyped, 
                                 primitiveType: PrimitiveType) =
  ## Writes MemberPrimitiveUnTyped record to stream
  ## Primitive type must be provided from context
  if primitiveType in {ptString, ptNull}:
    raise newException(ValueError, "Invalid primitive type: " & $primitiveType)

  # Validate value size matches primitive type
  let expectedSize = getPrimitiveTypeSize(primitiveType)
  if expectedSize > 0 and member.value.len != expectedSize:
    raise newException(ValueError, "Invalid value size for primitive type " & 
                      $primitiveType & ": expected " & $expectedSize & 
                      " bytes, got " & $member.value.len)

  # Write just the value - no record type or type enum needed
  if member.value.len > 0:
    outp.write(member.value)

proc writeMemberReference*(outp: OutputStream, refer: MemberReference) =
  ## Writes MemberReference record to stream
  if refer.recordType != rtMemberReference:
    raise newException(ValueError, "Invalid member reference record type")

  if refer.idRef <= 0:
    raise newException(ValueError, "Member reference ID must be positive")

  writeRecord(outp, refer.recordType)
  outp.write(cast[array[4, byte]](refer.idRef))

proc writeObjectNull*(outp: OutputStream, obj: ObjectNull) =
  ## Writes ObjectNull record to stream
  if obj.recordType != rtObjectNull:
    raise newException(ValueError, "Invalid object null record type")

  writeRecord(outp, obj.recordType)

proc writeObjectNullMultiple*(outp: OutputStream, obj: ObjectNullMultiple) =
  ## Writes ObjectNullMultiple record to stream
  if obj.recordType != rtObjectNullMultiple:
    raise newException(ValueError, "Invalid object null multiple record type")

  if obj.nullCount <= 0:
    raise newException(ValueError, "Null count must be positive")

  writeRecord(outp, obj.recordType)
  outp.write(cast[array[4, byte]](obj.nullCount))

proc writeObjectNullMultiple256*(outp: OutputStream, obj: ObjectNullMultiple256) =
  ## Writes ObjectNullMultiple256 record to stream
  if obj.recordType != rtObjectNullMultiple256:
    raise newException(ValueError, "Invalid object null multiple 256 record type")

  writeRecord(outp, obj.recordType)
  outp.write(byte(obj.nullCount))

proc writeBinaryObjectString*(outp: OutputStream, obj: BinaryObjectString) =
  ## Writes BinaryObjectString record to stream  
  if obj.recordType != rtBinaryObjectString:
    raise newException(ValueError, "Invalid binary object string record type")

  if obj.objectId <= 0:
    raise newException(ValueError, "String object ID must be positive")

  writeRecord(outp, obj.recordType)
  outp.write(cast[array[4, byte]](obj.objectId))
  writeLengthPrefixedString(outp, obj.value.value)

# Helper to determine if a primitive value can be written untyped
proc canWriteUntyped*(value: MemberPrimitiveTyped): bool =
  ## Returns true if the primitive value can be written in untyped format
  ## This requires:
  ## 1. Known fixed size type (not Decimal)
  ## 2. Not String or Null type
  case value.primitiveType
  of ptBoolean, ptByte, ptChar, ptDouble, ptInt16, ptUInt16,
     ptInt32, ptUInt32, ptInt64, ptUInt64, ptSByte, ptSingle,
     ptTimeSpan, ptDateTime:
    result = true
  else:
    result = false
