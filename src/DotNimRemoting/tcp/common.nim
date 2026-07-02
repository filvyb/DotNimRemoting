import faststreams/[inputs]
import strutils, sequtils
import ../msnrbf/[grammar, context, enums, types, helpers]
import ../msnrbf/records/[methodinv, member, serialization]

const
  DefaultTimeout* = 20000 # 20 seconds default timeout

proc qualifiedTypeName(typeName: string): string =
  ## Appends the default assembly version info unless already qualified
  if "Version=" in typeName: typeName
  else: typeName & ", Version=1.0.0.0, Culture=neutral, PublicKeyToken=null"

proc isInlineable(value: RemotingValue): bool =
  ## Primitives and strings travel inline; classes, arrays and nulls cannot
  value.kind == rvString or
    (value.kind == rvPrimitive and value.primitiveVal.kind notin {ptNull, ptUnused})

proc inlineValueWithCode(value: RemotingValue): ValueWithCode =
  case value.kind
  of rvString:
    ValueWithCode(primitiveType: ptString,
                  value: PrimitiveValue(kind: ptString, stringVal: value.stringRecord.value))
  of rvPrimitive:
    toValueWithCode(value.primitiveVal)
  else:
    raise newException(ValueError, "value of kind " & $value.kind & " cannot travel inline")

proc createMethodCallRequest*(methodName, typeName: string,
                              args: seq[RemotingValue],
                              oneWay: bool = false,
                              libraries: seq[BinaryLibrary] = @[]): seq[byte] =
  ## Method call request from RemotingValue arguments. Layout matches .NET:
  ## all-primitive/string args travel inline, otherwise the whole list moves
  ## into the call array. libraries must cover every referenced library id.
  var flags: MessageFlags = {MessageFlag.NoContext}
  if oneWay:
    flags.incl(MessageFlag.NoReturnValue)

  var call = BinaryMethodCall(
    recordType: rtMethodCall,
    methodName: newStringValueWithCode(methodName),
    typeName: newStringValueWithCode(qualifiedTypeName(typeName))
  )
  var callArray: seq[RemotingValue]
  if args.len == 0:
    flags.incl(MessageFlag.NoArgs)
  elif args.allIt(isInlineable(it)):
    flags.incl(MessageFlag.ArgsInline)
    call.args = args.mapIt(inlineValueWithCode(it))
  else:
    flags.incl(MessageFlag.ArgsIsArray)
    callArray = args
  call.messageEnum = flags

  let ctx = newSerializationContext()
  let msg = newRemotingMessage(ctx, methodCall = some(call), callArray = callArray,
                               libraries = requiredLibraries(args, libraries))
  serializeRemotingMessage(msg, ctx)

proc createMethodReturnResponse*(value: RemotingValue,
                                 libraries: seq[BinaryLibrary] = @[]): seq[byte] =
  ## Method return response. Layout matches .NET: null means no return value,
  ## primitives/strings travel inline, classes and arrays use the call array.
  ## libraries must cover every referenced library id.
  var flags: MessageFlags = {MessageFlag.NoContext, MessageFlag.NoArgs}
  var ret = BinaryMethodReturn(recordType: rtMethodReturn)
  var callArray: seq[RemotingValue]
  if value == nil or value.kind == rvNull:
    flags.incl(MessageFlag.NoReturnValue)
  elif isInlineable(value):
    flags.incl(MessageFlag.ReturnValueInline)
    ret.returnValue = inlineValueWithCode(value)
  else:
    flags.incl(MessageFlag.ReturnValueInArray)
    callArray = @[value]
  ret.messageEnum = flags

  let ctx = newSerializationContext()
  let msg = newRemotingMessage(ctx, methodReturn = some(ret), callArray = callArray,
                               libraries = requiredLibraries(callArray, libraries))
  serializeRemotingMessage(msg, ctx)

proc createMethodReturnExceptionResponse*(exception: RemotingValue): seq[byte] =
  ## Method return response carrying a serialized exception (built with
  ## dotNetExceptionValue) in the call array; .NET clients deserialize and
  ## rethrow it. Flags match what .NET/Mono emit on a throwing method.
  let ret = BinaryMethodReturn(
    recordType: rtMethodReturn,
    messageEnum: {MessageFlag.NoArgs, MessageFlag.NoContext,
                  MessageFlag.NoReturnValue, MessageFlag.ExceptionInArray})
  let ctx = newSerializationContext()
  let msg = newRemotingMessage(ctx, methodReturn = some(ret),
                               callArray = @[exception])
  serializeRemotingMessage(msg, ctx)

proc createMethodCallRequest*(methodName, typeName: string, args: seq[PrimitiveValue] = @[]): seq[byte]
    {.deprecated: "use createMethodCallRequest with seq[RemotingValue]".} =
  ## Method call request with inline primitive arguments
  {.push warning[Deprecated]: off.}
  result = serializeRemotingMessage(createMethodCallMessage(methodName, qualifiedTypeName(typeName), args))
  {.pop.}

proc toPrimitiveValue*(rv: RemotingValue): PrimitiveValue
    {.deprecated: "use the RemotingValue accessors (getInt32, getString, ...)".} =
  ## Converts a RemotingValue holding a primitive or string into a
  ## PrimitiveValue; anything else (class, array, reference) maps to ptNull.
  case rv.kind
  of rvPrimitive: rv.primitiveVal
  of rvString: PrimitiveValue(kind: ptString, stringVal: rv.stringRecord.value)
  else: PrimitiveValue(kind: ptNull)

proc extractMethodCallArgs*(msg: RemotingMessage): seq[PrimitiveValue]
    {.deprecated: "use callArgs".} =
  ## Extracts the primitive arguments of a method call regardless of the wire
  ## layout chosen by the sender. Returns an empty sequence if there are no arguments or if
  ## the message does not contain a method call.
  if msg.methodCall.isNone:
    return @[]
  let call = msg.methodCall.get
  {.push warning[Deprecated]: off.}
  if MessageFlag.ArgsInline in call.messageEnum:
    for arg in call.args:
      result.add(arg.value)
  elif MessageFlag.ArgsIsArray in call.messageEnum:
    resolveReferences(msg)
    for elem in msg.methodCallArray:
      result.add(toPrimitiveValue(elem))
  elif MessageFlag.ArgsInArray in call.messageEnum:
    resolveReferences(msg)
    if msg.methodCallArray.len > 0 and msg.methodCallArray[0].kind == rvArray:
      for elem in msg.methodCallArray[0].arrayVal.elements:
        result.add(toPrimitiveValue(elem))
  {.pop.}

proc extractMethodCallInfo*(data: seq[byte]): tuple[methodName, typeName: string, isOneWay: bool] =
  ## Extracts method name and type name from serialized message content
  
  try:
    # Deserialize the message
    var input = memoryInput(data)
    let msg = readRemotingMessage(input)
    
    # Extract method call info
    if msg.methodCall.isSome:
      let call = msg.methodCall.get
      let methodName = call.methodName.value.stringVal.value
      let typeName = call.typeName.value.stringVal.value
      # Check if it's a one-way call (no return expected)
      let isOneWay = MessageFlag.NoReturnValue in call.messageEnum
      return (methodName, typeName, isOneWay)
    else:
      # No method call found
      return ("", "", false)
  except:
    # Failed to extract method call info
    return ("", "", false)

proc createMethodReturnResponse*(returnValue: PrimitiveValue = PrimitiveValue(kind: ptNull)): seq[byte]
    {.deprecated: "use createMethodReturnResponse with a RemotingValue".} =
  ## Method return response with an inline primitive return value
  {.push warning[Deprecated]: off.}
  result = serializeRemotingMessage(createMethodReturnMessage(returnValue))
  {.pop.}

proc extractReturnValue*(data: seq[byte]): PrimitiveValue
    {.deprecated: "use returnValueOf".} =
  ## Extracts return value from serialized method return message
  ## Returns null primitive value if no return value or if extraction fails
  
  try:
    # Deserialize the message
    var input = memoryInput(data)
    let msg = readRemotingMessage(input)
    
    # Extract return value
    if msg.methodReturn.isSome:
      let ret = msg.methodReturn.get
      if MessageFlag.ReturnValueInline in ret.messageEnum:
        return ret.returnValue.value
      elif MessageFlag.ReturnValueVoid in ret.messageEnum:
        return PrimitiveValue(kind: ptNull)
    
    # Default null return
    return PrimitiveValue(kind: ptNull)
  except:
    # Failed to extract return value
    return PrimitiveValue(kind: ptNull)
    
proc createOneWayMethodCallRequest*(methodName, typeName: string, args: seq[PrimitiveValue] = @[]): seq[byte]
    {.deprecated: "use createMethodCallRequest with oneWay = true".} =
  ## One-way method call request: a basic call flagged NoReturnValue
  {.push warning[Deprecated]: off.}
  var call = methodCallBasic(methodName, qualifiedTypeName(typeName), args)
  {.pop.}
  call.messageEnum.incl(MessageFlag.NoReturnValue)
  let ctx = newSerializationContext()
  serializeRemotingMessage(newRemotingMessage(ctx, methodCall = some(call)))
