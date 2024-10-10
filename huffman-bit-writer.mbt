/// This file is based on the Go implementation found here:
/// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/huffman_bit_writer.go
/// which has the copyright notice:
/// Copyright 2009 The Go Authors. All rights reserved.
/// Use of this source code is governed by a BSD-style
/// license that can be found in the LICENSE file.

// The largest offset code.
let offset_code_count = 30

// The special code used to mark the end of a block.
let end_block_marker = 256

// The first length code.
let length_codes_start = 257

// The number of codegen codes.
let codegen_code_count = 19

let bad_code = b'\xff'

// buffer_flush_size indicates the buffer size
// after which bytes are flushed to the writer.
// Should preferably be a multiple of 6, since
// we accumulate 6 bytes between writes to the buffer.
let buffer_flush_size = 240

// buffer_size is the actual output byte buffer size.
// It must have additional headroom for a flush
// which can contain up to 8 bytes.
let buffer_size : Int = buffer_flush_size + 8

// The number of extra bits needed by length code X - LENGTH_CODES_START.
let length_extra_bits : Array[Int] = [
  0, 0, 0, // /* 257 */
   0, 0, 0, 0, 0, 1, 1, 1, 1, 2, // /* 260 */
   2, 2, 2, 3, 3, 3, 3, 4, 4, 4, // /* 270 */
   4, 5, 5, 5, 5, 0, // /* 280 */
]

// The length indicated by length code X - LENGTH_CODES_START.
let length_base : Array[UInt] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80,
  96, 112, 128, 160, 192, 224, 255,
]

// offset code word extra bits.
let offset_extra_bits : Array[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

let offset_base : Array[UInt] = [
  0x000000, 0x000001, 0x000002, 0x000003, 0x000004, 0x000006, 0x000008, 0x00000c,
  0x000010, 0x000018, 0x000020, 0x000030, 0x000040, 0x000060, 0x000080, 0x0000c0,
  0x000100, 0x000180, 0x000200, 0x000300, 0x000400, 0x000600, 0x000800, 0x000c00,
  0x001000, 0x001800, 0x002000, 0x003000, 0x004000, 0x006000,
]

// The odd order in which the codegen code sizes are written.
let codegen_order : Array[Int] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

struct HuffmanBitWriter {
  // writer is the underlying writer.
  // Do not use it directly; use the write method, which ensures
  // that Write errors are sticky.
  writer : Buffer

  // Data waiting to be written is bytes[0:nbytes]
  // and then the low nbits of bits.  Data is always written
  // sequentially into the bytes array.
  mut bits : UInt64
  mut nbits : UInt
  bytes : FixedArray[Byte] // [buffer_size]byte
  // codegen_freq : FixedArray[Int] // [codegen_code_count]int32
  codegen_freq : Array[Int] // [codegen_code_count]int32
  mut nbytes : Int
  literal_freq : Array[Int]
  offset_freq : Array[Int]
  codegen : Bytes
  literal_encoding : HuffmanEncoder
  offset_encoding : HuffmanEncoder
  codegen_encoding : HuffmanEncoder
  mut err : Error?
} derive(Show)

fn HuffmanBitWriter::new(writer : Buffer) -> HuffmanBitWriter {
  let literal_freq = Array::make(max_num_lit, 0)
  let offset_freq = Array::make(offset_code_count, 0)
  let codegen = Bytes::make(max_num_lit + offset_code_count + 1, b'\x00')
  let literal_encoding = HuffmanEncoder::new(max_num_lit)
  let codegen_encoding = HuffmanEncoder::new(codegen_code_count)
  let offset_encoding = HuffmanEncoder::new(offset_code_count)
  let bytes = FixedArray::make(buffer_size, b'\x00') // [buffer_size]byte
  // let codegen_freq = FixedArray::make(codegen_code_count, 0) // [codegen_code_count]int32
  let codegen_freq = Array::make(codegen_code_count, 0) // [codegen_code_count]int32
  {
    writer,
    bits: 0,
    nbits: 0,
    bytes,
    codegen_freq,
    nbytes: 0,
    literal_freq,
    offset_freq,
    codegen,
    literal_encoding,
    offset_encoding,
    codegen_encoding,
    err: None,
  }
}

fn flush(self : HuffmanBitWriter) -> Unit {
  if not(self.err.is_empty()) {
    self.nbits = 0
    return
  }
  let mut n = self.nbytes
  while self.nbits != 0 {
    self.bytes[n] = self.bits.to_byte()
    self.bits = self.bits >> 8
    if self.nbits > 8 { // Avoid underflow
      self.nbits -= 8
    } else {
      self.nbits = 0
    }
    n += 1
  }
  self.bits = 0
  let b = Bytes::from_iter(self.bytes.iter().take(n))
  self.write(b)
  self.nbytes = 0
}

fn write(self : HuffmanBitWriter, b : Bytes) -> Unit {
  println(
    "GML: huffman_bit_writer.go: (w *huffmanBitWriter) write(b []byte) {: b=\{dump_bytes(b)}",
  )
  if not(self.err.is_empty()) {
    return
  }
  self.writer.write_bytes(b)
}

pub fn dump_bytes(buf : Bytes) -> Array[Int] {
  buf.to_array().map(fn(b) { b.to_int() })
}

fn write_byte(self : HuffmanBitWriter, b : Byte) -> Unit {
  if not(self.err.is_empty()) {
    return
  }
  self.writer.write_byte(b)
}

fn write_bits(self : HuffmanBitWriter, b : Int, nb : UInt) -> Unit {
  println(
    "GML: huffman_bit_writer.go: (w *huffmanBitWriter) writeBits(b int32, nb uint) {: b=\{b}, nb=\{nb}, self.bits=\{self.bits}, self.nbits=\{self.nbits}",
  )
  if not(self.err.is_empty()) {
    return
  }
  self.bits = self.bits |
    (b.reinterpret_as_uint().to_uint64() << self.nbits.reinterpret_as_int())
  println("GML: huffman_bit_writer.go: writeBits: self.bits=\{self.bits}")
  self.nbits += nb
  if self.nbits >= 48 {
    let bits = self.bits
    self.bits = self.bits >> 48
    self.nbits -= 48
    let mut n = self.nbytes
    // let bytes = self.bytes[n : n+6]
    self.bytes[n + 0] = bits.to_byte()
    self.bytes[n + 1] = (bits >> 8).to_byte()
    self.bytes[n + 2] = (bits >> 16).to_byte()
    self.bytes[n + 3] = (bits >> 24).to_byte()
    self.bytes[n + 4] = (bits >> 32).to_byte()
    self.bytes[n + 5] = (bits >> 40).to_byte()
    n += 6
    if n >= buffer_flush_size {
      let b = Bytes::from_iter(self.bytes.iter().take(n))
      self.write(b)
      n = 0
    }
    self.nbytes = n
  }
}

fn write_bytes(self : HuffmanBitWriter, bytes : Bytes) -> Unit {
  if not(self.err.is_empty()) {
    return
  }
  let mut n = self.nbytes
  if (self.nbits & 7U) != 0U {
    self.err = Some(InternalError("write_bytes with unfinished bits"))
    return
  }
  while self.nbits != 0U {
    self.bytes[n] = self.bits.to_byte()
    self.bits = self.bits >> 8
    self.nbits -= 8
    n += 1
  }
  if n != 0 {
    let b = Bytes::from_iter(self.bytes.iter().take(n))
    self.write(b)
  }
  self.nbytes = 0
  self.write(bytes)
}

// RFC 1951 3.2.7 specifies a special run-length encoding for specifying
// the literal and offset lengths arrays (which are concatenated into a single
// array).  This method generates that run-length encoding.
//
// The result is written into the codegen array, and the frequencies
// of each code is written into the codegen_freq array.
// Codes 0-15 are single byte codes. Codes 16-18 are followed by additional
// information. Code bad_code is an end marker
//
//	num_literals      The number of literals in literal_encoding
//	num_offsets       The number of offsets in offset_encoding
//	litenc, offenc   The literal and offset encoder to use
fn generate_codegen(
  self : HuffmanBitWriter,
  num_literals : Int,
  num_offsets : Int,
  lit_enc : HuffmanEncoder,
  off_enc : HuffmanEncoder
) -> Unit {
  println(
    "GML: huffman_bit_writer.go: (w *huffmanBitWriter) generateCodegen(numLiterals=\{num_literals}, numOffsets=\{num_offsets}, litEnc, offEnc *huffmanEncoder) {",
  )
  for i in self.codegen_freq {
    self.codegen_freq[i] = 0
  }
  // println("GML: generate_codegen: B")
  // Note that we are using codegen both as a temporary variable for holding
  // a copy of the frequencies, and as the place where we put the result.
  // This is fine because the output is always shorter than the input used
  // so far.
  let codegen = self.codegen // cache
  // Copy the concatenated code sizes to codegen. Put a marker at the end.
  // let cgnl = codegen[:num_literals]
  // println("GML: generate_codegen: C")
  for i in 0..<num_literals {
    codegen[i] = lit_enc.codes[i].len.to_byte()
  }
  // println(
  //   "GML: generate_codegen: D: off_enc.codes.length()=\{off_enc.codes.length()}, codegen.length()=\{codegen.length()}",
  // )

  // cgnl = codegen[num_literals : num_literals+num_offsets]
  for i in 0..<num_offsets {
    // println("GML: generate_codegen: D1: i=\{i}")
    codegen[num_literals + i] = off_enc.codes[i].len.to_byte()
  }
  // println("GML: generate_codegen: E")
  codegen[num_literals + num_offsets] = bad_code
  // println("GML: generate_codegen: F")
  let mut size = codegen[0]
  // println("GML: generate_codegen: G")
  let mut count = 1
  let mut out_index = 0
  for in_index = 1; size != bad_code; in_index = in_index + 1 {
    // println("GML: generate_codegen: H")
    // INVARIANT: We have seen "count" copies of size that have not yet
    // had output generated for them.
    let nextSize = codegen[in_index]
    if nextSize == size {
      count += 1
      continue
    }
    // println("GML: generate_codegen: I")
    // We need to generate codegen indicating "count" of size.
    if size != b'\x00' {
      codegen[out_index] = size
      out_index += 1
      self.codegen_freq[size.to_int()] += 1
      count -= 1
      // println("GML: generate_codegen: J")
      while count >= 3 {
        // println("GML: generate_codegen: J1")
        let mut n = 6
        if n > count {
          n = count
        }
        codegen[out_index] = b'\x10' // 16
        out_index += 1
        codegen[out_index] = (n - 3).to_byte()
        out_index += 1
        self.codegen_freq[16] += 1
        count -= n
        // println("GML: generate_codegen: K")
      }
      // println("GML: generate_codegen: L")
    } else {
      // println("GML: generate_codegen: M")
      while count >= 11 {
        // println("GML: generate_codegen: M1")
        let mut n = 138
        if n > count {
          n = count
        }
        codegen[out_index] = b'\x12' // 18
        out_index += 1
        codegen[out_index] = (n - 11).to_byte()
        out_index += 1
        self.codegen_freq[18] += 1
        count -= n
        // println("GML: generate_codegen: N")
      }
      // println("GML: generate_codegen: O")
      if count >= 3 {
        // println("GML: generate_codegen: P")
        // count >= 3 && count <= 10
        codegen[out_index] = b'\x11' // 17
        out_index += 1
        codegen[out_index] = (count - 3).to_byte()
        out_index += 1
        self.codegen_freq[17] += 1
        count = 0
      }
      // println("GML: generate_codegen: Q")
    }
    // println("GML: generate_codegen: R")
    count -= 1
    for count = count; count >= 0; count = count - 1 {
      // println("GML: generate_codegen: S")
      codegen[out_index] = size
      out_index += 1
      self.codegen_freq[size.to_int()] += 1
    }
    // println("GML: generate_codegen: T")
    // Set up invariant for next time through the loop.
    size = nextSize
    count = 1
    // println("GML: generate_codegen: U")
  }
  // println("GML: generate_codegen: V")
  // Marker indicating the end of the codegen.
  codegen[out_index] = bad_code
}

// dynamic_size returns the size of dynamically encoded data in bits.
fn dynamic_size(
  self : HuffmanBitWriter,
  lit_enc : HuffmanEncoder,
  off_enc : HuffmanEncoder,
  extra_bits : Int
) -> (Int, Int) {
  let mut num_codegens = self.codegen_freq.length()
  while num_codegens > 4 &&
        self.codegen_freq[codegen_order[num_codegens - 1]] == 0 {
    num_codegens -= 1
  }
  let header = 3 +
    5 +
    5 +
    4 +
    3 * num_codegens +
    self.codegen_encoding.bit_length(Slice::new(self.codegen_freq)) +
    self.codegen_freq[16] * 2 +
    self.codegen_freq[17] * 3 +
    self.codegen_freq[18] * 7
  let size = header +
    lit_enc.bit_length(Slice::new(self.literal_freq)) +
    off_enc.bit_length(Slice::new(self.offset_freq)) +
    extra_bits
  (size, num_codegens)
}

// fixed_size returns the size of dynamically encoded data in bits.
fn fixed_size(self : HuffmanBitWriter, extra_bits : Int) -> Int {
  3 +
  fixed_literal_encoding.bit_length(Slice::new(self.literal_freq)) +
  fixed_offset_encoding.bit_length(Slice::new(self.offset_freq)) +
  extra_bits
}

// stored_size calculates the stored size, including header.
// The function returns the size in bits and whether the block
// fits inside a single block.
fn stored_size(inp_length : Int) -> (Int, Bool) {
  if inp_length == 0 {
    return (0, false)
  }
  if inp_length <= max_store_block_size {
    return ((inp_length + 5) * 8, true)
  }
  (0, false)
}

fn write_code(self : HuffmanBitWriter, c : HCode) -> Unit {
  if not(self.err.is_empty()) {
    return
  }
  self.bits = self.bits |
    (c.code.to_uint64() << self.nbits.reinterpret_as_int())
  self.nbits += c.len
  if self.nbits >= 48 {
    let bits = self.bits
    self.bits = self.bits >> 48
    self.nbits -= 48
    let mut n = self.nbytes
    // let bytes = self.bytes[n:n + 6]
    self.bytes[n + 0] = bits.to_byte()
    self.bytes[n + 1] = (bits >> 8).to_byte()
    self.bytes[n + 2] = (bits >> 16).to_byte()
    self.bytes[n + 3] = (bits >> 24).to_byte()
    self.bytes[n + 4] = (bits >> 32).to_byte()
    self.bytes[n + 5] = (bits >> 40).to_byte()
    n += 6
    if n >= buffer_flush_size {
      // self.write(self.bytes[:n])
      for i in 0..<n {
        self.write_byte(self.bytes[i])
      }
      n = 0
    }
    self.nbytes = n
  }
}

// Write the header of a dynamic Huffman block to the output stream.
//
//	num_literals  The number of literals specified in codegen
//	num_offsets   The number of offsets specified in codegen
//	num_codegens  The number of codegens used in codegen
fn write_dynamic_header(
  self : HuffmanBitWriter,
  num_literals : Int,
  num_offsets : Int,
  num_codegens : Int,
  is_eof : Bool
) -> Unit {
  println(
    "GML: huffman_bit_writer.go: (w *huffmanBitWriter) writeDynamicHeader(numLiterals=\{num_literals}, numOffsets=\{num_offsets}, numCodegens=\{num_codegens}, isEof=\{is_eof}) {",
  )
  if not(self.err.is_empty()) {
    return
  }
  let mut first_bits = 4
  if is_eof {
    first_bits = 5
  }
  println("GML: writeDynamicHeader: A")
  self.write_bits(first_bits, 3)
  println("GML: writeDynamicHeader: B")
  self.write_bits(num_literals - 257, 5)
  println("GML: writeDynamicHeader: C")
  self.write_bits(num_offsets - 1, 5)
  println("GML: writeDynamicHeader: D")
  self.write_bits(num_codegens - 4, 4)

  //
  for i in 0..<num_codegens {
    println("GML: writeDynamicHeader: E: i=\{i}")
    let value = self.codegen_encoding.codes[codegen_order[i]].len.reinterpret_as_int()
    self.write_bits(value, 3)
  }

  //
  let mut i = 0
  for {
    println("GML: writeDynamicHeader: F: i=\{i}")
    let code_word = self.codegen[i]
    i += 1
    if code_word == bad_code {
      break
    }
    self.write_code(self.codegen_encoding.codes[code_word.to_int()])
    match code_word.to_int() {
      16 => {
        println("GML: writeDynamicHeader: G")
        self.write_bits(self.codegen[i].to_int(), 2)
        i += 1
      }
      17 => {
        println("GML: writeDynamicHeader: H")
        self.write_bits(self.codegen[i].to_int(), 3)
        i += 1
      }
      18 => {
        println("GML: writeDynamicHeader: I")
        self.write_bits(self.codegen[i].to_int(), 7)
        i += 1
      }
      _ => ()
    }
  }
}

fn write_stored_header(
  self : HuffmanBitWriter,
  length : Int,
  is_eof : Bool
) -> Unit {
  if not(self.err.is_empty()) {
    return
  }
  let flag = if is_eof { 1 } else { 0 }
  self.write_bits(flag, 3)
  self.flush()
  self.write_bits(length, 16)
  self.write_bits(length.lnot() & 0xffff, 16)
}

// write_block_huff encodes a block of bytes as either
// Huffman encoded literals or uncompressed bytes if the
// results only gains very little from compression.
fn write_block_huff(
  self : HuffmanBitWriter,
  eof : Bool,
  input : Bytes,
  len : Int
) -> Unit {
  if not(self.err.is_empty()) {
    return
  }

  // Clear histogram
  for i = 0; i < max_num_lit; i = i + 1 {
    self.literal_freq[i] = 0
  }

  // Add everything as literals
  histogram(input, len, self.literal_freq)
  self.literal_freq[end_block_marker] = 1
  let num_literals = end_block_marker + 1
  self.offset_freq[0] = 1
  let num_offsets = 1
  self.literal_encoding.generate(Slice::new(self.literal_freq), 15)

  // Figure out smallest code.
  // Always use dynamic Huffman or Store
  // let num_codegens = 0

  // Generate codegen and codegen_frequencies, which indicates how to encode
  // the literal_encoding and the offset_encoding.
  self.generate_codegen(
    num_literals,
    num_offsets,
    self.literal_encoding,
    huff_offset,
  )
  self.codegen_encoding.generate(Slice::new(self.codegen_freq), 7)
  let (size, num_codegens) = self.dynamic_size(
    self.literal_encoding,
    huff_offset,
    0,
  )

  // Store bytes, if we don't get a reasonable improvement.
  let (ssize, storable) = stored_size(input.length())
  if storable && ssize < ((size + size) >> 4) {
    self.write_stored_header(input.length(), eof)
    self.write_bytes(input)
    return
  }

  // Huffman.
  self.write_dynamic_header(num_literals, num_offsets, num_codegens, eof)
  let encoding = self.literal_encoding.codes[:257]
  let mut n = self.nbytes
  for t in input {
    // Bitwriting inlined, ~30% speedup
    let c = encoding[t.to_int()]
    self.bits = self.bits |
      (c.code.to_uint64() << self.nbits.reinterpret_as_int())
    self.nbits += c.len
    if self.nbits < 48 {
      continue
    }
    // Store 6 bytes
    let bits = self.bits
    self.bits = self.bits >> 48
    self.nbits -= 48
    // bytes := self.bytes[n : n+6]
    self.bytes[n + 0] = bits.to_byte()
    self.bytes[n + 1] = (bits >> 8).to_byte()
    self.bytes[n + 2] = (bits >> 16).to_byte()
    self.bytes[n + 3] = (bits >> 24).to_byte()
    self.bytes[n + 4] = (bits >> 32).to_byte()
    self.bytes[n + 5] = (bits >> 40).to_byte()
    n += 6
    if n < buffer_flush_size {
      continue
    }
    // self.write(self.bytes[:n])
    let b = Bytes::from_iter(self.bytes.iter().take(n))
    self.write(b)
    if not(self.err.is_empty()) {
      return  // Return early in the event of write failures
    }
    n = 0
  }
  self.nbytes = n
  self.write_code(encoding[end_block_marker])
}

// write_block_dynamic encodes a block using a dynamic Huffman table.
// This should be used if the symbols used have a disproportionate
// histogram distribution.
// If input is supplied and the compression savings are below 1/16th of the
// input size the block is stored.
fn write_block_dynamic(
  self : HuffmanBitWriter,
  tokens : Array[Token],
  eof : Bool,
  input : Bytes
) -> Unit {
  println(
    "GML: huffman_bit_writer.go: (w *huffmanBitWriter) writeBlockDynamic(tokens []token, eof bool, input []byte) {",
  )
  if not(self.err.is_empty()) {
    return
  }

  //
  tokens.push(end_block_marker.reinterpret_as_uint())
  let (num_literals, num_offsets) = self.index_tokens(tokens)

  // Generate codegen and codegen_frequencies, which indicates how to encode
  // the literal_encoding and the offset_encoding.
  println("GML: writeBlockDynamic: generateCodegen")
  self.generate_codegen(
    num_literals,
    num_offsets,
    self.literal_encoding,
    self.offset_encoding,
  )
  println("GML: writeBlockDynamic: generate")
  self.codegen_encoding.generate(Slice::new(self.codegen_freq), 7)
  println("GML: writeBlockDynamic: dynamicSize")
  let (size, numCodegens) = self.dynamic_size(
    self.literal_encoding,
    self.offset_encoding,
    0,
  )

  // Store bytes, if we don't get a reasonable improvement.
  println("GML: writeBlockDynamic: storedSize")
  let (ssize, storable) = stored_size(input.length())
  if storable && ssize < ((size + size) >> 4) {
    println("GML: writeBlockDynamic: writeStoredHeader")
    self.write_stored_header(input.length(), eof)
    println("GML: writeBlockDynamic: writeBytes")
    self.write_bytes(input)
    return
  }

  // Write Huffman table.
  println("GML: writeBlockDynamic: writeDynamicHeader")
  self.write_dynamic_header(num_literals, num_offsets, numCodegens, eof)

  // Write the tokens.
  println("GML: writeBlockDynamic: writeTokens")
  self.write_tokens(
    tokens,
    self.literal_encoding.codes,
    self.offset_encoding.codes,
  )
}

// index_tokens indexes a slice of tokens, and updates
// literal_freq and offset_freq, and generates literal_encoding
// and offset_encoding.
// The number of literal and offset tokens is returned.
fn index_tokens(self : HuffmanBitWriter, tokens : Array[Token]) -> (Int, Int) {
  println(
    "GML: huffman_bit_writer.go: (w *huffmanBitWriter) indexTokens(tokens []token) (numLiterals, numOffsets int) {",
  )
  for i in 0..<self.literal_freq.length() {
    self.literal_freq[i] = 0
  }
  for i in 0..<self.offset_freq.length() {
    self.offset_freq[i] = 0
  }

  //
  for i, t in tokens {
    println("GML: indexTokens: tokens[\{i}]=\{t._}")
    if t._ < match_type {
      self.literal_freq[t.literal().reinterpret_as_int()] += 1
      continue
    }
    let length = t.length() // .reinterpret_as_int()
    let offset = t.offset() // .reinterpret_as_int()
    self.literal_freq[length_codes_start + length_code(length)] += 1
    let code = offset_code(offset)
    self.offset_freq[code] += 1
    println(
      "GML: indexTokens: self.offset_freq[\{code}] = \{self.offset_freq[code]}",
    )
  }

  // get the number of literals
  let mut num_literals = self.literal_freq.length()
  while self.literal_freq[num_literals - 1] == 0 {
    num_literals -= 1
  }
  println("GML: indexTokens: numLiterals=\{num_literals}")
  for i = 0; i < self.offset_freq.length(); i = i + 1 {
    println("GML: indexTokens: offsetFreq[\{i}]=\{self.offset_freq[i]}")
  }
  // get the number of offsets
  let mut num_offsets = self.offset_freq.length()
  while num_offsets > 0 && self.offset_freq[num_offsets - 1] == 0 {
    num_offsets -= 1
  }
  if num_offsets == 0 {
    // We haven't found a single match. If we want to go with the dynamic encoding,
    // we should count at least one offset to be sure that the offset huffman tree could be encoded.
    self.offset_freq[0] = 1
    num_offsets = 1
  }
  println("GML: indexTokens: numOffsets=\{num_offsets}")
  println("GML: indexTokens: literalEncoding.generate")
  self.literal_encoding.generate(Slice::new(self.literal_freq), 15)
  println("GML: indexTokens: offsetEncoding.generate")
  self.offset_encoding.generate(Slice::new(self.offset_freq), 15)
  (num_literals, num_offsets)
}

// write_tokens writes a slice of tokens to the output.
// codes for literal and offset encoding must be supplied.
fn write_tokens(
  self : HuffmanBitWriter,
  tokens : Array[Token],
  le_codes : Array[HCode],
  oe_codes : Array[HCode]
) -> Unit {
  if not(self.err.is_empty()) {
    return
  }
  for t in tokens {
    if t._ < match_type {
      self.write_code(le_codes[t.literal().reinterpret_as_int()])
      continue
    }
    // Write the length
    let length = t.length()
    let length_code = length_code(length)
    self.write_code(le_codes[length_code + length_codes_start])
    let extra_length_bits = length_extra_bits[length_code].reinterpret_as_uint()
    if extra_length_bits > 0 {
      let extra_length = (length - length_base[length_code]).reinterpret_as_int()
      self.write_bits(extra_length, extra_length_bits)
    }
    // Write the offset
    let offset = t.offset()
    let offset_code = offset_code(offset)
    self.write_code(oe_codes[offset_code])
    let extra_offset_bits = offset_extra_bits[offset_code].reinterpret_as_uint()
    if extra_offset_bits > 0 {
      let extra_offset = (offset - offset_base[offset_code]).reinterpret_as_int()
      self.write_bits(extra_offset, extra_offset_bits)
    }
  }
}

// histogram accumulates a histogram of b in h.
//
// len(h) must be >= 256, and h's elements must be all zeroes.
fn histogram(b : Bytes, len : Int, h : Array[Int]) -> Unit {
  for i = 0; i < len; i = i + 1 {
    let t = b[i].to_int()
    h[t] += 1
  }
}
