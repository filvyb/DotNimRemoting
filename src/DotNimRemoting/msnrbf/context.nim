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

  ReferenceContext* = ref object
    ## Tracks object references during deserialization
    libraries*: Table[int32, BinaryLibrary]     # Maps library IDs to libraries


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

proc newReferenceContext*(): ReferenceContext =
  ReferenceContext(
    libraries: initTable[int32, BinaryLibrary]()
  )


type
  SerializationContext* = ref object
    ## Manages object ID assignment during serialization, tracking objects by memory address
    nextId*: int32                               # Counter for generating new IDs, starts at 1
    assignedIds*: Table[int, int32]             # Maps object memory addresses to their assigned IDs
    writtenObjects*: Table[int, int32]          # Maps object memory addresses to their assigned IDs for objects that have been written

proc newSerializationContext*(): SerializationContext =
  ## Creates a new SerializationContext with an initial ID of 1
  SerializationContext(
    nextId: 1,
    assignedIds: initTable[int, int32](),
    writtenObjects: initTable[int, int32]()
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
