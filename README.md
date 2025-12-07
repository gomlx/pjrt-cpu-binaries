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

## Release Version Numbers

The releases will take the form of `v<A>.<B>.<C>`, where `<A>` are the `PJRT_API_MAJOR` and `PJRT_API_MINOR` constants, 
as defined in [XLA sources](https://github.com/openxla/xla/blob/main/xla/pjrt/c/pjrt_c_api.h#L92).
And `<C>` is an increasing number added by `pjrt-cpu-binaries`.

E.g.: `v0.83.1` refers to a build based on XLA's PJRT version **0.83**, and `pjrt-cpu-binaries` build number 1.

## Building new PJRT CPU

1. Update the github.com/openxla/xla commit hash number in the file `XLA_COMMIT_HASH.txt`
2. Bump the number in `BUILDER_VERSION.txt`
3. Push, run the GitHub actions: they will generate one asset each, with the file `pjrt_cpu_<os_cpu>.tar.gz`.
   Download those.
4. Create a new release, matching the version of the file inside the PJRT `tar.gz` files (a mix of XLA version with the number in `BUILDER_VERSION.txt`).
   Attach the binary releases.
   
For now the `AmazonLinux` build seem to run out of disk space in the GitHub action, so instead there is a
`Dockerfile.amazonlinux2023_amd64` that will generate the file `pjrt_cpu_amazonlinux_amd64.tar.gz`.
It is also faster to run locally (if you have a good desktop) than in the GitHub cloud.
To do that use:

```bash
docker build -f Dockerfile --target export --output type=local,dest=. .
```
