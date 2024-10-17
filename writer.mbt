struct Writer {
  d : Compressor
  // dict : Bytes
}

/// `Writer::new` returns a new [@flate.IOWriteCloser] compressing data at the "BestSpeed" level.
/// It writes its (compressed) data to the provided `buf`.
pub fn Writer::new(buf : IOWriter) -> Writer {
  let d = Compressor::new(buf)
  // let dict = Bytes::new(0)
  // { d, dict }
  { d, }
}

/// `write` writes the provided data to the flate Writer.
pub fn write(self : Writer, data : ArrayView[Byte]) -> (Int, Error?) {
  let data = Array::from_iter(data.iter()) // unfortunate copy
  self.d.write(Slice::new(data))
}

/// `close` closes the input to the flate Writer.
/// After closing the Writer, the compressed data can be read
/// from the `IOWriter` provided to `new`.
pub fn close(self : Writer) -> Unit!Error {
  self.d.close!()
}
