import faststreams/[inputs, outputs]
import ../enums
import ../types
import class

type
  ArrayInfo* = object
    ## Section 2.4.2.1 ArrayInfo structure 
    ## Common structure used by Array records
    objectId*: int32   # Unique positive ID for array instance
    length*: int32     # Number of items in array

  BinaryArray* = object
    ## Section 2.4.3.1 BinaryArray record
    ## Most general and verbose form of Array records
    recordType*: RecordType        # Must be rtBinaryArray
    objectId*: int32              # Unique positive ID
    binaryArrayType*: BinaryArrayType  # Type of array (single/jagged/rectangular)
    rank*: int32                  # Number of dimensions
    lengths*: seq[int32]          # Length of each dimension
    lowerBounds*: seq[int32]      # Optional - Lower bound of each dimension
    typeEnum*: BinaryType         # Type of array items
    additionalTypeInfo*: AdditionalTypeInfo  # Additional type info based on typeEnum

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

proc readBinaryArray*(inp: InputStream): BinaryArray =
  ## Reads BinaryArray record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtBinaryArray:
    raise newException(IOError, "Invalid binary array record type")

  # Read object ID
  result.objectId = readValueWithContext[int32](inp, "reading binary array object ID")
  if result.objectId <= 0:
    raise newException(IOError, "Array object ID must be positive")

  # Read array type
  if not inp.readable:
    raise newException(IOError, "Missing binary array type")
  result.binaryArrayType = readBinaryArrayType(inp)

  # Read rank
  result.rank = readValueWithContext[int32](inp, "reading array rank")
  if result.rank < 0:
    raise newException(IOError, "Array rank must be positive")

  # Read lengths array
  for i in 0..<result.rank:
    let length = readValueWithContext[int32](inp, "reading dimension " & $i & " length")
    if length < 0:
      raise newException(IOError, "Array dimension length cannot be negative")
    result.lengths.add(length)

  # Read lower bounds if needed
  if result.binaryArrayType in {batSingleOffset, batJaggedOffset, batRectangularOffset}:
    for i in 0..<result.rank:
      let bound = readValueWithContext[int32](inp, "reading dimension " & $i & " lower bound")
      result.lowerBounds.add(bound)

  # Read type information
  if not inp.readable:
    raise newException(IOError, "Missing array item type enum")
  result.typeEnum = BinaryType(inp.read())

  # Read additional type info based on BinaryType
  case result.typeEnum
  of btPrimitive, btPrimitiveArray:
    # For primitive types, read the PrimitiveTypeEnum
    if not inp.readable:
      raise newException(IOError, "Missing primitive type info")
    let primType = PrimitiveType(inp.read())
    if primType in {ptString, ptNull}:
      raise newException(IOError, "Invalid primitive array type: " & $primType)
    case result.typeEnum
    of btPrimitive:
      result.additionalTypeInfo = AdditionalTypeInfo(kind: btPrimitive, primitiveType: primType)
    of btPrimitiveArray:
      result.additionalTypeInfo = AdditionalTypeInfo(kind: btPrimitiveArray, primitiveType: primType)
    else: discard # Can't happen due to case statement above

  of btSystemClass:
    # For system class, read the class name
    let className = readLengthPrefixedString(inp)
    result.additionalTypeInfo = AdditionalTypeInfo(kind: btSystemClass, className: className)

  of btClass:
    # For regular class, read ClassTypeInfo
    let classInfo = readClassTypeInfo(inp)
    result.additionalTypeInfo = AdditionalTypeInfo(kind: btClass, classInfo: classInfo)

  of btString, btObject, btObjectArray, btStringArray:
    # These types don't need additional info
    result.additionalTypeInfo = AdditionalTypeInfo(kind: result.typeEnum)

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

proc writeBinaryArray*(outp: OutputStream, arr: BinaryArray) =
  ## Writes BinaryArray record to stream
  if arr.recordType != rtBinaryArray:
    raise newException(ValueError, "Invalid binary array record type")

  if arr.objectId <= 0:
    raise newException(ValueError, "Array object ID must be positive")

  if arr.rank <= 0:
    raise newException(ValueError, "Array rank must be positive")

  if arr.lengths.len != arr.rank:
    raise newException(ValueError, "Number of lengths must match rank")

  # For offset array types, validate lower bounds
  if arr.binaryArrayType in {batSingleOffset, batJaggedOffset, batRectangularOffset}:
    if arr.lowerBounds.len != arr.rank:
      raise newException(ValueError, "Number of lower bounds must match rank")

  # Write record type
  writeRecord(outp, arr.recordType)

  # Write object ID
  outp.write(cast[array[4, byte]](arr.objectId))

  # Write array type
  writeBinaryArrayType(outp, arr.binaryArrayType)

  # Write rank
  if arr.rank < 0:
    raise newException(ValueError, "Array rank cannot be negative")
  outp.write(cast[array[4, byte]](arr.rank))

  # Write lengths
  for length in arr.lengths:
    if length < 0:
      raise newException(ValueError, "Array dimension length cannot be negative")
    outp.write(cast[array[4, byte]](length))

  # Write lower bounds if needed
  if arr.binaryArrayType in {batSingleOffset, batJaggedOffset, batRectangularOffset}:
    for bound in arr.lowerBounds:
      outp.write(cast[array[4, byte]](bound))

  # Write type enum
  outp.write(byte(arr.typeEnum))

  # Write additional type info based on type enum
  case arr.typeEnum
  of btPrimitive, btPrimitiveArray:
    if arr.additionalTypeInfo.primitiveType in {ptString, ptNull}:
      raise newException(ValueError, "Invalid primitive array type")
    outp.write(byte(arr.additionalTypeInfo.primitiveType))

  of btSystemClass:
    writeLengthPrefixedString(outp, arr.additionalTypeInfo.className.value)

  of btClass:
    writeClassTypeInfo(outp, arr.additionalTypeInfo.classInfo)

  of btString, btObject, btObjectArray, btStringArray:
    # No additional info needed
    discard

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