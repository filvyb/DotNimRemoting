import faststreams/[inputs, outputs]
import ../types
import ../enums

type
  ClassInfo* = object
    ## ClassInfo as specified in MS-NRBF section 2.3.1.1
    objectId*: int32      # Unique identifier 
    name*: LengthPrefixedString  # Class name
    memberCount*: int32   # Number of members
    memberNames*: seq[LengthPrefixedString] # Names of members

  AdditionalTypeInfo* = object
    ## Helper structure for MemberTypeInfo
    case kind*: BinaryType
    of btPrimitive, btPrimitiveArray:
      primitiveType*: PrimitiveType
    of btSystemClass:
      className*: LengthPrefixedString  
    of btClass:
      classInfo*: ClassTypeInfo
    else:
      discard
      
  MemberTypeInfo* = object
    ## Section 2.3.1.2 MemberTypeInfo structure
    ## Contains type information for Class Members
    binaryTypes*: seq[BinaryType]           # Types of members
    additionalInfos*: seq[AdditionalTypeInfo] # Additional type info where needed

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

proc readClassInfo*(inp: InputStream): ClassInfo =
  ## Reads ClassInfo structure from stream
  if not inp.readable(8): # Need at least 8 bytes for objectId and memberCount
    raise newException(IOError, "Incomplete ClassInfo data")
  
  result.objectId = cast[ptr int32](inp.read(4)[0].addr)[]
  let nameStr = readLengthPrefixedString(inp)
  result.name = nameStr
  
  result.memberCount = cast[ptr int32](inp.read(4)[0].addr)[]
  
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
  
  # First read all binary types
  for i in 0..<memberCount:
    if not inp.readable:
      raise newException(IOError, "Incomplete MemberTypeInfo data")
    result.binaryTypes.add(BinaryType(inp.read()))

  # Then read additional info based on binary type
  for btype in result.binaryTypes:
    var addInfo = AdditionalTypeInfo(kind: btype)
    
    case btype
    of btPrimitive, btPrimitiveArray:
      if not inp.readable:
        raise newException(IOError, "Missing primitive type info")
      addInfo.primitiveType = PrimitiveType(inp.read())
      
    of btSystemClass:
      addInfo.className = readLengthPrefixedString(inp)
      
    of btClass:
      addInfo.classInfo = readClassTypeInfo(inp)
      
    of btString, btObject, btObjectArray, btStringArray:
      discard # No additional info needed
      
    result.additionalInfos.add(addInfo)

proc writeMemberTypeInfo*(outp: OutputStream, mti: MemberTypeInfo) =
  ## Writes MemberTypeInfo structure to stream
  
  # Write binary types first
  for btype in mti.binaryTypes:
    outp.write(byte(btype))
    
  # Write additional type info where needed
  for addInfo in mti.additionalInfos:
    case addInfo.kind
    of btPrimitive, btPrimitiveArray:
      outp.write(byte(addInfo.primitiveType))
      
    of btSystemClass:
      writeLengthPrefixedString(outp, addInfo.className.value)
      
    of btClass:
      writeClassTypeInfo(outp, addInfo.classInfo)
      
    else:
      discard # No additional info to write

proc readClassWithMembersAndTypes*(inp: InputStream): ClassWithMembersAndTypes =
  ## Reads ClassWithMembersAndTypes record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtClassWithMembersAndTypes:
    raise newException(IOError, "Invalid record type")
    
  result.classInfo = readClassInfo(inp)
  result.memberTypeInfo = readMemberTypeInfo(inp, result.classInfo.memberCount)
  
  if not inp.readable(4):
    raise newException(IOError, "Missing library ID")
  result.libraryId = cast[ptr int32](inp.read(4)[0].addr)[]

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
  result.libraryId = cast[ptr int32](inp.read(4)[0].addr)[]

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
    
  result.objectId = cast[ptr int32](inp.read(4)[0].addr)[]
  result.metadataId = cast[ptr int32](inp.read(4)[0].addr)[]

proc writeClassWithId*(outp: OutputStream, obj: ClassWithId) =
  ## Writes ClassWithId record to stream
  writeRecord(outp, obj.recordType)
  outp.write(cast[array[4, byte]](obj.objectId))
  outp.write(cast[array[4, byte]](obj.metadataId))
