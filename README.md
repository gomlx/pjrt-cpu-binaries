# pjrt-cpu-binaries
[XLA](https://openxla.org/) build actions for PJRT CPU and binary releases for [**GoMLX**](https://github.com/gomlx/gomlx) and [go-xla](https://github.com/gomlx/go-xla).

These are kept on a separate repository to decouple the versioning from `go-xla`.

## Glossary:

* **GoMLX**: a machine learning framework for Go that uses XLA as its main backend for performatic "number crunching".
* **XLA**: or OpenXLA, is a Just-In-Time compiler of computations with support for various hardwares (CPU, various GPU, TPU, etc).
  It uses an "intermediary representation" (a textual language, not very human friendly) called _StableHLO_ to describe teh computation to be built.
  It's an accelerated "number crunching" engine.
* **PJRT**: the name for an XLA "plugin" that implements it for one hardware. To use XLA, you need the PJRT plugin installed for the hardware you are going to use.
  It's a C/C++ dynamic library.
* **`go-xla`**: a Go library to (1) Generate _StableHLO_; (2) Dynamically load and a wrap PJRT plugins APIs to a Go API.
