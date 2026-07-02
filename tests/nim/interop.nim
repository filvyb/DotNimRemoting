import ../../src/DotNimRemoting

# Test-domain types (Person/Address/Employee) shared by the Nim interop
# client and server; field names match the public fields of the C# classes,
# so objectToClass/classToObject convert them directly.

type
  Person* = object
    Name*: string
    Age*: int32
    Score*: float64

  Address* = object
    Street*: string
    City*: string

  Employee* = object
    Name*: string
    Home*: Address

const
  PersonClassName* = "DotNimTester.Lib.Person"
  AddressClassName* = "DotNimTester.Lib.Address"
  EmployeeClassName* = "DotNimTester.Lib.Employee"
  LibAssemblyName* = "Lib, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null"
  PersonLibraryId* = 100'i32
    ## High id so it cannot collide with object ids handed out sequentially
    ## by the SerializationContext

proc personLibrary*(): BinaryLibrary =
  binaryLibrary(LibAssemblyName, PersonLibraryId)

# These overloads bind each Nim type to its .NET class name; objectToClass
# also picks them up for nested fields (Employee.Home).

proc toRemotingValue*(a: Address): RemotingValue =
  objectToClass(a, AddressClassName, PersonLibraryId)

proc toRemotingValue*(p: Person): RemotingValue =
  objectToClass(p, PersonClassName, PersonLibraryId)

proc toRemotingValue*(e: Employee): RemotingValue =
  objectToClass(e, EmployeeClassName, PersonLibraryId)

proc personArrayValue*(people: seq[RemotingValue]): RemotingValue =
  ## Person[] as a typed class array, so .NET materializes a typed array
  classArrayValue(PersonClassName, PersonLibraryId, people)

const EmployeeLayout* = @["Name", "Home"]
  ## Member layout fallback for Employee values arriving as ClassWithId

proc employeeValue*(name: string, home: RemotingValue): RemotingValue =
  ## Employee whose Home member is passed as a RemotingValue, so callers can
  ## share one Address instance between employees (diamond graphs); the
  ## writer dedupes by ref, emitting a MemberReference for repeats
  classValue(EmployeeClassName, PersonLibraryId,
    {"Name": toRemotingValue(name), "Home": home})

proc employeeArrayValue*(employees: seq[RemotingValue]): RemotingValue =
  ## Employee[] as a typed class array
  classArrayValue(EmployeeClassName, PersonLibraryId, employees)

# Node is the self-referential C# class used by the cyclic-graph and deep-list
# tests. classToObject cannot materialize it (a Nim object can't contain
# itself), so the tests walk the RemotingValue graph directly.

const NodeClassName* = "DotNimTester.Lib.Node"
const NodeLayout* = @["Label", "Next"]
  ## Member layout fallback for Node values arriving as ClassWithId

proc nodeValue*(label: string, next: RemotingValue): RemotingValue =
  classValue(NodeClassName, PersonLibraryId,
    {"Label": toRemotingValue(label), "Next": next})

proc setNext*(node, next: RemotingValue) =
  ## Rewires Next in place; closing a cycle is only possible after the
  ## referenced nodes exist
  node.classVal.members[1] = next

proc nextOf*(node: RemotingValue): RemotingValue =
  getMember(node, "Next", NodeLayout)

proc labelOf*(node: RemotingValue): string =
  getMember(node, "Label", NodeLayout).getString

proc ringValue*(size: int): RemotingValue =
  ## Cyclic list n0 -> n1 -> ... -> n(size-1) -> n0; the writer must emit the
  ## closing edge as a MemberReference to a record it is still writing
  result = nodeValue("n0", nullValue())
  var tail = result
  for i in 1..<size:
    let n = nodeValue("n" & $i, nullValue())
    setNext(tail, n)
    tail = n
  setNext(tail, result)

proc chainValue*(depth: int): RemotingValue =
  ## Straight list d0 -> d1 -> ... -> null, built tail-first so construction
  ## needs no recursion; serialization still nests depth levels on the wire
  result = nullValue()
  for i in countdown(depth - 1, 0):
    result = nodeValue("d" & $i, result)

proc kleinValue*(): RemotingValue =
  ## object[2] whose element 0 is the array itself
  result = objectArrayValue(@[nullValue(), toRemotingValue("hi")])
  result.arrayVal.elements[0] = result
