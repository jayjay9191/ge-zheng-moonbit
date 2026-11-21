///|
#derive(ToJson)
pub(all) struct NdviTransitions {
  cut_points : Array[Double]
  counts : Array[Array[Int32]]
  valid : Int32
  excluded : Int32
  water_excluded : Int32
  qa_screened : Bool
  land_only : Bool
  valid_fraction : Double
}

///|
pub extend NdviTransitions with @json.ToJson::{to_json}

///|
fn ndvi_band(value : Double, cuts : Array[Double]) -> Int32 {
  let mut index = 0
  while index < cuts.length() && value >= cuts[index] {
    index += 1
  }
  index
}

///|
fn validate_ndvi_cut_points(
  cut_points : Array[Double],
) -> Unit raise AuditError {
  if cut_points.is_empty() || cut_points.length() > 16 {
    raise Invalid("NDVI transitions require 1 to 16 cut points")
  }
  let mut previous = -1.0
  for cut in cut_points {
    if !(cut > previous && cut < 1.0) {
      raise Invalid("NDVI cut points must strictly increase between -1 and 1")
    }
    previous = cut
  }
}

///|
fn visit_ndvi_pairs(
  before : Chip,
  after : Chip,
  screen_qa : Bool,
  land_only : Bool,
  min_coverage : Double,
  visit : (Int32, Int32, (Int32, Int32), Double, Double) -> Unit,
) -> (Int32, Int32, Int32, Double) raise AuditError {
  validate_coverage(min_coverage)
  let { dx, dy, row0, row1, col0, col1, } = common_window(before, after)
  let mut valid = 0
  let mut water_excluded = 0
  for row in row0..<row1 {
    for col in col0..<col1 {
      let ia = row * before.width + col
      let ib = (row - dy) * after.width + col - dx
      let (reason_a, a) = pixel(before, ia, screen_qa)
      let (reason_b, b) = pixel(after, ib, screen_qa)
      if reason_a != 0 || reason_b != 0 {
        continue
      }
      if land_only && water_state(before, ia, after, ib) != 0 {
        water_excluded += 1
        continue
      }
      visit(row, col, (ia, ib), a, b)
      valid += 1
    }
  }
  let overlap = (row1 - row0) * (col1 - col0)
  let valid_fraction = shared_coverage(valid, overlap, min_coverage)
  (overlap, valid, water_excluded, valid_fraction)
}

///|
/// Count before-band (row) to after-band (column) transitions on common valid pixels.
/// Cut points are strictly increasing in (-1, 1); equality enters the higher band.
pub fn ndvi_transitions(
  before : Chip,
  after : Chip,
  cut_points : Array[Double],
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> NdviTransitions raise AuditError {
  validate_ndvi_cut_points(cut_points)
  let bands = cut_points.length() + 1
  let counts = Array::makei(bands, _ => Array::make(bands, 0))
  let (overlap, valid, water_excluded, valid_fraction) = visit_ndvi_pairs(
    before,
    after,
    screen_qa,
    land_only,
    min_coverage,
    (_, _, _, a, b) => {
      counts[ndvi_band(a, cut_points)][ndvi_band(b, cut_points)] += 1
    },
  )
  {
    cut_points: cut_points.copy(),
    counts,
    valid,
    excluded: overlap - valid,
    water_excluded,
    qa_screened: screen_qa,
    land_only,
    valid_fraction,
  }
}

///|
#derive(ToJson)
pub(all) struct NdviBandChange {
  retained : Int32
  gained : Int32
  lost : Int32
  net : Int32
  exchange : Int32
}

///|
pub extend NdviBandChange with @json.ToJson::{to_json}

///|
#derive(ToJson)
pub(all) struct NdviCutCrossing {
  threshold : Double
  up : Int32
  down : Int32
  net : Int32
}

///|
pub extend NdviCutCrossing with @json.ToJson::{to_json}

///|
#derive(ToJson)
pub(all) struct NdviTransitionSummary {
  before_counts : Array[Int32]
  after_counts : Array[Int32]
  lower : Int32
  same : Int32
  higher : Int32
  quantity_disagreement : Int32
  allocation_disagreement : Int32
  bands : Array[NdviBandChange]
  cut_crossings : Array[NdviCutCrossing]
}

///|
pub extend NdviTransitionSummary with @json.ToJson::{to_json}

///|
/// Count movements between NDVI bands, over the same common valid pixels.
pub fn summarize_ndvi_transitions(
  matrix : NdviTransitions,
) -> NdviTransitionSummary raise AuditError {
  validate_ndvi_cut_points(matrix.cut_points)
  let bands = matrix.cut_points.length() + 1
  if matrix.counts.length() != bands ||
    matrix.valid < 1 ||
    matrix.valid > 2048 * 2048 ||
    matrix.excluded < 0 ||
    matrix.excluded > 2048 * 2048 - matrix.valid ||
    matrix.water_excluded < 0 ||
    matrix.water_excluded > matrix.excluded {
    raise Invalid("NDVI transition dimensions or totals are invalid")
  }
  let before_counts = Array::make(bands, 0)
  let after_counts = Array::make(bands, 0)
  // Each off-diagonal cell contributes to the contiguous cuts between the bands.
  let up_delta = Array::make(bands, 0)
  let down_delta = Array::make(bands, 0)
  let mut total = 0
  let mut lower = 0
  let mut same = 0
  let mut higher = 0
  for row in 0..<bands {
    let cells = matrix.counts[row]
    if cells.length() != bands {
      raise Invalid("NDVI transition matrix must be square")
    }
    for column in 0..<bands {
      let count = cells[column]
      if count < 0 || count > matrix.valid - total {
        raise Invalid(
          "NDVI transition count disagrees with the valid pixel total",
        )
      }
      total += count
      before_counts[row] += count
      after_counts[column] += count
      if column < row {
        lower += count
        down_delta[column] += count
        down_delta[row] -= count
      } else if column == row {
        same += count
      } else {
        higher += count
        up_delta[row] += count
        up_delta[column] -= count
      }
    }
  }
  if total != matrix.valid {
    raise Invalid("NDVI transition count disagrees with the valid pixel total")
  }
  let details = Array::makei(bands, i => {
    let retained = matrix.counts[i][i]
    let gained = after_counts[i] - retained
    let lost = before_counts[i] - retained
    let exchange = if gained < lost { gained } else { lost }
    { retained, gained, lost, net: gained - lost, exchange, }
  })
  let cut_crossings : Array[NdviCutCrossing] = []
  let mut up = 0
  let mut down = 0
  for i, threshold in matrix.cut_points {
    up += up_delta[i]
    down += down_delta[i]
    cut_crossings.push({ threshold, up, down, net: up - down, })
  }
  // Half the L1 distance of equal-total marginals equals the sum of positive offsets.
  let quantity_disagreement = details.fold(init=0, (sum, band) => {
    sum + (if band.net > 0 { band.net } else { 0 })
  })
  {
    before_counts,
    after_counts,
    lower,
    same,
    higher,
    quantity_disagreement,
    allocation_disagreement: lower + higher - quantity_disagreement,
    bands: details,
    cut_crossings,
  }
}

///|
#derive(ToJson)
pub(all) struct NdviCountBounds {
  guaranteed : Int32
  observed : Int32
  possible : Int32
}

///|
#derive(ToJson)
pub(all) struct NdviNetBounds {
  minimum : Int32
  observed : Int32
  maximum : Int32
}

///|
#derive(ToJson)
pub(all) struct NdviNeutralization {
  single_step_pairs : Int32
  double_step_pairs : Int32
  minimum_changed_pairs : Int32?
}

///|
#derive(ToJson)
pub(all) struct NdviThresholdBounds {
  threshold : Double
  margin : Double
  up : NdviCountBounds
  down : NdviCountBounds
  net : NdviNetBounds
  neutralization : NdviNeutralization
  valid : Int32
  excluded : Int32
  water_excluded : Int32
  qa_screened : Bool
  land_only : Bool
  valid_fraction : Double
}

///|
pub extend NdviThresholdBounds with @json.ToJson::{to_json}

///|
/// Count guaranteed, observed, and possible crossings under independent bounded
/// perturbations of each measured NDVI. Equality belongs to the upper side.
pub fn ndvi_threshold_bounds(
  before : Chip,
  after : Chip,
  threshold : Double,
  margin : Double,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> NdviThresholdBounds raise AuditError {
  let lower = threshold - margin
  let upper = threshold + margin
  if !(margin >= 0.0 && lower > -1.0 && upper < 1.0) {
    raise Invalid(
      "NDVI margin must be nonnegative, with both endpoints inside (-1, 1)",
    )
  }
  let cuts = if margin == 0.0 { [threshold] } else { [lower, threshold, upper] }
  let matrix = ndvi_transitions(
    before,
    after,
    cuts,
    screen_qa~,
    min_coverage~,
    land_only~,
  )
  let nominal = cuts.length() / 2
  let last_band = cuts.length()
  let mut observed_up = 0
  let mut observed_down = 0
  let mut possible_up = 0
  let mut possible_down = 0
  let mut double_increase = 0
  let mut double_decrease = 0
  for i in 0..<matrix.counts.length() {
    for j in 0..<matrix.counts.length() {
      let count = matrix.counts[i][j]
      if i <= nominal && j > nominal {
        observed_up += count
      } else if i > nominal && j <= nominal {
        observed_down += count
      }
      if i < last_band && j > 0 {
        possible_up += count
      }
      if j < last_band && i > 0 {
        possible_down += count
      }
      if i > nominal && i < last_band && j > 0 && j <= nominal {
        double_increase += count
      }
      if j > nominal && j < last_band && i > 0 && i <= nominal {
        double_decrease += count
      }
    }
  }
  let guaranteed_up = matrix.counts[0][last_band]
  let guaranteed_down = matrix.counts[last_band][0]
  let net : NdviNetBounds = {
    minimum: guaranteed_up - possible_down,
    observed: observed_up - observed_down,
    maximum: possible_up - guaranteed_down,
  }
  let (needed, capacity, double_step_pairs) = if net.observed < 0 {
    (-net.observed, net.maximum - net.observed, double_increase)
  } else if net.observed > 0 {
    (net.observed, net.observed - net.minimum, double_decrease)
  } else {
    (0, 0, 0)
  }
  // A two-step pair can contribute either one or two steps. Use it first.
  let half = (needed + 1) / 2
  let minimum_changed_pairs = if needed > capacity {
    None
  } else if half <= double_step_pairs {
    Some(half)
  } else {
    Some(needed - double_step_pairs)
  }
  {
    threshold,
    margin,
    up: {
      guaranteed: guaranteed_up,
      observed: observed_up,
      possible: possible_up,
    },
    down: {
      guaranteed: guaranteed_down,
      observed: observed_down,
      possible: possible_down,
    },
    net,
    neutralization: {
      single_step_pairs: capacity - 2 * double_step_pairs,
      double_step_pairs,
      minimum_changed_pairs,
    },
    valid: matrix.valid,
    excluded: matrix.excluded,
    water_excluded: matrix.water_excluded,
    qa_screened: matrix.qa_screened,
    land_only: matrix.land_only,
    valid_fraction: matrix.valid_fraction,
  }
}

///|
#derive(ToJson)
pub(all) struct NdviMarginRow {
  margin : Double
  net : NdviNetBounds
}

///|
#derive(ToJson)
pub(all) struct NdviMarginSweep {
  threshold : Double
  rows : Array[NdviMarginRow]
  first_inconclusive_margin : Double?
  valid : Int32
  excluded : Int32
  water_excluded : Int32
  qa_screened : Bool
  land_only : Bool
  valid_fraction : Double
}

///|
pub extend NdviMarginSweep with @json.ToJson::{to_json}

///|
/// Build one matrix for the cut and all tolerance endpoints, then reuse its marginal
/// counts. The reported first inconclusive margin is taken from the requested grid.
pub fn ndvi_margin_sweep(
  before : Chip,
  after : Chip,
  threshold : Double,
  margins : Array[Double],
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> NdviMarginSweep raise AuditError {
  if margins.is_empty() || margins.length() > 7 {
    raise Invalid("NDVI margin sweep requires 1 to 7 margins")
  }
  let mut previous = -1.0
  let lower_cuts : Array[Double] = []
  let upper_cuts : Array[Double] = []
  for margin in margins {
    if !(margin >= 0.0 && margin > previous) {
      raise Invalid(
        "NDVI sweep margins must strictly increase from zero or greater",
      )
    }
    if margin > 0.0 {
      lower_cuts.push(threshold - margin)
      upper_cuts.push(threshold + margin)
    }
    previous = margin
  }
  let center = lower_cuts.length()
  let cuts = lower_cuts.rev() + [threshold] + upper_cuts
  let matrix = ndvi_transitions(
    before,
    after,
    cuts,
    screen_qa~,
    min_coverage~,
    land_only~,
  )
  let summary = summarize_ndvi_transitions(matrix)
  let before_above = Array::make(cuts.length(), 0)
  let after_above = Array::make(cuts.length(), 0)
  let mut before_count = 0
  let mut after_count = 0
  for offset in 0..<cuts.length() {
    let i = cuts.length() - 1 - offset
    before_count += summary.before_counts[i + 1]
    after_count += summary.after_counts[i + 1]
    before_above[i] = before_count
    after_above[i] = after_count
  }
  let mut offset = 0
  let observed = after_above[center] - before_above[center]
  let rows : Array[NdviMarginRow] = margins.map(margin => {
    if margin > 0.0 {
      offset += 1
    }
    {
      margin,
      net: {
        minimum: after_above[center + offset] - before_above[center - offset],
        observed,
        maximum: after_above[center - offset] - before_above[center + offset],
      },
    }
  })
  {
    threshold,
    rows,
    first_inconclusive_margin: rows
    .iter()
    .find_first(row => row.net.minimum <= 0 && row.net.maximum >= 0)
    .map(row => row.margin),
    valid: matrix.valid,
    excluded: matrix.excluded,
    water_excluded: matrix.water_excluded,
    qa_screened: matrix.qa_screened,
    land_only: matrix.land_only,
    valid_fraction: matrix.valid_fraction,
  }
}

///|
#derive(ToJson)
pub(all) struct NdviCriticalMargin {
  threshold : Double
  observed_net : Int32
  margin_infimum : Double
  zero_possible_at_infimum : Bool
  valid : Int32
  excluded : Int32
  water_excluded : Int32
  qa_screened : Bool
  land_only : Bool
  valid_fraction : Double
}

///|
pub extend NdviCriticalMargin with @json.ToJson::{to_json}

///|
/// The break point for attaining zero net change under independent bounded perturbations.
/// A value at the threshold belongs to the upper band, so downward flips need a strict margin.
pub fn ndvi_critical_margin(
  before : Chip,
  after : Chip,
  threshold : Double,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> NdviCriticalMargin raise AuditError {
  validate_ndvi_cut_points([threshold])
  let mut observed_net = 0
  // ponytail: store two flip distances per valid pixel pair; selection can replace sorting if large rasters dominate.
  let increase : Array[(Double, Bool)] = []
  let decrease : Array[(Double, Bool)] = []
  let (overlap, valid, water_excluded, valid_fraction) = visit_ndvi_pairs(
    before,
    after,
    screen_qa,
    land_only,
    min_coverage,
    (_, _, _, a, b) => {
      if a >= threshold {
        observed_net -= 1
        increase.push((a - threshold, false))
      } else {
        decrease.push((threshold - a, true))
      }
      if b >= threshold {
        observed_net += 1
        decrease.push((b - threshold, false))
      } else {
        increase.push((threshold - b, true))
      }
    },
  )
  let (margin_infimum, zero_possible_at_infimum) = if observed_net == 0 {
    (0.0, true)
  } else {
    let events = if observed_net < 0 { increase } else { decrease }
    let needed = if observed_net < 0 { -observed_net } else { observed_net }
    events.sort_by(compare_flip_margins)
    events[needed - 1]
  }
  {
    threshold,
    observed_net,
    margin_infimum,
    zero_possible_at_infimum,
    valid,
    excluded: overlap - valid,
    water_excluded,
    qa_screened: screen_qa,
    land_only,
    valid_fraction,
  }
}

///|
#derive(ToJson, FromJson)
pub(all) enum NdviPairFlip {
  BeforeDate
  AfterDate
  BothDates
}

///|
#derive(ToJson, FromJson)
pub(all) struct NdviPairWitness {
  row : Int32
  column : Int32
  flip : NdviPairFlip
}

///|
pub extend NdviPairWitness with @json.ToJson::{to_json}

///|
/// Construct an exact zero-net witness on the first chip's zero-based grid.
/// The output cap bounds materialization; None means no attainable witness.
pub fn ndvi_neutralization_witness(
  before : Chip,
  after : Chip,
  threshold : Double,
  margin : Double,
  limit~ : Int32 = 1024,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> Array[NdviPairWitness]? raise AuditError {
  if limit < 0 || limit > 4096 {
    raise Invalid("witness limit must be in [0, 4096]")
  }
  let bounds = ndvi_threshold_bounds(
    before,
    after,
    threshold,
    margin,
    screen_qa~,
    min_coverage~,
    land_only~,
  )
  guard bounds.neutralization.minimum_changed_pairs is Some(pair_count) else {
    return None
  }
  if pair_count > limit {
    raise Invalid("minimal witness exceeds output limit")
  }
  if pair_count == 0 {
    return Some([])
  }
  let increase = bounds.net.observed < 0
  let deficit = if increase {
    -bounds.net.observed
  } else {
    bounds.net.observed
  }
  let doubles = deficit - pair_count
  let singles = pair_count - doubles
  let spare_double = bounds.neutralization.double_step_pairs > doubles &&
    singles == 1
  let lower = threshold - margin
  let upper = threshold + margin
  let double_changes : Array[NdviPairWitness] = []
  let single_changes : Array[NdviPairWitness] = []
  // ponytail: replay the pair iterator once, retaining only emitted cells.
  ignore(
    visit_ndvi_pairs(before, after, screen_qa, land_only, min_coverage, (
      row,
      column,
      _,
      a,
      b,
    ) => {
      let a_can_flip = if increase {
        a >= threshold && a < upper
      } else {
        a < threshold && a >= lower
      }
      let b_can_flip = if increase {
        b < threshold && b >= lower
      } else {
        b >= threshold && b < upper
      }
      match (a_can_flip, b_can_flip) {
        (true, true) =>
          if double_changes.length() < doubles {
            double_changes.push({ row, column, flip: BothDates, })
          } else if spare_double && single_changes.is_empty() {
            single_changes.push({ row, column, flip: BeforeDate, })
          }
        (true, false) | (false, true) =>
          if !spare_double && single_changes.length() < singles {
            let flip = if a_can_flip { BeforeDate } else { AfterDate }
            single_changes.push({ row, column, flip, })
          }
        (false, false) => ()
      }
    }),
  )
  Some(double_changes + single_changes)
}

///|
#derive(ToJson)
pub(all) enum NdviWitnessFailure {
  RepeatedCell(Int32, Int32)
  OutsideCoverage(Int32, Int32)
  OutsideTolerance(Int32, Int32)
  NonNeutral(Int32)
  NonMinimal(Int32)
}

///|
#derive(ToJson)
pub(all) struct NdviWitnessAudit {
  observed_net : Int32
  final_net : Int32
  changed_pairs : Int32
}

///|
/// Verify a caller-provided witness in the first chip's grid, including minimality.
/// Chip and tolerance validation raise AuditError; witness defects are typed results.
pub fn verify_ndvi_witness(
  before : Chip,
  after : Chip,
  threshold : Double,
  margin : Double,
  witness : Array[NdviPairWitness],
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> Result[NdviWitnessAudit, NdviWitnessFailure] raise AuditError {
  if witness.length() > 4096 {
    raise Invalid("external witness exceeds 4096 pairs")
  }
  let bounds = ndvi_threshold_bounds(
    before,
    after,
    threshold,
    margin,
    screen_qa~,
    min_coverage~,
    land_only~,
  )
  let by_cell : Map[(Int32, Int32), Int32] = Map([])
  for i, cell in witness {
    let key = (cell.row, cell.column)
    if by_cell.contains(key) {
      return Err(RepeatedCell(cell.row, cell.column))
    }
    by_cell[key] = i
  }
  let seen = Array::make(witness.length(), false)
  let deltas : Array[Int32?] = Array::make(witness.length(), None)
  let lower = threshold - margin
  let upper = threshold + margin
  // A selected date can flip iff the half-open uncertainty band contains its measurement.
  if !witness.is_empty() {
    ignore(
      visit_ndvi_pairs(before, after, screen_qa, land_only, min_coverage, (
        row,
        column,
        _,
        a,
        b,
      ) => {
        if by_cell.get((row, column)) is Some(i) {
          seen[i] = true
          let (flip_a, flip_b) = match witness[i].flip {
            BeforeDate => (true, false)
            AfterDate => (false, true)
            BothDates => (true, true)
          }
          if (!flip_a || (a >= lower && a < upper)) &&
            (!flip_b || (b >= lower && b < upper)) {
            let delta_a = if !flip_a {
              0
            } else if a >= threshold {
              1
            } else {
              -1
            }
            let delta_b = if !flip_b {
              0
            } else if b >= threshold {
              -1
            } else {
              1
            }
            deltas[i] = Some(delta_a + delta_b)
          }
        }
      }),
    )
  }
  let mut final_net = bounds.net.observed
  for i, cell in witness {
    if !seen[i] {
      return Err(OutsideCoverage(cell.row, cell.column))
    }
    guard deltas[i] is Some(delta) else {
      return Err(OutsideTolerance(cell.row, cell.column))
    }
    final_net += delta
  }
  if final_net != 0 {
    return Err(NonNeutral(final_net))
  }
  if bounds.neutralization.minimum_changed_pairs is Some(minimum) &&
    witness.length() != minimum {
    return Err(NonMinimal(minimum))
  }
  Ok({
    observed_net: bounds.net.observed,
    final_net,
    changed_pairs: witness.length(),
  })
}

///|
fn compare_flip_margins(a : (Double, Bool), b : (Double, Bool)) -> Int32 {
  let by_distance = a.0.compare(b.0)
  if by_distance != 0 || a.1 == b.1 {
    by_distance
  } else if a.1 {
    -1
  } else {
    1
  }
}

///|
#derive(ToJson)
pub(all) struct NdviBudgetBoundary {
  margin : Double
  attained : Bool
}

///|
#derive(ToJson)
pub(all) struct NdviBudgetMargin {
  observed_net : Int32
  pair_budget : Int32
  critical : NdviBudgetBoundary?
}

///|
/// Return the theoretical boundary for a single pair budget.
pub fn ndvi_budget_margin(
  before : Chip,
  after : Chip,
  threshold : Double,
  pair_budget : Int32,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> NdviBudgetMargin raise AuditError {
  ndvi_budget_margins(
    before,
    after,
    threshold,
    [pair_budget],
    screen_qa~,
    min_coverage~,
    land_only~,
  )[0]
}

///|
/// Resolve all requested pair budgets in one distance sweep.
/// The result keeps input order, including repeated budgets.
pub fn ndvi_budget_margins(
  before : Chip,
  after : Chip,
  threshold : Double,
  pair_budgets : Array[Int32],
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> Array[NdviBudgetMargin] raise AuditError {
  if pair_budgets.any(budget => budget < 0) {
    raise Invalid("pair budget must be nonnegative")
  }
  validate_ndvi_cut_points([threshold])
  if pair_budgets.is_empty() {
    return []
  }
  let mut observed_net = 0
  let mut pair = 0
  // ponytail: sort the at-most-two events per pair in memory; compact
  // event storage would be worthwhile for substantially larger chips.
  let increase : Array[(Double, Bool, Int32)] = []
  let decrease : Array[(Double, Bool, Int32)] = []
  ignore(
    visit_ndvi_pairs(before, after, screen_qa, land_only, min_coverage, (
      _,
      _,
      _,
      a,
      b,
    ) => {
      if a >= threshold {
        observed_net -= 1
        increase.push((a - threshold, false, pair))
      } else {
        decrease.push((threshold - a, true, pair))
      }
      if b >= threshold {
        observed_net += 1
        decrease.push((b - threshold, false, pair))
      } else {
        increase.push((threshold - b, true, pair))
      }
      pair += 1
    }),
  )
  if observed_net == 0 {
    return pair_budgets.map(pair_budget => {
      observed_net,
      pair_budget,
      critical: Some({ margin: 0.0, attained: true, }),
    })
  }
  let needed = observed_net.abs()
  let half = needed / 2 + needed % 2
  let rows : Array[NdviBudgetMargin] = pair_budgets.map(pair_budget => {
    observed_net,
    pair_budget,
    critical: None,
  })
  let pending : Array[(Int32, Int32)] = []
  for i, budget in pair_budgets {
    if budget >= half {
      pending.push((budget, i))
    }
  }
  if pending.is_empty() {
    return rows
  }
  pending.sort_by((a, b) => b.0.compare(a.0))
  let events = if observed_net < 0 { increase } else { decrease }
  events.sort_by((a, b) => compare_flip_margins((a.0, a.1), (b.0, b.1)))
  let active = Array::make(pair, false)
  let mut active_pairs = 0
  let mut double_pairs = 0
  let mut next = 0
  for event in events {
    if active[event.2] {
      double_pairs += 1
    } else {
      active[event.2] = true
      active_pairs += 1
    }
    if active_pairs < needed - double_pairs {
      continue
    }
    // Double pairs offset up to two steps but can always supply a single step.
    let required = needed - double_pairs.min(needed / 2)
    while next < pending.length() && pending[next].0 >= required {
      let (pair_budget, index) = pending[next]
      rows[index] = {
        observed_net,
        pair_budget,
        critical: Some({ margin: event.0, attained: event.1, }),
      }
      next += 1
    }
    if next == pending.length() {
      break
    }
  }
  rows
}

///|
#derive(ToJson)
pub(all) struct NdviCalibrationBounds {
  threshold : Double
  margin : Double
  valid : Int32
  minimum : Int32
  observed_net : Int32
  maximum : Int32
  first_zero_offset : Double?
}

///|
fn calibration_ndvi(chip : Chip, i : Int32) -> Double {
  let red = 11 * chip.red[i] - 80000
  let nir = 11 * chip.nir[i] - 80000
  // Collection 2 affine factors share a denominator of 400000.
  // A single correctly rounded quotient preserves ties between DN ratios.
  (nir - red).to_double() / (nir + red).to_double()
}

///|
/// Apply the same additive NDVI offset to every valid observation on both dates.
/// Equal NDVIs enter the upper class simultaneously.
pub fn ndvi_calibration_bounds(
  before : Chip,
  after : Chip,
  threshold : Double,
  margin : Double,
  screen_qa~ : Bool = true,
  min_coverage~ : Double = 0.0,
  land_only~ : Bool = false,
) -> NdviCalibrationBounds raise AuditError {
  validate_ndvi_cut_points([threshold])
  if !(margin >= 0.0 && threshold - margin > -1.0 && threshold + margin < 1.0) {
    raise Invalid(
      "calibration margin must be nonnegative and keep the cutoff inside (-1, 1)",
    )
  }
  let mut net = 0
  let mut observed_net = 0
  let events : Array[(Double, Int32)] = []
  fn observe(value : Double, weight : Int32) -> Unit {
    let offset = threshold - value
    if offset <= 0.0 {
      observed_net += weight
    }
    if offset <= -margin {
      net += weight
    } else if offset <= margin {
      events.push((value, weight))
    }
  }
  let (_, valid, _, _) = visit_ndvi_pairs(
    before,
    after,
    screen_qa,
    land_only,
    min_coverage,
    (_, _, indices, _, _) => {
      observe(calibration_ndvi(before, indices.0), -1)
      observe(calibration_ndvi(after, indices.1), 1)
    },
  )
  events.sort_by((a, b) => b.0.compare(a.0))
  let mut minimum = net
  let mut maximum = net
  let mut first_zero_offset = if net == 0 { Some(0.0 - margin) } else { None }
  for i, event in events {
    net += event.1
    if i + 1 < events.length() && event.0 == events[i + 1].0 {
      continue
    }
    minimum = minimum.min(net)
    maximum = maximum.max(net)
    if net == 0 && first_zero_offset is None {
      first_zero_offset = Some(threshold - event.0)
    }
  }
  {
    threshold,
    margin,
    valid,
    minimum,
    observed_net,
    maximum,
    first_zero_offset,
  }
}
