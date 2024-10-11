// -*- compile-command: "moon test --target js > got.txt"; -*-

// This file is based on the Go implementation found here:
// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/deflate.go
// which has the copyright notice:
// Copyright 2016 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

struct Compressor {
  // compressionLevel

  w : HuffmanBitWriter
  // bulkHasher func([]byte, []uint32)

  // compression algorithm
  // fill      func(*compressor, []byte) int // copy data to window
  // step      func(*compressor)             // process window
  best_speed : DeflateFast // Encoder for best_speed

  // Input hash chains
  // hashHead[hashValue] contains the largest inputIndex with the specified hash value
  // If hashHead[hashValue] is within the current window, then
  // hashPrev[hashHead[hashValue] & windowMask] contains the previous index
  // with the same hash value.
  // chainHead  int
  // hashHead   [hashSize]uint32
  // hashPrev   [windowSize]uint32
  // hashOffset int

  // input window: unprocessed data is window[index:window_end]
  // mut index : Int
  window : Slice[Byte]
  mut window_end : Int
  // blockStart    int  // window index where current tokens start
  // byteAvailable bool // if true, still need to process window[index-1].

  mut sync : Bool // requesting flush

  // queued output tokens
  mut tokens : Array[Token]

  // deflate state
  // length         int
  // offset         int
  // maxInsertIndex int
  mut err : Error?

  // hashMatch must be able to contain hashes for the maximum match length.
  // hashMatch [maxMatchLength - 1]uint32
} derive(Show)

fn Compressor::new(buf : Buffer) -> Compressor {
  // d.compressionLevel = levels[level]
  let w = HuffmanBitWriter::new(buf)
  {
    w,
    // index: 0,
    window: Slice::new(Array::make(max_store_block_size, b'\x00')),
    window_end: 0,
    sync: false,
    // fill:  (*compressor).fillStore,
    // step:  (*compressor).encSpeed,
    best_speed: DeflateFast::new(),
    tokens: Array::make(max_store_block_size, 0),
    err: None,
  }
}

type! WriterClosedError  derive(Show)

fn close(self : Compressor) -> Unit!Error {
  match self.err {
    Some(WriterClosedError) => return
    Some(err) => raise err
    _ => ()
  }
  self.sync = true
  self.enc_speed()
  match self.err {
    Some(err) => raise err
    _ => ()
  }
  self.w.write_stored_header(0, true)
  match self.w.err {
    Some(err) => raise err
    _ => ()
  }
  self.w.flush()
  match self.w.err {
    Some(err) => raise err
    _ => ()
  }
  self.err = Some(WriterClosedError)
}

fn write_stored_block(self : Compressor, buf : Slice[Byte]) -> Error? {
  self.w.write_stored_header(buf.length(), false)
  if not(self.w.err.is_empty()) {
    return self.w.err
  }
  self.w.write_bytes(buf)
  return self.w.err
}

fn fill_store(self : Compressor, b : Slice[Byte]) -> Int {
  let n = minimum(self.window.length() - self.window_end, b.length())
  // let n = copy(self.window[self.window_end:], b)
  for i in 0..<n {
    self.window[self.window_end + i] = b[i]
  }
  self.window_end += n
  n
}

// encSpeed will compress and store the currently added data,
// if enough has been accumulated or we at the end of the stream.
// Any error that occurred will be in self.err
fn enc_speed(self : Compressor) -> Unit {
  // We only compress if we have max_store_block_size.
  if self.window_end < max_store_block_size {
    if not(self.sync) {
      return
    }

    // Handle small sizes.
    if self.window_end < 128 {
      if self.window_end == 0 {
        return
      }
      if self.window_end <= 16 {
        self.err = self.write_stored_block(self.window[:self.window_end])
      } else {
        self.w.write_block_huff(false, self.window[:self.window_end])
        self.err = self.w.err
      }
      self.window_end = 0
      self.best_speed.reset()
      return
    }
  }
  // Encode the block.
  // self.tokens = self.best_speed.encode([], self.window[:self.window_end])
  self.tokens = self.best_speed.encode([], self.window[:self.window_end])

  // If we removed less than 1/16th, Huffman compress the block.
  if self.tokens.length() > self.window_end - (self.window_end >> 4) {
    self.w.write_block_huff(false, self.window[:self.window_end])
  } else {
    // self.w.write_block_dynamic(self.tokens, false, self.window[:self.window_end])
    self.w.write_block_dynamic(
      self.tokens,
      false,
      self.window[:self.window_end],
    )
  }
  self.err = self.w.err
  self.window_end = 0
}

pub fn write(self : Compressor, b : Bytes) -> Int!Error {
  if not(self.err.is_empty()) {
    raise self.err.unwrap()
  }
  let mut b : Slice[Byte] = Slice::new(Array::from_iter(b.iter()))
  let n = b.length()
  while b.length() > 0 {
    self.enc_speed()
    b = b[self.fill_store(b):]
    if not(self.err.is_empty()) {
      raise self.err.unwrap()
    }
  }
  return n
}
