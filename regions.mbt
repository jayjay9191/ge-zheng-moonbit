///|
#derive(ToJson)
pub(all) struct RegionStats {
  regions : Int32
  pixels : Int32
  isolated_pixels : Int32
  largest_pixels : Int32
  largest_area_m2 : Int64
}

///|
#derive(ToJson)
pub(all) struct ChangeRegions {
  connectivity : Int32
  gain : RegionStats
  loss : RegionStats
}

///|
/// Count contiguous gain and loss patches separately. Stable and masked cells never join patches.
pub fn change_regions(
  audit : Audit,
  connectivity~ : Int32 = 4,
) -> ChangeRegions raise AuditError {
  if connectivity != 4 && connectivity != 8 {
    raise Invalid("region connectivity must be 4 or 8")
  }
  if audit.cell != 30 {
    raise Invalid("region area requires 30 m pixels")
  }
  let size = complete_class_grid(audit)
  let seen = Array::make(size, false)
  let totals = Array::make(4, 0)
  let regions = Array::make(4, 0)
  let isolated = Array::make(4, 0)
  let largest = Array::make(4, 0)
  let stack : Array[Int32] = []
  let steps = [
    (0, -1),
    (0, 1),
    (-1, 0),
    (1, 0),
    (-1, -1),
    (-1, 1),
    (1, -1),
    (1, 1),
  ]
  for i in 0..<size {
    let code = audit.classes[i]
    let slot = class_slot(code)
    totals[slot] += 1
    if seen[i] || (code != 1 && code != -1) {
      continue
    }
    regions[slot] += 1
    let mut pixels = 0
    stack.push(i)
    seen[i] = true
    while stack.pop() is Some(index) {
      pixels += 1
      for j in 0..<connectivity {
        let (dr, dc) = steps[j]
        let row = index / audit.width + dr
        let col = index % audit.width + dc
        if row < 0 || row >= audit.height || col < 0 || col >= audit.width {
          continue
        }
        let neighbor = row * audit.width + col
        if !seen[neighbor] && audit.classes[neighbor] == code {
          seen[neighbor] = true
          stack.push(neighbor)
        }
      }
    }
    if pixels == 1 {
      isolated[slot] += 1
    }
    if pixels > largest[slot] {
      largest[slot] = pixels
    }
  }
  check_class_totals(audit, size, totals)
  let stats = slot => {
    regions: regions[slot],
    pixels: totals[slot],
    isolated_pixels: isolated[slot],
    largest_pixels: largest[slot],
    largest_area_m2: largest[slot].to_int64() * 900L,
  }
  { connectivity, gain: stats(3), loss: stats(1), }
}
