/// This file is based on the Go implementation found here:
/// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/token.go
/// which has the copyright notice:
/// Copyright 2009 The Go Authors. All rights reserved.
/// Use of this source code is governed by a BSD-style
/// license that can be found in the LICENSE file.

// 2 bits:   type   0 = literal  1=EOF  2=Match   3=Unused
// 8 bits:   xlength = length - MIN_MATCH_LENGTH
// 22 bits   xoffset = offset - MIN_OFFSET_SIZE, or literal
let length_shift = 22

let offset_mask : UInt = (1U << length_shift) - 1

// let type_mask : Int = 3 << 30

let literal_type : UInt = 0U << 30

let match_type : UInt = 1U << 30

// The length code for length X (MIN_MATCH_LENGTH <= X <= MAX_MATCH_LENGTH)
// is length_codes[length - MIN_MATCH_LENGTH]
let length_codes : Array[Int] = [ // Array[UInt] // Values are always used for indexing, so make them Int
  0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 12, 12, 13, 13, 13,
  13, 14, 14, 14, 14, 15, 15, 15, 15, 16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17,
  17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19,
  19, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 21, 21, 21,
  21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22,
  22, 22, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23,
  23, 23, 23, 23, 23, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
  24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25,
  25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25,
  25, 25, 25, 25, 25, 25, 25, 25, 25, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
  26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
  26, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
  27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 28,
]

let offset_codes : Array[Int] = [ // Array[UInt] // Values are always used for indexing, so make them Int
  0, 1, 2, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9,
  9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
  11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12,
  12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
  12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
  13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
  14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15,
]

type Token UInt derive(Show)

// Convert a literal into a literal token.
fn literal_token(literal : UInt) -> Token {
  literal_type + literal
}

// Convert a < xlength, xoffset > pair into a match token.
fn match_token(xlength : UInt, xoffset : UInt) -> Token {
  match_type + (xlength << length_shift) + xoffset
}

// Returns the literal of a literal token.
fn literal(self : Token) -> UInt {
  let v = self._ - literal_type
  gmldbg("GML: token.go: t(\{self._}).literal=\{v}")
  v
}

// Returns the extra offset of a match token.
fn offset(self : Token) -> UInt {
  let v = self._ & offset_mask
  gmldbg("GML: token.go: t(\{self._}).offset=\{v}")
  v
}

test "offset behaves correctly" {
  let token = Token(2143289471U)
  let got = token.offset()
  inspect!(got, content="127")
}

fn length(self : Token) -> UInt {
  let v = (self._ - match_type) >> length_shift
  gmldbg("GML: token.go: t(\{self._}).length=\{v}")
  v
}

fn length_code(len : UInt) -> Int { // -> UInt // Values are always used for indexing, so make them Int
  gmldbg(
    "GML: token.go: lengthCode(\{len})=\{length_codes[len.reinterpret_as_int()]}",
  )
  length_codes[len.reinterpret_as_int()]
}

fn offset_code(off : UInt) -> Int { // -> UInt // Values are always used for indexing, so make them Int
  if off < offset_codes.length().reinterpret_as_uint() {
    let idx = off.reinterpret_as_int()
    gmldbg("GML: token.go: offsetCode(\{off}) = \{offset_codes[idx]} A")
    return offset_codes[idx]
  }
  if (off >> 7) < offset_codes.length().reinterpret_as_uint() {
    let idx = (off >> 7).reinterpret_as_int()
    gmldbg("GML: token.go: offsetCode(\{off}) = \{offset_codes[idx] + 14} B")
    return offset_codes[idx] + 14
  }
  let idx = (off >> 14).reinterpret_as_int()
  gmldbg("GML: token.go: offsetCode(\{off}) = \{offset_codes[idx] + 28} C")
  offset_codes[idx] + 28
}
