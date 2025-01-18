import faststreams/[inputs, outputs]
import strutils
import unicode
import macros

type
  Char* = string
    ## Section 2.1.1.1 - Unicode character value
    ## Must represent exactly one Unicode character
  
  Double* = float64
    ## Section 2.1.1.2 - IEEE 754 64-bit floating point number
  
  Single* = float32
    ## Section 2.1.1.3 - IEEE 754 32-bit floating point number

  TimeSpan* = int64
    ## Section 2.1.1.4 - Time duration as 100ns ticks

  DateTime* = object
    ## Section 2.1.1.5 - Time instant
    ticks*: int64  # 62 bits - Number of 100ns ticks since 12:00:00, January 1, 0001
    kind*: uint8   # 2 bits - 0=unspecified, 1=UTC, 2=local
  
  LengthPrefixedString* = object
    ## Section 2.1.1.6 - Length-prefixed string
    value*: string

  Decimal* = LengthPrefixedString
    ## Section 2.1.1.7 - Decimal number
    ## Must contain valid decimal string with optional - prefix and . separator
 
  ClassTypeInfo* = object
    ## Section 2.1.1.8 - Identifies a Class by name and library reference
    typeName*: LengthPrefixedString  # Name of class
    libraryId*: int32               # ID that references BinaryLibrary record

# Reading procedures
template readValueImpl[T](context: string, inp: InputStream): T =
  ## Implementation template that includes error context
  when sizeof(T) > 0:
    if not inp.readable(sizeof(T)):
      # Include type, size and context in error
      raise newException(IOError, "Not enough bytes to read " & $T & " (need " & $sizeof(T) & " bytes) at " & context)
    var bytes: array[sizeof(T), byte]
    if not inp.readInto(bytes):
      raise newException(IOError, "Failed to read " & $T & " at " & context)
    cast[T](bytes)
  else:
    default(T)

template readValue*[T](inp: InputStream): T =
  ## Wrapper that adds line information to context
  readValueImpl[T]("line " & $lineInfoObj().line, inp)

template readValueWithContext*[T](inp: InputStream, context: string): T =
  ## Allows adding custom context to error message
  readValueImpl[T](context, inp)

proc readChar*(inp: InputStream): Char =
  ## Reads UTF-8 encoded character
  # First need to peek at the first byte to determine length
  if not inp.readable:
    raise newException(IOError, "Not enough bytes for char")
    
  let firstByte = inp.peek
  let len = if (firstByte and 0x80'u8) == 0: 1
            elif (firstByte and 0xE0'u8) == 0xC0: 2 
            elif (firstByte and 0xF0'u8) == 0xE0: 3
            elif (firstByte and 0xF8'u8) == 0xF0: 4
            else: raise newException(IOError, "Invalid UTF-8 start byte")

  if not inp.readable(len):
    raise newException(IOError, "Incomplete UTF-8 sequence")

  result = newString(len)
  if not inp.readInto(result.toOpenArrayByte(0, len-1)):
    raise newException(IOError, "Failed to read UTF-8 sequence")

  if validateUtf8(result) != -1:
    raise newException(IOError, "Invalid UTF-8 sequence")

  if result.runeLen != 1:
    raise newException(IOError, "Must be exactly one Unicode character")

proc readDouble*(inp: InputStream): Double =
  ## Reads 64-bit double
  if not inp.readable(8):
    raise newException(IOError, "Not enough bytes for double")
  var bytes: array[8, byte]
  discard inp.readInto(bytes)
  result = cast[float64](bytes)

proc readSingle*(inp: InputStream): Single =
  ## Reads 32-bit float 
  if not inp.readable(4):
    raise newException(IOError, "Not enough bytes for float")
  var bytes: array[4, byte]
  discard inp.readInto(bytes)
  result = cast[float32](bytes)

proc readTimeSpan*(inp: InputStream): TimeSpan =
  ## Reads 64-bit timespan ticks
  if not inp.readable(8):
    raise newException(IOError, "Not enough bytes for timespan")
  var bytes: array[8, byte]
  discard inp.readInto(bytes)
  result = cast[int64](bytes)

proc readDateTime*(inp: InputStream): DateTime =
  ## Reads DateTime value - 64 bits total
  ## - 62 bits for ticks
  ## - 2 bits for kind
  if not inp.readable(8):
    raise newException(IOError, "Not enough bytes for datetime")
    
  var bytes: array[8, byte]
  discard inp.readInto(bytes)
  let raw = cast[int64](bytes)
  
  # Extract kind from last 2 bits
  result.kind = uint8(raw and 0b11)
  # Extract ticks from first 62 bits
  result.ticks = raw shr 2

proc readLengthPrefixedString*(inp: InputStream): LengthPrefixedString =
  ## Reads a length-prefixed string from stream using variable length encoding
  var length = 0
  var shift = 0
  
  # Read 7 bits at a time until high bit is 0
  while inp.readable:
    let b = inp.read
    length = length or ((int(b and 0x7F)) shl shift)
    if (b and 0x80) == 0:
      break
    shift += 7
    if shift > 35:
      raise newException(IOError, "Invalid string length encoding")

  # Read the actual string data
  if length > 0:
    var buffer = newString(length)
    if inp.readInto(buffer.toOpenArrayByte(0, length-1)):
      result.value = buffer
    else:
      raise newException(IOError, "Incomplete string data")

proc validateDecimalFormat(s: string): bool =
  if s.len == 0: return false
  
  var pos = 0
  # Optional minus sign
  if pos < s.len and s[pos] == '-':
    inc pos
  
  # Must have at least one digit in integral part
  if pos >= s.len or not s[pos].isDigit:
    return false
  
  # Consume all digits of integral part
  while pos < s.len and s[pos].isDigit:
    inc pos
    
  # Optional fractional part
  if pos < s.len:
    if s[pos] != '.': return false
    inc pos
    # Must have at least one digit after decimal point
    if pos >= s.len or not s[pos].isDigit:
      return false
    # Consume all remaining digits
    while pos < s.len and s[pos].isDigit:
      inc pos
      
  # Should have consumed entire string
  result = (pos == s.len)

proc readDecimal*(inp: InputStream): Decimal =
  ## Reads decimal from length-prefixed string representation
  let str = readLengthPrefixedString(inp)
  if not validateDecimalFormat(str.value):
    raise newException(IOError, "Invalid decimal format: " & str.value)
  result = str

proc readClassTypeInfo*(inp: InputStream): ClassTypeInfo =
  ## Reads ClassTypeInfo structure from stream
  result.typeName = readLengthPrefixedString(inp)
  
  if not inp.readable(4):
    raise newException(IOError, "Missing library ID in ClassTypeInfo")
  
  var bytes: array[4, byte]
  discard inp.readInto(bytes)
  result.libraryId = cast[int32](bytes)


# Writing procedures
template writeValue*[T](outp: OutputStream, val: T) =
  ## Generic template for writing a fixed-size value to stream
  when sizeof(T) > 0:
    outp.write(cast[array[sizeof(T), byte]](val))

template writeValues*[T](outp: OutputStream, vals: varargs[T]) =
  ## Write multiple values of same type
  for val in vals:
    writeValue[T](outp, val)

proc writeChar*(outp: OutputStream, c: Char) =
  ## Writes UTF-8 encoded character
  if c.len == 0:
    raise newException(ValueError, "Empty char")
  if c.runeLen != 1:
    raise newException(ValueError, "Must be exactly one Unicode character")
  outp.write(c.toOpenArrayByte(0, c.len-1))

proc writeDouble*(outp: OutputStream, d: Double) =
  ## Writes 64-bit double
  let bytes = cast[array[8, byte]](d)
  outp.write(bytes)

proc writeSingle*(outp: OutputStream, s: Single) =
  ## Writes 32-bit float
  let bytes = cast[array[4, byte]](s)
  outp.write(bytes)

proc writeTimeSpan*(outp: OutputStream, ts: TimeSpan) =
  ## Writes 64-bit timespan ticks
  let bytes = cast[array[8, byte]](ts)
  outp.write(bytes)

proc writeDateTime*(outp: OutputStream, dt: DateTime) =
  ## Writes DateTime value as 64 bits
  ## Combines 62-bit ticks with 2-bit kind
  if dt.kind > 2:
    raise newException(ValueError, "Invalid DateTime kind")
    
  # Combine ticks and kind into 64 bits
  let combined = (dt.ticks shl 2) or int64(dt.kind)
  let bytes = cast[array[8, byte]](combined) 
  outp.write(bytes)

proc writeLengthPrefixedString*(outp: OutputStream, s: string) =
  ## Writes a length-prefixed string to stream using variable length encoding
  var length = s.len
  
  # Write length using 7 bits per byte with high bit indicating continuation
  while length >= 0x80:
    outp.write(byte((length and 0x7F) or 0x80))
    length = length shr 7
  outp.write(byte(length))

  # Write string data
  if length > 0:
    outp.write(s)

proc writeDecimal*(outp: OutputStream, d: Decimal) =
  ## Writes decimal as length-prefixed string
  if not validateDecimalFormat(d.value):
    raise newException(ValueError, "Invalid decimal format: " & d.value)
  writeLengthPrefixedString(outp, d.value)

proc writeClassTypeInfo*(outp: OutputStream, cti: ClassTypeInfo) =
  ## Writes ClassTypeInfo structure to stream
  writeLengthPrefixedString(outp, cti.typeName.value)
  outp.write(cast[array[4, byte]](cti.libraryId))
