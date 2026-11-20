///|
#derive(ToJson)
pub(all) struct TileCounts {
  row : Int32
  column : Int32
  row_start : Int32
  column_start : Int32
  height : Int32
  width : Int32
  counts : ChangeCounts
}

///|
/// Zero-based starts refer to the common window; row/column labels are one-based.
/// Integer partition boundaries retain the remainder in uneven windows.
pub fn tile_counts(
  audit : Audit,
  rows~ : Int32 = 2,
  columns~ : Int32 = 2,
) -> Array[TileCounts] raise AuditError {
  let size = complete_class_grid(audit)
  if rows < 1 || columns < 1 || rows > audit.height || columns > audit.width {
    raise Invalid("tile rows and columns must fit the common window")
  }
  let tiles = []
  let totals = Array::make(4, 0)
  for row in 0..<rows {
    let row_start = row * audit.height / rows
    let row_end = (row + 1) * audit.height / rows
    for column in 0..<columns {
      let column_start = column * audit.width / columns
      let column_end = (column + 1) * audit.width / columns
      let counts = Array::make(4, 0)
      for y in row_start..<row_end {
        for x in column_start..<column_end {
          let code = audit.classes[y * audit.width + x]
          let slot = class_slot(code)
          counts[slot] += 1
          totals[slot] += 1
        }
      }
      tiles.push({
        row: row + 1,
        column: column + 1,
        row_start,
        column_start,
        height: row_end - row_start,
        width: column_end - column_start,
        counts: {
          excluded: counts[0],
          loss: counts[1],
          stable: counts[2],
          gain: counts[3],
          valid: counts[1] + counts[2] + counts[3],
        },
      })
    }
  }
  check_class_totals(audit, size, totals)
  tiles
}

///|
fn complete_class_grid(audit : Audit) -> Int32 raise AuditError {
  if audit.width < 1 ||
    audit.height < 1 ||
    audit.width > 2048 ||
    audit.height > 2048 {
    raise Invalid(
      "classification grid must be between 1 and 2048 pixels per side",
    )
  }
  let size = audit.width * audit.height
  if audit.classes.length() != size {
    raise Invalid("analysis requires the complete classification grid")
  }
  size
}

///|
fn class_slot(code : Int32) -> Int32 raise AuditError {
  if code < -2 || code > 1 {
    raise Invalid("classification grid contains an unsupported class")
  }
  code + 2
}

///|
fn check_class_totals(
  audit : Audit,
  size : Int32,
  totals : Array[Int32],
) -> Unit raise AuditError {
  if audit.overlap != size ||
    [audit.excluded, audit.loss, audit.stable, audit.gain, audit.valid] !=
    [
      totals[0],
      totals[1],
      totals[2],
      totals[3],
      totals[1] + totals[2] + totals[3],
    ] {
    raise Invalid("classification grid disagrees with whole-window counts")
  }
}
