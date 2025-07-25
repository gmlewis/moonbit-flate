// This file is based on the Go implementation found here:
// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/inflate.go
// which has the copyright notice:
// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// Package flate implements the DEFLATE compressed data format, described in
// RFC 1951.  The gzip and zlib packages implement access to DEFLATE-based file
// formats.

///|
typealias @io.Slice

///|
typealias @io.IOError

///|
pub let ioeof : IOError = @io.eof

///|
let max_code_len = 16 // max length of Huffman code
// The next three numbers come from the RFC section 3.2.7, with the
// additional proviso in section 3.2.5 which implies that distance codes
// 30 and 31 should never occur in compressed data.

///|
let max_num_lit = 286

///|
let max_num_dist = 30

///|
let num_codes = 19 // number of codes in Huffman meta-code

///|
/// A corrupt_input_error reports the presence of corrupt input at a given offset.
fn corrupt_input_error(v : Int64) -> IOError {
  IOError("flate: corrupt input before offset \{v}")
}

///|
/// An internal_error reports an error in the flate code itself.
fn internal_error(s : String) -> IOError {
  IOError("flate: internal error: \{s}")
}

// The data structure for decoding Huffman tables is based on that of
// zlib. There is a lookup table of a fixed bit width (huffman_chunk_bits),
// For codes smaller than the table width, there are multiple entries
// (each combination of trailing bits has the same value). For codes
// larger than the table width, the table contains a link to an overflow
// table. The width of each entry in the link table is the maximum code
// size minus the chunk width.
//
// Note that you can do a lookup in the table even without all bits
// filled. Since the extra bits are zero, and the DEFLATE Huffman codes
// have the property that shorter codes come before longer ones, the
// bit length estimate in the result is a lower bound on the actual
// number of bits.
//
// See the following:
//	https://github.com/madler/zlib/raw/master/doc/algorithm.txt

// chunk & 15 is number of bits
// chunk >> 4 is value, including table link

///|
let huffman_chunk_bits = 9

///|
let huffman_num_chunks : UInt = 1U << huffman_chunk_bits

///|
let huffman_count_mask = 15U

///|
let huffman_value_shift = 4

///|
priv struct HuffmanDecoder {
  mut min : Int // the minimum code length
  mut chunks : Array[UInt] // [huffman_num_chunks]uint32 // chunks as described above
  mut links : Array[Array[UInt]] // [][]uint32               // overflow links
  mut link_mask : UInt // mask the width of the link table
}

///|
fn HuffmanDecoder::new() -> HuffmanDecoder {
  let chunks = Array::make(huffman_num_chunks.reinterpret_as_int(), 0U)
  { min: 0, chunks, links: [], link_mask: 0 }
}

///|
/// Initialize Huffman decoding tables from array of code lengths.
/// Following this function, h is guaranteed to be initialized into a complete
/// tree (i.e., neither over-subscribed nor under-subscribed). The exception is a
/// degenerate case where the tree has only a single symbol with length 1. Empty
/// trees are permitted.
fn initialize(self : HuffmanDecoder, lengths : Slice[Int]) -> Bool {

  // Sanity enables additional runtime tests during Huffman
  // table construction. It's intended to be used during
  // development to supplement the currently ad-hoc unit tests.
  // let sanity = false

  //
  if self.min != 0 {
    self.min = 0
    self.chunks = Array::make(huffman_num_chunks.reinterpret_as_int(), 0U)
    self.links = []
    self.link_mask = 0
  }

  // Count number of codes of each length,
  // compute min and max length.
  let count = Array::make(max_code_len, 0) // [max_code_len]int
  let mut min = 0
  let mut max = 0
  for n in lengths {
    if n == 0 {
      continue
    }
    if min == 0 || n < min {
      min = n
    }
    if n > max {
      max = n
    }
    count[n] += 1
  }

  // Empty tree. The decompressor.huff_sym function will fail later if the tree
  // is used. Technically, an empty tree is only valid for the HDIST tree and
  // not the HCLEN and HLIT tree. However, a stream with an empty HCLEN tree
  // is guaranteed to fail since it will attempt to use the tree to decode the
  // codes for the HLIT and HDIST trees. Similarly, an empty HLIT tree is
  // guaranteed to fail later since the compressed data section must be
  // composed of at least one symbol (the end-of-block marker).
  if max == 0 {
    return true
  }

  //
  let mut code = 0
  let nextcode = Array::make(max_code_len, 0) //  [max_code_len]int
  for i = min; i <= max; i = i + 1 {
    code = code << 1
    nextcode[i] = code
    code += count[i]
  }

  // Check that the coding is complete (i.e., that we've
  // assigned all 2-to-the-max possible bit sequences).
  // Exception: To be compatible with zlib, we also need to
  // accept degenerate single-code codings. See also
  // TestDegenerateHuffmanCoding.
  if code != 1 << max && not(code == 1 && max == 1) {
    return false
  }

  //
  self.min = min
  if max > huffman_chunk_bits {
    let num_links = 1U << (max - huffman_chunk_bits)
    self.link_mask = num_links - 1

    // create link tables
    let link = nextcode[huffman_chunk_bits + 1] >> 1
    self.links = Array::make(
      (huffman_num_chunks - link.reinterpret_as_uint()).reinterpret_as_int(),
      [],
    )
    for j = link.reinterpret_as_uint(); j < huffman_num_chunks; j = j + 1 {
      let mut reverse = reverse16(j & 0xffff).reinterpret_as_int()
      reverse = reverse >> (16 - huffman_chunk_bits)
      let off = j - link.reinterpret_as_uint()
      self.chunks[reverse] = (off << huffman_value_shift) |
        (huffman_chunk_bits + 1).reinterpret_as_uint()
      self.links[off.reinterpret_as_int()] = Array::make(
        num_links.reinterpret_as_int(),
        0U,
      )
    }
  }

  //
  for i, n in lengths {
    if n == 0 {
      continue
    }
    let code = nextcode[n]
    nextcode[n] += 1
    let chunk = (i << huffman_value_shift).reinterpret_as_uint() |
      n.reinterpret_as_uint()
    let mut reverse = reverse16(code.reinterpret_as_uint() & 0xffff).reinterpret_as_int()
    reverse = reverse >> (16 - n)
    if n <= huffman_chunk_bits {
      for off = reverse; off < self.chunks.length(); off = off + (1 << n) {
        // We should never need to overwrite
        // an existing chunk. Also, 0 is
        // never a valid chunk, because the
        // lower 4 "count" bits should be
        // between 1 and 15.
        self.chunks[off] = chunk
      }
    } else {
      let j = reverse & (huffman_num_chunks - 1).reinterpret_as_int()
      let value = self.chunks[j] >> huffman_value_shift
      let linktab = self.links[value.reinterpret_as_int()]
      reverse = reverse >> huffman_chunk_bits
      for off = reverse
          off < linktab.length()
          off = off + (1 << (n - huffman_chunk_bits)) {
        linktab[off] = chunk
      }
    }
  }
  true
}

///|
/// The actual read interface needed by [Decompressor::new].
pub(open) trait Reader {
  // @io.Reader
  read(Self, Slice[Byte]) -> (Int, IOError?)
  // @io.ByteReader
  read_byte(Self) -> (Byte, IOError?)
}

///|
pub impl @io.Reader for &Reader with read(self, b) {
  self.read(b)
}

///|
pub impl @io.ByteReader for &Reader with read_byte(self) {
  self.read_byte()
}

///|
pub impl Reader for @io.Buffer with read(self, b) {
  self.read(b)
}

///|
pub impl Reader for @io.Buffer with read_byte(self) {
  self.read_byte()
}

// Decompress state.

///|
struct Decompressor {
  // Input source.
  mut r : &Reader
  mut roffset : Int64

  // Input bits, in top of b.
  mut b : UInt
  mut nb : UInt

  // Huffman decoders for literal/length, distance.
  mut h1 : HuffmanDecoder
  mut h2 : HuffmanDecoder

  // Length arrays used to define Huffman codes.
  bits : Array[Int] // *[max_num_lit + max_num_dist]int
  codebits : Array[Int] // *[num_codes]int

  // Output history, buffer.
  mut dict : DictDecoder

  // Temporary buffer (avoids repeated allocation).
  buf : Array[Byte] // [4]byte

  // Next step in the decompression,
  // and decompression state.
  mut step : StepFunc
  mut step_state : StepState
  mut final_flag : Bool
  mut err : IOError?
  mut to_read : Slice[Byte] // []byte
  mut hl : HuffmanDecoder?
  mut hd : HuffmanDecoder?
  mut copy_len : Int
  mut copy_dist : Int
}

///|
priv enum StepState {
  StateInit
  StateDict
}

///|
priv type StepFunc (Decompressor) -> Unit

///|
/// `Reader::new` returns a new [@io.ReadCloser] that can be used
/// to read the uncompressed version of r.
pub fn &Reader::new(r : &Reader) -> Decompressor {
  Decompressor::new(r, Slice::new([]))
}

///|
/// `Reader::new_dict` is like [NewReader] but initializes the reader
/// with a preset dictionary. The returned [Reader] behaves as if
/// the uncompressed data stream started with the given dictionary,
/// which has already been read. NewReaderDict is typically used
/// to read data compressed by NewWriterDict.
pub fn &Reader::new_dict(r : &Reader, dict : Slice[Byte]) -> Decompressor {
  Decompressor::new(r, dict)
}

///|
fn Decompressor::new(r : &Reader, dict : Slice[Byte]) -> Decompressor {
  {
    r,
    roffset: 0,
    b: 0,
    nb: 0,
    h1: HuffmanDecoder::new(),
    h2: HuffmanDecoder::new(),
    bits: Array::make(max_num_lit + max_num_dist, 0),
    codebits: Array::make(num_codes, 0),
    dict: DictDecoder::new(max_match_offset, dict),
    buf: [b'\x00', b'\x00', b'\x00', b'\x00'],
    step: Decompressor::next_block,
    step_state: StateInit,
    final_flag: false,
    err: None,
    to_read: Slice::new([]),
    hl: None,
    hd: None,
    copy_len: 0,
    copy_dist: 0,
  }
}

///|
fn next_block(self : Decompressor) -> Unit {
  while self.nb < 1U + 2 {
    self.err = self.more_bits()
    guard self.err is None else { return }
  }
  self.final_flag = (self.b & 1) == 1
  self.b = self.b >> 1
  let typ = self.b & 3
  self.b = self.b >> 2
  self.nb -= 1U + 2
  match typ {
    0 => self.data_block()
    1 => {
      // compressed, fixed Huffman tables
      self.hl = Some(fixed_huffman_decoder)
      self.hd = None
      self.huffman_block()
    }
    2 => {
      // compressed, dynamic Huffman tables
      self.err = self.read_huffman()
      match self.err {
        None => {
          self.hl = Some(self.h1)
          self.hd = Some(self.h2)
          self.huffman_block()
        }
        _ => ()
      }
    }
    _ =>
      // 3 is reserved.
      self.err = Some(corrupt_input_error(self.roffset))
  }
}

///|
pub impl @io.Reader for Decompressor with read(self, b) {
  for {
    if self.to_read.length() > 0 {
      let mut n = self.to_read.length()
      if b.length() < n {
        n = b.length()
      }
      for i = 0; i < n; i = i + 1 {
        b[i] = self.to_read[i]
      }
      self.to_read = self.to_read[n:]
      if self.to_read.length() == 0 {
        return (n, self.err)
      }
      return (n, None)
    }
    match self.err {
      Some(_) => return (0, self.err)
      _ => ()
    }
    self.step.inner()(self)
    if None != self.err && self.to_read.length() == 0 {
      self.to_read = self.dict.read_flush() // Flush what's left in case of error
    }
  }
}

///|
pub impl @io.Closer for Decompressor with close(self) {
  if Some(ioeof) == self.err {
    return None
  }
  self.err
}

// RFC 1951 section 3.2.7.
// Compression with dynamic Huffman codes

///|
let code_order = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

///|
fn read_huffman(self : Decompressor) -> IOError? {
  // HLIT[5], HDIST[5], HCLEN[4].
  while self.nb < 5U + 5 + 4 {
    match self.more_bits() {
      Some(err) => return Some(err)
      _ => ()
    }
  }
  let nlit = (self.b & 0x1F).reinterpret_as_int() + 257
  if nlit > max_num_lit {
    return Some(corrupt_input_error(self.roffset))
  }
  self.b = self.b >> 5
  let ndist = (self.b & 0x1F).reinterpret_as_int() + 1
  if ndist > max_num_dist {
    return Some(corrupt_input_error(self.roffset))
  }
  self.b = self.b >> 5
  let nclen = (self.b & 0xF).reinterpret_as_int() + 4
  // num_codes is 19, so nclen is always valid.
  self.b = self.b >> 4
  self.nb -= 5U + 5 + 4

  // (HCLEN+4)*3 bits: code lengths in the magic code_order order.
  for i = 0; i < nclen; i = i + 1 {
    while self.nb < 3 {
      match self.more_bits() {
        Some(err) => return Some(err)
        _ => ()
      }
    }
    self.codebits[code_order[i]] = (self.b & 0x7).reinterpret_as_int()
    self.b = self.b >> 3
    self.nb -= 3
  }
  for i = nclen; i < code_order.length(); i = i + 1 {
    self.codebits[code_order[i]] = 0
  }
  if not(self.h1.initialize(Slice::new(self.codebits))) {
    return Some(corrupt_input_error(self.roffset))
  }

  // HLIT + 257 code lengths, HDIST + 1 code lengths,
  // using the code length Huffman code.
  let mut i = 0
  let n = nlit + ndist
  while i < n {
    let (x, err) = self.huff_sym(self.h1)
    match err {
      Some(e) => return Some(e)
      _ => ()
    }
    if x < 16 {
      // Actual length.
      self.bits[i] = x
      i += 1
      continue
    }
    // Repeat previous length or zero.
    let mut rep = 0
    let mut nb = 0U
    let mut b = 0
    match x {
      16 => {
        rep = 3
        nb = 2
        if i == 0 {
          return Some(corrupt_input_error(self.roffset))
        }
        b = self.bits[i - 1]
      }
      17 => {
        rep = 3
        nb = 3
        b = 0
      }
      18 => {
        rep = 11
        nb = 7
        b = 0
      }
      _ => return Some(internal_error("unexpected length code"))
    }
    while self.nb < nb {
      match self.more_bits() {
        Some(err) => return Some(err)
        _ => ()
      }
    }
    let delta_rep = (self.b &
    ((1 << nb.reinterpret_as_int()) - 1).reinterpret_as_uint()).reinterpret_as_int()
    rep += delta_rep
    self.b = self.b >> nb.reinterpret_as_int()
    self.nb -= nb
    if i + rep > n {
      return Some(corrupt_input_error(self.roffset))
    }
    for j = 0; j < rep; j = j + 1 {
      self.bits[i] = b
      i += 1
    }
  }

  //
  if not(self.h1.initialize(Slice::new(self.bits)[0:nlit])) ||
    not(self.h2.initialize(Slice::new(self.bits)[nlit:nlit + ndist])) {
    return Some(corrupt_input_error(self.roffset))
  }

  // As an optimization, we can initialize the min bits to read at a time
  // for the HLIT tree to the length of the EOB marker since we know that
  // every block must terminate with one. This preserves the property that
  // we never read any extra bytes after the end of the DEFLATE stream.
  if self.h1.min < self.bits[end_block_marker] {
    self.h1.min = self.bits[end_block_marker]
  }

  //
  None
}

///|
/// Decode a single Huffman block.
/// hl and hd are the Huffman states for the lit/length values
/// and the distance values, respectively. If hd == nil, using the
/// fixed distance encoding associated with fixed Huffman blocks.
fn huffman_block(self : Decompressor) -> Unit {
  match self.step_state {
    StateInit => self.read_literal()
    StateDict => self.copy_history()
  }
}

///|
/// read_literal:
/// Read literal and/or (length, distance) according to RFC section 3.2.3.
fn read_literal(self : Decompressor) -> Unit {
  let (v, err) = self.huff_sym(self.hl.unwrap())
  match err {
    Some(err) => {
      self.err = Some(err)
      return
    }
    _ => ()
  }
  let mut n = 0U // number of bits extra
  let mut length = 0
  if v < 256 {
    self.dict.write_byte(v.to_byte())
    if self.dict.avail_write() == 0 {
      self.to_read = self.dict.read_flush()
      self.step = Decompressor::huffman_block
      self.step_state = StateInit
      return
    }
    return self.read_literal()
  }
  if v == 256 {
    self.finish_block()
    return
  }
  // otherwise, reference to older data
  if v < 265 {
    length = v - (257 - 3)
    n = 0
  } else if v < 269 {
    length = v * 2 - (265 * 2 - 11)
    n = 1
  } else if v < 273 {
    length = v * 4 - (269 * 4 - 19)
    n = 2
  } else if v < 277 {
    length = v * 8 - (273 * 8 - 35)
    n = 3
  } else if v < 281 {
    length = v * 16 - (277 * 16 - 67)
    n = 4
  } else if v < 285 {
    length = v * 32 - (281 * 32 - 131)
    n = 5
  } else if v < max_num_lit {
    length = 258
    n = 0
  } else {
    self.err = Some(corrupt_input_error(self.roffset))
    return
  }

  //
  if n > 0 {
    while self.nb < n {
      self.err = self.more_bits()
      guard self.err is None else { return }
    }
    let mask = (1U << n.reinterpret_as_int()) - 1
    length += (self.b & mask).reinterpret_as_int()
    self.b = self.b >> n.reinterpret_as_int()
    self.nb -= n
  }

  //
  let mut dist = 0
  match self.hd {
    None => {
      while self.nb < 5 {
        self.err = self.more_bits()
        guard self.err is None else { return }
      }
      let to_rev = ((self.b & 0x1F) << 3).to_byte()
      dist = reverse8(to_rev).to_int()
      self.b = self.b >> 5
      self.nb -= 5
    }
    Some(hd) => {
      let (d, err) = self.huff_sym(hd)
      dist = d
      match err {
        Some(err) => {
          self.err = Some(err)
          return
        }
        _ => ()
      }
    }
  }

  //
  if dist < 4 {
    dist += 1
  } else if dist < max_num_dist {
    let nb = (dist - 2).reinterpret_as_uint() >> 1
    // have 1 bit in bottom of dist, need nb more.
    let mut extra = (dist & 1) << nb.reinterpret_as_int()
    while self.nb < nb {
      self.err = self.more_bits()
      guard self.err is None else { return }
    }
    let mask = (1U << nb.reinterpret_as_int()) - 1
    extra = extra | (self.b & mask).reinterpret_as_int()
    self.b = self.b >> nb.reinterpret_as_int()
    self.nb -= nb
    dist = (1 << (nb + 1).reinterpret_as_int()) + 1 + extra
  } else {
    self.err = Some(corrupt_input_error(self.roffset))
    return
  }

  // No check on length; encoding can be prescient.
  if dist > self.dict.hist_size() {
    self.err = Some(corrupt_input_error(self.roffset))
    return
  }
  self.copy_len = length
  self.copy_dist = dist
  self.copy_history()
}

///|
/// copy_history:
/// Perform a backwards copy according to RFC section 3.2.3.
fn copy_history(self : Decompressor) -> Unit {
  let mut cnt = self.dict.try_write_copy(self.copy_dist, self.copy_len)
  if cnt == 0 {
    cnt = self.dict.write_copy(self.copy_dist, self.copy_len)
  }
  self.copy_len -= cnt

  //
  if self.dict.avail_write() == 0 || self.copy_len > 0 {
    self.to_read = self.dict.read_flush()
    self.step = Decompressor::huffman_block // We need to continue this work
    self.step_state = StateDict
    return
  }
  self.read_literal()
}

///|
/// Copy a single uncompressed data block from input to output.
fn data_block(self : Decompressor) -> Unit {
  // Uncompressed.
  // Discard current half-byte.
  self.nb = 0
  self.b = 0

  // Length then ones-complement of length.
  let (nr, err) = @io.read_full(self.r, Slice::new(self.buf)[0:4])
  self.roffset += nr.to_int64()
  match err {
    Some(err) => {
      self.err = Some(no_eof(err))
      return
    }
    _ => ()
  }
  let n = self.buf[0].to_int() | (self.buf[1].to_int() << 8)
  let nn = self.buf[2].to_int() | (self.buf[3].to_int() << 8)
  if (nn & 0xffff) != (n.lnot() & 0xffff) {
    self.err = Some(corrupt_input_error(self.roffset))
    return
  }
  if n == 0 {
    self.to_read = self.dict.read_flush()
    self.finish_block()
    return
  }
  self.copy_len = n
  self.copy_data()
}

///|
/// copy_data copies f.copy_len bytes from the underlying reader into f.hist.
/// It pauses for reads when f.hist is full.
fn copy_data(self : Decompressor) -> Unit {
  let mut buf = self.dict.write_slice()
  if buf.length() > self.copy_len {
    buf = buf[:self.copy_len]
  }
  let (cnt, err) = @io.read_full(self.r, buf)
  self.roffset += cnt.to_int64()
  self.copy_len -= cnt
  self.dict.write_mark(cnt)
  match err {
    Some(err) => {
      self.err = Some(no_eof(err))
      return
    }
    _ => ()
  }

  //
  if self.dict.avail_write() == 0 || self.copy_len > 0 {
    self.to_read = self.dict.read_flush()
    self.step = Decompressor::copy_data
    return
  }
  self.finish_block()
}

///|
fn finish_block(self : Decompressor) -> Unit {
  if self.final_flag {
    if self.dict.avail_read() > 0 {
      self.to_read = self.dict.read_flush()
    }
    self.err = Some(ioeof)
  }
  self.step = Decompressor::next_block
}

///|
/// no_eof returns err, unless err == ioeof, in which case it returns @io.err_unexpected_eof.
fn no_eof(e : IOError) -> IOError {
  if e == ioeof {
    return @io.err_unexpected_eof
  }
  e
}

///|
fn more_bits(self : Decompressor) -> IOError? {
  let (c, err) = self.r.read_byte()
  match err {
    Some(_) => return err
    _ => ()
  }
  self.roffset += 1
  self.b = self.b | (c.to_uint() << self.nb.reinterpret_as_int())
  self.nb += 8
  None
}

///|
/// Read the next Huffman-encoded symbol from f according to h.
fn huff_sym(self : Decompressor, h : HuffmanDecoder) -> (Int, IOError?) {
  // Since a huffmanDecoder can be empty or be composed of a degenerate tree
  // with single element, huff_sym must error on these two edge cases. In both
  // cases, the chunks slice will be 0 for the invalid sequence, leading it
  // satisfy the n == 0 check below.
  let mut n = h.min.reinterpret_as_uint()
  // Go comment: Optimization. Compiler isn't smart enough to keep f.b,f.nb in registers,
  // but is smart enough to keep local variables in registers, so use nb and b,
  // inline call to more_bits and reassign b,nb back to f on return.
  let mut nb = self.nb
  let mut b = self.b
  for {
    while nb < n {
      let (c, err) = self.r.read_byte()
      match err {
        Some(e) => {
          self.b = b
          self.nb = nb
          return (0, Some(no_eof(e)))
        }
        _ => ()
      }
      self.roffset += 1
      b = b | (c.to_uint() << (nb & 31).reinterpret_as_int())
      nb += 8
    }
    let mut chunk = h.chunks[(b & (huffman_num_chunks - 1)).reinterpret_as_int()]
    n = chunk & huffman_count_mask
    if n > huffman_chunk_bits.reinterpret_as_uint() {
      chunk = h.links[(chunk >> huffman_value_shift).reinterpret_as_int()][((
          b >> huffman_chunk_bits
        ) &
        h.link_mask).reinterpret_as_int()]
      n = chunk & huffman_count_mask
    }
    if n <= nb {
      if n == 0 {
        self.b = b
        self.nb = nb
        self.err = Some(corrupt_input_error(self.roffset))
        return (0, self.err)
      }
      self.b = b >> (n & 31).reinterpret_as_int()
      self.nb = nb - n
      let v = (chunk >> huffman_value_shift).reinterpret_as_int()
      return (v, None)
    }
  }
}

///|
pub fn make_reader(self : Decompressor, r : &Reader) -> Unit {
  self.r = r
}

///|
pub fn Decompressor::reset(
  self : Decompressor,
  r : &Reader,
  dict : Slice[Byte],
) -> Unit {
  self.r = r
  self.roffset = 0
  self.b = 0
  self.nb = 0
  self.h1 = HuffmanDecoder::new()
  self.h2 = HuffmanDecoder::new()
  self.dict = DictDecoder::new(max_match_offset, dict)
  self.step = Decompressor::next_block
  self.step_state = StateInit
  self.final_flag = false
  self.err = None
  self.to_read = Slice::new([])
  self.hl = None
  self.hd = None
  self.copy_len = 0
  self.copy_dist = 0
}

///|
let fixed_huffman_decoder : HuffmanDecoder = {
  min: 7,
  chunks: [
    0x1007, 0x508, 0x108, 0x1188, 0x1107, 0x708, 0x308, 0xc09, 0x1087, 0x608, 0x208,
    0xa09, 0x8, 0x808, 0x408, 0xe09, 0x1047, 0x588, 0x188, 0x909, 0x1147, 0x788,
    0x388, 0xd09, 0x10c7, 0x688, 0x288, 0xb09, 0x88, 0x888, 0x488, 0xf09, 0x1027,
    0x548, 0x148, 0x11c8, 0x1127, 0x748, 0x348, 0xc89, 0x10a7, 0x648, 0x248, 0xa89,
    0x48, 0x848, 0x448, 0xe89, 0x1067, 0x5c8, 0x1c8, 0x989, 0x1167, 0x7c8, 0x3c8,
    0xd89, 0x10e7, 0x6c8, 0x2c8, 0xb89, 0xc8, 0x8c8, 0x4c8, 0xf89, 0x1017, 0x528,
    0x128, 0x11a8, 0x1117, 0x728, 0x328, 0xc49, 0x1097, 0x628, 0x228, 0xa49, 0x28,
    0x828, 0x428, 0xe49, 0x1057, 0x5a8, 0x1a8, 0x949, 0x1157, 0x7a8, 0x3a8, 0xd49,
    0x10d7, 0x6a8, 0x2a8, 0xb49, 0xa8, 0x8a8, 0x4a8, 0xf49, 0x1037, 0x568, 0x168,
    0x11e8, 0x1137, 0x768, 0x368, 0xcc9, 0x10b7, 0x668, 0x268, 0xac9, 0x68, 0x868,
    0x468, 0xec9, 0x1077, 0x5e8, 0x1e8, 0x9c9, 0x1177, 0x7e8, 0x3e8, 0xdc9, 0x10f7,
    0x6e8, 0x2e8, 0xbc9, 0xe8, 0x8e8, 0x4e8, 0xfc9, 0x1007, 0x518, 0x118, 0x1198,
    0x1107, 0x718, 0x318, 0xc29, 0x1087, 0x618, 0x218, 0xa29, 0x18, 0x818, 0x418,
    0xe29, 0x1047, 0x598, 0x198, 0x929, 0x1147, 0x798, 0x398, 0xd29, 0x10c7, 0x698,
    0x298, 0xb29, 0x98, 0x898, 0x498, 0xf29, 0x1027, 0x558, 0x158, 0x11d8, 0x1127,
    0x758, 0x358, 0xca9, 0x10a7, 0x658, 0x258, 0xaa9, 0x58, 0x858, 0x458, 0xea9,
    0x1067, 0x5d8, 0x1d8, 0x9a9, 0x1167, 0x7d8, 0x3d8, 0xda9, 0x10e7, 0x6d8, 0x2d8,
    0xba9, 0xd8, 0x8d8, 0x4d8, 0xfa9, 0x1017, 0x538, 0x138, 0x11b8, 0x1117, 0x738,
    0x338, 0xc69, 0x1097, 0x638, 0x238, 0xa69, 0x38, 0x838, 0x438, 0xe69, 0x1057,
    0x5b8, 0x1b8, 0x969, 0x1157, 0x7b8, 0x3b8, 0xd69, 0x10d7, 0x6b8, 0x2b8, 0xb69,
    0xb8, 0x8b8, 0x4b8, 0xf69, 0x1037, 0x578, 0x178, 0x11f8, 0x1137, 0x778, 0x378,
    0xce9, 0x10b7, 0x678, 0x278, 0xae9, 0x78, 0x878, 0x478, 0xee9, 0x1077, 0x5f8,
    0x1f8, 0x9e9, 0x1177, 0x7f8, 0x3f8, 0xde9, 0x10f7, 0x6f8, 0x2f8, 0xbe9, 0xf8,
    0x8f8, 0x4f8, 0xfe9, 0x1007, 0x508, 0x108, 0x1188, 0x1107, 0x708, 0x308, 0xc19,
    0x1087, 0x608, 0x208, 0xa19, 0x8, 0x808, 0x408, 0xe19, 0x1047, 0x588, 0x188,
    0x919, 0x1147, 0x788, 0x388, 0xd19, 0x10c7, 0x688, 0x288, 0xb19, 0x88, 0x888,
    0x488, 0xf19, 0x1027, 0x548, 0x148, 0x11c8, 0x1127, 0x748, 0x348, 0xc99, 0x10a7,
    0x648, 0x248, 0xa99, 0x48, 0x848, 0x448, 0xe99, 0x1067, 0x5c8, 0x1c8, 0x999,
    0x1167, 0x7c8, 0x3c8, 0xd99, 0x10e7, 0x6c8, 0x2c8, 0xb99, 0xc8, 0x8c8, 0x4c8,
    0xf99, 0x1017, 0x528, 0x128, 0x11a8, 0x1117, 0x728, 0x328, 0xc59, 0x1097, 0x628,
    0x228, 0xa59, 0x28, 0x828, 0x428, 0xe59, 0x1057, 0x5a8, 0x1a8, 0x959, 0x1157,
    0x7a8, 0x3a8, 0xd59, 0x10d7, 0x6a8, 0x2a8, 0xb59, 0xa8, 0x8a8, 0x4a8, 0xf59,
    0x1037, 0x568, 0x168, 0x11e8, 0x1137, 0x768, 0x368, 0xcd9, 0x10b7, 0x668, 0x268,
    0xad9, 0x68, 0x868, 0x468, 0xed9, 0x1077, 0x5e8, 0x1e8, 0x9d9, 0x1177, 0x7e8,
    0x3e8, 0xdd9, 0x10f7, 0x6e8, 0x2e8, 0xbd9, 0xe8, 0x8e8, 0x4e8, 0xfd9, 0x1007,
    0x518, 0x118, 0x1198, 0x1107, 0x718, 0x318, 0xc39, 0x1087, 0x618, 0x218, 0xa39,
    0x18, 0x818, 0x418, 0xe39, 0x1047, 0x598, 0x198, 0x939, 0x1147, 0x798, 0x398,
    0xd39, 0x10c7, 0x698, 0x298, 0xb39, 0x98, 0x898, 0x498, 0xf39, 0x1027, 0x558,
    0x158, 0x11d8, 0x1127, 0x758, 0x358, 0xcb9, 0x10a7, 0x658, 0x258, 0xab9, 0x58,
    0x858, 0x458, 0xeb9, 0x1067, 0x5d8, 0x1d8, 0x9b9, 0x1167, 0x7d8, 0x3d8, 0xdb9,
    0x10e7, 0x6d8, 0x2d8, 0xbb9, 0xd8, 0x8d8, 0x4d8, 0xfb9, 0x1017, 0x538, 0x138,
    0x11b8, 0x1117, 0x738, 0x338, 0xc79, 0x1097, 0x638, 0x238, 0xa79, 0x38, 0x838,
    0x438, 0xe79, 0x1057, 0x5b8, 0x1b8, 0x979, 0x1157, 0x7b8, 0x3b8, 0xd79, 0x10d7,
    0x6b8, 0x2b8, 0xb79, 0xb8, 0x8b8, 0x4b8, 0xf79, 0x1037, 0x578, 0x178, 0x11f8,
    0x1137, 0x778, 0x378, 0xcf9, 0x10b7, 0x678, 0x278, 0xaf9, 0x78, 0x878, 0x478,
    0xef9, 0x1077, 0x5f8, 0x1f8, 0x9f9, 0x1177, 0x7f8, 0x3f8, 0xdf9, 0x10f7, 0x6f8,
    0x2f8, 0xbf9, 0xf8, 0x8f8, 0x4f8, 0xff9,
  ],
  links: [],
  link_mask: 0,
}
