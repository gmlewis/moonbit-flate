struct Writer {
  d : Compressor
  // dict : Bytes
}

pub fn Writer::new(buf : Buffer) -> Writer {
  let d = Compressor::new(buf)
  // let dict = Bytes::new(0)
  // { d, dict }
  { d, }
}

pub fn write(self : Writer, data : Bytes) -> Int!Error {
  self.d.write!(data)
}
