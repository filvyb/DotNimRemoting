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

  ClassInfo* = object
    ## ClassInfo as specified in MS-NRBF section 2.3.1.1
    objectId*: int32      # Unique identifier 
    name*: LengthPrefixedString  # Class name
    memberCount*: int32   # Number of members
    memberNames*: seq[LengthPrefixedString] # Names of members

  MemberTypeInfo* = object
    ## MemberTypeInfo as specified in MS-NRBF section 2.3.1.2
    binaryTypes*: seq[BinaryType]      # Types of members
    additionalInfos*: seq[PrimitiveType] # Additional type info where needed

  ClassWithMembersAndTypes* = object
    ## Section 2.3.2.1 ClassWithMembersAndTypes record
    ## The most verbose class record containing class metadata, 
    ## member types and library reference
    recordType*: RecordType     # Must be rtClassWithMembersAndTypes
    classInfo*: ClassInfo       # Class name and members info
    memberTypeInfo*: MemberTypeInfo # Member types info  
    libraryId*: int32          # Reference to library

  ClassWithMembers* = object
    ## Section 2.3.2.2 ClassWithMembers record
    ## Less verbose - no member type information
    recordType*: RecordType     # Must be rtClassWithMembers  
    classInfo*: ClassInfo       # Class info
    libraryId*: int32          # Library reference

  SystemClassWithMembersAndTypes* = object
    ## Section 2.3.2.3 SystemClassWithMembersAndTypes record
    ## For system library classes, so no library ID needed
    recordType*: RecordType     # Must be rtSystemClassWithMembersAndTypes
    classInfo*: ClassInfo       # Class info
    memberTypeInfo*: MemberTypeInfo # Member types

  SystemClassWithMembers* = object
    ## Section 2.3.2.4 SystemClassWithMembers record
    ## For system library classes without member type information
    recordType*: RecordType     # Must be rtSystemClassWithMembers
    classInfo*: ClassInfo       # Class info without member types

  ClassWithId* = object  
    ## Section 2.3.2.5 ClassWithId record
    ## Most compact - references metadata defined in other records
    recordType*: RecordType     # Must be rtClassWithId
    objectId*: int32           # Unique object ID
    metadataId*: int32        # Reference to existing class metadata

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

proc readClassInfo*(inp: InputStream): ClassInfo =
  ## Reads ClassInfo structure from stream
  if not inp.readable(8): # Need at least 8 bytes for objectId and memberCount
    raise newException(IOError, "Incomplete ClassInfo data")
  
  result.objectId = cast[int32](inp.read(4))
  let nameStr = readLengthPrefixedString(inp)
  result.name = nameStr
  
  result.memberCount = cast[int32](inp.read(4))
  
  # Read member names
  for i in 0..<result.memberCount:
    result.memberNames.add(readLengthPrefixedString(inp))

proc writeClassInfo*(outp: OutputStream, ci: ClassInfo) =
  ## Writes ClassInfo structure to stream
  outp.write(cast[array[4, byte]](ci.objectId))
  writeLengthPrefixedString(outp, ci.name.value)
  outp.write(cast[array[4, byte]](ci.memberCount))
  
  # Write member names
  for name in ci.memberNames:
    writeLengthPrefixedString(outp, name.value)

proc readMemberTypeInfo*(inp: InputStream, memberCount: int): MemberTypeInfo =
  ## Reads MemberTypeInfo structure from stream.
  ## memberCount specifies number of members to read types for.
  
  # Read binary types first
  for i in 0..<memberCount:
    if not inp.readable:
      raise newException(IOError, "Incomplete MemberTypeInfo data")
    result.binaryTypes.add(BinaryType(inp.read()))

  # Read additional info for types that need it
  for btype in result.binaryTypes:
    case btype
    of btPrimitive, btPrimitiveArray:
      if not inp.readable:
        raise newException(IOError, "Missing primitive type info")
      result.additionalInfos.add(PrimitiveType(inp.read()))
    else:
      # Other types don't need additional info
      result.additionalInfos.add(ptNull)

proc writeMemberTypeInfo*(outp: OutputStream, mti: MemberTypeInfo) =
  ## Writes MemberTypeInfo structure to stream
  # Write binary types
  for btype in mti.binaryTypes:
    outp.write(byte(btype))
    
  # Write additional type info
  for i, addInfo in mti.additionalInfos:
    if mti.binaryTypes[i] in {btPrimitive, btPrimitiveArray}:
      outp.write(byte(addInfo))

proc readClassWithMembersAndTypes*(inp: InputStream): ClassWithMembersAndTypes =
  ## Reads ClassWithMembersAndTypes record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtClassWithMembersAndTypes:
    raise newException(IOError, "Invalid record type")
    
  result.classInfo = readClassInfo(inp)
  result.memberTypeInfo = readMemberTypeInfo(inp, result.classInfo.memberCount)
  
  if not inp.readable(4):
    raise newException(IOError, "Missing library ID")
  result.libraryId = cast[int32](inp.read(4))

proc writeClassWithMembersAndTypes*(outp: OutputStream, obj: ClassWithMembersAndTypes) =
  ## Writes ClassWithMembersAndTypes record to stream 
  writeRecord(outp, obj.recordType)
  writeClassInfo(outp, obj.classInfo)
  writeMemberTypeInfo(outp, obj.memberTypeInfo)
  outp.write(cast[array[4, byte]](obj.libraryId))

proc readClassWithMembers*(inp: InputStream): ClassWithMembers =
  ## Reads ClassWithMembers record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtClassWithMembers:
    raise newException(IOError, "Invalid record type")
    
  result.classInfo = readClassInfo(inp)
  
  if not inp.readable(4):
    raise newException(IOError, "Missing library ID")
  result.libraryId = cast[int32](inp.read(4))

proc writeClassWithMembers*(outp: OutputStream, obj: ClassWithMembers) =
  ## Writes ClassWithMembers record to stream
  writeRecord(outp, obj.recordType)
  writeClassInfo(outp, obj.classInfo) 
  outp.write(cast[array[4, byte]](obj.libraryId))

proc readSystemClassWithMembersAndTypes*(inp: InputStream): SystemClassWithMembersAndTypes =
  ## Reads SystemClassWithMembersAndTypes record from stream
  result.recordType = readRecord(inp) 
  if result.recordType != rtSystemClassWithMembersAndTypes:
    raise newException(IOError, "Invalid record type")
    
  result.classInfo = readClassInfo(inp)
  result.memberTypeInfo = readMemberTypeInfo(inp, result.classInfo.memberCount)

proc writeSystemClassWithMembersAndTypes*(outp: OutputStream, obj: SystemClassWithMembersAndTypes) =
  ## Writes SystemClassWithMembersAndTypes record to stream
  writeRecord(outp, obj.recordType)
  writeClassInfo(outp, obj.classInfo)
  writeMemberTypeInfo(outp, obj.memberTypeInfo)

proc readSystemClassWithMembers*(inp: InputStream): SystemClassWithMembers =
  ## Reads SystemClassWithMembers record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtSystemClassWithMembers:
    raise newException(IOError, "Invalid record type")
    
  result.classInfo = readClassInfo(inp)

proc writeSystemClassWithMembers*(outp: OutputStream, obj: SystemClassWithMembers) =
  ## Writes SystemClassWithMembers record to stream
  writeRecord(outp, obj.recordType)
  writeClassInfo(outp, obj.classInfo)
  
proc readClassWithId*(inp: InputStream): ClassWithId =
  ## Reads ClassWithId record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtClassWithId:
    raise newException(IOError, "Invalid record type")
    
  if not inp.readable(8): # Need 8 bytes for IDs
    raise newException(IOError, "Missing IDs")
    
  result.objectId = cast[int32](inp.read(4))
  result.metadataId = cast[int32](inp.read(4))

proc writeClassWithId*(outp: OutputStream, obj: ClassWithId) =
  ## Writes ClassWithId record to stream
  writeRecord(outp, obj.recordType)
  outp.write(cast[array[4, byte]](obj.objectId))
  outp.write(cast[array[4, byte]](obj.metadataId))
