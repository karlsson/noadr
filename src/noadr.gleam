import ewe.{type Request, type Response}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Get}
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import logging
import oadr3/schema
import oadr3/utils

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)
  let assert Ok(_) =
    ewe.new(handle_request)
    |> ewe.bind("localhost")
    |> ewe.listening(port: 8000)
    |> ewe.start

  process.sleep_forever()
}

type DayAheadError {
  NoContent
  DecodeError(json.DecodeError)
  StatusError(Int)
  HttpcError(httpc.HttpError)
  FormatError
}

// Nord Pool 
pub type TodayOrTomorrow {
  Today
  Tomorrow
}

pub type Currency {
  DKK
  EUR
  NOK
  PLN
  RON
  SEK
}

/// DeliveryArea becomes eventID in events/{eventID} URL
pub type DeliveryArea {
  /// Nordic
  DK1
  DK2
  FI
  NO1
  NO2
  NO3
  NO4
  NO5
  SE1
  SE2
  SE3
  SE4
  /// Baltic
  EE
  LT
  LV
  /// CWE - Central Western Europe
  AT
  BE
  FR
  GER
  NL
  PL
  /// SEE - South East Europe
  BG
  // Romania?
  TEL
  /// System - Nordic System price
  SYS
  NOTAVAIL
}

pub type EnergyUnit {
  MWH
  KWH
}

pub type Price =
  Float

pub type DayAheadResponse {
  DayAheadResponse(
    delivery_date_cet: String,
    version: Int,
    updated_at: option.Option(Timestamp),
    delivery_area: DeliveryArea,
    currency: Currency,
    energy_unit: EnergyUnit,
    area_entries: List(AreaEntry),
    final_state: Bool,
  )
}

pub type AreaEntry {
  AreaEntry(start: Timestamp, duration: String, price: Price)
}

// -----------------------------------------

pub fn handle_request(req: Request) -> Response {
  case request.path_segments(req), req.method {
    ["events", area], Get -> {
      case string_to_delivery_area(area) {
        Ok(area) ->
          case openadr_dayahead(area) {
            Ok(json) ->
              response.new(200)
              |> response.set_header(
                "content-type",
                "application/json; charset=utf-8",
              )
              |> response.set_body(ewe.TextData(json))
            Error(e) ->
              case e {
                NoContent ->
                  problem_response(
                    204,
                    "Data not available (yet) from Nord Pool",
                  )
                DecodeError(_) ->
                  problem_response(500, "Could not decode Nord Pool data")
                StatusError(e) ->
                  problem_response(
                    e,
                    "Error status returned from Nord Pool server",
                  )
                HttpcError(_) ->
                  problem_response(408, "Error connecting to Nord Pool server")
                FormatError ->
                  problem_response(400, "Error formatting Nord Pool request")
              }
          }
        Error(Nil) ->
          problem_response(
            404,
            "Last URL segment {evendID} shall be the Delivery Area (eg SE3)",
          )
      }
    }
    // This matches all other paths.
    _, Get -> problem_response(400, "Check your URL")
    _, _ ->
      problem_response(400, "Only Get requests are accepted at the moment")
  }
}

fn problem_response(status: Int, detail: String) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(ewe.TextData(problem(status, detail)))
}

fn problem(status: Int, detail: String) -> String {
  let title = case status {
    200 -> "OK"
    204 -> "No Content"
    400 -> "Bad Request"
    403 -> "Forbidden"
    404 -> "Not Found"
    408 -> "Request Timeout"
    500 -> "Internal Server Error"
    _ -> ""
  }
  json.to_string(
    schema.problem_encode(schema.Problem(
      status: Some(status),
      title: Some(title),
      detail: Some(detail),
      instance: None,
      type_: Some("PROBLEM"),
    )),
  )
}

fn openadr_dayahead(area: DeliveryArea) -> Result(String, DayAheadError) {
  let currency = delivery_area_to_currency(area)
  use today <- result.try(helper(Today, area, currency))
  let tomorrow = case helper(Tomorrow, area, currency) {
    Ok(tomorrow) -> Some(tomorrow)
    Error(NoContent) -> None
    Error(_e) -> None
  }

  Ok(encode_multi_price_event(today, tomorrow))
}

fn helper(
  day: TodayOrTomorrow,
  area: DeliveryArea,
  currency: Currency,
) -> Result(DayAheadResponse, DayAheadError) {
  use request <- result.try(
    nordpool_request(day, area, currency)
    |> result.map_error(fn(_) { FormatError }),
  )
  use response <- result.try(
    httpc.send(request)
    |> result.map_error(fn(e) { HttpcError(e) }),
  )
  day_ahead_response(response, currency, MWH)
}

// https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?date=2026-07-01&market=DayAhead&deliveryArea=SE3&currency=EUR
// 200 OK / 204 No Content if not yet available
fn nordpool_request(
  day: TodayOrTomorrow,
  da: DeliveryArea,
  currency: Currency,
) -> Result(request.Request(String), Nil) {
  use date <- result.try(get_date(day))
  request.new()
  |> request.set_scheme(http.Https)
  |> request.prepend_header("accept", "application/json")
  |> request.set_host("dataportal-api.nordpoolgroup.com")
  |> request.set_path("/api/DayAheadPrices")
  |> request.set_query([
    #("date", date),
    #("market", "DayAhead"),
    #("deliveryArea", delivery_area_string(da)),
    #("currency", currency_string(currency)),
  ])
  |> request.set_body("")
  |> Ok
}

// ------- Nord Pool decoder --------
fn day_ahead_response(
  response: response.Response(String),
  currency: Currency,
  energy_unit: EnergyUnit,
) {
  let response.Response(status:, body:, ..) = response
  case status {
    200 ->
      json.parse(body, day_ahead_response_decoder(currency, energy_unit))
      |> result.map_error(DecodeError)
    // when Tomorrow prices are not yet ready 
    204 -> Error(NoContent)
    _ -> Error(StatusError(status))
  }
}

fn day_ahead_response_decoder(currency: Currency, energy_unit: EnergyUnit) {
  use delivery_date_cet <- decode.field("deliveryDateCET", decode.string)
  use version <- decode.field("version", decode.int)
  use updated_at <- decode.optional_field(
    "updatedAt",
    None,
    decode.optional(timestamp_decoder()),
  )
  use delivery_area <- decode.field(
    "deliveryAreas",
    decode.at([0], delivery_area_decoder()),
  )
  use area_entries <- decode.field(
    "multiAreaEntries",
    decode.list(area_entry_decoder(delivery_area)),
  )
  use final_state <- decode.field(
    "areaStates",
    decode.at(
      [0],
      decode.field("state", decode.string, fn(a) {
        case a {
          "Final" -> decode.success(True)
          // "Preliminary"
          _ -> decode.success(False)
        }
      }),
    ),
  )
  decode.success(DayAheadResponse(
    delivery_date_cet: delivery_date_cet,
    version: version,
    updated_at: updated_at,
    delivery_area: delivery_area,
    energy_unit: energy_unit,
    currency: currency,
    area_entries: area_entries,
    final_state: final_state,
  ))
}

fn timestamp_decoder() {
  use string <- decode.then(decode.string)
  case timestamp.parse_rfc3339(string) {
    Ok(ts) -> decode.success(ts)
    Error(_) -> decode.failure(timestamp.system_time(), "timestamp.Timestamp")
  }
}

fn delivery_area_decoder() {
  use da_string <- decode.then(decode.string)
  case string_to_delivery_area(da_string) {
    Ok(da) -> decode.success(da)
    Error(Nil) -> decode.failure(NOTAVAIL, "DeliveryArea")
  }
}

fn string_to_delivery_area(da_string: String) -> Result(DeliveryArea, Nil) {
  let da = case da_string {
    "DK1" -> DK1
    "DK2" -> DK2
    "FI" -> FI
    "NO1" -> NO1
    "NO2" -> NO2
    "NO3" -> NO3
    "NO4" -> NO4
    "NO5" -> NO5
    "SE1" -> SE1
    "SE2" -> SE2
    "SE3" -> SE3
    "SE4" -> SE4
    "EE" -> EE
    "LT" -> LT
    "LV" -> LV
    "AT" -> AT
    "BE" -> BE
    "FR" -> FR
    "GER" -> GER
    "NL" -> NL
    "PL" -> PL
    "BG" -> BG
    "TEL" -> TEL
    "SYS" -> SYS
    _ -> NOTAVAIL
  }
  case da {
    NOTAVAIL -> Error(Nil)
    _ -> Ok(da)
  }
}

fn area_entry_decoder(area: DeliveryArea) {
  use start <- decode.field("deliveryStart", timestamp_decoder())
  use end <- decode.field("deliveryEnd", timestamp_decoder())
  let duration = duration.to_iso8601_string(timestamp.difference(start, end))
  let area_string = delivery_area_string(area)
  use price <- decode.subfield(["entryPerArea", area_string], decode.float)
  decode.success(AreaEntry(start: start, duration: duration, price: price))
}

// ---- Encode to OpenADR 

// https://github.com/grid-coordination/openadr3-specification/blob/main/3.1.0/User_Guide.md#multi-valued-payloads
fn encode_multi_price_event(
  today: DayAheadResponse,
  tomorrow: option.Option(DayAheadResponse),
) {
  let pldf = fn(dar: DayAheadResponse) -> List(schema.EventPayloadDescriptor) {
    [
      schema.EventPayloadDescriptor(
        currency: Some(currency_string(dar.currency)),
        object_type: "",
        payload_type: "PRICE",
        units: Some(energy_unit_string(dar.energy_unit)),
      ),
    ]
  }

  let entryf = fn(dar: DayAheadResponse, id: Int) {
    let entries = dar.area_entries
    case entries {
      [x, ..] -> {
        [
          schema.Interval(
            id: id,
            interval_period: Some(schema.IntervalPeriod(
              start: Some(timestamp.to_rfc3339(x.start, calendar.utc_offset)),
              duration: Some("PT24H"),
              randomize_start: None,
            )),
            payloads: [
              schema.ValuesMap(
                type_: "PRICE",
                values: list.map(entries, fn(e) { utils.Number(e.price) }),
              ),
            ],
          ),
        ]
      }
      _ -> []
    }
  }

  let intervals1 = entryf(today, 0)

  let intervals2 = case tomorrow {
    Some(tomorrow) -> entryf(tomorrow, 1)
    None -> []
  }

  let das = delivery_area_string(today.delivery_area)
  let event_request =
    schema.EventRequest(
      duration: None,
      event_name: Some("NordPoolDayAhead " <> das),
      interval_period: None,
      intervals: Some(list.append(intervals1, intervals2)),
      payload_descriptors: Some(pldf(today)),
      priority: None,
      program_id: das,
      report_descriptors: None,
      targets: None,
    )
  let created_at = case today.updated_at {
    Some(date) -> timestamp.to_rfc3339(date, calendar.utc_offset)
    None -> result.unwrap(get_date(Today), today.delivery_date_cet)
  }
  let modified_at = case tomorrow {
    None -> created_at
    Some(tomorrow) ->
      case tomorrow.updated_at {
        Some(date) -> timestamp.to_rfc3339(date, calendar.utc_offset)
        None -> created_at
      }
  }

  let object_metadata =
    schema.ObjectMetadata(
      created_date_time: created_at,
      id: int.to_string(today.version),
      modification_date_time: modified_at,
      object_type: "EVENT",
    )
  json.to_string(schema.event_encode(#(object_metadata, event_request)))
}

// --- private functions

fn get_date(day: TodayOrTomorrow) -> Result(String, Nil) {
  // Update date to coming day using local time
  let dur = case day {
    Today -> duration.hours(0)
    Tomorrow -> duration.hours(24)
  }
  use #(date, _) <- result.try(string.split_once(
    timestamp.to_rfc3339(
      timestamp.system_time(),
      duration.add(calendar.local_offset(), dur),
    ),
    "T",
  ))
  Ok(date)
}

fn currency_string(currency: Currency) -> String {
  case currency {
    DKK -> "DKK"
    EUR -> "EUR"
    NOK -> "NOK"
    PLN -> "PLN"
    RON -> "RON"
    SEK -> "SEK"
  }
}

fn delivery_area_to_currency(delivery_area: DeliveryArea) -> Currency {
  case delivery_area {
    DK1 | DK2 -> DKK
    FI -> EUR
    NO1 | NO2 | NO3 | NO4 | NO5 -> NOK
    SE1 | SE2 | SE3 | SE4 -> SEK
    EE | LT | LV | AT | BE | FR | GER | NL | BG -> EUR
    PL -> PLN
    TEL -> RON
    _ -> EUR
  }
}

fn delivery_area_string(delivery_area: DeliveryArea) -> String {
  case delivery_area {
    DK1 -> "DK1"
    DK2 -> "DK2"
    FI -> "FI"
    NO1 -> "NO1"
    NO2 -> "NO2"
    NO3 -> "NO3"
    NO4 -> "NO4"
    NO5 -> "NO5"
    SE1 -> "SE1"
    SE2 -> "SE2"
    SE3 -> "SE3"
    SE4 -> "SE4"
    EE -> "EE"
    LT -> "LT"
    LV -> "LV"
    AT -> "AT"
    BE -> "BE"
    FR -> "FR"
    GER -> "GER"
    NL -> "NL"
    PL -> "PL"
    BG -> "BG"
    TEL -> "TEL"
    SYS -> "SYS"
    NOTAVAIL -> ""
  }
}

fn energy_unit_string(e: EnergyUnit) {
  case e {
    MWH -> "MWH"
    KWH -> "KWH"
  }
}
