import tables
import hashes
import enums
import records/arrays
import records/class
import records/serialization

type
  ClassRecord* = ref object
    ## Union of all possible class records
    case kind*: RecordType
    of rtClassWithId:
      classWithId*: ClassWithId
    of rtSystemClassWithMembers:
      systemClassWithMembers*: SystemClassWithMembers 
    of rtClassWithMembers:
      classWithMembers*: ClassWithMembers
    of rtSystemClassWithMembersAndTypes:
      systemClassWithMembersAndTypes*: SystemClassWithMembersAndTypes
    of rtClassWithMembersAndTypes:  
      classWithMembersAndTypes*: ClassWithMembersAndTypes
    else:
      discard

  ArrayRecord* = ref object
    ## Union of all possible array records  
    case kind*: RecordType
    of rtBinaryArray:
      binaryArray*: BinaryArray
    of rtArraySinglePrimitive:
      arraySinglePrimitive*: ArraySinglePrimitive
    of rtArraySingleObject:  
      arraySingleObject*: ArraySingleObject
    of rtArraySingleString:
      arraySingleString*: ArraySingleString
    else:
      discard

  ClassMetadataInfo* = object
    ## Member layout of a metadata-bearing class record (SystemClassWithMembers,
    ## SystemClassWithMembersAndTypes, ClassWithMembers, ClassWithMembersAndTypes).
    ## Needed to read/write the member values of ClassWithId records, which carry
    ## no metadata of their own (Section 2.3.2.5)
    memberCount*: int32
    hasTypeInfo*: bool             # True for the ...AndTypes record variants
    memberTypeInfo*: MemberTypeInfo

  ReferenceContext* = ref object
    ## Tracks object references during deserialization
    libraries*: Table[int32, BinaryLibrary]     # Maps library IDs to libraries
    classMetadata*: Table[int32, ClassMetadataInfo] # Maps class record object IDs to their metadata


proc addLibrary*(ctx: ReferenceContext, lib: BinaryLibrary) =
  ## Track a new library reference
  if lib.libraryId in ctx.libraries:
    raise newException(IOError, "Duplicate library ID: " & $lib.libraryId)
  ctx.libraries[lib.libraryId] = lib


proc getLibrary*(ctx: ReferenceContext, id: int32): BinaryLibrary =
  ## Look up referenced library
  if id notin ctx.libraries:
    raise newException(IOError, "Missing library reference: " & $id)
  result = ctx.libraries[id]

proc addClassMetadata*(ctx: ReferenceContext, objectId: int32, info: ClassMetadataInfo) =
  ## Track the metadata of a class record so later ClassWithId records can
  ## reference it by object ID
  ctx.classMetadata[objectId] = info

proc getClassMetadata*(ctx: ReferenceContext, id: int32): ClassMetadataInfo =
  ## Look up class metadata referenced by a ClassWithId record's MetadataId.
  ## The referenced record must appear earlier in the stream (Section 2.3.2.5)
  if id notin ctx.classMetadata:
    raise newException(IOError, "Missing class metadata reference: " & $id)
  result = ctx.classMetadata[id]

proc newReferenceContext*(): ReferenceContext =
  ReferenceContext(
    libraries: initTable[int32, BinaryLibrary](),
    classMetadata: initTable[int32, ClassMetadataInfo]()
  )


type
  SerializationContext* = ref object
    ## Manages object ID assignment during serialization, tracking objects by memory address
    nextId*: int32                               # Counter for generating new IDs, starts at 1
    assignedIds*: Table[int, int32]             # Maps object memory addresses to their assigned IDs
    writtenObjects*: Table[int, int32]          # Maps object memory addresses to their assigned IDs for objects that have been written
    writtenClassMetadata*: Table[int32, tuple[newId: int32, info: ClassMetadataInfo]]
      # Maps the original object ID of written class records to their newly
      # assigned ID and metadata, so ClassWithId records can be remapped

proc newSerializationContext*(): SerializationContext =
  ## Creates a new SerializationContext with an initial ID of 1
  SerializationContext(
    nextId: 1,
    assignedIds: initTable[int, int32](),
    writtenObjects: initTable[int, int32](),
    writtenClassMetadata: initTable[int32, tuple[newId: int32, info: ClassMetadataInfo]]()
  )

proc `$`*(ctx: ReferenceContext): string =
  result = "ReferenceContext(" & $ctx.libraries.len() & " libraries)"

proc `$`*(ctx: SerializationContext): string =
  result = "SerializationContext(\n" &
           "  nextId: " & $ctx.nextId & ",\n" &
           "  assignedIds: {\n"
      
  # Show all assigned IDs
  for ptrVal, id in ctx.assignedIds.pairs():
    result.add("    " & $ptrVal & " => " & $id & ",\n")
      
  result.add("  },\n  writtenObjects: {\n")
      
  # Show all written object pointers and their IDs
  for ptrVal, id in ctx.writtenObjects.pairs():
    result.add("    " & $ptrVal & " => " & $id & ",\n")
      
  result.add("  }\n)")

proc hasAssignedId*(ctx: SerializationContext, obj: pointer): bool =
  ## Check if an object pointer has been assigned an ID
  let key = cast[int](obj)
  return ctx.assignedIds.hasKey(key)

proc getAssignedId*(ctx: SerializationContext, obj: pointer): int32 =
  ## Get the assigned ID for an object pointer
  let key = cast[int](obj)
  return ctx.assignedIds[key]

proc setAssignedId*(ctx: SerializationContext, obj: pointer, id: int32) =
  ## Store an object pointer and its assigned ID
  let key = cast[int](obj)
  ctx.assignedIds[key] = id

proc hasWrittenObject*(ctx: SerializationContext, obj: pointer): bool =
  ## Check if an object pointer has been written before
  let key = cast[int](obj)
  return ctx.writtenObjects.hasKey(key)

proc getWrittenObjectId*(ctx: SerializationContext, obj: pointer): int32 =
  ## Get the ID for a previously written object pointer
  let key = cast[int](obj)
  return ctx.writtenObjects[key]

proc setWrittenObjectId*(ctx: SerializationContext, obj: pointer, id: int32) =
  ## Store an object pointer and its assigned ID
  let key = cast[int](obj)
  ctx.writtenObjects[key] = id


proc registerWrittenClassMetadata*(ctx: SerializationContext, originalId, newId: int32, info: ClassMetadataInfo) =
  ## Records the metadata of a class record that was written to the stream,
  ## keyed by its original object ID, so later ClassWithId records can resolve
  ## their MetadataId and have it remapped to the newly assigned ID.
  ## Records without a meaningful original ID (0) are not registered.
  if originalId != 0:
    ctx.writtenClassMetadata[originalId] = (newId: newId, info: info)

proc hasWrittenClassMetadata*(ctx: SerializationContext, originalId: int32): bool =
  ## Check if class metadata with the given original object ID has been written
  ctx.writtenClassMetadata.hasKey(originalId)

proc getWrittenClassMetadata*(ctx: SerializationContext, originalId: int32): tuple[newId: int32, info: ClassMetadataInfo] =
  ## Get the newly assigned ID and metadata for a previously written class record
  ctx.writtenClassMetadata[originalId]

proc assignIdForPointer*(ctx: SerializationContext, objPtr: pointer): int32 =
  ## Assigns the next available ID for a given object pointer if not already assigned.
  ## This assigns an ID and marks the object as written in one step.
  if ctx.hasWrittenObject(objPtr):
    return ctx.getWrittenObjectId(objPtr)
  else:
    let id = ctx.nextId
    ctx.nextId += 1
    ctx.setAssignedId(objPtr, id)
    ctx.setWrittenObjectId(objPtr, id)
    return id
