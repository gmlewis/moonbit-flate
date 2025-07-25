// This file is based on the Go implementation found here:
// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/huffman_code.go
// which has the copyright notice:
// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

///|
priv struct HuffmanEncoder {
  codes : Array[HCode]
  mut freqcache : Array[LiteralNode]
  bit_count : Array[Int] // [17]Int
}

///|
fn HuffmanEncoder::new(size : Int) -> HuffmanEncoder {
  let codes = Array::make(size, { code: 0U, len: 0U })
  // Is this a MoonBit bug? Need to make unique arrays or else they will
  // all refer to the same one.
  for i = 0; i < size; i = i + 1 {
    codes[i] = { code: 0U, len: 0U }
  }
  let freqcache = []
  let bit_count = Array::make(17, 0)
  { codes, freqcache, bit_count }
}

///|
priv struct LiteralNode {
  literal : UInt // uint16
  freq : Int
}

// HCode is a huffman code with a bit code and bit length.

///|
priv struct HCode {
  mut code : UInt
  mut len : UInt
}

// A levelInfo describes the state of the constructed tree for a given depth.

///|
priv struct LevelInfo {
  // Our level.  for better printing
  level : Int

  // The frequency of the last node at this level
  mut last_freq : Int

  // The frequency of the next character to add to this level
  mut next_char_freq : Int

  // The frequency of the next pair (from level below) to add to this level.
  // Only valid if the "needed" value of the next lower level is 0.
  mut next_pair_freq : Int

  // The number of chains remaining to generate for this level before moving
  // up to the next level
  mut needed : Int
}

///|
fn LevelInfo::new() -> LevelInfo {
  { level: 0, last_freq: 0, next_char_freq: 0, next_pair_freq: 0, needed: 0 }
}

// set sets the code and length of an hcode.

///|
fn set(self : HCode, code : UInt, length : UInt) -> Unit {
  self.len = length
  self.code = code
}

///|
fn max_node() -> LiteralNode {
  { literal: @uint.max_value, freq: @int.max_value }
}

///|
fn bit_length(self : HuffmanEncoder, freq : Slice[Int]) -> Int {
  let mut total = 0
  for i, f in freq {
    if f != 0 {
      total += f * self.codes[i].len.reinterpret_as_int()
    }
  }
  total
}

///|
let max_bits_limit = 16

// bit_counts computes the number of literals assigned to each bit size in the Huffman encoding.
// It is only called when list.length >= 3.
// The cases of 0, 1, and 2 literals are handled by special case code.
//
// list is an array of the literals with non-zero frequencies
// and their associated frequencies. The array is in order of increasing
// frequency and has as its last element a special element with frequency
// MaxInt.
//
// max_bits is the maximum number of bits that should be used to encode any literal.
// It must be less than 16.
//
// bit_counts returns an integer slice in which slice[i] indicates the number of literals
// that should be encoded in i bits.

///|
fn bit_counts(
  self : HuffmanEncoder,
  list : Slice[LiteralNode],
  max_bits : Int,
) -> Slice[Int] {
  if max_bits >= max_bits_limit {
    abort("flate: max_bits too large")
  }
  let n = list.length()
  let list = list[0:n + 1]
  list[n] = max_node()

  // The tree can't have greater depth than n - 1, no matter what. This
  // saves a little bit of work in some small cases
  let mut max_bits = max_bits
  if max_bits > n - 1 {
    max_bits = n - 1
  }

  // Create information about each of the levels.
  // A bogus "Level 0" whose sole purpose is so that
  // level1.prev.needed==0.  This makes level1.next_pair_freq
  // be a legitimate value that never gets chosen.
  let levels = FixedArray::make(max_bits_limit, LevelInfo::new()) // [max_bits_limit]levelInfo
  // leaf_counts[i] counts the number of literals at the left
  // of ancestors of the rightmost node at level i.
  // leaf_counts[i][j] is the number of literals at the left
  // of the level j ancestor.
  let leaf_counts = FixedArray::make(
    max_bits_limit,
    FixedArray::make(max_bits_limit, 0),
  ) // [max_bits_limit][max_bits_limit]Int
  // Is this a MoonBit bug? Need to make unique arrays or else they will
  // all refer to the same one.
  for i = 0; i < max_bits_limit; i = i + 1 {
    leaf_counts[i] = FixedArray::make(max_bits_limit, 0)
  }

  //
  for level = 1; level <= max_bits; level = level + 1 {
    // For every level, the first two items are the first two characters.
    // We initialize the levels as if we had already figured this out.
    levels[level] = {
      level,
      last_freq: list[1].freq,
      next_char_freq: list[2].freq,
      next_pair_freq: list[0].freq + list[1].freq,
      needed: 0,
    }
    leaf_counts[level][level] = 2
    if level == 1 {
      levels[level].next_pair_freq = @int.max_value
    }
  }

  // We need a total of 2*n - 2 items at top level and have already generated 2.
  levels[max_bits].needed = 2 * n - 4

  //
  let mut level = max_bits
  for {
    if levels[level].next_pair_freq == @int.max_value &&
      levels[level].next_char_freq == @int.max_value {
      // We've run out of both leafs and pairs.
      // End all calculations for this level.
      // To make sure we never come back to this level or any lower level,
      // set next_pair_freq impossibly large.
      levels[level].needed = 0
      levels[level + 1].next_pair_freq = @int.max_value
      level += 1
      continue
    }

    //
    let prev_freq = levels[level].last_freq
    if levels[level].next_char_freq < levels[level].next_pair_freq {
      // The next item on this row is a leaf node.
      let n = leaf_counts[level][level] + 1
      levels[level].last_freq = levels[level].next_char_freq
      // Lower leaf_counts are the same of the previous node.
      leaf_counts[level][level] = n
      levels[level].next_char_freq = list[n].freq
    } else {
      // The next item on this row is a pair from the previous row.
      // next_pair_freq isn't valid until we generate two
      // more values in the level below
      levels[level].last_freq = levels[level].next_pair_freq
      // Take leaf counts from the lower level, except counts[level] remains the same.
      // copy(leaf_counts[level][:level], leaf_counts[level - 1][:level])
      for i in 0..<level {
        leaf_counts[level][i] = leaf_counts[level - 1][i]
      }
      levels[levels[level].level - 1].needed = 2
    }

    //
    levels[level].needed -= 1
    if levels[level].needed == 0 {
      // We've done everything we need to do for this level.
      // Continue calculating one level up. Fill in next_pair_freq
      // of that level with the sum of the two nodes we've just calculated on
      // this level.
      if levels[level].level == max_bits {
        // All done!
        break
      }
      levels[levels[level].level + 1].next_pair_freq = prev_freq +
        levels[level].last_freq
      level += 1
    } else {
      // If we stole from below, move down temporarily to replenish it.
      while levels[level - 1].needed > 0 {
        level -= 1
      }
    }
  }

  // Somethings is wrong if at the end, the top level is null or hasn't used
  // all of the leaves.
  if leaf_counts[max_bits][max_bits] != n {
    abort("leaf_counts[max_bits][max_bits] != n")
  }
  let bit_count = Slice::new(self.bit_count)[:max_bits + 1]
  let mut bits = 1
  let counts = leaf_counts[max_bits]
  for level = max_bits; level > 0; level = level - 1 {
    // chain.leafCount gives the number of literals requiring at least "bits"
    // bits to encode.
    bit_count[bits] = counts[level] - counts[level - 1]
    bits += 1
  }
  bit_count
}

// Look at the leaves and assign them a bit count and an encoding as specified
// in RFC 1951 3.2.2

///|
fn assign_encoding_and_size(
  self : HuffmanEncoder,
  bit_count : Slice[Int],
  list : Slice[LiteralNode],
) -> Unit {
  let mut list = list
  let mut code = 0
  for n, bits in bit_count {
    code = code << 1
    if n == 0 || bits == 0 {
      continue
    }
    // The literals list[len(list)-bits] .. list[len(list)-bits]
    // are encoded using "bits" bits, and get the values
    // code, code + 1, ....  The code values are
    // assigned in literal order (not frequency order).
    let chunk = list[list.length() - bits:]
    quicksort(chunk, by_literal)
    for node in chunk {
      let key = node.literal.reinterpret_as_int()
      let debug_code = reverse_bits(
        code.reinterpret_as_uint() & 0xffff,
        n.to_byte(),
      )
      let len = n.reinterpret_as_uint()
      self.codes[key] = { code: debug_code, len }
      code += 1
    }
    list = list[0:list.length() - bits]
  }
}

///|
fn reverse_bits(number : UInt, bit_length : Byte) -> UInt {
  let v = reverse16(number << (16 - bit_length.to_int()))
  return v
}

///|
test "reverse_bits works" {
  let got = reverse_bits(64, b'\x07')
  inspect(got, content="1")
}

///|
fn generate(self : HuffmanEncoder, freq : Slice[Int], max_bits : Int) -> Unit {
  if self.freqcache.length() == 0 {
    // Allocate a reusable buffer with the longest possible frequency table.
    // Possible lengths are codegenCodeCount, offsetCodeCount and max_num_lit.
    // The largest of these is max_num_lit, so we allocate for that case.
    self.freqcache = Array::make(max_num_lit + 1, { literal: 0, freq: 0 })
    // Is this a MoonBit bug? Need to make unique structs or else they will
    // all refer to the same one.
    for i = 0; i <= max_num_lit; i = i + 1 {
      self.freqcache[i] = { literal: 0, freq: 0 }
    }
  }
  let mut list = Slice::new(self.freqcache)[:freq.length() + 1]
  // Number of non-zero literals
  let mut count = 0
  // Set list to be the set of all non-zero literals and their frequencies
  for i, f in freq {
    if f != 0 {
      list[count] = { literal: (i & 0xffff).reinterpret_as_uint(), freq: f }
      count += 1
    } else {
      self.codes[i].len = 0
    }
  }

  //
  list = list[:count]
  if count <= 2 {
    // Handle the small cases here, because they are awkward for the general case code. With
    // two or fewer literals, everything has bit length 1.
    for i, node in list {
      // "list" is in order of increasing literal value.
      let key = node.literal.reinterpret_as_int() & 0xffff
      let code = (i & 0xffff).reinterpret_as_uint()
      self.codes[key].set(code, 1)
    }
    return
  }
  quicksort(list, by_frequency)

  // Get the number of literals for each bit count
  let bit_count = self.bit_counts(list, max_bits)
  // And do the assignment
  self.assign_encoding_and_size(bit_count, list)
}

///|
fn by_frequency(a : LiteralNode, b : LiteralNode) -> Bool {
  if a.freq == b.freq {
    return a.literal.reinterpret_as_int() < b.literal.reinterpret_as_int()
  }
  return a.freq < b.freq
}

///|
fn by_literal(a : LiteralNode, b : LiteralNode) -> Bool {
  return a.literal.reinterpret_as_int() < b.literal.reinterpret_as_int()
}

// ///|
// let fixed_literal_encoding : HuffmanEncoder = {
//   codes: [
//     { code: 12, len: 8 },
//     { code: 140, len: 8 },
//     { code: 76, len: 8 },
//     { code: 204, len: 8 },
//     { code: 44, len: 8 },
//     { code: 172, len: 8 },
//     { code: 108, len: 8 },
//     { code: 236, len: 8 },
//     { code: 28, len: 8 },
//     { code: 156, len: 8 },
//     { code: 92, len: 8 },
//     { code: 220, len: 8 },
//     { code: 60, len: 8 },
//     { code: 188, len: 8 },
//     { code: 124, len: 8 },
//     { code: 252, len: 8 },
//     { code: 2, len: 8 },
//     { code: 130, len: 8 },
//     { code: 66, len: 8 },
//     { code: 194, len: 8 },
//     { code: 34, len: 8 },
//     { code: 162, len: 8 },
//     { code: 98, len: 8 },
//     { code: 226, len: 8 },
//     { code: 18, len: 8 },
//     { code: 146, len: 8 },
//     { code: 82, len: 8 },
//     { code: 210, len: 8 },
//     { code: 50, len: 8 },
//     { code: 178, len: 8 },
//     { code: 114, len: 8 },
//     { code: 242, len: 8 },
//     { code: 10, len: 8 },
//     { code: 138, len: 8 },
//     { code: 74, len: 8 },
//     { code: 202, len: 8 },
//     { code: 42, len: 8 },
//     { code: 170, len: 8 },
//     { code: 106, len: 8 },
//     { code: 234, len: 8 },
//     { code: 26, len: 8 },
//     { code: 154, len: 8 },
//     { code: 90, len: 8 },
//     { code: 218, len: 8 },
//     { code: 58, len: 8 },
//     { code: 186, len: 8 },
//     { code: 122, len: 8 },
//     { code: 250, len: 8 },
//     { code: 6, len: 8 },
//     { code: 134, len: 8 },
//     { code: 70, len: 8 },
//     { code: 198, len: 8 },
//     { code: 38, len: 8 },
//     { code: 166, len: 8 },
//     { code: 102, len: 8 },
//     { code: 230, len: 8 },
//     { code: 22, len: 8 },
//     { code: 150, len: 8 },
//     { code: 86, len: 8 },
//     { code: 214, len: 8 },
//     { code: 54, len: 8 },
//     { code: 182, len: 8 },
//     { code: 118, len: 8 },
//     { code: 246, len: 8 },
//     { code: 14, len: 8 },
//     { code: 142, len: 8 },
//     { code: 78, len: 8 },
//     { code: 206, len: 8 },
//     { code: 46, len: 8 },
//     { code: 174, len: 8 },
//     { code: 110, len: 8 },
//     { code: 238, len: 8 },
//     { code: 30, len: 8 },
//     { code: 158, len: 8 },
//     { code: 94, len: 8 },
//     { code: 222, len: 8 },
//     { code: 62, len: 8 },
//     { code: 190, len: 8 },
//     { code: 126, len: 8 },
//     { code: 254, len: 8 },
//     { code: 1, len: 8 },
//     { code: 129, len: 8 },
//     { code: 65, len: 8 },
//     { code: 193, len: 8 },
//     { code: 33, len: 8 },
//     { code: 161, len: 8 },
//     { code: 97, len: 8 },
//     { code: 225, len: 8 },
//     { code: 17, len: 8 },
//     { code: 145, len: 8 },
//     { code: 81, len: 8 },
//     { code: 209, len: 8 },
//     { code: 49, len: 8 },
//     { code: 177, len: 8 },
//     { code: 113, len: 8 },
//     { code: 241, len: 8 },
//     { code: 9, len: 8 },
//     { code: 137, len: 8 },
//     { code: 73, len: 8 },
//     { code: 201, len: 8 },
//     { code: 41, len: 8 },
//     { code: 169, len: 8 },
//     { code: 105, len: 8 },
//     { code: 233, len: 8 },
//     { code: 25, len: 8 },
//     { code: 153, len: 8 },
//     { code: 89, len: 8 },
//     { code: 217, len: 8 },
//     { code: 57, len: 8 },
//     { code: 185, len: 8 },
//     { code: 121, len: 8 },
//     { code: 249, len: 8 },
//     { code: 5, len: 8 },
//     { code: 133, len: 8 },
//     { code: 69, len: 8 },
//     { code: 197, len: 8 },
//     { code: 37, len: 8 },
//     { code: 165, len: 8 },
//     { code: 101, len: 8 },
//     { code: 229, len: 8 },
//     { code: 21, len: 8 },
//     { code: 149, len: 8 },
//     { code: 85, len: 8 },
//     { code: 213, len: 8 },
//     { code: 53, len: 8 },
//     { code: 181, len: 8 },
//     { code: 117, len: 8 },
//     { code: 245, len: 8 },
//     { code: 13, len: 8 },
//     { code: 141, len: 8 },
//     { code: 77, len: 8 },
//     { code: 205, len: 8 },
//     { code: 45, len: 8 },
//     { code: 173, len: 8 },
//     { code: 109, len: 8 },
//     { code: 237, len: 8 },
//     { code: 29, len: 8 },
//     { code: 157, len: 8 },
//     { code: 93, len: 8 },
//     { code: 221, len: 8 },
//     { code: 61, len: 8 },
//     { code: 189, len: 8 },
//     { code: 125, len: 8 },
//     { code: 253, len: 8 },
//     { code: 19, len: 9 },
//     { code: 275, len: 9 },
//     { code: 147, len: 9 },
//     { code: 403, len: 9 },
//     { code: 83, len: 9 },
//     { code: 339, len: 9 },
//     { code: 211, len: 9 },
//     { code: 467, len: 9 },
//     { code: 51, len: 9 },
//     { code: 307, len: 9 },
//     { code: 179, len: 9 },
//     { code: 435, len: 9 },
//     { code: 115, len: 9 },
//     { code: 371, len: 9 },
//     { code: 243, len: 9 },
//     { code: 499, len: 9 },
//     { code: 11, len: 9 },
//     { code: 267, len: 9 },
//     { code: 139, len: 9 },
//     { code: 395, len: 9 },
//     { code: 75, len: 9 },
//     { code: 331, len: 9 },
//     { code: 203, len: 9 },
//     { code: 459, len: 9 },
//     { code: 43, len: 9 },
//     { code: 299, len: 9 },
//     { code: 171, len: 9 },
//     { code: 427, len: 9 },
//     { code: 107, len: 9 },
//     { code: 363, len: 9 },
//     { code: 235, len: 9 },
//     { code: 491, len: 9 },
//     { code: 27, len: 9 },
//     { code: 283, len: 9 },
//     { code: 155, len: 9 },
//     { code: 411, len: 9 },
//     { code: 91, len: 9 },
//     { code: 347, len: 9 },
//     { code: 219, len: 9 },
//     { code: 475, len: 9 },
//     { code: 59, len: 9 },
//     { code: 315, len: 9 },
//     { code: 187, len: 9 },
//     { code: 443, len: 9 },
//     { code: 123, len: 9 },
//     { code: 379, len: 9 },
//     { code: 251, len: 9 },
//     { code: 507, len: 9 },
//     { code: 7, len: 9 },
//     { code: 263, len: 9 },
//     { code: 135, len: 9 },
//     { code: 391, len: 9 },
//     { code: 71, len: 9 },
//     { code: 327, len: 9 },
//     { code: 199, len: 9 },
//     { code: 455, len: 9 },
//     { code: 39, len: 9 },
//     { code: 295, len: 9 },
//     { code: 167, len: 9 },
//     { code: 423, len: 9 },
//     { code: 103, len: 9 },
//     { code: 359, len: 9 },
//     { code: 231, len: 9 },
//     { code: 487, len: 9 },
//     { code: 23, len: 9 },
//     { code: 279, len: 9 },
//     { code: 151, len: 9 },
//     { code: 407, len: 9 },
//     { code: 87, len: 9 },
//     { code: 343, len: 9 },
//     { code: 215, len: 9 },
//     { code: 471, len: 9 },
//     { code: 55, len: 9 },
//     { code: 311, len: 9 },
//     { code: 183, len: 9 },
//     { code: 439, len: 9 },
//     { code: 119, len: 9 },
//     { code: 375, len: 9 },
//     { code: 247, len: 9 },
//     { code: 503, len: 9 },
//     { code: 15, len: 9 },
//     { code: 271, len: 9 },
//     { code: 143, len: 9 },
//     { code: 399, len: 9 },
//     { code: 79, len: 9 },
//     { code: 335, len: 9 },
//     { code: 207, len: 9 },
//     { code: 463, len: 9 },
//     { code: 47, len: 9 },
//     { code: 303, len: 9 },
//     { code: 175, len: 9 },
//     { code: 431, len: 9 },
//     { code: 111, len: 9 },
//     { code: 367, len: 9 },
//     { code: 239, len: 9 },
//     { code: 495, len: 9 },
//     { code: 31, len: 9 },
//     { code: 287, len: 9 },
//     { code: 159, len: 9 },
//     { code: 415, len: 9 },
//     { code: 95, len: 9 },
//     { code: 351, len: 9 },
//     { code: 223, len: 9 },
//     { code: 479, len: 9 },
//     { code: 63, len: 9 },
//     { code: 319, len: 9 },
//     { code: 191, len: 9 },
//     { code: 447, len: 9 },
//     { code: 127, len: 9 },
//     { code: 383, len: 9 },
//     { code: 255, len: 9 },
//     { code: 511, len: 9 },
//     { code: 0, len: 7 },
//     { code: 64, len: 7 },
//     { code: 32, len: 7 },
//     { code: 96, len: 7 },
//     { code: 16, len: 7 },
//     { code: 80, len: 7 },
//     { code: 48, len: 7 },
//     { code: 112, len: 7 },
//     { code: 8, len: 7 },
//     { code: 72, len: 7 },
//     { code: 40, len: 7 },
//     { code: 104, len: 7 },
//     { code: 24, len: 7 },
//     { code: 88, len: 7 },
//     { code: 56, len: 7 },
//     { code: 120, len: 7 },
//     { code: 4, len: 7 },
//     { code: 68, len: 7 },
//     { code: 36, len: 7 },
//     { code: 100, len: 7 },
//     { code: 20, len: 7 },
//     { code: 84, len: 7 },
//     { code: 52, len: 7 },
//     { code: 116, len: 7 },
//     { code: 3, len: 8 },
//     { code: 131, len: 8 },
//     { code: 67, len: 8 },
//     { code: 195, len: 8 },
//     { code: 35, len: 8 },
//     { code: 163, len: 8 },
//   ],
//   freqcache: [],
//   bit_count: [],
// }

// ///|
// let fixed_offset_encoding : HuffmanEncoder = {
//   codes: [
//     { code: 0, len: 5 },
//     { code: 16, len: 5 },
//     { code: 8, len: 5 },
//     { code: 24, len: 5 },
//     { code: 4, len: 5 },
//     { code: 20, len: 5 },
//     { code: 12, len: 5 },
//     { code: 28, len: 5 },
//     { code: 2, len: 5 },
//     { code: 18, len: 5 },
//     { code: 10, len: 5 },
//     { code: 26, len: 5 },
//     { code: 6, len: 5 },
//     { code: 22, len: 5 },
//     { code: 14, len: 5 },
//     { code: 30, len: 5 },
//     { code: 1, len: 5 },
//     { code: 17, len: 5 },
//     { code: 9, len: 5 },
//     { code: 25, len: 5 },
//     { code: 5, len: 5 },
//     { code: 21, len: 5 },
//     { code: 13, len: 5 },
//     { code: 29, len: 5 },
//     { code: 3, len: 5 },
//     { code: 19, len: 5 },
//     { code: 11, len: 5 },
//     { code: 27, len: 5 },
//     { code: 7, len: 5 },
//     { code: 23, len: 5 },
//   ],
//   freqcache: [],
//   bit_count: [],
// }

///|
let huff_offset : HuffmanEncoder = {
  codes: [
    { code: 0, len: 1 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
    { code: 0, len: 0 },
  ],
  freqcache: [],
  bit_count: [],
}
