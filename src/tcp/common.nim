import faststreams/[inputs]
import ../msnrbf/[grammar, context, enums, types, helpers]
import ../msnrbf/records/[methodinv, member]

const 
  DefaultTimeout* = 20000 # 20 seconds default timeout

proc createMethodCallRequest*(methodName, typeName: string, args: seq[PrimitiveValue] = @[]): seq[byte] =
  ## Creates a binary-formatted method call request
  ## This will create a RemotingMessage with a BinaryMethodCall record

  var fullTypeName = typename & ", Version=1.0.0.0, Culture=neutral, PublicKeyToken=null"

  # Create serialization context
  let ctx = newSerializationContext()
  
  # Create a method call with inline arguments
  var flags: MessageFlags = {MessageFlag.NoContext}
  
  if args.len > 0:
    flags.incl(MessageFlag.ArgsInline)
  else:
    flags.incl(MessageFlag.NoArgs)
  
  var call = BinaryMethodCall(
    recordType: rtMethodCall,
    messageEnum: flags,
    methodName: newStringValueWithCode(methodName),
    typeName: newStringValueWithCode(typeName)
  )
  
  if args.len > 0:
    var valueWithCodes: seq[ValueWithCode]
    for arg in args:
      valueWithCodes.add(toValueWithCode(arg))
    call.args = valueWithCodes
  
  # Create a complete message
  let msg = newRemotingMessage(ctx, methodCall = some(call))
  
  # Serialize to bytes
  return serializeRemotingMessage(msg)

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
      return (methodName, typeName, false)
    else:
      # No method call found
      return ("", "", false)
  except:
    # Failed to extract method call info
    return ("", "", false)

proc createMethodReturnResponse*(returnValue: PrimitiveValue = PrimitiveValue(kind: ptNull)): seq[byte] =
  ## Creates a binary-formatted method return response
  
  # Create serialization context
  let ctx = newSerializationContext()
  
  # Create the method return
  var flags: MessageFlags = {MessageFlag.NoContext, MessageFlag.NoArgs}
  
  if returnValue.kind == ptNull:
    flags.incl(MessageFlag.NoReturnValue)
  else:
    flags.incl(MessageFlag.ReturnValueInline)
  
  var ret = BinaryMethodReturn(
    recordType: rtMethodReturn,
    messageEnum: flags
  )
  
  if returnValue.kind != ptNull:
    ret.returnValue = toValueWithCode(returnValue)
  
  # Create a complete message
  let msg = newRemotingMessage(ctx, methodReturn = some(ret))
  
  # Serialize to bytes
  return serializeRemotingMessage(msg)