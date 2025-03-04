# gmlewis/flate
[![check](https://github.com/gmlewis/moonbit-flate/actions/workflows/check.yml/badge.svg)](https://github.com/gmlewis/moonbit-flate/actions/workflows/check.yml)

This is a simplified flate compression algorithm based on Go's implementation:
https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/deflatefast.go
which has the copyright notice:

```
// Copyright 2016 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
```

## Status

The code has been updated to support compiler:

```bash
$ moon version --all
moon 0.1.20250304 (6af90d7 2025-03-04) ~/.moon/bin/moon
moonc v0.1.20250304+fdfcb3f1f ~/.moon/bin/moonc
moonrun 0.1.20250304 (6af90d7 2025-03-04) ~/.moon/bin/moonrun
```

Use `moonup` to manage `moon` compiler versions:
https://github.com/chawyehsu/moonup
