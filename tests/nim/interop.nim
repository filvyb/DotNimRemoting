import ../../src/DotNimRemoting

# Test-domain values (Person/Address/Employee) shared by the Nim interop
# client and server; the generic plumbing lives in the library.

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

#
# Test-domain value constructors
#

proc personValue*(name: string, age: int32, score: float64): RemotingValue =
  ## Member names must match the public fields of the C# class
  classValue(PersonClassName, PersonLibraryId, {
    "Name": toRemotingValue(name),
    "Age": toRemotingValue(age),
    "Score": toRemotingValue(score),
  })

proc addressValue*(street, city: string): RemotingValue =
  classValue(AddressClassName, PersonLibraryId, {
    "Street": toRemotingValue(street),
    "City": toRemotingValue(city),
  })

proc employeeValue*(name: string, address: RemotingValue): RemotingValue =
  ## Employee with a class-typed Home member
  classValue(EmployeeClassName, PersonLibraryId, {
    "Name": toRemotingValue(name),
    "Home": address,
  })

proc personArrayValue*(people: seq[RemotingValue]): RemotingValue =
  ## Person[] as a typed class array, so .NET materializes a typed array
  classArrayValue(PersonClassName, PersonLibraryId, people)

#
# Test-domain value extraction
#

proc personFields*(rv: RemotingValue): tuple[name: string, age: int32, score: float64] =
  ## Field order doubles as the fallback layout for ClassWithId records
  const layout = ["Name", "Age", "Score"]
  result.name = rv.getMember("Name", layout).getString
  result.age = rv.getMember("Age", layout).getInt32
  result.score = rv.getMember("Score", layout).getDouble

proc addressFields*(rv: RemotingValue): tuple[street, city: string] =
  const layout = ["Street", "City"]
  result.street = rv.getMember("Street", layout).getString
  result.city = rv.getMember("City", layout).getString

proc employeeFields*(rv: RemotingValue): tuple[name, street, city: string] =
  const layout = ["Name", "Home"]
  result.name = rv.getMember("Name", layout).getString
  let (street, city) = addressFields(rv.getMember("Home", layout))
  result.street = street
  result.city = city
