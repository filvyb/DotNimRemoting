import faststreams/[inputs, outputs]
import ../enums
import ../types
#import class

type
  SerializationHeaderRecord* = object
    ## Section 2.6.1 SerializationHeaderRecord
    ## Must be the first record in a binary serialization
    recordType*: RecordType   # Must be rtSerializedStreamHeader
    rootId*: int32           # Root object ID
    headerId*: int32         # Header array ID 
    majorVersion*: int32     # Major version, must be 1
    minorVersion*: int32     # Minor version, must be 0

  BinaryLibrary* = object
    ## Section 2.6.2 BinaryLibrary 
    ## Associates a library name with an ID for referencing
    recordType*: RecordType      # Must be rtBinaryLibrary
    libraryId*: int32           # Unique positive ID
    libraryName*: LengthPrefixedString # Name of library

  MessageEnd* = object
    ## Section 2.6.3 MessageEnd
    ## Marks the end of serialization stream
    recordType*: RecordType      # Must be rtMessageEnd

# Reading procedures
proc readSerializationHeader*(inp: InputStream): SerializationHeaderRecord =
  ## Reads SerializationHeaderRecord from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtSerializedStreamHeader:
    raise newException(IOError, "Invalid serialization header record type")
    
  if not inp.readable(16): # Need 16 bytes for 4 int32s
    raise newException(IOError, "Incomplete serialization header - expected 16 bytes")
    
  # Read 4 int32 fields
  var bytes: array[16, byte] 
  if not inp.readInto(bytes):
    raise newException(IOError, "Failed to read header data")
    
  result.rootId = cast[ptr int32](bytes[0].unsafeAddr)[]
  result.headerId = cast[ptr int32](bytes[4].unsafeAddr)[]
  result.majorVersion = cast[ptr int32](bytes[8].unsafeAddr)[]
  result.minorVersion = cast[ptr int32](bytes[12].unsafeAddr)[]
  
  # Validate version numbers
  if result.majorVersion != 1 or result.minorVersion != 0:
    raise newException(IOError, "Unsupported serialization format version")

proc readBinaryLibrary*(inp: InputStream): BinaryLibrary =
  ## Reads BinaryLibrary record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtBinaryLibrary:
    raise newException(IOError, "Invalid binary library record type")
    
  result.libraryId = readValueWithContext[int32](inp, "reading library ID for BinaryLibrary")
  
  if result.libraryId <= 0:
    raise newException(IOError, "Library ID must be positive")
    
  result.libraryName = readLengthPrefixedString(inp)

proc readMessageEnd*(inp: InputStream): MessageEnd =
  ## Reads MessageEnd record from stream
  result.recordType = readRecord(inp)
  if result.recordType != rtMessageEnd:
    raise newException(IOError, "Invalid message end record type")

# Writing procedures 
proc writeSerializationHeader*(outp: OutputStream, hdr: SerializationHeaderRecord) =
  ## Writes SerializationHeaderRecord to stream
  writeRecord(outp, hdr.recordType)
  outp.write(cast[array[4, byte]](hdr.rootId))
  outp.write(cast[array[4, byte]](hdr.headerId))
  outp.write(cast[array[4, byte]](hdr.majorVersion))
  outp.write(cast[array[4, byte]](hdr.minorVersion))

proc writeBinaryLibrary*(outp: OutputStream, lib: BinaryLibrary) =
  ## Writes BinaryLibrary record to stream
  if lib.recordType != rtBinaryLibrary:
    raise newException(ValueError, "Invalid binary library record type")
  writeRecord(outp, lib.recordType)
  outp.write(cast[array[4, byte]](lib.libraryId))
  writeLengthPrefixedString(outp, lib.libraryName.value)

proc writeMessageEnd*(outp: OutputStream, msgEnd: MessageEnd) =
  ## Writes MessageEnd record to stream
  if msgEnd.recordType != rtMessageEnd:
    raise newException(ValueError, "Invalid message end record type")
  writeRecord(outp, msgEnd.recordType)
