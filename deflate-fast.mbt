// This file is based on the Go implementation found here:
// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/deflatefast.go
// which has the copyright notice:
// Copyright 2016 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// This encoding algorithm, which prioritizes speed over output size, is
// based on Snappy's LZ77-style encoder: github.com/golang/snappy

///|
let table_bits = 14 // Bits used in the table.

///|
let table_size : Int = 1 << table_bits // Size of the table.

///|
let table_mask : Int = table_size - 1 // Mask for table indices. Redundant, but can eliminate bounds checks.

///|
let table_shift : Int = 32 - table_bits // Right-shift to get the table_bits most significant bits of a UInt.

// The LZ77 step produces a sequence of literal tokens and <length, offset>
// pair tokens. The offset is also known as distance. The underlying wire
// format limits the range of lengths and offsets. For example, there are
// 256 legitimate lengths: those in the range [3, 258]. This package's
// compressor uses a higher minimum match length, enabling optimizations
// such as finding matches via 32-bit loads and compares.

///|
let base_match_length = 3 // The smallest match length per the RFC section 3.2.5

///|
let max_match_length = 258 // The largest match length

///|
let base_match_offset = 1 // The smallest match offset

///|
let max_match_offset : Int = 1 << 15 // The largest match offset

// The maximum number of tokens we put into a single flate block, just to
// stop things from getting too large.

///|
let max_store_block_size = 65535

// Reset the buffer offset when reaching this.
// Offsets are stored between blocks as Int values.
// Since the offset we are checking against is at the beginning
// of the buffer, we need to subtract the current and input
// buffer to not risk overflowing the Int.

///|
let buffer_reset : Int = @int.max_value - max_store_block_size * 2

///|
fn load32(b : Slice[Byte], i : Int) -> UInt {
  return b[i + 0].to_uint() |
    (b[i + 1].to_uint() << 8) |
    (b[i + 2].to_uint() << 16) |
    (b[i + 3].to_uint() << 24)
}

///|
fn load64(b : Slice[Byte], i : Int) -> UInt64 {
  return b[i + 0].to_uint().to_uint64() |
    (b[i + 1].to_uint().to_uint64() << 8) |
    (b[i + 2].to_uint().to_uint64() << 16) |
    (b[i + 3].to_uint().to_uint64() << 24) |
    (b[i + 4].to_uint().to_uint64() << 32) |
    (b[i + 5].to_uint().to_uint64() << 40) |
    (b[i + 6].to_uint().to_uint64() << 48) |
    (b[i + 7].to_uint().to_uint64() << 56)
}

///|
fn hash(u : UInt) -> Int { // uint32 - but always used as int below
  let v = (u * 0x1e35a7bd) >> table_shift
  return v.reinterpret_as_int()
}

// These constants are defined by the Snappy implementation so that its
// assembly implementation can fast-path some 16-bytes-at-a-time copies. They
// aren't necessary in the pure Go implementation, as we don't use those same
// optimizations, but using the same thresholds doesn't really hurt.

///|
let input_margin : Int = 16 - 1

///|
let min_non_literal_block_size : Int = 1 + 1 + input_margin

///|
priv struct TableEntry {
  val : UInt // Value at destination
  mut offset : Int
}

// DeflateFast maintains the table for matches,
// and the previous byte block for cross block matching.

///|
priv struct DeflateFast {
  table : FixedArray[TableEntry] // [table_size]TableEntry
  mut prev : Slice[Byte] // Previous block, zero length if unknown.
  mut cur : Int // Current match offset.
}

///|
fn DeflateFast::new() -> DeflateFast {
  {
    table: FixedArray::make(table_size, { val: 0U, offset: 0 }),
    prev: Slice::new([]),
    cur: max_store_block_size,
  }
}

// encode encodes a block given in src and appends tokens
// to dst and returns the result.

///|
fn encode(
  self : DeflateFast,
  dst : Array[Token],
  src : Slice[Byte],
) -> Array[Token] {
  let mut dst = dst
  // Ensure that self.cur doesn't wrap.
  if self.cur >= buffer_reset {
    self.shift_offsets()
  }

  // This check isn't in the Snappy implementation, but there, the caller
  // instead of the callee handles this case.
  if src.length() < min_non_literal_block_size {
    self.cur += max_store_block_size
    self.prev = Slice::new([])
    return emit_literal(dst, src)
  }

  // s_limit is when to stop looking for offset/length copies. The input_margin
  // lets us use a fast path for emit_literal in the main loop, while we are
  // looking for copies.
  let s_limit = src.length() - input_margin
  let mut next_emit = 0
  let mut s = 0

  // next_emit is where in src the next emit_literal should start from.
  let mut cv = load32(src, s)
  let mut next_hash = hash(cv)
  let emit_remainder = fn() {
    if next_emit < src.length() {
      dst = emit_literal(dst, src[next_emit:])
    }
    self.cur += src.length()
    let _ = slice_copy(self.prev, src)
    return dst
  }

  //
  for {
    // Copied from the C++ snappy implementation:
    //
    // Heuristic match skipping: If 32 bytes are scanned with no matches
    // found, start looking only at every other byte. If 32 more bytes are
    // scanned (or skipped), look at every third byte, etc.. When a match
    // is found, immediately go back to looking at every byte. This is a
    // small loss (~5% performance, ~0.1% density) for compressible data
    // due to more bookkeeping, but for non-compressible data (such as
    // JPEG) it's a huge win since the compressor quickly "realizes" the
    // data is incompressible and doesn't bother looking for matches
    // everywhere.
    //
    // The "skip" variable keeps track of how many bytes there are since
    // the last match; dividing it by 32 (ie. right-shifting by five) gives
    // the number of bytes to move ahead for each iteration.
    let mut skip = 32
    let mut next_s = s
    let mut candidate : TableEntry = { val: 0U, offset: 0 }

    //
    for {
      s = next_s
      let bytes_between_hash_lookups = skip >> 5
      next_s = s + bytes_between_hash_lookups
      skip += bytes_between_hash_lookups
      if next_s > s_limit {
        return emit_remainder()
      }
      candidate = self.table[next_hash & table_mask]
      let now = load32(src, next_s)
      self.table[next_hash & table_mask] = { offset: s + self.cur, val: cv }
      next_hash = hash(now)
      let offset = s - (candidate.offset - self.cur)
      if offset > max_match_offset || cv != candidate.val {
        // Out of range or not matched.
        cv = now
        continue
      }
      break
    }

    // A 4-byte match has been found. We'll later see if more than 4 bytes
    // match. But, prior to the match, src[next_emit:s] are unmatched. Emit
    // them as literal bytes.
    dst = emit_literal(dst, src[next_emit:s])

    // Call emitCopy, and then see if another emitCopy could be our next
    // move. Repeat until we find no match for the input immediately after
    // what was consumed by the last emitCopy call.
    //
    // If we exit this loop normally then we need to call emit_literal next,
    // though we don't yet know how big the literal will be. We handle that
    // by proceeding to the next iteration of the main loop. We also can
    // exit this loop via goto if we get close to exhausting the input.
    for {
      // Invariant: we have a 4-byte match at s, and no need to emit any
      // literal bytes prior to s.

      // Extend the 4-byte match as long as possible.
      //
      s += 4
      let t = candidate.offset - self.cur + 4
      let l = self.match_len(s, t, src)

      // match_token is flate's equivalent of Snappy's emitCopy. (length,offset)
      dst.push(
        match_token(
          (l + 4 - base_match_length).reinterpret_as_uint(),
          (s - t - base_match_offset).reinterpret_as_uint(),
        ),
      )
      s += l
      next_emit = s
      if s >= s_limit {
        return emit_remainder()
      }

      // We could immediately start working at s now, but to improve
      // compression we first update the hash table at s-1 and at s. If
      // another emitCopy is not our next move, also calculate next_hash
      // at s+1. At least on GOARCH=amd64, these three hash calculations
      // are faster as one load64 call (with some shifts) instead of
      // three load32 calls.
      let mut x = load64(src, s - 1)
      let prev_hash = hash(x.to_uint())
      self.table[prev_hash & table_mask] = {
        offset: self.cur + s - 1,
        val: x.to_uint(),
      }
      x = x >> 8
      let curr_hash = hash(x.to_uint())
      candidate = self.table[curr_hash & table_mask]
      self.table[curr_hash & table_mask] = {
        offset: self.cur + s,
        val: x.to_uint(),
      }
      let offset = s - (candidate.offset - self.cur)
      if offset > max_match_offset || x.to_uint() != candidate.val {
        cv = (x >> 8).to_uint()
        next_hash = hash(cv)
        s += 1
        break
      }
    }
  }
  //
  emit_remainder()
}

///|
fn emit_literal(dst : Array[Token], lit : Slice[Byte]) -> Array[Token] {
  for i in 0..<lit.length() {
    let v = lit[i]
    dst.push(literal_token(v.to_uint()))
  }
  return dst
}

// match_len returns the match length between src[s:] and src[t:].
// t can be negative to indicate the match is starting in self.prev.
// We assume that src[s-4:s] and src[t-4:t] already match.

///|
fn match_len(self : DeflateFast, s : Int, t : Int, src : Slice[Byte]) -> Int {
  let mut s1 = s + max_match_length - 4
  if s1 > src.length() {
    s1 = src.length()
  }

  // If we are inside the current block
  if t >= 0 {
    let a_length = s1 - s
    // Extend the match to be as long as possible.
    for i = 0; i < a_length; i = i + 1 {
      if src[s + i] != src[t + i] {
        return i
      }
    }
    return a_length
  }

  // We found a match in the previous block.
  let tp = self.prev.length() + t
  if tp < 0 {
    return 0
  }

  // Extend the match to be as long as possible.
  let a_length = s1 - s
  let mut b_length = self.prev.length() - tp
  if b_length > a_length {
    b_length = a_length
  }
  for i = 0; i < b_length; i = i + 1 {
    if src[s + i] != self.prev[tp + i] {
      return i
    }
  }

  // If we reached our limit, we matched everything we are
  // allowed to in the previous block and we return.
  let n = b_length
  if s + n == s1 {
    return n
  }

  // Continue looking for more matches in the current block.
  let a_length = s1 - (s + n)
  for i = 0; i < a_length; i = i + 1 {
    if src[s + n + i] != src[i] {
      return i + n
    }
  }
  return a_length + n
}

// Reset resets the encoding history.
// This ensures that no matches are made to the previous block.

///|
fn reset(self : DeflateFast) -> Unit {
  self.prev = Slice::new([])
  // Bump the offset, so all matches will fail distance check.
  // Nothing should be >= self.cur in the table.
  self.cur += max_match_offset

  // Protect against self.cur wraparound.
  if self.cur >= buffer_reset {
    self.shift_offsets()
  }
}

// shift_offsets will shift down all match offset.
// This is only called in rare situations to prevent integer overflow.
//
// See https://golang.org/issue/18636 and https://github.com/golang/go/issues/34121.

///|
fn shift_offsets(self : DeflateFast) -> Unit {
  if self.prev.length() == 0 {
    // We have no history; just clear the table.
    for i = 0; i < table_size; i = i + 1 {
      self.table[i] = { val: 0U, offset: 0 }
    }
    self.cur = max_match_offset + 1
    return
  }

  // Shift down everything in the table that isn't already too far away.
  for i = 0; i < table_size; i = i + 1 {
    let mut v = self.table[i].offset - self.cur + max_match_offset + 1
    if v < 0 {
      // We want to reset self.cur to max_match_offset + 1, so we need to shift
      // all table entries down by (self.cur - (max_match_offset + 1)).
      // Because we ignore matches > max_match_offset, we can cap
      // any negative offsets at 0.
      v = 0
    }
    self.table[i].offset = v
  }
  self.cur = max_match_offset + 1
}
