import faststreams/[inputs, outputs]
import ../enums
import ../types
import member

type
  ValueWithCode* = object
    ## Section 2.2.2.1 ValueWithCode structure
    ## Associates a Primitive Value with its type
    primitiveType*: PrimitiveType  # Identifies the type of data
    value*: PrimitiveValue        # The actual primitive value

  StringValueWithCode* = ValueWithCode
    ## Section 2.2.2.2 StringValueWithCode structure
    ## ValueWithCode specifically for String type

  ArrayOfValueWithCode* = seq[ValueWithCode]
    ## Section 2.2.2.3 ArrayOfValueWithCode structure
    ## Contains list of ValueWithCode records prefixed with length

  BinaryMethodCall* = object
    ## Section 2.2.3.1 BinaryMethodCall record 
    ## Contains info needed for Remote Method invocation
    recordType*: RecordType  # Must be rtMethodCall
    messageEnum*: MessageFlags  # Flags about args/context
    methodName*: StringValueWithCode  # Remote Method name
    typeName*: StringValueWithCode  # Server Type name
    callContext*: StringValueWithCode # Optional Logical Call ID
    args*: ArrayOfValueWithCode  # Optional input arguments

  BinaryMethodReturn* = object
    ## Section 2.2.3.3 BinaryMethodReturn record
    ## Contains info returned by Remote Method
    recordType*: RecordType  # Must be rtMethodReturn
    messageEnum*: MessageFlags  # Flags about return value/args/context
    returnValue*: ValueWithCode  # Optional Return Value 
    callContext*: StringValueWithCode  # Optional Logical Call ID
    args*: ArrayOfValueWithCode  # Optional output arguments

proc newStringValueWithCode*(value: string): StringValueWithCode =
  ## Creates new StringValueWithCode structure
  let strVal = PrimitiveValue(kind: ptString, stringVal: LengthPrefixedString(value: value))
  result = StringValueWithCode(primitiveType: ptString, value: strVal)

converter toValueWithCode*(strVal: StringValueWithCode): ValueWithCode =
  ## Converts StringValueWithCode to ValueWithCode
  result.primitiveType = strVal.primitiveType
  result.value = strVal.value

# Reading procedures
proc readValueWithCode*(inp: InputStream): ValueWithCode =
  ## Reads ValueWithCode structure from stream
  if not inp.readable:
    raise newException(IOError, "Missing primitive type")
    
  result.primitiveType = PrimitiveType(inp.read)
  result.value = readPrimitiveValue(inp, result.primitiveType)

proc readStringValueWithCode*(inp: InputStream): StringValueWithCode =
  ## Reads StringValueWithCode structure from stream
  if not inp.readable:
    raise newException(IOError, "Missing primitive type")
    
  result.primitiveType = PrimitiveType(inp.read)
  if result.primitiveType != ptString:
    raise newException(IOError, "Expected String primitive type (18)")
    
  let strVal = PrimitiveValue(kind: ptString, stringVal: readLengthPrefixedString(inp))
  result.value = strVal

proc readArrayOfValueWithCode*(inp: InputStream): ArrayOfValueWithCode =
  ## Reads array of ValueWithCode from stream
  let length = readValueWithContext[int32](inp, "reading value array length")
  if length < 0:
    raise newException(IOError, "Array length cannot be negative")
  
  for i in 0..<length:
    result.add(readValueWithCode(inp))

proc readBinaryMethodCall*(inp: InputStream): BinaryMethodCall =
  ## Reads BinaryMethodCall record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtMethodCall:
    raise newException(IOError, "Invalid method call record type")
    
  result.messageEnum = readMessageFlags(inp)
  result.methodName = readStringValueWithCode(inp) 
  result.typeName = readStringValueWithCode(inp)
  
  if MessageFlag.ContextInline in result.messageEnum:
    result.callContext = readStringValueWithCode(inp)
    
  if MessageFlag.ArgsInline in result.messageEnum:
    result.args = readArrayOfValueWithCode(inp)

proc readBinaryMethodReturn*(inp: InputStream): BinaryMethodReturn =
  ## Reads BinaryMethodReturn record from stream  
  result.recordType = readRecord(inp)
  if result.recordType != rtMethodReturn:
    raise newException(IOError, "Invalid method return record type")
    
  result.messageEnum = readMessageFlags(inp)
  
  # Method signature and generic flags not allowed here
  if MessageFlag.MethodSignatureInArray in result.messageEnum or
     MessageFlag.GenericMethod in result.messageEnum:
    raise newException(IOError, "Invalid flags for method return")
    
  if MessageFlag.ReturnValueInline in result.messageEnum:
    result.returnValue = readValueWithCode(inp)
    
  if MessageFlag.ContextInline in result.messageEnum:
    result.callContext = readStringValueWithCode(inp)
    
  if MessageFlag.ArgsInline in result.messageEnum:
    result.args = readArrayOfValueWithCode(inp)


# Writing procedures
proc writeValueWithCode*(outp: OutputStream, value: ValueWithCode) =
  ## Writes ValueWithCode structure to stream
  outp.write(byte(value.primitiveType))
  writePrimitiveValue(outp, value.value)

proc writeStringValueWithCode*(outp: OutputStream, value: StringValueWithCode) =
  ## Writes StringValueWithCode structure to stream
  if value.primitiveType != ptString:
    raise newException(ValueError, "Expected String primitive type (18)")
  
  outp.write(byte(value.primitiveType))
  writeLengthPrefixedString(outp, value.value.stringVal.value)

proc writeArrayOfValueWithCode*(outp: OutputStream, values: seq[ValueWithCode]) =
  ## Writes array of ValueWithCode to stream prefixed with length
  outp.write(cast[array[4, byte]](int32(values.len)))
  for value in values:
    writeValueWithCode(outp, value)

proc writeBinaryMethodCall*(outp: OutputStream, call: BinaryMethodCall) = 
  ## Writes BinaryMethodCall record to stream
  if call.recordType != rtMethodCall:
    raise newException(ValueError, "Invalid method call record type")
  
  writeRecord(outp, call.recordType)
  writeMessageFlags(outp, call.messageEnum)
  writeStringValueWithCode(outp, call.methodName)
  writeStringValueWithCode(outp, call.typeName)

  # Write optional fields based on flags  
  if MessageFlag.ContextInline in call.messageEnum:
    writeStringValueWithCode(outp, call.callContext)
    
  if MessageFlag.ArgsInline in call.messageEnum:
    writeArrayOfValueWithCode(outp, call.args)

proc writeBinaryMethodReturn*(outp: OutputStream, ret: BinaryMethodReturn) =
  ## Writes BinaryMethodReturn record to stream
  if ret.recordType != rtMethodReturn:
    raise newException(ValueError, "Invalid method return record type")
    
  # Method signature and generic flags not allowed
  if MessageFlag.MethodSignatureInArray in ret.messageEnum or 
     MessageFlag.GenericMethod in ret.messageEnum:
    raise newException(ValueError, "Invalid flags for method return")

  writeRecord(outp, ret.recordType)
  writeMessageFlags(outp, ret.messageEnum)

  # Write optional fields based on flags
  if MessageFlag.ReturnValueInline in ret.messageEnum:
    writeValueWithCode(outp, ret.returnValue)
    
  if MessageFlag.ContextInline in ret.messageEnum:
    writeStringValueWithCode(outp, ret.callContext)
    
  if MessageFlag.ArgsInline in ret.messageEnum:
    writeArrayOfValueWithCode(outp, ret.args)