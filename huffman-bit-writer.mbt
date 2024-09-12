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

let bad_code = 255

// buffer_flush_size indicates the buffer size
// after which bytes are flushed to the writer.
// Should preferably be a multiple of 6, since
// we accumulate 6 bytes between writes to the buffer.
let buffer_flush_size = 240

// buffer_size is the actual output byte buffer size.
// It must have additional headroom for a flush
// which can contain up to 8 bytes.
let buffer_size : Int = buffer_flush_size + 8

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
  codegen_freq : FixedArray[Int] // [codegen_code_count]int32
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
  let codegen_freq = FixedArray::make(codegen_code_count, 0) // [codegen_code_count]int32
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

type! InternalError String derive(Show)

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
  if not(self.err.is_empty()) {
    return
  }
  self.writer.write_bytes(b)
}

fn write_bits(self : HuffmanBitWriter, b : Int, nb : UInt) -> Unit {
  if not(self.err.is_empty()) {
    return
  }
  self.bits = self.bits |
    (b.reinterpret_as_uint().to_uint64() << self.nbits.reinterpret_as_int())
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
  self.write_bits(length.lnot(), 16)
}

// write_block_huff encodes a block of bytes as either
// Huffman encoded literals or uncompressed bytes if the
// results only gains very little from compression.
fn write_block_huff(self: HuffmanBitWriter, eof : Bool, input : Bytes, len: Int) -> Unit {
  if not(self.err.is_empty()) {
		return
	}

	// Clear histogram
	for i =0; i < max_num_lit; i = i + 1 {
		self.literal_freq[i] = 0
	}

	// Add everything as literals
	histogram(input, len, self.literal_freq)

	self.literal_freq[end_block_marker] = 1

	let num_literals = end_block_marker + 1
	self.offset_freq[0] = 1
	let num_offsets = 1

	self.literal_encoding.generate(self.literal_freq, 15)

	// Figure out smallest code.
	// Always use dynamic Huffman or Store
	let mut num_codegens = 0

	// Generate codegen and codegen_frequencies, which indicates how to encode
	// the literal_encoding and the offsetEncoding.
	self.generate_codegen(num_literals, num_offsets, self.literal_encoding, huff_offset)
	self.codegen_encoding.generate(self.codegen_freq[:], 7)
	size, num_codegens = self.dynamic_size(self.literal_encoding, huff_offset, 0)

	// Store bytes, if we don't get a reasonable improvement.
	ssize, storable = self.storedSize(input)
  if storable && ssize < (size+size>>4) {
		self.writeStoredHeader(len(input), eof)
		self.writeBytes(input)
		return
	}

	// Huffman.
	self.write_dynamic_header(num_literals, num_offsets, num_codegens, eof)
	let encoding = self.literal_encoding.codes[:257]
	let mut n = self.nbytes
	for _, t := range input {
		// Bitwriting inlined, ~30% speedup
		c := encoding[t]
		self.bits |= uint64(c.code) << self.nbits
		self.nbits += uint(c.len)
		if self.nbits < 48 {
			continue
		}
		// Store 6 bytes
		bits := self.bits
		self.bits >>= 48
		self.nbits -= 48
		bytes := self.bytes[n : n+6]
		bytes[0] = byte(bits)
		bytes[1] = byte(bits >> 8)
		bytes[2] = byte(bits >> 16)
		bytes[3] = byte(bits >> 24)
		bytes[4] = byte(bits >> 32)
		bytes[5] = byte(bits >> 40)
		n += 6
		if n < bufferFlushSize {
			continue
		}
		self.write(self.bytes[:n])
		if self.err != nil {
			return // Return early in the event of write failures
		}
		n = 0
	}
	self.nbytes = n
	self.writeCode(encoding[end_block_marker])
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
