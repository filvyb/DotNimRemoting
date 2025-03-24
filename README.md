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

### Server Example

```nim
import faststreams/inputs
import DotNimRemoting/tcp/[server, common]
import DotNimRemoting/msnrbf/[grammar, enums, helpers]
import DotNimRemoting/msnrbf/records/member
import asyncdispatch

proc echoHandler(requestUri, methodName, typeName: string, requestData: seq[byte]): Future[seq[byte]] {.async.} =
  var input = memoryInput(requestData)
  let msg = readRemotingMessage(input)
  if msg.methodCall.isSome:
    let call = msg.methodCall.get
    if call.args.len > 0 and call.args[0].primitiveType == ptString:
      let inputStr = call.args[0].value.stringVal.value
      return createMethodReturnResponse(stringValue(inputStr))
  return createMethodReturnResponse()

proc main() {.async.} =
  let server = newNrtpTcpServer(8080)
  server.registerHandler("/EchoService", echoHandler)
  await server.start()

waitFor main()
```

### Client Example

```nim
import faststreams/inputs
import DotNimRemoting/tcp/[client, common]
import DotNimRemoting/msnrbf/[helpers, grammar, enums]
import asyncdispatch

proc main() {.async.} =
  let typename = "DotNimTester.Lib.IEchoService, Lib"
  let client = newNrtpTcpClient("tcp://127.0.0.1:8080/EchoService")
  await client.connect()
  let requestData = createMethodCallRequest(
    methodName = "Echo",
    typeName = typename,
    args = @[stringValue("Hello from Nim")]
  )
  let responseData = await client.invoke("Echo", typename, false, requestData)
  
  # Parse response
  var input = memoryInput(responseData)
  let msg = readRemotingMessage(input)
  if msg.methodReturn.isSome:
    let ret = msg.methodReturn.get
    if ret.returnValue.primitiveType == ptString:
      echo "Response: ", ret.returnValue.value.stringVal.value
  await client.close()

waitFor main()
```

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
proc connect*(client: NrtpTcpClient): Future[void]
```
Connects to the remote server.

```nim
proc invoke*(client: NrtpTcpClient, methodName: string, typeName: string, 
             isOneWay: bool = false, requestData: seq[byte]): Future[seq[byte]]
```
Invokes a remote method and returns the response.

```nim
proc close*(client: NrtpTcpClient): Future[void]
```
Closes the connection to the remote server.

### TCP Server

```nim
proc newNrtpTcpServer*(port: int): NrtpTcpServer
```
Creates a new MS-NRTP server for TCP communication.

```nim
proc registerHandler*(server: NrtpTcpServer, path: string, handler: RequestHandler)
```
Registers a handler for a specific server object URI path.

```nim
proc start*(server: NrtpTcpServer): Future[void]
```
Starts the server and begins listening for connections.

```nim
proc stop*(server: NrtpTcpServer): Future[void]
```
Stops the server.

## License

MIT License

## Dependencies

- Nim >= 2.0.0
- faststreams
