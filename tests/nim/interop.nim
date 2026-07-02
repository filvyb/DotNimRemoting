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
