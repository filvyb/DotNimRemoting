import ../src/DotNimRemoting

type Person = object
  Name: string
  Age: int32

# Example server: a method-level service handler
proc myService(methodName: string, args: seq[RemotingValue]): Future[RemotingValue] {.async.} =
  echo "Received call: ", methodName
  case methodName
  of "Echo":
    return args[0]
  of "Add":
    return toRemotingValue(args[0].getInt32 + args[1].getInt32)
  of "SumIntArray":
    var sum = 0'i32
    for elem in args[0].elements:
      sum += elem.getInt32
    return toRemotingValue(sum)
  of "DescribePerson":
    # Class arguments parse back into plain Nim objects
    let p = classToObject[Person](args[0])
    return toRemotingValue(p.Name & " is " & $p.Age)
  else:
    # Unknown method: reply void
    return nullValue()

proc serverExample() {.async.} =
  let server = newNrtpTcpServer(8080)
  server.registerService("/MyServer.rem", myService)
  await server.start()

# Run server example
when isMainModule:
  waitFor serverExample()
