## DotNimRemoting — talk to .NET applications over MS-NRTP / MS-NRBF.
##
## The only import most applications need: TCP client/server plus the value
## helpers. Protocol internals (records, wire framing, serialization
## contexts) stay under DotNimRemoting/tcp/* and DotNimRemoting/msnrbf/*.
## See the README and example/ for usage.

import DotNimRemoting/tcp/[client, server, common]
import DotNimRemoting/msnrbf/[helpers, grammar, enums, types]
import DotNimRemoting/msnrbf/records/[methodinv, serialization, member]
import std/[asyncdispatch, options]

export client, server, common
export helpers, grammar, enums, types
export methodinv, serialization, member
export asyncdispatch, options
