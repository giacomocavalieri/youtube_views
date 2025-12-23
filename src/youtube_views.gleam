import envoy
import gleam/dynamic/decode
import gleam/http.{Get, Https}
import gleam/http/request.{type Request}
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string

type Video {
  Video(title: String, id: String, statistics: Statistics)
}

type Statistics {
  Statistics(views: Int, likes: Int, comments: Int)
}

type Error {
  HttpcError(httpc.HttpError)
  JsonError(json.DecodeError)
}

pub fn main() -> Nil {
  let assert Ok(youtube_api_key) = envoy.get("YOUTUBE_API_KEY")
    as "YOUTUBE_API_KEY must be set"
  let playlist = "PLrHHjz1sVz0iPk29TJy8wYZgdhe9beY2L"
  let assert Ok(videos) = fetch_videos_ids(youtube_api_key, in: playlist)
    as "cannot fetch videos from playlist"
  let assert Ok(videos) = fetch_statistics(youtube_api_key, for: videos)
    as "cannot fetch statistics for videos"

  pretty_report(videos)
  |> io.println

  list.fold(over: videos, from: 0, with: fn(sum, video) {
    sum + video.statistics.views
  })
  |> int.to_string
  |> string.append("\nTotal views: ", _)
  |> io.println
}

fn googleapis_request(resource: String) -> Request(String) {
  request.new()
  |> request.set_scheme(Https)
  |> request.set_method(Get)
  |> request.set_host("www.googleapis.com")
  |> request.set_path("youtube/v3/" <> resource)
}

fn fetch_videos_ids(
  youtube_api_key: String,
  in playlist: String,
) -> Result(List(String), Error) {
  googleapis_request("playlistItems")
  |> request.set_query([
    #("part", "id,contentDetails"),
    #("playlistId", playlist),
    #("key", youtube_api_key),
  ])
  |> fetch_videos_ids_loop(youtube_api_key, playlist, _, [])
}

fn fetch_videos_ids_loop(
  youtube_api_key: String,
  playlist: String,
  request: Request(String),
  acc: List(String),
) -> Result(List(String), Error) {
  let response = httpc.send(request)
  use response <- result.try(result.map_error(response, HttpcError))
  let video_id_decoder =
    decode.list(decode.at(["contentDetails", "videoId"], decode.string))
  let ids = json.parse(response.body, decode.at(["items"], video_id_decoder))
  use ids <- result.try(result.map_error(ids, JsonError))
  let acc = list.append(ids, acc)
  case json.parse(response.body, decode.at(["nextPageToken"], decode.string)) {
    Error(_) -> Ok(acc)
    Ok(next_page_token) ->
      googleapis_request("playlistItems")
      |> request.set_query([
        #("part", "id,contentDetails"),
        #("playlistId", playlist),
        #("pageToken", next_page_token),
        #("key", youtube_api_key),
      ])
      |> fetch_videos_ids_loop(youtube_api_key, playlist, _, acc)
  }
}

fn fetch_statistics(
  for videos_ids: List(String),
  with youtube_api_key: String,
) -> Result(List(Video), Error) {
  let response =
    googleapis_request("videos")
    |> request.set_query([
      #("part", "statistics,id,snippet"),
      #("id", string.join(videos_ids, with: ",")),
      #("key", youtube_api_key),
    ])
    |> httpc.send

  use response <- result.try(result.map_error(response, HttpcError))
  json.parse(response.body, decode.at(["items"], decode.list(video_decoder())))
  |> result.map_error(JsonError)
}

fn video_decoder() -> decode.Decoder(Video) {
  use id <- decode.field("id", decode.string)
  use title <- decode.subfield(["snippet", "title"], decode.string)
  use statistics <- decode.field("statistics", statistics_decoder())
  decode.success(Video(title:, id:, statistics:))
}

fn statistics_decoder() -> decode.Decoder(Statistics) {
  use views <- decode.field("viewCount", permissive_int_decoder())
  use likes <- decode.field("likeCount", permissive_int_decoder())
  use comments <- decode.field("commentCount", permissive_int_decoder())
  decode.success(Statistics(views:, likes:, comments:))
}

fn permissive_int_decoder() -> decode.Decoder(Int) {
  let string_int_decoder = {
    use string <- decode.then(decode.string)
    case int.parse(string) {
      Ok(n) -> decode.success(n)
      Error(_) -> decode.failure(0, "Int")
    }
  }

  decode.one_of(decode.int, [string_int_decoder])
}

fn pretty_report(videos: List(Video)) -> String {
  videos
  |> list.sort(fn(one, other) {
    int.compare(one.statistics.views, other.statistics.views)
    |> order.negate
  })
  |> list.map(fn(video) {
    let max_length = 70
    let title =
      shorten(video.title, to: max_length)
      |> string.pad_end(to: max_length, with: " ")

    title <> "  " <> int.to_string(video.statistics.views)
  })
  |> string.join(with: "\n")
}

fn shorten(string: String, to size: Int) -> String {
  case string.slice(string, at_index: 0, length: size - 3) {
    shortened if shortened == string -> string
    shortened -> shortened <> "..."
  }
}
