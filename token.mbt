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

// let offset_mask : Int = 1 << (length_shift - 1)

// let type_mask : Int = 3 << 30

let literal_type : UInt = 0U << 30

let match_type : UInt = 1U << 30

typealias Token = UInt

// Convert a literal into a literal token.
fn literal_token(literal : UInt) -> Token {
  literal_type + literal
}

// Convert a < xlength, xoffset > pair into a match token.
fn match_token(xlength : UInt, xoffset : UInt) -> Token {
  match_type + (xlength << length_shift) + xoffset
}
