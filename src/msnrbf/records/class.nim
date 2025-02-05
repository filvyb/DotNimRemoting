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
  result.objectId = readValueWithContext[int32](inp, "reading object ID for ClassInfo")
  let nameStr = readLengthPrefixedString(inp)
  result.name = nameStr
  
  result.memberCount = readValueWithContext[int32](inp, "reading member count for ClassInfo")
  
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

proc readAdditionalTypeInfo*(inp: InputStream, btype: BinaryType): AdditionalTypeInfo =
  ## Reads AdditionalTypeInfo structure from stream based on BinaryType
  ## As specified in MS-NRBF section 2.3.1.2 MemberTypeInfo
  result = AdditionalTypeInfo(kind: btype)
  
  case btype
  of btPrimitive, btPrimitiveArray:
    # For primitive types, read the PrimitiveTypeEnum value
    if not inp.readable:
      raise newException(IOError, "Missing primitive type info")
    result.primitiveType = PrimitiveType(inp.read())
    
    # Validate primitive type - String and Null are not valid here
    if result.primitiveType in {ptString, ptNull}:
      raise newException(IOError, "Invalid primitive type: " & $result.primitiveType)
      
  of btSystemClass:
    # System class requires just the class name as string
    result.className = readLengthPrefixedString(inp)
    
  of btClass:
    # Regular class requires ClassTypeInfo with name and library ID
    result.classInfo = readClassTypeInfo(inp)
    
  of btString, btObject, btObjectArray, btStringArray:
    # These types don't require additional info
    discard

proc writeAdditionalTypeInfo*(outp: OutputStream, info: AdditionalTypeInfo) =
  ## Writes AdditionalTypeInfo structure to stream
  ## The BinaryType determines what additional data needs to be written
  
  case info.kind
  of btPrimitive, btPrimitiveArray:
    # Validate primitive type before writing
    if info.primitiveType in {ptString, ptNull}:
      raise newException(ValueError, "Invalid primitive type: " & $info.primitiveType)
    outp.write(byte(info.primitiveType))
    
  of btSystemClass:
    # Write length-prefixed class name
    writeLengthPrefixedString(outp, info.className.value)
    
  of btClass:
    # Write complete ClassTypeInfo structure
    writeClassTypeInfo(outp, info.classInfo)
    
  of btString, btObject, btObjectArray, btStringArray:
    # No additional data to write
    discard

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
    let addInfo = readAdditionalTypeInfo(inp, btype)      
    result.additionalInfos.add(addInfo)

proc writeMemberTypeInfo*(outp: OutputStream, mti: MemberTypeInfo) =
  ## Writes MemberTypeInfo structure to stream
  
  # Write binary types first
  for btype in mti.binaryTypes:
    outp.write(byte(btype))
    
  # Write additional type info where needed
  for addInfo in mti.additionalInfos:
    writeAdditionalTypeInfo(outp, addInfo)

proc readClassWithMembersAndTypes*(inp: InputStream): ClassWithMembersAndTypes =
  ## Reads ClassWithMembersAndTypes record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtClassWithMembersAndTypes:
    raise newException(IOError, "Invalid record type")
    
  result.classInfo = readClassInfo(inp)
  result.memberTypeInfo = readMemberTypeInfo(inp, result.classInfo.memberCount)
  
  result.libraryId = readValueWithContext[int32](inp, "reading library ID for ClassWithMembersAndTypes")

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
  
  result.libraryId = readValueWithContext[int32](inp, "reading library ID for ClassWithMembers")

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
    
  #if not inp.readable(8): # Need 8 bytes for IDs
  #  raise newException(IOError, "Missing IDs")
    
  result.objectId = readValueWithContext[int32](inp, "reading object ID for ClassWithId")
  result.metadataId = readValueWithContext[int32](inp, "reading metadata ID for ClassWithId")

proc writeClassWithId*(outp: OutputStream, obj: ClassWithId) =
  ## Writes ClassWithId record to stream
  writeRecord(outp, obj.recordType)
  outp.write(cast[array[4, byte]](obj.objectId))
  outp.write(cast[array[4, byte]](obj.metadataId))
