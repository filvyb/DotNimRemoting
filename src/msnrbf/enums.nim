import faststreams/[inputs, outputs]

type
  RecordType* = enum
    ## Section 2.1.2.1 RecordTypeEnumeration
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
    ## Section 2.1.2.2 BinaryTypeEnumeration  
    btPrimitive = 0      # Primitive type (not string)
    btString = 1         # LengthPrefixedString
    btObject = 2         # System.Object
    btSystemClass = 3    # Class in System Library
    btClass = 4          # Class not in System Library
    btObjectArray = 5    # Single-dim Array of System.Object, lower bound 0
    btStringArray = 6    # Single-dim Array of String, lower bound 0
    btPrimitiveArray = 7 # Single-dim Array of primitive type, lower bound 0

  PrimitiveType* = enum
    ## Section 2.1.2.3 PrimitiveTypeEnumeration
    ptBoolean = 1 # Boolean
    ptByte = 2 # unsigned 8-bit
    ptChar = 3 # Unicode character
    ptUnused = 4 # Unused
    ptDecimal = 5 # LengthPrefixedString
    ptDouble = 6 # IEEE 754 64-bit
    ptInt16 = 7 # signed 16-bit
    ptInt32 = 8 # signed 32-bit
    ptInt64 = 9 # signed 64-bit
    ptSByte = 10 # signed 8-bit integer
    ptSingle = 11 # IEEE 754 32-bit
    ptTimeSpan = 12 # 64-bit integer count of 100-nanosecond intervals
    ptDateTime = 13 # read spec
    ptUInt16 = 14 # unsigned 16-bit
    ptUInt32 = 15 # unsigned 32-bit
    ptUInt64 = 16 # unsigned 64-bit
    ptNull = 17 # null object
    ptString = 18 # LengthPrefixedString

proc readRecord*(inp: InputStream): RecordType =
  ## Reads record type from stream
  if inp.readable:
    result = RecordType(inp.read())

proc writeRecord*(outp: OutputStream, rt: RecordType) =
  ## Writes record type to stream
  outp.write(byte(rt))
