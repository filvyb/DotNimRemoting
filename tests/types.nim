import unittest
import strutils
import faststreams/[inputs, outputs]
import msnrbf/types

suite "NRBF String Tests":
  test "LengthPrefixedString decoding":
    # Original hex bytes: 12 13 47 65 74 49 6e 74 65 72 66 61 63 65 56 65 72 73 69 6f 6e
    # 0x12 = 18 -> String type marker (we don't need this for our test)
    # 0x13 = 19 -> String length
    # Rest are ASCII bytes for "GetInterfaceVersion"
    
    let inputBytes = @[
      0x13'u8,  # Length = 19
      0x47'u8, 0x65'u8, 0x74'u8, 0x49'u8, 0x6e'u8, 0x74'u8, 0x65'u8, 0x72'u8,
      0x66'u8, 0x61'u8, 0x63'u8, 0x65'u8, 0x56'u8, 0x65'u8, 0x72'u8, 0x73'u8,
      0x69'u8, 0x6f'u8, 0x6e'u8
    ]
    
    let inp = memoryInput(inputBytes)
    let str = readLengthPrefixedString(inp)
    
    check str.value == "GetInterfaceVersion"

  test "LengthPrefixedString round trip":
    let original = "GetInterfaceVersion"
    
    # Write to a memory stream
    var outStream = memoryOutput()
    writeLengthPrefixedString(outStream, original)
    let serialized = outStream.getOutput(seq[byte])
    
    # Read back from memory stream
    let inStream = memoryInput(serialized)
    let decoded = readLengthPrefixedString(inStream)
    
    check decoded.value == original
    
    # Verify first byte is correct length
    check serialized[0] == 0x13'u8  # Length should be 19
    
  test "Empty string":
    let original = ""
    var outStream = memoryOutput()
    writeLengthPrefixedString(outStream, original)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readLengthPrefixedString(inStream)
    
    check decoded.value == original
    check serialized[0] == 0x00'u8  # Length should be 0

  test "String with length requiring multiple bytes":
    # Generate a string > 127 chars to test multi-byte length encoding
    let original = repeat('a', 130)
    var outStream = memoryOutput()
    writeLengthPrefixedString(outStream, original)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readLengthPrefixedString(inStream)
    
    check decoded.value == original
    # First byte should have high bit set indicating more bytes follow
    check (serialized[0] and 0x80'u8) != 0
