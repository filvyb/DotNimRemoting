import tables
import hashes
import enums
import records/arrays
import records/class
import records/member
import records/serialization

type
  ReferenceableRecord* = ref object
    ## Base type for records that can be referenced
    ## Classes/Arrays/BinaryObjectString
    case kind*: RecordType
    of rtClassWithId..rtClassWithMembersAndTypes:
      classRecord*: ClassRecord # Any class record variant
    of rtBinaryArray..rtArraySingleString:  
      arrayRecord*: ArrayRecord # Any array record variant
    of rtBinaryObjectString:
      stringRecord*: BinaryObjectString
    else:
      discard

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
    objects: Table[int32, ReferenceableRecord] # Maps object IDs to records
    libraries*: Table[int32, BinaryLibrary]     # Maps library IDs to libraries

proc addReference*(ctx: ReferenceContext, id: int32, record: ReferenceableRecord) =
  ## Track a new object reference
  if id in ctx.objects:
    raise newException(IOError, "Duplicate object ID: " & $id)
  ctx.objects[id] = record

proc addLibrary*(ctx: ReferenceContext, lib: BinaryLibrary) =
  ## Track a new library reference
  if lib.libraryId in ctx.libraries:
    raise newException(IOError, "Duplicate library ID: " & $lib.libraryId)
  ctx.libraries[lib.libraryId] = lib

proc getReference*(ctx: ReferenceContext, id: int32): ReferenceableRecord =
  ## Look up referenced object 
  if id notin ctx.objects:
    raise newException(IOError, "Missing object reference: " & $id)
  result = ctx.objects[id]

proc getLibrary*(ctx: ReferenceContext, id: int32): BinaryLibrary =
  ## Look up referenced library
  if id notin ctx.libraries:
    raise newException(IOError, "Missing library reference: " & $id)
  result = ctx.libraries[id]

proc newReferenceContext*(): ReferenceContext =
  ReferenceContext(
    objects: initTable[int32, ReferenceableRecord](),
    libraries: initTable[int32, BinaryLibrary]()
  )

proc hash*(x: ReferenceableRecord): Hash =
  ## Custom hash function for ReferenceableRecord.
  ## Using the object's memory address as hash allows us to compare
  ## records by reference identity rather than content
  result = hash(cast[pointer](x))

type
  SerializationContext* = ref object
    ## Manages object ID assignment during serialization, tracking records and IDs
    nextId*: int32                               # Counter for generating new IDs, starts at 1
    recordToId*: Table[ReferenceableRecord, int32]  # Maps records to their assigned IDs
    writtenObjects*: Table[int, int32]  # Maps object memory addresses to their assigned IDs

proc newSerializationContext*(): SerializationContext =
  ## Creates a new SerializationContext with an initial ID of 1
  SerializationContext(
    nextId: 1,
    recordToId: initTable[ReferenceableRecord, int32](),
    writtenObjects: initTable[int, int32]()
  )

proc `$`*(ctx: ReferenceContext): string =
  result = "ReferenceContext(" & $ctx.objects.len() &
               " objects, " & $ctx.libraries.len() & " libraries)"

proc `$`*(ctx: SerializationContext): string =
  result = "SerializationContext(\n" &
           "  nextId: " & $ctx.nextId & ",\n" &
           "  recordToId: {\n"
      
  # Show all record to ID mappings
  for record, id in ctx.recordToId:
    result.add("    " & $record.kind & " => " & $id & ",\n")
      
  result.add("  },\n  writtenObjects: {\n")
      
  # Show all written object pointers and their IDs
  for ptrVal, id in ctx.writtenObjects.pairs():
    result.add("    " & $ptrVal & " => " & $id & ",\n")
      
  result.add("  }\n)")

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

proc assignId*(ctx: SerializationContext, record: ReferenceableRecord): int32 =
  ## Assigns a unique ID to a ReferenceableRecord and sets its inner objectId.
  ## Returns the assigned or existing ID.
  if record in ctx.recordToId:
    return ctx.recordToId[record]
  
  # Assign new ID and increment counter
  let id = ctx.nextId
  ctx.nextId += 1
  ctx.recordToId[record] = id
  
  # Set the objectId in the inner record based on kind
  case record.kind
  of rtClassWithId..rtClassWithMembersAndTypes:
    case record.classRecord.kind
    of rtClassWithId:
      record.classRecord.classWithId.objectId = id
    of rtSystemClassWithMembers:
      record.classRecord.systemClassWithMembers.classInfo.objectId = id
    of rtClassWithMembers:
      record.classRecord.classWithMembers.classInfo.objectId = id
    of rtSystemClassWithMembersAndTypes:
      record.classRecord.systemClassWithMembersAndTypes.classInfo.objectId = id
    of rtClassWithMembersAndTypes:
      record.classRecord.classWithMembersAndTypes.classInfo.objectId = id
    else:
      discard  # Unreachable due to outer case constraint
  of rtBinaryArray..rtArraySingleString:
    case record.arrayRecord.kind
    of rtBinaryArray:
      record.arrayRecord.binaryArray.objectId = id
    of rtArraySinglePrimitive:
      record.arrayRecord.arraySinglePrimitive.arrayInfo.objectId = id
    of rtArraySingleObject:
      record.arrayRecord.arraySingleObject.arrayInfo.objectId = id
    of rtArraySingleString:
      record.arrayRecord.arraySingleString.arrayInfo.objectId = id
    else:
      discard  # Unreachable due to outer case constraint
  of rtBinaryObjectString:
    record.stringRecord.objectId = id
  else:
    raise newException(ValueError, "Invalid ReferenceableRecord kind: " & $record.kind)
  
  return id

proc assignIdForPointer*(ctx: SerializationContext, objPtr: pointer): int32 =
  ## Assigns the next available ID for a given object pointer if not already assigned.
  if ctx.hasWrittenObject(objPtr):
    return ctx.getWrittenObjectId(objPtr)
  else:
    let id = ctx.nextId
    ctx.nextId += 1
    ctx.setWrittenObjectId(objPtr, id)
    return id
