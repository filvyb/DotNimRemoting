import faststreams/[inputs, outputs]

type
  RecordType* = enum
    # Section 2.1.2.1 RecordTypeEnumeration
    rtSerializedStreamHeader = 0  # 0x00
    rtClassWithId = 1             # 0x01  
    rtSystemClassWithMembers = 2  # 0x02
    rtClassWithMembers = 3        # 0x03
    rtSystemClassWithMembersAndTypes = 4  # 0x04
    rtClassWithMembersAndTypes = 5 # 0x05
    rtBinaryObjectString = 6      # 0x06
    rtBinaryArray = 7             # 0x07
    rtMemberPrimitiveTyped = 8    # 0x08
    rtMemberReference = 9         # 0x09
    rtObjectNull = 10             # 0x0A
    rtMessageEnd = 11             # 0x0B
    rtBinaryLibrary = 12          # 0x0C
    rtObjectNullMultiple256 = 13  # 0x0D
    rtObjectNullMultiple = 14     # 0x0E
    rtArraySinglePrimitive = 15   # 0x0F
    rtArraySingleObject = 16      # 0x10
    rtArraySingleString = 17      # 0x11
    rtMethodCall = 21             # 0x15
    rtMethodReturn = 22           # 0x16

  BinaryType* = enum
    # Section 2.1.2.2 BinaryTypeEnumeration  
    btPrimitive = 0      # Primitive type (not string)
    btString = 1         # LengthPrefixedString
    btObject = 2         # System.Object
    btSystemClass = 3    # Class in System Library
    btClass = 4          # Class not in System Library
    btObjectArray = 5    # Single-dim Array of System.Object, lower bound 0
    btStringArray = 6    # Single-dim Array of String, lower bound 0
    btPrimitiveArray = 7 # Single-dim Array of primitive type, lower bound 0

  PrimitiveType* = enum
    # Section 2.1.2.3 PrimitiveTypeEnumeration
    ptBoolean = 1
    ptByte = 2
    ptChar = 3
    ptUnused = 4
    ptDecimal = 5
    ptDouble = 6
    ptInt16 = 7
    ptInt32 = 8
    ptInt64 = 9
    ptSByte = 10
    ptSingle = 11
    ptTimeSpan = 12
    ptDateTime = 13
    ptUInt16 = 14
    ptUInt32 = 15 
    ptUInt64 = 16
    ptNull = 17
    ptString = 18

proc readRecord*(inp: InputStream): RecordType =
  ## Reads record type from stream
  if inp.readable:
    result = RecordType(inp.read())

proc writeRecord*(outp: OutputStream, rt: RecordType) =
  ## Writes record type to stream
  outp.write(byte(rt))

# Implementation of LengthPrefixedString as described in [MS-NRBF] section 2.1.1.6

type
  LengthPrefixedString* = object
    value*: string

proc readLengthPrefixedString*(inp: InputStream): LengthPrefixedString =
  ## Reads a length-prefixed string from stream using variable length encoding
  var length = 0
  var shift = 0
  
  # Read 7 bits at a time until high bit is 0
  while inp.readable:
    let b = inp.read
    length = length or ((int(b and 0x7F)) shl shift)
    if (b and 0x80) == 0:
      break
    shift += 7
    if shift > 35:
      raise newException(IOError, "Invalid string length encoding")

  # Read the actual string data
  if length > 0:
    var buffer = newString(length)
    if inp.readInto(buffer.toOpenArrayByte(0, length-1)):
      result.value = buffer
    else:
      raise newException(IOError, "Incomplete string data")

proc writeLengthPrefixedString*(outp: OutputStream, s: string) =
  ## Writes a length-prefixed string to stream using variable length encoding
  var length = s.len
  
  # Write length using 7 bits per byte with high bit indicating continuation
  while length >= 0x80:
    outp.write(byte((length and 0x7F) or 0x80))
    length = length shr 7
  outp.write(byte(length))

  # Write string data
  if length > 0:
    outp.write(s)
