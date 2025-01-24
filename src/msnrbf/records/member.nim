import faststreams/[inputs, outputs]
import ../enums
import ../types

type
  PrimitiveValue* = object
    case kind*: PrimitiveType  # Type tag for the value
    of ptBoolean:
      boolVal*: bool
    of ptByte:
      byteVal*: uint8
    of ptChar:
      charVal*: string # UTF-8 encoded char
    of ptDouble:
      doubleVal*: float64
    of ptInt16:
      int16Val*: int16
    of ptUInt16:
      uint16Val*: uint16
    of ptInt32:
      int32Val*: int32
    of ptUInt32:
      uint32Val*: uint32
    of ptInt64:  
      int64Val*: int64
    of ptUInt64:
      uint64Val*: uint64
    of ptSByte:
      sbyteVal*: int8
    of ptSingle:
      singleVal*: float32
    of ptTimeSpan:
      timeSpanVal*: TimeSpan
    of ptDateTime:
      dateTimeVal*: DateTime
    of ptDecimal:
      decimalVal*: Decimal
    else:
      discard # String, Null and Unused not valid for primitive values

  MemberPrimitiveTyped* = object
    ## Section 2.5.1 MemberPrimitiveTyped record
    ## Contains a Primitive Type value other than String
    recordType*: RecordType   # Must be rtMemberPrimitiveTyped 
    value*: PrimitiveValue    # Strongly typed value

  MemberPrimitiveUnTyped* = object
    ## Section 2.5.2 MemberPrimitiveUnTyped record
    ## Most compact record for Primitive Types
    ## No record type enum needed as type is known from context
    value*: PrimitiveValue

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
proc readPrimitiveValue*(inp: InputStream, primitiveType: PrimitiveType): PrimitiveValue =
  result = PrimitiveValue(kind: primitiveType)
  case primitiveType
  of ptBoolean:
    let b = inp.read
    result.boolVal = b != 0
  of ptByte:
    result.byteVal = uint8(inp.read)
  of ptChar:
    result.charVal = readChar(inp)
  of ptDouble:
    result.doubleVal = readDouble(inp)
  of ptInt16:
    result.int16Val = readValue[int16](inp)
  of ptUInt16: 
    result.uint16Val = readValue[uint16](inp)
  of ptInt32:
    result.int32Val = readValue[int32](inp)
  of ptUInt32:
    result.uint32Val = readValue[uint32](inp)
  of ptInt64:
    result.int64Val = readValue[int64](inp)
  of ptUInt64:
    result.uint64Val = readValue[uint64](inp)
  of ptSByte:
    result.sbyteVal = cast[int8](inp.read)
  of ptSingle:
    result.singleVal = readSingle(inp)
  of ptTimeSpan:
    result.timeSpanVal = readTimeSpan(inp)
  of ptDateTime:
    result.dateTimeVal = readDateTime(inp)
  of ptDecimal:
    result.decimalVal = readDecimal(inp)
  else:
    raise newException(IOError, "Invalid primitive type: " & $primitiveType)

proc readMemberPrimitiveTyped*(inp: InputStream): MemberPrimitiveTyped =
  ## Reads MemberPrimitiveTyped record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtMemberPrimitiveTyped:
    raise newException(IOError, "Invalid member primitive typed record type")

  if not inp.readable:
    raise newException(IOError, "Missing primitive type")
  let primitiveType = PrimitiveType(inp.read)

  # Validate primitive type
  if primitiveType in {ptString, ptNull, ptUnused}:
    raise newException(IOError, "Invalid primitive type: " & $primitiveType)

  result.value = readPrimitiveValue(inp, primitiveType)

proc readMemberPrimitiveUnTyped*(inp: InputStream, primitiveType: PrimitiveType): MemberPrimitiveUnTyped =
  ## Reads MemberPrimitiveUnTyped record from stream
  ## Primitive type must be provided from context
  if primitiveType in {ptString, ptNull, ptUnused}:
    raise newException(IOError, "Invalid primitive type: " & $primitiveType)

  result.value = readPrimitiveValue(inp, primitiveType)

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
proc writePrimitiveValue*(outp: OutputStream, value: PrimitiveValue) =
  case value.kind
  of ptBoolean:
    outp.write(byte(ord(value.boolVal)))
  of ptByte:
    outp.write(byte(value.byteVal))
  of ptChar:
    writeChar(outp, value.charVal)
  of ptDouble:
    writeDouble(outp, value.doubleVal)
  of ptInt16:
    writeValue[int16](outp, value.int16Val)
  of ptUInt16:
    writeValue[uint16](outp, value.uint16Val)
  of ptInt32:
    writeValue[int32](outp, value.int32Val)
  of ptUInt32:
    writeValue[uint32](outp, value.uint32Val)
  of ptInt64:
    writeValue[int64](outp, value.int64Val)
  of ptUInt64:
    writeValue[uint64](outp, value.uint64Val)
  of ptSByte:
    outp.write(byte(value.sbyteVal))
  of ptSingle:
    writeSingle(outp, value.singleVal) 
  of ptTimeSpan:
    writeTimeSpan(outp, value.timeSpanVal)
  of ptDateTime:
    writeDateTime(outp, value.dateTimeVal)
  of ptDecimal:
    writeDecimal(outp, value.decimalVal)
  else:
    raise newException(ValueError, "Invalid primitive type: " & $value.kind)

proc writeMemberPrimitiveTyped*(outp: OutputStream, member: MemberPrimitiveTyped) =
  ## Writes MemberPrimitiveTyped record to stream
  if member.recordType != rtMemberPrimitiveTyped:
    raise newException(ValueError, "Invalid member primitive typed record type")

  writeRecord(outp, member.recordType)
  outp.write(byte(member.value.kind))
  writePrimitiveValue(outp, member.value)

proc writeMemberPrimitiveUnTyped*(outp: OutputStream, member: MemberPrimitiveUnTyped) =
  ## Writes MemberPrimitiveUnTyped record to stream
  ## Type comes from the PrimitiveValue variant
  writePrimitiveValue(outp, member.value)

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
proc canWriteUntyped*(value: PrimitiveValue): bool =
  ## Returns true if the primitive value can be written in untyped format
  ## This requires:
  ## 1. Fixed size type (not Decimal)
  ## 2. Not String, Null or Unused type
  case value.kind
  of ptString, ptNull, ptUnused:
    false
  of ptDecimal:
    false  # Variable length
  else:
    true   # All other primitive types are fixed size

proc canWriteUntyped*(member: MemberPrimitiveTyped): bool =
  ## Helper that works directly with MemberPrimitiveTyped
  canWriteUntyped(member.value)
