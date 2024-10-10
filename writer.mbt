struct Writer {
  d : Compressor
  // dict : Bytes
}

pub fn Writer::new(buf : Buffer) -> Writer {
    println("GML: deflate.go: NewWriter(w io.Writer, level int) (*Writer, error) {")
  let d = Compressor::new(buf)
  // let dict = Bytes::new(0)
  // { d, dict }
  { d, }
}

pub fn write(self : Writer, data : Bytes) -> Int!Error {
  println("GML: deflate.go: w *Writer) Write(data []byte) (n int, err error) {")
  self.d.write!(data)
}

pub fn close(self : Writer) -> Unit!Error {
  println("GML: deflate.go: w *Writer) Close() error {")
  self.d.close!()
}
