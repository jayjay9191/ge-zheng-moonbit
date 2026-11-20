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
  // Public Audit values retain compare's size bounds before Int32 products.
  if audit.width < 1 ||
    audit.height < 1 ||
    audit.width > 2048 ||
    audit.height > 2048 {
    raise Invalid(
      "tile statistics require a window between 1 and 2048 pixels per side",
    )
  }
  if rows < 1 || columns < 1 || rows > audit.height || columns > audit.width {
    raise Invalid("tile rows and columns must fit the common window")
  }
  if audit.classes.length() != audit.width * audit.height {
    raise Invalid("tile statistics require the complete classification grid")
  }
  let tiles = []
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
          if code < -2 || code > 1 {
            raise Invalid("classification grid contains an unsupported class")
          }
          counts[code + 2] += 1
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
  tiles
}
