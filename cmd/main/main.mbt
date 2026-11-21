///|
extern "js" fn read_utf8(path : String) -> String =
  #|(path) => {
  #|  try { return process.getBuiltinModule("fs").readFileSync(path, "utf8"); }
  #|  catch { return ""; }
  #|}

///|
fn load_chip(path : String) -> @audit.Chip raise {
  let raw = read_utf8(path)
  if raw == "" {
    fail("cannot read input file: " + path)
  }
  @audit.parse_chip(raw)
}

///|
fn parse_thresholds(raw : String) -> Array[Double] raise {
  let values = []
  for item in raw.split(",") {
    values.push(@json.from_json(@json.parse(item.to_owned())))
  }
  values
}

///|
fn main {
  let args = @env.args()
  let start = if args.length() > 2 && args[2] == "--" { 3 } else { 2 }
  if args.length() < start + 3 {
    println(
      "Usage: moon run cmd/main -- <before.json> <after.json> <NDVI threshold | --transitions <cuts> [--margin <NDVI tolerance> [--witness | --verify-witness <file>] | --margins <list> | --critical-margin | --calibration-margin <tolerance> | --pair-budget <count> | --pair-budgets <list>]] [--direct] [--min-coverage <fraction>] [--inspect <row> <column> | --summary | --sweep [0.10,0.15,0.20] | --qa-impact | --tiles 2x2 | --regions [4|8] [--min-region-pixels <pixels>] [--land-only]]",
    )
    @env.exit(2)
  }
  try {
    let before = load_chip(args[start])
    let after = load_chip(args[start + 1])
    let transition_mode = args[start + 2] == "--transitions"
    let threshold : Double = if transition_mode {
      0.15
    } else {
      @json.from_json(@json.parse(args[start + 2]))
    }
    @audit.validate_threshold(threshold)
    let mut direct = false
    let mut minimum = 0.0
    let mut summary = false
    let mut inspect : (Int32, Int32)? = None
    let mut sweep : Array[Double]? = None
    let mut impact = false
    let mut regions : Int32? = None
    let mut region_min : Int32? = None
    let mut land_only = false
    let mut tiles : (Int32, Int32)? = None
    let mut transition : Array[Double]? = None
    let mut margin : Double? = None
    let mut margins : Array[Double]? = None
    let mut critical_margin = false
    let mut calibration_margin : Double? = None
    let mut pair_budget : Int32? = None
    let mut pair_budgets : Array[Int32]? = None
    let mut witness = false
    let mut verify_witness : String? = None
    let mut index = start + (if transition_mode { 2 } else { 3 })
    let seen : Map[String, Bool] = Map([])
    while index < args.length() {
      let flag = args[index]
      if seen.contains(flag) {
        fail("duplicate argument: " + flag)
      }
      seen[flag] = true
      match flag {
        "--direct" => direct = true
        "--land-only" => land_only = true
        "--critical-margin" => critical_margin = true
        "--calibration-margin" => {
          index += 1
          if index >= args.length() {
            fail("--calibration-margin requires an NDVI tolerance")
          }
          calibration_margin = Some(@json.from_json(@json.parse(args[index])))
        }
        "--pair-budget" => {
          index += 1
          if index >= args.length() {
            fail("--pair-budget requires a nonnegative integer")
          }
          pair_budget = Some(@json.from_json(@json.parse(args[index])))
        }
        "--pair-budgets" => {
          index += 1
          if index >= args.length() {
            fail("--pair-budgets requires comma-separated nonnegative integers")
          }
          let budgets : Array[Int32] = []
          for value in args[index].split(",") {
            budgets.push(@json.from_json(@json.parse(value.to_owned())))
          }
          pair_budgets = Some(budgets)
        }
        "--witness" => witness = true
        "--verify-witness" => {
          index += 1
          if index >= args.length() {
            fail("--verify-witness requires a JSON file")
          }
          verify_witness = Some(args[index])
        }
        "--summary" => summary = true
        "--qa-impact" => impact = true
        "--sweep" => {
          let thresholds : Array[Double] = [0.10, 0.15, 0.20]
          if index + 1 < args.length() && !args[index + 1].has_prefix("--") {
            index += 1
            thresholds.clear()
            for value in args[index].split(",") {
              thresholds.push(@json.from_json(@json.parse(value.to_owned())))
            }
          }
          sweep = Some(thresholds)
        }
        "--regions" => {
          let mut connectivity = 4
          if index + 1 < args.length() && !args[index + 1].has_prefix("--") {
            index += 1
            connectivity = @json.from_json(@json.parse(args[index]))
          }
          regions = Some(connectivity)
        }
        "--min-region-pixels" => {
          index += 1
          if index >= args.length() {
            fail("--min-region-pixels requires a positive integer")
          }
          region_min = Some(@json.from_json(@json.parse(args[index])))
        }
        "--transitions" => {
          index += 1
          if index >= args.length() {
            fail("--transitions requires comma-separated NDVI cut points")
          }
          transition = Some(parse_thresholds(args[index]))
        }
        "--margin" => {
          index += 1
          if index >= args.length() {
            fail("--margin requires an NDVI tolerance")
          }
          margin = Some(@json.from_json(@json.parse(args[index])))
        }
        "--margins" => {
          index += 1
          if index >= args.length() {
            fail("--margins requires comma-separated NDVI tolerances")
          }
          margins = Some(parse_thresholds(args[index]))
        }
        "--tiles" => {
          index += 1
          if index >= args.length() {
            fail("--tiles requires rows x columns, for example 2x2")
          }
          let shape = args[index].split("x").to_array()
          if shape.length() != 2 {
            fail("--tiles requires rows x columns, for example 2x2")
          }
          tiles = Some(
            (
              @json.from_json(@json.parse(shape[0].to_owned())),
              @json.from_json(@json.parse(shape[1].to_owned())),
            ),
          )
        }
        "--min-coverage" => {
          index += 1
          if index >= args.length() {
            fail("--min-coverage requires a fraction")
          }
          minimum = @json.from_json(@json.parse(args[index]))
        }
        "--inspect" => {
          if index + 2 >= args.length() {
            fail("--inspect requires row and column")
          }
          let row : Int32 = @json.from_json(@json.parse(args[index + 1]))
          let column : Int32 = @json.from_json(@json.parse(args[index + 2]))
          inspect = Some((row, column))
          index += 2
        }
        unknown => fail("unknown argument: " + unknown)
      }
      index += 1
    }
    let modes = [
      summary,
      inspect is Some(_),
      sweep is Some(_),
      impact,
      tiles is Some(_),
      regions is Some(_),
      transition is Some(_),
    ]
    if modes.filter(value => value).length() > 1 {
      fail(
        "choose only one of --summary, --inspect, --sweep, --qa-impact, --tiles, --regions and --transitions",
      )
    }
    if region_min is Some(_) && regions is None {
      fail("--min-region-pixels requires --regions")
    }
    if land_only && regions is None && transition is None {
      fail("--land-only requires --regions or --transitions")
    }
    if margin is Some(_) && transition is None {
      fail("--margin requires --transitions with one cut")
    }
    if margins is Some(_) {
      if transition is None {
        fail("--margins requires --transitions with one cut")
      }
      if margin is Some(_) {
        fail("choose only one of --margin and --margins")
      }
    }
    if (witness || verify_witness is Some(_)) && margin is None {
      fail("--witness and --verify-witness require --margin and --transitions")
    }
    if witness && verify_witness is Some(_) {
      fail("choose only one of --witness and --verify-witness")
    }
    if calibration_margin is Some(_) &&
      (
        transition is None ||
        critical_margin ||
        pair_budget is Some(_) ||
        pair_budgets is Some(_) ||
        margin is Some(_) ||
        margins is Some(_)
      ) {
      fail(
        "--calibration-margin requires --transitions and no other margin option",
      )
    }
    if pair_budget is Some(_) && pair_budgets is Some(_) {
      fail("choose only one of --pair-budget and --pair-budgets")
    }
    if (pair_budget is Some(_) || pair_budgets is Some(_)) &&
      (
        transition is None ||
        critical_margin ||
        margin is Some(_) ||
        margins is Some(_)
      ) {
      fail(
        "pair budget analysis requires --transitions with one cut and no other margin option",
      )
    }
    if critical_margin {
      if transition is None {
        fail("--critical-margin requires --transitions with one cut")
      }
      if margin is Some(_) || margins is Some(_) {
        fail("--critical-margin cannot be combined with --margin or --margins")
      }
    }
    if impact && direct {
      fail("--qa-impact compares both QA policies; do not also select --direct")
    }
    if transition is Some(cuts) {
      let response = if calibration_margin is Some(radius) {
        if cuts.length() != 1 {
          fail("--calibration-margin requires one cut point")
        }
        Json(
          @audit.ndvi_calibration_bounds(
            before,
            after,
            cuts[0],
            radius,
            screen_qa=!direct,
            min_coverage=minimum,
            land_only~,
          ),
        )
      } else if pair_budgets is Some(budgets) {
        if cuts.length() != 1 {
          fail("--pair-budgets requires --transitions with one cut")
        }
        let rows = @audit.ndvi_budget_margins(
          before,
          after,
          cuts[0],
          budgets,
          screen_qa=!direct,
          min_coverage=minimum,
          land_only~,
        )
        Json::object({ "budgets": Json(rows) })
      } else if pair_budget is Some(budget) {
        if cuts.length() != 1 {
          fail("--pair-budget requires --transitions with one cut")
        }
        Json(
          @audit.ndvi_budget_margin(
            before,
            after,
            cuts[0],
            budget,
            screen_qa=!direct,
            min_coverage=minimum,
            land_only~,
          ),
        )
      } else if critical_margin {
        if cuts.length() != 1 {
          fail("--critical-margin requires --transitions with one cut")
        }
        @json.ToJson::to_json(
          @audit.ndvi_critical_margin(
            before,
            after,
            cuts[0],
            screen_qa=!direct,
            min_coverage=minimum,
            land_only~,
          ),
        )
      } else if margins is Some(tolerances) {
        if cuts.length() != 1 {
          fail("--margins requires --transitions with one cut")
        }
        @json.ToJson::to_json(
          @audit.ndvi_margin_sweep(
            before,
            after,
            cuts[0],
            tolerances,
            screen_qa=!direct,
            min_coverage=minimum,
            land_only~,
          ),
        )
      } else if margin is Some(tolerance) {
        if cuts.length() != 1 {
          fail("--margin requires --transitions with one cut")
        }
        if verify_witness is Some(path) {
          let supplied : Array[@audit.NdviPairWitness] = @json.from_json(
            @json.parse(read_utf8(path)),
          )
          match
            @audit.verify_ndvi_witness(
              before,
              after,
              cuts[0],
              tolerance,
              supplied,
              screen_qa=!direct,
              min_coverage=minimum,
              land_only~,
            ) {
            Ok(audit) =>
              Json::object({
                "valid": Json(true),
                "audit": @json.ToJson::to_json(audit),
              })
            Err(failure) =>
              Json::object({
                "valid": Json(false),
                "failure": @json.ToJson::to_json(failure),
              })
          }
        } else if witness {
          let changes = @audit.ndvi_neutralization_witness(
            before,
            after,
            cuts[0],
            tolerance,
            screen_qa=!direct,
            min_coverage=minimum,
            land_only~,
          )
          Json::object({
            "threshold": Json(cuts[0]),
            "margin": Json(tolerance),
            "witness": match changes {
              Some(rows) => @json.ToJson::to_json(rows)
              None => Json::null()
            },
          })
        } else {
          @json.ToJson::to_json(
            @audit.ndvi_threshold_bounds(
              before,
              after,
              cuts[0],
              tolerance,
              screen_qa=!direct,
              min_coverage=minimum,
              land_only~,
            ),
          )
        }
      } else {
        let result = @audit.ndvi_transitions(
          before,
          after,
          cuts,
          screen_qa=!direct,
          min_coverage=minimum,
          land_only~,
        )
        let response = @json.ToJson::to_json(result)
        if response is Object(fields) {
          fields["summary"] = @json.ToJson::to_json(
            @audit.summarize_ndvi_transitions(result),
          )
        }
        response
      }
      if response is Object(fields) {
        fields["sources"] = Json::object({
          "first_scene": Json(before.scene),
          "second_scene": Json(after.scene),
          "first_date": Json(before.date),
          "second_date": Json(after.date),
          "epsg": Json(before.epsg),
        })
      }
      println(response.stringify())
      return
    }
    if sweep is Some(thresholds) {
      let result = @audit.sensitivity(
        before,
        after,
        thresholds,
        screen_qa=!direct,
        min_coverage=minimum,
      )
      println(@json.ToJson::to_json(result).stringify())
      return
    }
    if impact {
      println(
        @json.ToJson::to_json(
          @audit.qa_impact(before, after, threshold, min_coverage=minimum),
        ).stringify(),
      )
      return
    }
    if inspect is Some((row, column)) {
      let pixel = @audit.inspect_sources(
        before,
        after,
        threshold,
        row,
        column,
        screen_qa=!direct,
        min_coverage=minimum,
      )
      let evidence = @json.ToJson::to_json(pixel)
      if evidence is Object(fields) {
        fields["delta"] = number_or_null(pixel.delta)
      }
      println(evidence.stringify())
      return
    }
    let result = if tiles is Some(_) || regions is Some(_) {
      @audit.compare_classification(
        before,
        after,
        threshold,
        screen_qa=!direct,
        min_coverage=minimum,
      )
    } else {
      @audit.compare(
        before,
        after,
        threshold,
        screen_qa=!direct,
        min_coverage=minimum,
        pixel_grids=!summary,
      )
    }
    if tiles is Some((rows, columns)) {
      println(
        @json.ToJson::to_json(@audit.tile_counts(result, rows~, columns~)).stringify(),
      )
      return
    }
    if regions is Some(connectivity) {
      let min_pixels = region_min.unwrap_or(1)
      let patches = @audit.change_regions(
        result,
        connectivity~,
        min_pixels~,
        land_only~,
      )
      println(@json.ToJson::to_json(patches).stringify())
      return
    }
    let json = @json.ToJson::to_json(result)
    if json is Object(fields) {
      if summary {
        for
          name in [
            "delta", "ndvi_before", "ndvi_after", "classes", "water_code", "before_reason",
            "after_reason",
          ] {
          fields.remove(name)
        }
        println(json.stringify())
        return
      }
      fields["delta"] = nullable_grid(result.delta)
      fields["ndvi_before"] = nullable_grid(result.ndvi_before)
      fields["ndvi_after"] = nullable_grid(result.ndvi_after)
    }
    println(json.stringify())
  } catch {
    @audit.Invalid(reason) => {
      println("BLOCKED: " + reason)
      @env.exit(2)
    }
    err => {
      println("INPUT ERROR: " + err.to_string())
      @env.exit(2)
    }
  }
}

///|
fn number_or_null(value : Double?) -> Json {
  match value {
    Some(n) => Json::number(n)
    None => Json::null()
  }
}

///|
fn nullable_grid(values : Array[Double?]) -> Json {
  Json::array(values.map(number_or_null))
}
