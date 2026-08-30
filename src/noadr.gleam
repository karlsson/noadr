//// Read from Nord Pool
//// Respond to client

import ewe
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Get}
import gleam/http/request
import gleam/http/response
import gleam/httpc
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

/// Will start a web server on localhost:8000
pub fn main() {
  //  observer_start()
  let listener_name = process.new_name("noadr_listener")
  let connection_factory_name = process.new_name("noadr_connection_factory")
  logging.configure()
  logging.set_level(logging.Info)
  let assert Ok(_) =
    ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
    |> ewe.bind(to: "localhost")
    |> ewe.listening(on: 8000)
    |> ewe.start

  process.sleep_forever()
}

// type ErlangResult

// @external(erlang, "observer", "start")
// fn observer_start() -> ErlangResult

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
  // Romania
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
  AreaEntry(start: Timestamp, duration: duration.Duration, price: Price)
}

// -----------------------------------------
/// Handler, can be used by any ewe server.
pub fn handle_request(
  req: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  case request.path_segments(req), req.method {
    ["programs"], Get -> encode_programs() |> ok_response
    ["programs", program_id], Get -> {
      case string_to_delivery_area(program_id) {
        Ok(area) -> encode_program(area) |> ok_response
        Error(Nil) ->
          problem_response(
            404,
            "Program with id: " <> program_id <> " does not exist.",
          )
      }
    }
    ["events"], Get -> {
      case request.get_query(req) {
        Ok([#("programID", area)]) ->
          case string_to_delivery_area(area) {
            Ok(area) ->
              case openadr_dayahead(area) {
                Ok(json) -> ok_response(json)
                Error(e) -> day_ahead_error_response(e)
              }
            Error(Nil) ->
              problem_response(
                404,
                "programID shall be a Delivery area (eg SE3)",
              )
          }
        Ok(_) -> problem_response(400, "You need programID in the query")
        Error(_) -> problem_response(400, "You need programID query")
      }
    }
    ["events", event_id], Get -> {
      let req_pars = {
        use ba <- result.try(bit_array.base64_decode(event_id))
        use ba <- result.try(bit_array.to_string(ba))
        use #(area, date) <- result.try(string.split_once(ba, "-"))
        use area <- result.map(string_to_delivery_area(area))
        #(area, date)
      }
      case req_pars {
        Ok(#(area, date)) ->
          case openadr_specific_date(area, date) {
            Ok(response) -> ok_response(response)
            // Bad response from Nord Pool
            Error(e) -> day_ahead_error_response(e)
          }
        // Bad Request
        Error(Nil) -> problem_response(400, "")
      }
    }

    // This matches all other paths.
    _, Get -> problem_response(400, "Check your URL")
    _, _ ->
      problem_response(400, "Only Get requests are accepted at the moment")
  }
}

fn ok_response(json: json.Json) -> response.Response(ewe.Body) {
  response.new(200)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(ewe.Text(json.to_string(json)))
}

fn day_ahead_error_response(e: DayAheadError) -> response.Response(ewe.Body) {
  case e {
    NoContent ->
      problem_response(204, "Data not available (yet) from Nord Pool")
    DecodeError(_) -> problem_response(500, "Could not decode Nord Pool data")
    StatusError(e) ->
      problem_response(e, "Error status returned from Nord Pool server")
    HttpcError(_) ->
      problem_response(408, "Error connecting to Nord Pool server")
    FormatError -> problem_response(400, "Error formatting Nord Pool request")
  }
}

fn problem_response(
  status: Int,
  detail: String,
) -> response.Response(ewe.Body) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(ewe.Text(problem(status, detail)))
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

fn openadr_dayahead(area: DeliveryArea) -> Result(json.Json, DayAheadError) {
  use today <- result.try(
    get_date(Today) |> result.map_error(fn(_) { FormatError }),
  )

  use tomorrow <- result.try(
    get_date(Tomorrow) |> result.map_error(fn(_) { FormatError }),
  )
  use today <- result.try(openadr_specific_date(area, today))
  let and_tomorrow = case openadr_specific_date(area, tomorrow) {
    Ok(tomorrow) -> [today, tomorrow]
    Error(NoContent) -> [today]
    Error(_e) -> [today]
  }
  Ok(and_tomorrow |> json.array(fn(a) { a }))
}

fn openadr_specific_date(
  area: DeliveryArea,
  date: String,
) -> Result(json.Json, DayAheadError) {
  let currency = delivery_area_to_currency(area)
  use response <- result.try(helper(date, area, currency))
  Ok(encode_price_event(response))
}

fn helper(
  date: String,
  area: DeliveryArea,
  currency: Currency,
) -> Result(DayAheadResponse, DayAheadError) {
  let request = nordpool_request(date, area, currency)

  use response <- result.try(
    httpc.send(request)
    |> result.map_error(fn(e) { HttpcError(e) }),
  )
  day_ahead_response(response, currency, MWH)
}

// https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?date=2026-07-01&market=DayAhead&deliveryArea=SE3&currency=EUR
// 200 OK / 204 No Content if not yet available
fn nordpool_request(
  date: String,
  da: DeliveryArea,
  currency: Currency,
) -> request.Request(String) {
  request.new()
  |> request.set_scheme(http.Https)
  |> request.prepend_header("accept", "application/json")
  |> request.set_host("dataportal-api.nordpoolgroup.com")
  |> request.set_path("/api/DayAheadPrices")
  |> request.set_query([
    #("date", date),
    #("market", "DayAhead"),
    #("deliveryArea", delivery_area_to_string(da)),
    #("currency", currency_string(currency)),
  ])
  |> request.set_body("")
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
  let duration = timestamp.difference(start, end)
  let area_string = delivery_area_to_string(area)
  use price <- decode.subfield(["entryPerArea", area_string], decode.float)
  decode.success(AreaEntry(start: start, duration: duration, price: price))
}

// ---- Encode to OpenADR 

// https://github.com/grid-coordination/openadr3-specification/blob/main/3.1.0/User_Guide.md#multi-valued-payloads
fn encode_price_event(day: DayAheadResponse) {
  let pldf = fn(dar: DayAheadResponse) -> List(schema.EventPayloadDescriptor) {
    [
      schema.EventPayloadDescriptor(
        currency: Some(currency_string(dar.currency)),
        object_type: "EVENT_PAYLOAD_DESCRIPTOR",
        payload_type: "EXPORT_PRICE",
        units: Some(energy_unit_string(dar.energy_unit)),
      ),
    ]
  }

  let entryf = fn(dar: DayAheadResponse, id: Int) {
    let entries = dar.area_entries
    case entries {
      [x, ..] -> {
        let dur =
          list.fold(entries, duration.hours(0), fn(acc, e) {
            duration.add(acc, e.duration)
          })
        [
          schema.Interval(
            id: id,
            interval_period: Some(schema.IntervalPeriod(
              start: Some(timestamp.to_rfc3339(x.start, calendar.utc_offset)),
              duration: Some(duration.to_iso8601_string(dur)),
              randomize_start: None,
            )),
            payloads: [
              schema.ValuesMap(
                type_: "EXPORT_PRICE",
                values: list.map(entries, fn(e) { utils.Number(e.price) }),
              ),
              schema.ValuesMap(type_: "EXPORT_PRICE_STATE", values: [
                utils.String(case dar.final_state {
                  True -> "Final"
                  False -> "Preliminary"
                }),
              ]),
            ],
          ),
        ]
      }
      _ -> []
    }
  }

  let intervals = entryf(day, 0)

  let das = delivery_area_to_string(day.delivery_area)
  let event_request =
    schema.EventRequest(
      duration: None,
      event_name: Some(
        "NordPoolDayAhead " <> das <> ":" <> day.delivery_date_cet,
      ),
      interval_period: None,
      intervals: Some(intervals),
      payload_descriptors: Some(pldf(day)),
      priority: None,
      program_id: das,
      report_descriptors: None,
      targets: None,
    )
  let created_at = case day.updated_at {
    Some(date) -> timestamp.to_rfc3339(date, calendar.utc_offset)
    None -> result.unwrap(get_date(Today), day.delivery_date_cet)
  }
  let modified_at = created_at

  let object_metadata =
    schema.ObjectMetadata(
      created_date_time: created_at,
      id: bit_array.base64_encode(
        bit_array.from_string(das <> "-" <> day.delivery_date_cet),
        False,
      ),
      modification_date_time: modified_at,
      object_type: "EVENT",
    )
  schema.event_encode(#(object_metadata, event_request))
}

// --- private functions

fn get_date(day: TodayOrTomorrow) -> Result(String, Nil) {
  // Update date to coming day using local time.
  // What about daylight saving time shifts?
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

fn delivery_area_to_string(delivery_area: DeliveryArea) -> String {
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

type Country {
  Country(code: String, name: String)
}

fn delivery_area_to_country(delivery_area: DeliveryArea) -> Country {
  case delivery_area {
    DK1 | DK2 -> Country("DK", "Denmark")
    FI -> Country("FI", "Finland")
    NO1 | NO2 | NO3 | NO4 | NO5 -> Country("NO", "Norway")
    SE1 | SE2 | SE3 | SE4 -> Country("SE", "Sweden")
    EE -> Country("EE", "Estonia")
    LT -> Country("LT", "Lithuania")
    LV -> Country("LV", "Latvia")
    AT -> Country("AT", "Austria")
    BE -> Country("BE", "Belgium")
    FR -> Country("FR", "France")
    GER -> Country("GER", "Germany")
    NL -> Country("NL", "Netherlands")
    BG -> Country("BG", "Bulgaria")
    PL -> Country("PL", "Poland")
    TEL -> Country("TEL", "Romania")
    SYS -> Country("System", "Nordic system price")
    NOTAVAIL -> Country("", "")
  }
}

fn energy_unit_string(e: EnergyUnit) {
  case e {
    MWH -> "MWH"
    KWH -> "KWH"
  }
}

// ------------ Programs --------------------
// Hardcoded
pub type Region {
  Baltic
  /// Central Western Europe
  CWE
  Nordic
  /// South East Europe
  SEE
  /// Nordic System Price
  System
}

fn area_list() -> List(Region) {
  [Baltic, CWE, Nordic, SEE, System]
}

// fn region_to_string(region: Region) -> String {
//   case region {
//     Baltic -> "Baltic"
//     CWE -> "CWE"
//     Nordic -> "Nordic"
//     SEE -> "SEE"
//     System -> "System"
//   }
// }

// fn decode_region(region_string: String) -> Result(Region, Nil) {
//   case region_string {
//     "Baltic" -> Ok(Baltic)
//     "CWE" -> Ok(CWE)
//     "Nordic" -> Ok(Nordic)
//     "SEE" -> Ok(SEE)
//     "System" -> Ok(System)
//     _ -> Error(Nil)
//   }
// }

fn areas_by_region(region: Region) -> List(DeliveryArea) {
  case region {
    Baltic -> [EE, LT, LV]
    CWE -> [AT, BE, FR, GER, NL, PL]
    Nordic -> [DK1, DK2, FI, NO1, NO2, NO3, NO4, NO5, SE1, SE2, SE3, SE4]
    SEE -> [BG, TEL]
    System -> [SYS]
  }
}

fn encode_programs() -> json.Json {
  let all =
    area_list() |> list.map(areas_by_region) |> list.fold([], list.append)
  json.array(all, encode_program)
}

fn encode_program(area: DeliveryArea) -> json.Json {
  let today_date =
    timestamp.to_rfc3339(
      timestamp.system_time(),
      duration.add(calendar.utc_offset, duration.hours(0)),
    )

  let area_str = delivery_area_to_string(area)
  // List of #(ObjectMetadata, ProgramRequest)

  let om =
    schema.ObjectMetadata(
      created_date_time: today_date,
      id: area_str,
      modification_date_time: today_date,
      object_type: "PROGRAM",
    )
  let pr =
    schema.ProgramRequest(
      interval_period: None,
      program_name: area_str,
      attributes: Some([
        schema.ValuesMap("PROGRAM_LONG_NAME", [
          utils.String(
            delivery_area_to_country(area).name
            <> "/"
            <> area_str
            <> " Day ahead prices from Nord Pool",
          ),
        ]),
        schema.ValuesMap("COUNTRY", [
          utils.String(delivery_area_to_country(area).code),
        ]),
      ]),
      payload_descriptors: Some([
        utils.Object(
          dict.from_list([
            #(
              "currency",
              utils.String(currency_string(delivery_area_to_currency(area))),
            ),
            #("object_type", utils.String("EVENT_PAYLOAD_DESCRIPTOR")),
            #("payload_type", utils.String("EXPORT_PRICE")),
            #("units", utils.String(energy_unit_string(MWH))),
          ]),
        ),
      ]),
      program_descriptions: None,
      targets: None,
    )

  schema.program_encode(#(om, pr))
}
