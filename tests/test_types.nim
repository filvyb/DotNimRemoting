import unittest
import strutils
import faststreams/[inputs, outputs]
import DotNimRemoting/msnrbf/types

suite "Common Data Types Tests":
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

  test "ASCII char serialization":
    let original = "A"
    var outStream = memoryOutput()
    writeChar(outStream, original)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readChar(inStream)
    check decoded == original
    check serialized.len == 1  # Single byte for ASCII

  test "Unicode char serialization":
    let testCases = [
      "π",   # Greek letter pi (2 bytes)
      "€",   # Euro sign (3 bytes)
      "🙂"  # Smiley face emoji (4 bytes)
    ]
    
    for original in testCases:
      var outStream = memoryOutput()
      writeChar(outStream, original)
      let serialized = outStream.getOutput(seq[byte])
      
      let inStream = memoryInput(serialized)
      let decoded = readChar(inStream)
      
      check decoded == original
      
      # Check correct number of bytes based on Unicode encoding
      let expectedLen = original.len # UTF-8 byte length
      check serialized.len == expectedLen

  test "Invalid UTF-8 sequences should raise IOError":
    # Create some invalid UTF-8 sequences
    let invalidSequences = [
      @[0xC0'u8, 0x80'u8],  # Invalid 2-byte sequence
      @[0xE0'u8, 0x80'u8],  # Incomplete 3-byte sequence
      @[0xF0'u8, 0x80'u8, 0x80'u8]  # Incomplete 4-byte sequence
    ]
    
    for invalid in invalidSequences:
      let inStream = memoryInput(invalid)
      expect IOError:
        discard readChar(inStream)

  test "Multiple Unicode characters should raise ValueError":
    let multipleChars = [
      "ab",     # Multiple ASCII chars
      "π€",     # Multiple Unicode chars
      "🙂😊",   # Multiple emoji
    ]
    
    for chars in multipleChars:
      var outStream = memoryOutput()
      expect ValueError:
        writeChar(outStream, chars)

  test "Empty char should raise ValueError":
    expect ValueError:
      var outStream = memoryOutput()
      writeChar(outStream, "")

  test "Double regular number serialization":
    let original = 3.14159265359
    var outStream = memoryOutput()
    writeDouble(outStream, original)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readDouble(inStream)
    check decoded == original
    check serialized.len == 8  # 64 bits = 8 bytes

  test "Double Infinity serialization":
    var outStream = memoryOutput()
    writeDouble(outStream, Inf)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readDouble(inStream)
    check decoded == Inf

  test "Double Negative Infinity serialization":
    var outStream = memoryOutput()
    writeDouble(outStream, NegInf)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readDouble(inStream)
    check decoded == NegInf

  test "Single regular number serialization":
    let original = 3.14159'f32
    var outStream = memoryOutput()
    writeSingle(outStream, original)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readSingle(inStream)
    check decoded == original
    check serialized.len == 4  # 32 bits = 4 bytes

  test "TimeSpan positive duration serialization":
    let oneSecond = 10_000_000'i64  # 1 second in 100ns ticks
    var outStream = memoryOutput()
    writeTimeSpan(outStream, oneSecond)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readTimeSpan(inStream)
    check decoded == oneSecond
    check serialized.len == 8  # 64 bits = 8 bytes

  test "TimeSpan negative duration serialization":
    let negativeTime = -10_000_000'i64
    var outStream = memoryOutput()
    writeTimeSpan(outStream, negativeTime)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readTimeSpan(inStream)
    check decoded == negativeTime

  test "DateTime Unix epoch UTC serialization":
    let unixEpochTicks = 621355968000000000'i64  # .NET ticks for Unix epoch
    let dt = DateTime(ticks: unixEpochTicks, kind: 1)  # UTC
    
    var outStream = memoryOutput()
    writeDateTime(outStream, dt)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readDateTime(inStream)
    
    check decoded.ticks == dt.ticks
    check decoded.kind == dt.kind
    check serialized.len == 8  # 64 bits = 8 bytes

  test "DateTime kind validation":
    for kind in 0'u8..2'u8:
      let dt = DateTime(ticks: 0'i64, kind: kind)
      var outStream = memoryOutput()
      writeDateTime(outStream, dt)
      let serialized = outStream.getOutput(seq[byte])
      
      let inStream = memoryInput(serialized)
      let decoded = readDateTime(inStream)
      check decoded.kind == kind

  test "DateTime invalid kind should raise ValueError":
    expect ValueError:
      let dt = DateTime(ticks: 0'i64, kind: 3)
      var outStream = memoryOutput()
      writeDateTime(outStream, dt)

  test "Decimal positive number serialization":
    let original = "123.456"
    var outStream = memoryOutput()
    writeDecimal(outStream, Decimal(value: original))
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readDecimal(inStream)
    check decoded.value == original

  test "Decimal negative number serialization":
    let original = "-123.456"
    var outStream = memoryOutput()
    writeDecimal(outStream, Decimal(value: original))
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readDecimal(inStream)
    check decoded.value == original

  test "Decimal zero serialization":
    let original = "0"
    var outStream = memoryOutput()
    writeDecimal(outStream, Decimal(value: original))
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readDecimal(inStream)
    check decoded.value == original

  test "Decimal invalid format should raise ValueError":
    let invalidDecimals = ["", ".", "123.", ".123", "12.34.56", "abc", "-", "+-123"]
    for invalid in invalidDecimals:
      expect ValueError:
        var outStream = memoryOutput()
        writeDecimal(outStream, Decimal(value: invalid))

  test "ClassTypeInfo basic serialization":
    let original = ClassTypeInfo(
      typeName: LengthPrefixedString(value: "MyNamespace.MyClass"),
      libraryId: 12345
    )
    
    var outStream = memoryOutput()
    writeClassTypeInfo(outStream, original)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readClassTypeInfo(inStream)
    
    check decoded.typeName.value == original.typeName.value
    check decoded.libraryId == original.libraryId

  test "ClassTypeInfo with empty type name":
    let original = ClassTypeInfo(
      typeName: LengthPrefixedString(value: ""),
      libraryId: 0
    )
    
    var outStream = memoryOutput()
    writeClassTypeInfo(outStream, original)
    let serialized = outStream.getOutput(seq[byte])
    
    let inStream = memoryInput(serialized)
    let decoded = readClassTypeInfo(inStream)
    
    check decoded.typeName.value == original.typeName.value
    check decoded.libraryId == original.libraryId
    
  # Float to Decimal conversion tests
  test "Float to Decimal basic conversion":
    let f = 123.456
    let d = toDecimal(f)
    check d.value == "123.456"
    
  test "Float to Decimal with scientific notation":
    let f = 1.234e5
    let d = toDecimal(f)
    check d.value == "123400"
    
  test "Float to Decimal with negative value":
    let f = -987.654
    let d = toDecimal(f)
    check d.value == "-987.654"
    
  test "Float to Decimal with rounding - integral digits":
    # Nim float can't represent the full precision we're testing, so we'll test
    # with values that it can accurately represent
    let f = 1.123456789012346
    let d = toDecimal(f)
    check d.value == "1.123456789012346"
    
  test "Float to Decimal with rounding - many integral digits":
    # Test where the integral part uses most of the allowed 29 digits
    # But work within float64 precision limits
    let f = 12345678901234568.0
    let d = toDecimal(f)
    # Should be represented correctly
    check d.value == "12345678901234568"
    
  test "Float to Decimal with precision limits":
    # Test a value that is within float precision
    let f = 1.234567890123457
    let d = toDecimal(f)
    check d.value == "1.234567890123457"
  