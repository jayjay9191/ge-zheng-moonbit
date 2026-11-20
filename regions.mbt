///|
#derive(ToJson)
pub(all) struct RegionStats {
  regions : Int32
  pixels : Int32
  isolated_pixels : Int32
  discarded_regions : Int32
  discarded_pixels : Int32
  water_excluded_pixels : Int32
  largest_pixels : Int32
  largest_area_m2 : Int64
}

///|
#derive(ToJson)
pub(all) struct ChangeRegions {
  connectivity : Int32
  min_pixels : Int32
  land_only : Bool
  gain : RegionStats
  loss : RegionStats
}

///|
/// Count contiguous gain and loss patches separately. Stable and masked cells never join patches.
pub fn change_regions(
  audit : Audit,
  connectivity~ : Int32 = 4,
  min_pixels~ : Int32 = 1,
  land_only~ : Bool = false,
) -> ChangeRegions raise AuditError {
  if connectivity != 4 && connectivity != 8 {
    raise Invalid("region connectivity must be 4 or 8")
  }
  if min_pixels < 1 {
    raise Invalid("minimum region size must be at least one pixel")
  }
  if audit.cell != 30 {
    raise Invalid("region area requires 30 m pixels")
  }
  let size = complete_class_grid(audit)
  if land_only && audit.water_code.length() != size {
    raise Invalid("land-only regions require complete water flags")
  }
  let wet = Array::make(4, 0)
  let seen = Array::make(size, false)
  let totals = Array::make(4, 0)
  let regions = Array::make(4, 0)
  let isolated = Array::make(4, 0)
  let small_regions = Array::make(4, 0)
  let small_pixels = Array::make(4, 0)
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
    if land_only {
      let water = audit.water_code[i]
      if (code == -2 && water != -1) || (code != -2 && (water < 0 || water > 3)) {
        raise Invalid("water flags disagree with the classification grid")
      }
      if water > 0 {
        wet[slot] += 1
        continue
      }
    }
    if seen[i] || (code != 1 && code != -1) {
      continue
    }
    let mut pixels = 0
    stack.push(i)
    seen[i] = true
    while stack.pop() is Some(index) {
      pixels += 1
      let base_row = index / audit.width
      let base_col = index % audit.width
      for j in 0..<connectivity {
        let (dr, dc) = steps[j]
        let row = base_row + dr
        let col = base_col + dc
        if row < 0 || row >= audit.height || col < 0 || col >= audit.width {
          continue
        }
        let neighbor = row * audit.width + col
        if !seen[neighbor] &&
          audit.classes[neighbor] == code &&
          (!land_only || audit.water_code[neighbor] == 0) {
          seen[neighbor] = true
          stack.push(neighbor)
        }
      }
    }
    if pixels < min_pixels {
      small_regions[slot] += 1
      small_pixels[slot] += pixels
      continue
    }
    regions[slot] += 1
    if pixels == 1 {
      isolated[slot] += 1
    }
    if pixels > largest[slot] {
      largest[slot] = pixels
    }
  }
  check_class_totals(audit, size, totals)
  if land_only &&
    [
      audit.both_nonwater_loss,
      audit.both_nonwater_gain,
      audit.both_nonwater_valid,
    ] !=
    [
      totals[1] - wet[1],
      totals[3] - wet[3],
      audit.valid - wet[1] - wet[2] - wet[3],
    ] {
    raise Invalid("water flags disagree with land-only counts")
  }
  let stats = slot => {
    regions: regions[slot],
    pixels: totals[slot] - small_pixels[slot] - wet[slot],
    isolated_pixels: isolated[slot],
    discarded_regions: small_regions[slot],
    discarded_pixels: small_pixels[slot],
    water_excluded_pixels: wet[slot],
    largest_pixels: largest[slot],
    largest_area_m2: largest[slot].to_int64() * 900L,
  }
  { connectivity, min_pixels, land_only, gain: stats(3), loss: stats(1), }
}
