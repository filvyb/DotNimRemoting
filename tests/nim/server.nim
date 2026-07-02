import strutils
import ../../src/DotNimRemoting
import interop

# Direction 2: .NET (Mono) client -> Nim server. Implements the IEchoService
# contract the .NET client expects through the registerService API.

proc echoService(methodName: string, args: seq[RemotingValue]): Future[RemotingValue] {.async.} =
  case methodName
  of "Echo":
    return args[0]
  of "Concat":
    return toRemotingValue(args[0].getString & args[1].getString)
  of "Add":
    return toRemotingValue(args[0].getInt32 + args[1].getInt32)
  of "Sum":
    return toRemotingValue(args[0].getInt64 + args[1].getInt64)
  of "Multiply":
    return toRemotingValue(args[0].getDouble * args[1].getDouble)
  of "IsPositive":
    return toRemotingValue(args[0].getInt32 > 0)
  of "EchoDecimal", "EchoDateTime", "EchoTimeSpan", "EchoChar",
     "EchoUInt16", "EchoUInt32", "EchoUInt64", "EchoDouble":
    # Pure round-trips: send the parsed argument straight back.
    return args[0]
  of "MultiplyFloat":
    return toRemotingValue(args[0].getSingle * args[1].getSingle)
  of "IncrementByte":
    return toRemotingValue(args[0].getByte + 1)
  of "NegateSByte":
    return toRemotingValue(-args[0].getSByte)
  of "NegateShort":
    return toRemotingValue(-args[0].getInt16)
  of "Ping":
    return nullValue()
  of "EchoIntArray", "EchoDoubleArray", "EchoStringArray", "EchoByteArray":
    # Echo the parsed array value back; object ids are reassigned on write
    return args[0]
  of "MakeNulls":
    var nulls: seq[Option[string]]
    for i in 0..<args[0].getInt32:
      nulls.add(none(string))
    return toRemotingValue(nulls)
  of "SumIntArray":
    var sum = 0'i32
    for elem in args[0].elements:
      sum += elem.getInt32
    return toRemotingValue(sum)
  of "JoinStrings":
    var parts: seq[string]
    for elem in args[0].elements:
      parts.add(elem.getString)
    return toRemotingValue(parts.join(args[1].getString))
  of "MakeRange":
    let start = args[0].getInt32
    var values: seq[int32]
    for i in 0..<args[1].getInt32:
      values.add(start + i)
    return toRemotingValue(values)
  of "EchoPerson":
    if args[0].isNull:
      # Null object return travels as the NoReturnValue flag
      return nullValue()
    # Rebuild rather than echo, so the response carries our own class metadata
    return toRemotingValue(classToObject[Person](args[0]))
  of "DescribePerson":
    let p = classToObject[Person](args[0])
    return toRemotingValue(p.Name & ":" & $p.Age)
  of "MakePerson":
    let age = args[1].getInt32
    return toRemotingValue(Person(Name: args[0].getString, Age: age,
                                  Score: age.float64 * 0.5))
  of "EchoPersonArray":
    var people: seq[RemotingValue]
    for elem in args[0].elements:
      people.add(toRemotingValue(classToObject[Person](elem)))
    return personArrayValue(people)
  of "MakeTwins":
    # The writer dedupes by pointer: the second element goes out as a
    # MemberReference, so .NET sees one shared object
    let age = args[1].getInt32
    let p = toRemotingValue(Person(Name: args[0].getString, Age: age,
                                   Score: age.float64 * 2.0))
    return personArrayValue(@[p, p])
  of "EchoEmployee":
    return toRemotingValue(classToObject[Employee](args[0]))
  of "HomesShared":
    # Diamond arg: true only when both Home members resolved to the same
    # RemotingValue (ref equality), i.e. the wire carried one Address record
    # plus a MemberReference
    let employees = args[0].elements
    return toRemotingValue(
      getMember(employees[0], "Home", EmployeeLayout) ==
      getMember(employees[1], "Home", EmployeeLayout))
  of "MakeCoworkers":
    # Build the diamond: one Address value shared by both employees, so the
    # writer emits the second Home as a MemberReference
    let home = toRemotingValue(Address(Street: "Shared 1", City: args[2].getString))
    return employeeArrayValue(@[
      employeeValue(args[0].getString, home),
      employeeValue(args[1].getString, home)])
  of "DescribeEmployee":
    let e = classToObject[Employee](args[0])
    return toRemotingValue(e.Name & "@" & e.Home.City)
  of "ThrowError":
    # registerService serializes raised exceptions as System.Exception
    # returns, which the .NET client materializes and rethrows
    raise newException(ValueError, args[0].getString)
  else:
    # Unknown method: reply void
    return nullValue()

proc main() {.async.} =
  let server = newNrtpTcpServer(8081)
  server.registerService("/EchoService", echoService, @[personLibrary()])
  await server.start()

waitFor main()
