# DotNimRemoting

A Nim library for communicating with .NET applications using MS-NRTP protocol.

## Features

- TCP client and server implementation for .NET remoting
- Full support for MS-NRBF serialization/deserialization
- Async API using Nim's asyncdispatch
- Cross-platform compatible

## Installation

```bash
nimble install dotnimremoting
```

Or add to your .nimble file:

```
requires "dotnimremoting"
```

## Quick Start

A single `import DotNimRemoting` brings in everything the examples below use.

### Client Example

```nim
import DotNimRemoting

proc main() {.async.} =
  let typename = "DotNimTester.Lib.IEchoService, Lib"
  let client = newNrtpTcpClient("tcp://127.0.0.1:8080/EchoService")

  # Plain Nim values convert to arguments; the result is a RemotingValue
  let greeting = await client.call("Echo", typename, "Hello from Nim")
  echo "Echo -> ", greeting.getString()

  let sum = await client.call("Add", typename, 40, 2)
  echo "Add -> ", sum.getInt32()

  # A seq becomes a .NET array
  let total = await client.call("SumIntArray", typename, @[1'i32, 2, 3])
  echo "SumIntArray -> ", total.getInt32()

  await client.close()

waitFor main()
```

### Server Example

```nim
import DotNimRemoting

proc echoService(methodName: string, args: seq[RemotingValue]): Future[RemotingValue] {.async.} =
  case methodName
  of "Echo":
    return args[0]
  of "Add":
    return toRemotingValue(args[0].getInt32 + args[1].getInt32)
  else:
    return nullValue()  # void response

proc main() {.async.} =
  let server = newNrtpTcpServer(8080)
  server.registerService("/EchoService", echoService)
  await server.start()

waitFor main()
```

### Custom Classes

Plain Nim objects convert to class values with `objectToClass` and back with
`classToObject`; class values reference a library (assembly) record created
with `binaryLibrary`:

```nim
type Person = object
  Name: string
  Age: int32
  Score: float64

let lib = binaryLibrary("Lib, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null", 100)
let ada = objectToClass(Person(Name: "Ada", Age: 36, Score: 99.5),
                        "DotNimTester.Lib.Person", lib.libraryId)
let r = await client.call("EchoPerson", typename, @[ada], @[lib])
echo classToObject[Person](r)
```

For ad-hoc members without a Nim type, build the value directly with
`classValue(className, libraryId, {"Name": toRemotingValue("Ada"), ...})` and
read members with `r["Name"].getString()`. Nested class-typed fields work by
defining a `toRemotingValue` overload for the field's type.

Calls that fail on the .NET side raise `RemoteException`, carrying the .NET
exception type in `className` and its message in `msg`.

For full-control scenarios (custom records, manual wire layout), the protocol
layers remain available under `DotNimRemoting/tcp/*` and
`DotNimRemoting/msnrbf/*` (see `registerHandler`, `invoke` and the
`msnrbf/records` modules).

### Additional examples

For further examples check `examples`, `tests/nim/` and project [OlyVIADownloader](https://github.com/filvyb/OlyVIADownloader).

## .NET Interoperability

DotNimRemoting allows you to:

1. Call .NET remoting services from Nim applications
2. Create .NET remoting services in Nim that can be consumed by .NET clients
3. Serialize and deserialize .NET objects using Microsoft Binary Format Data Structures

For testing .NET interop, check the examples in the `tests/` directory.

## Building and Testing

```bash
# Build the library
nimble build

# Build the library with debugging messages
nimble build -d:dbgEcho

# Install the library
nimble install

# Run all tests
nimble test

# Run a specific test
nim c -r tests/test_grammar.nim

# Test .NET interop
nim c -r tests/nim/server.nim
nim c -r tests/nim/client.nim
```

## API Documentation

### TCP Client

```nim
proc newNrtpTcpClient*(serverUri: string, timeout: int = DefaultTimeout): NrtpTcpClient
```
Creates a new MS-NRTP client for TCP communication.
- `serverUri`: URI in the format `tcp://hostname:port/path`

```nim
proc call*(client: NrtpTcpClient, methodName, typeName: string,
           args: varargs[RemotingValue, toRemotingValue]): Future[RemotingValue]
proc call*(client: NrtpTcpClient, methodName, typeName: string,
           args: seq[RemotingValue], libraries: seq[BinaryLibrary] = @[]): Future[RemotingValue]
```
Calls a remote method and returns its result with member references resolved.
Picks the wire layout automatically; raises `RemoteException` when the server
replies with a .NET exception. `callOneWay` is the fire-and-forget variant.

```nim
proc invoke*(client: NrtpTcpClient, methodName: string, typeName: string,
             isOneWay: bool = false, requestData: seq[byte]): Future[seq[byte]]
```
Lower-level: sends pre-serialized MS-NRBF bytes and returns the raw response.

```nim
proc connect*(client: NrtpTcpClient): Future[void]
proc close*(client: NrtpTcpClient): Future[void]
```
Connects to / disconnects from the remote server (`call` connects on demand).

### TCP Server

```nim
proc newNrtpTcpServer*(port: int): NrtpTcpServer
```
Creates a new MS-NRTP server for TCP communication.

```nim
proc registerService*(server: NrtpTcpServer, path: string, service: ServiceHandler,
                      libraries: seq[BinaryLibrary] = @[])
```
Registers a method-level service for a server object URI path. The handler
receives the method name and arguments as `RemotingValue`s and returns the
result value; parsing, layout selection and serialization happen in the
wrapper.

```nim
proc registerHandler*(server: NrtpTcpServer, path: string, handler: RequestHandler)
```
Lower-level: registers a raw handler that parses and produces MS-NRBF payload
bytes itself.

```nim
proc start*(server: NrtpTcpServer): Future[void]
proc stop*(server: NrtpTcpServer): Future[void]
```
Starts/stops the server.

### Working with values

- `toRemotingValue(x)` - converts Nim bools, ints, floats, strings and seqs
  of them to `RemotingValue`s; `nullValue()` is the .NET null.
- `classValue(name, libraryId, members)`, `systemClassValue`,
  `classArrayValue`, `objectArrayValue` - build class instances and arrays.
- `objectToClass(obj)` / `classToObject[T](rv)` - convert between plain Nim
  objects and class values by field name.
- `binaryLibrary(name, id)` - the assembly record class values reference.
- `getString`, `getInt32`, `getDouble`, … - typed accessors that raise
  `ValueError` on kind mismatches; `rv[i]`/`rv.elements` index arrays,
  `rv["Member"]`/`rv.getMember` look up class members, `rv.className` and
  `rv.isNull` inspect the value.
- On parsed messages: `callArgs`, `returnValueOf`, `methodNameOf`,
  `typeNameOf` extract data with references already resolved.

## License

MIT License

## Dependencies

- Nim >= 2.0.0
- faststreams
