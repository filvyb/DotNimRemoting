import faststreams/[inputs, outputs]
import ../enums
import ../types

type
  ArrayInfo* = object
    ## Section 2.4.2.1 ArrayInfo structure 
    ## Common structure used by Array records
    objectId*: int32   # Unique positive ID for array instance
    length*: int32     # Number of items in array

  ArraySingleObject* = object
    ## Section 2.4.3.2 ArraySingleObject record
    ## Single-dimensional Array where each member can contain any Data Value
    recordType*: RecordType    # Must be rtArraySingleObject
    arrayInfo*: ArrayInfo      # Array ID and length info

  ArraySinglePrimitive* = object
    ## Section 2.4.3.3 ArraySinglePrimitive record
    ## Single-dimensional Array with primitive value members
    recordType*: RecordType    # Must be rtArraySinglePrimitive
    arrayInfo*: ArrayInfo      # Array info
    primitiveType*: PrimitiveType  # Type of array items

  ArraySingleString* = object
    ## Section 2.4.3.4 ArraySingleString record
    ## Single-dimensional Array of string values
    recordType*: RecordType    # Must be rtArraySingleString
    arrayInfo*: ArrayInfo      # Array info

# Reading procedures
proc readArrayInfo*(inp: InputStream): ArrayInfo =
  ## Reads ArrayInfo structure from stream
  result.objectId = readValueWithContext[int32](inp, "reading array object ID")
  if result.objectId <= 0:
    raise newException(IOError, "Array object ID must be positive")

  result.length = readValueWithContext[int32](inp, "reading array length")
  if result.length < 0:
    raise newException(IOError, "Array length cannot be negative")

proc readArraySingleObject*(inp: InputStream): ArraySingleObject =
  ## Reads ArraySingleObject record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtArraySingleObject:
    raise newException(IOError, "Invalid array single object record type")
    
  result.arrayInfo = readArrayInfo(inp)

proc readArraySinglePrimitive*(inp: InputStream): ArraySinglePrimitive =
  ## Reads ArraySinglePrimitive record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtArraySinglePrimitive:
    raise newException(IOError, "Invalid array single primitive record type")
    
  result.arrayInfo = readArrayInfo(inp)
  
  # Read primitive type
  if not inp.readable:
    raise newException(IOError, "Missing primitive type")
    
  result.primitiveType = PrimitiveType(inp.read())
  if result.primitiveType in {ptNull, ptString}:
    raise newException(IOError, "Invalid primitive array type: " & $result.primitiveType)

proc readArraySingleString*(inp: InputStream): ArraySingleString =
  ## Reads ArraySingleString record from stream  
  result.recordType = readRecord(inp)
  if result.recordType != rtArraySingleString:
    raise newException(IOError, "Invalid array single string record type")
    
  result.arrayInfo = readArrayInfo(inp)

# Writing procedures
proc writeArrayInfo*(outp: OutputStream, info: ArrayInfo) =
  ## Writes ArrayInfo structure to stream
  if info.objectId <= 0:
    raise newException(ValueError, "Array object ID must be positive")
  if info.length < 0:
    raise newException(ValueError, "Array length cannot be negative")
    
  outp.write(cast[array[4, byte]](info.objectId))
  outp.write(cast[array[4, byte]](info.length))

proc writeArraySingleObject*(outp: OutputStream, arr: ArraySingleObject) =
  ## Writes ArraySingleObject record to stream
  if arr.recordType != rtArraySingleObject:
    raise newException(ValueError, "Invalid array single object record type")
    
  writeRecord(outp, arr.recordType)
  writeArrayInfo(outp, arr.arrayInfo)

proc writeArraySinglePrimitive*(outp: OutputStream, arr: ArraySinglePrimitive) = 
  ## Writes ArraySinglePrimitive record to stream
  if arr.recordType != rtArraySinglePrimitive:
    raise newException(ValueError, "Invalid array single primitive record type")
    
  if arr.primitiveType in {ptNull, ptString}:
    raise newException(ValueError, "Invalid primitive array type: " & $arr.primitiveType)
    
  writeRecord(outp, arr.recordType)
  writeArrayInfo(outp, arr.arrayInfo)
  outp.write(byte(arr.primitiveType))

proc writeArraySingleString*(outp: OutputStream, arr: ArraySingleString) =
  ## Writes ArraySingleString record to stream
  if arr.recordType != rtArraySingleString:
    raise newException(ValueError, "Invalid array single string record type") 
    
  writeRecord(outp, arr.recordType)
  writeArrayInfo(outp, arr.arrayInfo)