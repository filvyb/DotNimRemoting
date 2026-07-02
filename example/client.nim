import ../src/DotNimRemoting

type Person = object
  Name: string
  Age: int32

# Example client: calling a .NET remoting service
proc clientExample() {.async.} =
  let client = newNrtpTcpClient("tcp://localhost:8080/MyServer.rem")
  let serviceType = "MyNamespace.IMyService, MyAssembly"

  let greeting = await client.call("Echo", serviceType, "Hello, world!")
  echo "Echo -> ", greeting.getString()

  let sum = await client.call("Add", serviceType, 40, 2)
  echo "Add -> ", sum.getInt32()

  # A seq becomes a .NET array argument
  let total = await client.call("SumIntArray", serviceType, @[1'i32, 2, 3])
  echo "SumIntArray -> ", total.getInt32()

  # Plain Nim objects convert to class values with objectToClass; they need
  # the library (assembly) record they reference
  let lib = binaryLibrary("MyAssembly, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null", 100)
  let person = objectToClass(Person(Name: "Ada", Age: 36),
                             "MyNamespace.Person", lib.libraryId)
  let described = await client.call("DescribePerson", serviceType, @[person], @[lib])
  echo "DescribePerson -> ", described.getString()

  await client.close()

# Run client example
when isMainModule:
  waitFor clientExample()
