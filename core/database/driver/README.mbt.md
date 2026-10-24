# driver

Low-level database driver traits (`Driver`, `Connector`, `Conn`, `Stmt`, `Tx`, `Rows`) and wire-value representation (`Value`, `ExecResult`) for `KKKIIO/moondark/database`.

## Quick Start

Application code uses `KKKIIO/moondark/database` directly; only backend implementations (such as `moondark_sqlite/database` and `moondark_postgresql/database`) implement `@driver` traits:

```mbt check
///|
struct DummyTx {}

///|
impl @driver.Tx for DummyTx with fn commit(_self) {
  ()
}

///|
impl @driver.Tx for DummyTx with fn rollback(_self) {
  ()
}

///|
test {
  let tx : &@driver.Tx = DummyTx::{ }
  ignore(tx)
}
```
