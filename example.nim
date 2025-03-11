import src/msnrbf/grammar
import src/msnrbf/helpers
import src/msnrbf/enums
import src/msnrbf/types
import src/msnrbf/records/methodinv
import src/msnrbf/records/member
import src/msnrbf/context
import options

let methodName = newStringValueWithCode("Foo")
let typeName = newStringValueWithCode("Bar")
let binaryMethodCall = BinaryMethodCall(
      recordType: rtMethodCall,
      messageEnum: {ArgsInArray, NoContext},
      methodName: methodName,
      typeName: typeName
    )
let value = RemotingValue(
      kind: rvPrimitive,
      primitiveVal: PrimitiveValue(kind: ptInt32, int32Val: 10)
    )
let ctx = newSerializationContext()
var msg = newRemotingMessage(ctx, methodCall = some(binaryMethodCall), callArray = @[value])
var serialized = serializeRemotingMessage(msg, ctx)
echo serialized