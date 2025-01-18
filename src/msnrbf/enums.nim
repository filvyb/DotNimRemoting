import faststreams/[inputs, outputs]
import types

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

  BinaryArrayType* = enum
    ## Section 2.4.1.1 BinaryArrayTypeEnumeration
    ## Denotes type of array
    batSingle = 0            # Single-dimensional Array
    batJagged = 1           # Array whose elements are Arrays (can be different dimensions/sizes)
    batRectangular = 2      # Multi-dimensional rectangular Array
    batSingleOffset = 3     # Single-dimensional offset
    batJaggedOffset = 4     # Jagged Array with lower bound index > 0
    batRectangularOffset = 5 # Multi-dimensional Arrays with lower bound index > 0 for at least one dimension

  MessageFlag* {.pure.} = enum
    ## Section 2.2.1.1 MessageFlags individual bits
    NoArgs                  # No arguments 
    ArgsInline             # Arguments Array in Args field of Method record
    ArgsIsArray            # Each argument is item in separate Call Array record
    ArgsInArray            # Arguments Array is item in separate Call Array record
    NoContext              # No Call Context value
    ContextInline          # Call Context contains only Logical Call ID in CallContext field
    ContextInArray         # CallContext values in array in Call Array record
    MethodSignatureInArray # Method Signature in Call Array record
    PropertyInArray        # Message Properties in Call Array record
    NoReturnValue          # Return Value is Null object
    ReturnValueVoid        # Method has no Return Value
    ReturnValueInline      # Return Value in ReturnValue field
    ReturnValueInArray     # Return Value in Call Array record 
    ExceptionInArray       # Exception in Call Array record
    GenericMethod          # Remote Method is generic, actual types in Call Array
    Reserved15            # Reserved
    Reserved16            # Reserved 
    Reserved17            # Reserved
    Reserved18            # Reserved
    Reserved19            # Reserved
    Reserved20            # Reserved
    Reserved21            # Reserved
    Reserved22            # Reserved  
    Reserved23            # Reserved
    Reserved24            # Reserved
    Reserved25            # Reserved
    Reserved26            # Reserved
    Reserved27            # Reserved
    Reserved28            # Reserved
    Reserved29            # Reserved
    Reserved30            # Reserved
    Reserved31            # Reserved

  MessageFlags* = set[MessageFlag]
    ## Combination of MessageFlag bits

# Message flag validation
proc validateMessageFlags*(flags: MessageFlags) =
  ## Validates message flag combinations according to spec rules
  ## Raises ValueError for invalid combinations
  
  # Check mutually exclusive categories
  template checkMutuallyExclusive(categoryA, categoryB: set[MessageFlag]) =
    if len(flags * categoryA) > 0 and len(flags * categoryB) > 0:
      raise newException(ValueError, "Invalid flag combination")

  let
    argsFlags = {NoArgs, ArgsInline, ArgsIsArray, ArgsInArray}
    contextFlags = {NoContext, ContextInline, ContextInArray}
    signatureFlags = {MethodSignatureInArray}
    returnFlags = {NoReturnValue, ReturnValueVoid, ReturnValueInline, ReturnValueInArray}
    exceptionFlags = {ExceptionInArray}
    propertyFlags = {PropertyInArray}
    genericFlags = {GenericMethod}

  # Category exclusivity rules from spec
  checkMutuallyExclusive(argsFlags, exceptionFlags)
  checkMutuallyExclusive(returnFlags, exceptionFlags)
  checkMutuallyExclusive(returnFlags, signatureFlags)
  checkMutuallyExclusive(signatureFlags, exceptionFlags)
  
  # Check one flag per category at most
  for category in [argsFlags, contextFlags, signatureFlags, 
                  returnFlags, exceptionFlags, propertyFlags, genericFlags]:
    if len(flags * category) > 1:
      raise newException(ValueError, "Multiple flags from same category")

# Reading procedures
proc readRecord*(inp: InputStream): RecordType =
  ## Reads record type from stream
  if inp.readable:
    result = RecordType(inp.read())

proc readBinaryArrayType*(inp: InputStream): BinaryArrayType =
  ## Reads binary array type from stream
  if inp.readable:
    result = BinaryArrayType(inp.read())

proc readMessageFlags*(inp: InputStream): MessageFlags =
  ## Reads message flags from stream (as 32-bit value)
  ## Validates flag combinations according to spec rules
  ## Raises IOError for read failures or invalid flag combinations

  let value = readValueWithContext[uint32](inp, "reading message flags")
  
  # Convert bits to set
  for flag in MessageFlag:
    if (value and (1'u32 shl ord(flag))) != 0:
      result.incl(flag)

  # Validate the resulting flag combination
  try:
    validateMessageFlags(result)
  except ValueError as e:
    raise newException(IOError, "Invalid message flags: " & e.msg)

# Writing procedures
proc writeRecord*(outp: OutputStream, rt: RecordType) =
  ## Writes record type to stream
  outp.write(byte(rt))

proc writeBinaryArrayType*(outp: OutputStream, bat: BinaryArrayType) =
  ## Writes binary array type to stream
  outp.write(byte(bat))

proc writeMessageFlags*(outp: OutputStream, flags: MessageFlags) = 
  ## Writes message flags to stream (as 32-bit value)
  ## Validates flag combinations before writing
  ## Raises ValueError for invalid flag combinations
  
  # Validate before writing
  validateMessageFlags(flags)
  
  var value: uint32
  # Convert set to bits
  for flag in flags:
    value = value or (1'u32 shl ord(flag))
    
  let bytes = cast[array[4, byte]](value)
  outp.write(bytes)
