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
  @json.from_json(@json.parse(raw, reject_duplicate_keys=true))
}

///|
fn main {
  let args = @env.args()
  let start = if args.length() > 2 && args[2] == "--" { 3 } else { 2 }
  if args.length() < start + 3 {
    println(
      "Usage: moon run cmd/main -- <before.json> <after.json> <NDVI threshold> [--direct] [--min-coverage <fraction>] [--inspect <row> <column> | --summary]",
    )
    @env.exit(2)
  }
  try {
    let before = load_chip(args[start])
    let after = load_chip(args[start + 1])
    let threshold : Double = @json.from_json(@json.parse(args[start + 2]))
    let mut direct = false
    let mut minimum = 0.0
    let mut summary = false
    let mut inspect : (Int32, Int32)? = None
    let mut index = start + 3
    while index < args.length() {
      match args[index] {
        "--direct" => direct = true
        "--summary" => summary = true
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
    if summary && inspect is Some(_) {
      fail("--summary and --inspect cannot be used together")
    }
    let result = @audit.compare(
      before,
      after,
      threshold,
      screen_qa=!direct,
      min_coverage=minimum,
      pixel_grids=!summary,
    )
    if inspect is Some((row, column)) {
      let pixel = @audit.inspect_pixel(before, after, result, row, column)
      let evidence = @json.ToJson::to_json(pixel)
      if evidence is Object(fields) {
        fields["delta"] = number_or_null(pixel.delta)
      }
      println(evidence.stringify())
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
