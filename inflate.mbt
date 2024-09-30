/// This file is based on the Go implementation found here:
/// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/inflate.go
/// which has the copyright notice:
/// Copyright 2009 The Go Authors. All rights reserved.
/// Use of this source code is governed by a BSD-style
/// license that can be found in the LICENSE file.
///
/// Package flate implements the DEFLATE compressed data format, described in
/// RFC 1951.  The gzip and zlib packages implement access to DEFLATE-based file
/// formats.

// let max_code_len = 16 // max length of Huffman code
// The next three numbers come from the RFC section 3.2.7, with the
// additional proviso in section 3.2.5 which implies that distance codes
// 30 and 31 should never occur in compressed data.

let max_num_lit = 286

let max_num_dist = 30

let num_codes = 19 // number of codes in Huffman meta-code

// // Initialize the fixed_huffman_decoder only once upon first use.
// var fixedOnce sync.Once
// var fixed_huffman_decoder huffmanDecoder

/// A CorruptInputError reports the presence of corrupt input at a given offset.
pub type! CorruptInputError Int64

impl Show for CorruptInputError with output(self, logger) {
  logger.write_string("flate: corrupt input before offset \{self}")
}

fn to_string(self : CorruptInputError) -> String {
  Show::to_string(self)
}

/// An InternalError reports an error in the flate code itself.
pub type! InternalError String

impl Show for InternalError with output(self, logger) {
  logger.write_string("flate: internal error: \{self}")
}

fn to_string(self : InternalError) -> String {
  Show::to_string(self)
}

// // A ReadError reports an error encountered while reading input.
// //
// // Deprecated: No longer returned.
// type ReadError struct {
// 	Offset int64 // byte offset where error occurred
// 	Err    error // error returned by underlying Read
// }

// func (e *ReadError) Error() string {
// 	log.Printf("GML: inflate.go: (e *ReadError) Error() string {")
// 	return "flate: read error at offset " + strconv.FormatInt(e.Offset, 10) + ": " + e.Err.Error()
// }

// // A WriteError reports an error encountered while writing output.
// //
// // Deprecated: No longer returned.
// type WriteError struct {
// 	Offset int64 // byte offset where error occurred
// 	Err    error // error returned by underlying Write
// }

// func (e *WriteError) Error() string {
// 	log.Printf("GML: inflate.go: (e *WriteError) Error() string {")
// 	return "flate: write error at offset " + strconv.FormatInt(e.Offset, 10) + ": " + e.Err.Error()
// }

// // Resetter resets a ReadCloser returned by [NewReader] or [NewReaderDict]
// // to switch to a new underlying [Reader]. This permits reusing a ReadCloser
// // instead of allocating a new one.
// type Resetter interface {
// 	// Reset discards any buffered data and resets the Resetter as if it was
// 	// newly initialized with the given reader.
// 	Reset(r io.Reader, dict []byte) error
// }

// // The data structure for decoding Huffman tables is based on that of
// // zlib. There is a lookup table of a fixed bit width (huffmanChunkBits),
// // For codes smaller than the table width, there are multiple entries
// // (each combination of trailing bits has the same value). For codes
// // larger than the table width, the table contains a link to an overflow
// // table. The width of each entry in the link table is the maximum code
// // size minus the chunk width.
// //
// // Note that you can do a lookup in the table even without all bits
// // filled. Since the extra bits are zero, and the DEFLATE Huffman codes
// // have the property that shorter codes come before longer ones, the
// // bit length estimate in the result is a lower bound on the actual
// // number of bits.
// //
// // See the following:
// //	https://github.com/madler/zlib/raw/master/doc/algorithm.txt

// // chunk & 15 is number of bits
// // chunk >> 4 is value, including table link

// const (
// 	huffmanChunkBits  = 9
// 	huffmanNumChunks  = 1 << huffmanChunkBits
// 	huffmanCountMask  = 15
// 	huffmanValueShift = 4
// )

struct HuffmanDecoder {
  min : Int // the minimum code length
  chunks : Array[UInt] // [huffmanNumChunks]uint32 // chunks as described above
  links : Array[Array[UInt]] // [][]uint32               // overflow links
  link_mask : UInt // mask the width of the link table
}

// // Initialize Huffman decoding tables from array of code lengths.
// // Following this function, h is guaranteed to be initialized into a complete
// // tree (i.e., neither over-subscribed nor under-subscribed). The exception is a
// // degenerate case where the tree has only a single symbol with length 1. Empty
// // trees are permitted.
// func (h *huffmanDecoder) init(lengths []int) bool {
// 	log.Printf("GML: inflate.go: (h *huffmanDecoder) init(lengths []int) bool {")
// 	// Sanity enables additional runtime tests during Huffman
// 	// table construction. It's intended to be used during
// 	// development to supplement the currently ad-hoc unit tests.
// 	const sanity = false

// 	if h.min != 0 {
// 		*h = huffmanDecoder{}
// 	}

// 	// Count number of codes of each length,
// 	// compute min and max length.
// 	var count [maxCodeLen]int
// 	var min, max int
// 	for _, n := range lengths {
// 		if n == 0 {
// 			continue
// 		}
// 		if min == 0 || n < min {
// 			min = n
// 		}
// 		if n > max {
// 			max = n
// 		}
// 		count[n]++
// 	}

// 	// Empty tree. The decompressor.huff_sym function will fail later if the tree
// 	// is used. Technically, an empty tree is only valid for the HDIST tree and
// 	// not the HCLEN and HLIT tree. However, a stream with an empty HCLEN tree
// 	// is guaranteed to fail since it will attempt to use the tree to decode the
// 	// codes for the HLIT and HDIST trees. Similarly, an empty HLIT tree is
// 	// guaranteed to fail later since the compressed data section must be
// 	// composed of at least one symbol (the end-of-block marker).
// 	if max == 0 {
// 		return true
// 	}

// 	code := 0
// 	var nextcode [maxCodeLen]int
// 	for i := min; i <= max; i++ {
// 		code <<= 1
// 		nextcode[i] = code
// 		code += count[i]
// 	}

// 	// Check that the coding is complete (i.e., that we've
// 	// assigned all 2-to-the-max possible bit sequences).
// 	// Exception: To be compatible with zlib, we also need to
// 	// accept degenerate single-code codings. See also
// 	// TestDegenerateHuffmanCoding.
// 	if code != 1<<uint(max) && !(code == 1 && max == 1) {
// 		return false
// 	}

// 	h.min = min
// 	if max > huffmanChunkBits {
// 		numLinks := 1 << (uint(max) - huffmanChunkBits)
// 		h.link_mask = uint32(numLinks - 1)

// 		// create link tables
// 		link := nextcode[huffmanChunkBits+1] >> 1
// 		h.links = make([][]uint32, huffmanNumChunks-link)
// 		for j := uint(link); j < huffmanNumChunks; j++ {
// 			reverse := int(bits.Reverse16(uint16(j)))
// 			reverse >>= uint(16 - huffmanChunkBits)
// 			off := j - uint(link)
// 			if sanity && h.chunks[reverse] != 0 {
// 				panic("impossible: overwriting existing chunk")
// 			}
// 			h.chunks[reverse] = uint32(off<<huffmanValueShift | (huffmanChunkBits + 1))
// 			h.links[off] = make([]uint32, numLinks)
// 		}
// 	}

// 	for i, n := range lengths {
// 		if n == 0 {
// 			continue
// 		}
// 		code := nextcode[n]
// 		nextcode[n]++
// 		chunk := uint32(i<<huffmanValueShift | n)
// 		reverse := int(bits.Reverse16(uint16(code)))
// 		reverse >>= uint(16 - n)
// 		if n <= huffmanChunkBits {
// 			for off := reverse; off < len(h.chunks); off += 1 << uint(n) {
// 				// We should never need to overwrite
// 				// an existing chunk. Also, 0 is
// 				// never a valid chunk, because the
// 				// lower 4 "count" bits should be
// 				// between 1 and 15.
// 				if sanity && h.chunks[off] != 0 {
// 					panic("impossible: overwriting existing chunk")
// 				}
// 				h.chunks[off] = chunk
// 			}
// 		} else {
// 			j := reverse & (huffmanNumChunks - 1)
// 			if sanity && h.chunks[j]&huffmanCountMask != huffmanChunkBits+1 {
// 				// Longer codes should have been
// 				// associated with a link table above.
// 				panic("impossible: not an indirect chunk")
// 			}
// 			value := h.chunks[j] >> huffmanValueShift
// 			linktab := h.links[value]
// 			reverse >>= huffmanChunkBits
// 			for off := reverse; off < len(linktab); off += 1 << uint(n-huffmanChunkBits) {
// 				if sanity && linktab[off] != 0 {
// 					panic("impossible: overwriting existing chunk")
// 				}
// 				linktab[off] = chunk
// 			}
// 		}
// 	}

// 	if sanity {
// 		// Above we've sanity checked that we never overwrote
// 		// an existing entry. Here we additionally check that
// 		// we filled the tables completely.
// 		for i, chunk := range h.chunks {
// 			if chunk == 0 {
// 				// As an exception, in the degenerate
// 				// single-code case, we allow odd
// 				// chunks to be missing.
// 				if code == 1 && i%2 == 1 {
// 					continue
// 				}
// 				panic("impossible: missing chunk")
// 			}
// 		}
// 		for _, linktab := range h.links {
// 			for _, chunk := range linktab {
// 				if chunk == 0 {
// 					panic("impossible: missing chunk")
// 				}
// 			}
// 		}
// 	}

// 	return true
// }

// // The actual read interface needed by [NewReader].
// // If the passed in io.Reader does not also have read_byte,
// // the [NewReader] will introduce its own buffering.
// type Reader interface {
// 	io.Reader
// 	io.ByteReader
// }

// Decompress state.
struct Decompressor {
  // Input source.
  mut r : IOReader
  // rBuf    *bufio.Reader // created if provided io.Reader does not implement io.ByteReader
  mut roffset : Int64

  // Input bits, in top of b.
  mut b : UInt
  mut nb : UInt

  // Huffman decoders for literal/length, distance.
  h1 : HuffmanDecoder
  h2 : HuffmanDecoder

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
  mut step_state : Int
  mut final : Bool
  mut err : Error?
  mut to_read : ArrayView[Byte] // []byte
  mut hl : HuffmanDecoder
  mut hd : HuffmanDecoder?
  mut copy_len : Int
  mut copy_dist : Int
}

type StepFunc (Decompressor) -> Unit

fn Decompressor::new(r : IOReader) -> Decompressor {
  {
    r,
    roffset: 0,
    b: 0,
    nb: 0,
    h1: fixed_huffman_decoder,
    h2: fixed_huffman_decoder,
    bits: Array::make(max_num_lit + max_num_dist, 0),
    codebits: Array::make(num_codes, 0),
    dict: DictDecoder::new(max_match_offset),
    buf: [b'\x00', b'\x00', b'\x00', b'\x00'],
    step: next_block,
    step_state: 0,
    final: false,
    err: None,
    to_read: [][:],
    hl: fixed_huffman_decoder,
    hd: Some(fixed_huffman_decoder),
    copy_len: 0,
    copy_dist: 0,
  }
}

fn next_block(self : Decompressor) -> Unit {
  while self.nb < 1U + 2 {
    self.err = self.more_bits()
    guard let None = self.err else { _ => return  }

  }
  self.final = (self.b & 1) == 1
  self.b = self.b >> 1
  let typ = self.b & 3
  self.b = self.b >> 2
  self.nb -= 1U + 2
  match typ {
    0 => self.data_block()
    1 => {
      // compressed, fixed Huffman tables
      self.hl = fixed_huffman_decoder
      self.hd = None
      self.huffman_block()
    }
    2 => {
      // compressed, dynamic Huffman tables
      self.err = self.read_huffman()
      match self.err {
        None => {
          self.hl = self.h1
          self.hd = Some(self.h2)
          self.huffman_block()
        }
        _ => ()
      }
    }
    _ =>
      // 3 is reserved.
      self.err = Some(CorruptInputError(self.roffset))
  }
}

fn read(self : Decompressor, b : Bytes) -> Int!Error {
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
      return n
    }
    match self.err {
      Some(err) => raise err
      _ => ()
    }
    (self.step._)(self)
    match self.err {
      Some(IOEOF) =>
        if self.to_read.length() == 0 {
          self.to_read = self.dict.read_flush() // Flush what's left in case of error
        }
      _ => ()
    }
  }
}

fn close(self : Decompressor) -> Unit!Error {
  match self.err {
    Some(IOEOF) => return
    Some(err) => raise err
    _ => return
  }
}

// RFC 1951 section 3.2.7.
// Compression with dynamic Huffman codes

let code_order = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

fn read_huffman(self : Decompressor) -> Error? {
  None
  // 	log.Printf("GML: inflate.go: (f *decompressor) read_huffman() error {")
  // 	// HLIT[5], HDIST[5], HCLEN[4].
  // 	for f.nb < 5+5+4 {
  // 		if err := f.more_bits(); err != nil {
  // 			return err
  // 		}
  // 	}
  // 	nlit := int(f.b&0x1F) + 257
  // 	if nlit > max_num_lit {
  // 		return CorruptInputError(f.roffset)
  // 	}
  // 	f.b >>= 5
  // 	ndist := int(f.b&0x1F) + 1
  // 	if ndist > max_num_dist {
  // 		return CorruptInputError(f.roffset)
  // 	}
  // 	f.b >>= 5
  // 	nclen := int(f.b&0xF) + 4
  // 	// num_codes is 19, so nclen is always valid.
  // 	f.b >>= 4
  // 	f.nb -= 5 + 5 + 4

  // 	// (HCLEN+4)*3 bits: code lengths in the magic code_order order.
  // 	for i := 0; i < nclen; i++ {
  // 		for f.nb < 3 {
  // 			if err := f.more_bits(); err != nil {
  // 				return err
  // 			}
  // 		}
  // 		f.codebits[code_order[i]] = int(f.b & 0x7)
  // 		f.b >>= 3
  // 		f.nb -= 3
  // 	}
  // 	for i := nclen; i < len(code_order); i++ {
  // 		f.codebits[code_order[i]] = 0
  // 	}
  // 	if !f.h1.init(f.codebits[0:]) {
  // 		return CorruptInputError(f.roffset)
  // 	}

  // 	// HLIT + 257 code lengths, HDIST + 1 code lengths,
  // 	// using the code length Huffman code.
  // 	for i, n := 0, nlit+ndist; i < n; {
  // 		x, err := f.huff_sym(&f.h1)
  // 		if err != nil {
  // 			return err
  // 		}
  // 		if x < 16 {
  // 			// Actual length.
  // 			f.bits[i] = x
  // 			i++
  // 			continue
  // 		}
  // 		// Repeat previous length or zero.
  // 		var rep int
  // 		var nb uint
  // 		var b int
  // 		switch x {
  // 		default:
  // 			return InternalError("unexpected length code")
  // 		case 16:
  // 			rep = 3
  // 			nb = 2
  // 			if i == 0 {
  // 				return CorruptInputError(f.roffset)
  // 			}
  // 			b = f.bits[i-1]
  // 		case 17:
  // 			rep = 3
  // 			nb = 3
  // 			b = 0
  // 		case 18:
  // 			rep = 11
  // 			nb = 7
  // 			b = 0
  // 		}
  // 		for f.nb < nb {
  // 			if err := f.more_bits(); err != nil {
  // 				return err
  // 			}
  // 		}
  // 		rep += int(f.b & uint32(1<<nb-1))
  // 		f.b >>= nb
  // 		f.nb -= nb
  // 		if i+rep > n {
  // 			return CorruptInputError(f.roffset)
  // 		}
  // 		for j := 0; j < rep; j++ {
  // 			f.bits[i] = b
  // 			i++
  // 		}
  // 	}

  // 	if !f.h1.init(f.bits[0:nlit]) || !f.h2.init(f.bits[nlit:nlit+ndist]) {
  // 		return CorruptInputError(f.roffset)
  // 	}

  // 	// As an optimization, we can initialize the min bits to read at a time
  // 	// for the HLIT tree to the length of the EOB marker since we know that
  // 	// every block must terminate with one. This preserves the property that
  // 	// we never read any extra bytes after the end of the DEFLATE stream.
  // 	if f.h1.min < f.bits[endBlockMarker] {
  // 		f.h1.min = f.bits[endBlockMarker]
  // 	}

  // 	return nil
}

// // Decode a single Huffman block from f.
// // hl and hd are the Huffman states for the lit/length values
// // and the distance values, respectively. If hd == nil, using the
// // fixed distance encoding associated with fixed Huffman blocks.
fn huffman_block(self : Decompressor) -> Unit {
  // 	log.Printf("GML: inflate.go: (f *decompressor) huffman_block() {")
  // 	const (
  // 		stateInit = iota // Zero value must be stateInit
  // 		stateDict
  // 	)

  // 	switch f.step_state {
  // 	case stateInit:
  // 		goto readLiteral
  // 	case stateDict:
  // 		goto copyHistory
  // 	}

  // readLiteral:
  // 	// Read literal and/or (length, distance) according to RFC section 3.2.3.
  // 	{
  // 		v, err := f.huff_sym(f.hl)
  // 		if err != nil {
  // 			f.err = err
  // 			return
  // 		}
  // 		var n uint // number of bits extra
  // 		var length int
  // 		switch {
  // 		case v < 256:
  // 			f.dict.writeByte(byte(v))
  // 			if f.dict.avail_write() == 0 {
  // 				f.to_read = f.dict.read_flush()
  // 				f.step = (*decompressor).huffman_block
  // 				f.step_state = stateInit
  // 				return
  // 			}
  // 			goto readLiteral
  // 		case v == 256:
  // 			f.finish_block()
  // 			return
  // 		// otherwise, reference to older data
  // 		case v < 265:
  // 			length = v - (257 - 3)
  // 			n = 0
  // 		case v < 269:
  // 			length = v*2 - (265*2 - 11)
  // 			n = 1
  // 		case v < 273:
  // 			length = v*4 - (269*4 - 19)
  // 			n = 2
  // 		case v < 277:
  // 			length = v*8 - (273*8 - 35)
  // 			n = 3
  // 		case v < 281:
  // 			length = v*16 - (277*16 - 67)
  // 			n = 4
  // 		case v < 285:
  // 			length = v*32 - (281*32 - 131)
  // 			n = 5
  // 		case v < max_num_lit:
  // 			length = 258
  // 			n = 0
  // 		default:
  // 			f.err = CorruptInputError(f.roffset)
  // 			return
  // 		}
  // 		if n > 0 {
  // 			for f.nb < n {
  // 				if err = f.more_bits(); err != nil {
  // 					f.err = err
  // 					return
  // 				}
  // 			}
  // 			length += int(f.b & uint32(1<<n-1))
  // 			f.b >>= n
  // 			f.nb -= n
  // 		}

  // 		var dist int
  // 		if f.hd == nil {
  // 			for f.nb < 5 {
  // 				if err = f.more_bits(); err != nil {
  // 					f.err = err
  // 					return
  // 				}
  // 			}
  // 			dist = int(bits.Reverse8(uint8(f.b & 0x1F << 3)))
  // 			f.b >>= 5
  // 			f.nb -= 5
  // 		} else {
  // 			if dist, err = f.huff_sym(f.hd); err != nil {
  // 				f.err = err
  // 				return
  // 			}
  // 		}

  // 		switch {
  // 		case dist < 4:
  // 			dist++
  // 		case dist < max_num_dist:
  // 			nb := uint(dist-2) >> 1
  // 			// have 1 bit in bottom of dist, need nb more.
  // 			extra := (dist & 1) << nb
  // 			for f.nb < nb {
  // 				if err = f.more_bits(); err != nil {
  // 					f.err = err
  // 					return
  // 				}
  // 			}
  // 			extra |= int(f.b & uint32(1<<nb-1))
  // 			f.b >>= nb
  // 			f.nb -= nb
  // 			dist = 1<<(nb+1) + 1 + extra
  // 		default:
  // 			f.err = CorruptInputError(f.roffset)
  // 			return
  // 		}

  // 		// No check on length; encoding can be prescient.
  // 		if dist > f.dict.histSize() {
  // 			f.err = CorruptInputError(f.roffset)
  // 			return
  // 		}

  // 		f.copy_len, f.copy_dist = length, dist
  // 		goto copyHistory
  // 	}

  // copyHistory:
  // 	// Perform a backwards copy according to RFC section 3.2.3.
  // 	{
  // 		cnt := f.dict.tryWriteCopy(f.copy_dist, f.copy_len)
  // 		if cnt == 0 {
  // 			cnt = f.dict.writeCopy(f.copy_dist, f.copy_len)
  // 		}
  // 		f.copy_len -= cnt

  // 		if f.dict.avail_write() == 0 || f.copy_len > 0 {
  // 			f.to_read = f.dict.read_flush()
  // 			f.step = (*decompressor).huffman_block // We need to continue this work
  // 			f.step_state = stateDict
  // 			return
  // 		}
  // 		goto readLiteral
  // 	}
}

/// Copy a single uncompressed data block from input to output.
fn data_block(self : Decompressor) -> Unit {
  // Uncompressed.
  // Discard current half-byte.
  self.nb = 0
  self.b = 0

  // Length then ones-complement of length.
  let nr = try {
    self.r.read_full!(self.buf[0:4])
  } catch {
    err => {
      self.err = Some(no_eof(err))
      return
    }
  }
  self.roffset += nr.to_int64()
  let n = self.buf[0].to_int() | (self.buf[1].to_int() << 8)
  let nn = self.buf[2].to_int() | (self.buf[3].to_int() << 8)
  // if uint16(nn) != uint16(^n) {
  if nn.reinterpret_as_uint() != n.reinterpret_as_uint().lnot() {
    self.err = Some(CorruptInputError(self.roffset))
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

/// copy_data copies f.copy_len bytes from the underlying reader into f.hist.
/// It pauses for reads when f.hist is full.
fn copy_data(self : Decompressor) -> Unit {
  let mut buf = self.dict.write_slice()
  if buf.length() > self.copy_len {
    buf = buf[:self.copy_len]
  }

  // cnt, err := io.ReadFull(self.r, buf)
  let cnt = try {
    self.r.read_full!(buf)
  } catch {
    err => {
      self.err = Some(no_eof(err))
      return
    }
  }
  self.roffset += cnt.to_int64()
  self.copy_len -= cnt
  self.dict.write_mark(cnt)
  if self.dict.avail_write() == 0 || self.copy_len > 0 {
    self.to_read = self.dict.read_flush()
    self.step = copy_data
    return
  }
  self.finish_block()
}

fn finish_block(self : Decompressor) -> Unit {
  if self.final {
    if self.dict.avail_read() > 0 {
      self.to_read = self.dict.read_flush()
    }
    self.err = Some(IOEOF)
  }
  self.step = next_block
}

/// no_eof returns err, unless err == IOEOF, in which case it returns IOErrUnexpectedEOF.
fn no_eof(e : Error) -> Error {
  match e {
    IOEOF => return IOErrUnexpectedEOF
    _ => e
  }
}

fn more_bits(self : Decompressor) -> Error? {
  let c = try {
    self.r.read_byte!()
  } catch {
    err => return Some(err)
  }
  self.roffset += 1
  self.b = self.b | (c.to_uint() << self.nb.reinterpret_as_int())
  self.nb += 8
  None
}

// // Read the next Huffman-encoded symbol from f according to h.
fn huff_sym(self : Decompressor, h : HuffmanDecoder) -> Int!Error {
  raise IOEOF
  // 	log.Printf("GML: inflate.go: (f *decompressor) huff_sym(h *huffmanDecoder) (int, error) {")
  // 	// Since a huffmanDecoder can be empty or be composed of a degenerate tree
  // 	// with single element, huff_sym must error on these two edge cases. In both
  // 	// cases, the chunks slice will be 0 for the invalid sequence, leading it
  // 	// satisfy the n == 0 check below.
  // 	n := uint(h.min)
  // 	// Optimization. Compiler isn't smart enough to keep f.b,f.nb in registers,
  // 	// but is smart enough to keep local variables in registers, so use nb and b,
  // 	// inline call to more_bits and reassign b,nb back to f on return.
  // 	nb, b := f.nb, f.b
  // 	for {
  // 		for nb < n {
  // 			c, err := f.r.read_byte()
  // 			if err != nil {
  // 				f.b = b
  // 				f.nb = nb
  // 				return 0, no_eof(err)
  // 			}
  // 			f.roffset++
  // 			b |= uint32(c) << (nb & 31)
  // 			nb += 8
  // 		}
  // 		chunk := h.chunks[b&(huffmanNumChunks-1)]
  // 		n = uint(chunk & huffmanCountMask)
  // 		if n > huffmanChunkBits {
  // 			chunk = h.links[chunk>>huffmanValueShift][(b>>huffmanChunkBits)&h.link_mask]
  // 			n = uint(chunk & huffmanCountMask)
  // 		}
  // 		if n <= nb {
  // 			if n == 0 {
  // 				f.b = b
  // 				f.nb = nb
  // 				f.err = CorruptInputError(f.roffset)
  // 				return 0, f.err
  // 			}
  // 			f.b = b >> (n & 31)
  // 			f.nb = nb - n
  // 			return int(chunk >> huffmanValueShift), nil
  // 		}
  // 	}
  0
}

fn make_reader(self : Decompressor, r : IOReader) -> Unit {
  // 	log.Printf("GML: inflate.go: (f *decompressor) make_reader(r io.Reader) {")
  // 	if rr, ok := r.(Reader); ok {
  // 		f.rBuf = nil
  // 		f.r = rr
  // 		return
  // 	}
  // 	// Reuse rBuf if possible. Invariant: rBuf is always created (and owned) by decompressor.
  // 	if f.rBuf != nil {
  // 		f.rBuf.Reset(r)
  // 	} else {
  // 		// bufio.NewReader will not return r, as r does not implement flate.Reader, so it is not bufio.Reader.
  // 		f.rBuf = bufio.NewReader(r)
  // 	}
  // 	f.r = f.rBuf
}

// func fixed_huffman_decoderInit() {
// 	log.Printf("GML: inflate.go: fixed_huffman_decoderInit() {")
// 	fixedOnce.Do(func() {
// 		// These come from the RFC section 3.2.6.
// 		var bits [288]int
// 		for i := 0; i < 144; i++ {
// 			bits[i] = 8
// 		}
// 		for i := 144; i < 256; i++ {
// 			bits[i] = 9
// 		}
// 		for i := 256; i < 280; i++ {
// 			bits[i] = 7
// 		}
// 		for i := 280; i < 288; i++ {
// 			bits[i] = 8
// 		}
// 		fixed_huffman_decoder.init(bits[:])
// 	})
// }

fn reset(self : Decompressor, r : IOReader, dict : Bytes) -> Unit {
  self.r = r
  self.roffset = 0
  self.b = 0
  self.nb = 0
  self.dict = DictDecoder::new(max_match_offset, dict)
  self.step = next_block
  self.step_state = 0
  self.final = false
  self.err = None
  self.to_read = [][:]
  self.hl = fixed_huffman_decoder
  self.hd = Some(fixed_huffman_decoder)
  self.copy_len = 0
  self.copy_dist = 0
}

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
