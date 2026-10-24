// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }
import {
  "moonbitlang/async@0.22.5",
  "moonbitlang/moonback@0.8.9",
  "moonbitlang/x@0.5.5",
  "tonyfettes/xlog@0.4.2",
}

preferred_target = "native"

name = "KKKIIO/moondark"

version = "0.1.1"

readme = "README.mbt.md"

repository = "https://github.com/kkkiio/moondark"

license = "Apache-2.0"

keywords = [ "web", "backend", "framework", "http", "server" ]

description = "A Django-inspired backend framework for MoonBit, built on moonback"
