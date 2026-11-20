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
fn main {
  let args = @env.args()
  let start = if args.length() > 2 && args[2] == "--" { 3 } else { 2 }
  if args.length() < start + 3 {
    println(
      "Usage: moon run cmd/main -- <before.json> <after.json> <NDVI threshold | --transitions <cuts>] [--direct] [--min-coverage <fraction>] [--inspect <row> <column> | --summary | --sweep [0.10,0.15,0.20] | --qa-impact | --tiles 2x2 | --regions [4|8] [--min-region-pixels <pixels>] [--land-only]]",
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
          let cuts : Array[Double] = []
          for value in args[index].split(",") {
            cuts.push(@json.from_json(@json.parse(value.to_owned())))
          }
          transition = Some(cuts)
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
    if (region_min is Some(_) || land_only) && regions is None {
      fail("--min-region-pixels and --land-only require --regions")
    }
    if impact && direct {
      fail("--qa-impact compares both QA policies; do not also select --direct")
    }
    if transition is Some(cuts) {
      let result = @audit.ndvi_transitions(
        before,
        after,
        cuts,
        screen_qa=!direct,
        min_coverage=minimum,
      )
      let response = @json.ToJson::to_json(result)
      if response is Object(fields) {
        fields["summary"] = @json.ToJson::to_json(
          @audit.summarize_ndvi_transitions(result),
        )
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
