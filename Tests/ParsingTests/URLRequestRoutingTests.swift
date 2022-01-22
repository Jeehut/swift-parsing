import Parsing
import XCTest

struct ParsingError: LocalizedError {
  var errorDescription: String?

  init(expect errorDescription: String) {
    self.errorDescription = errorDescription
  }
}

class URLRequestRoutingTests: XCTestCase {
  func testURLRequestRouting() throws {
    enum AppRoute: Equatable {
      case home
      case contactUs
      case episodes(Episodes)
    }
    enum Episodes: Equatable {
      case index
      case episode(id: Int, route: Episode)
    }
    enum Episode: Equatable {
      case show
      case comments(Comments)
    }
    enum Comments: Equatable {
      case post(Comment)
      case show(count: Int)
    }
    struct Comment: Decodable, Equatable {
      let commenter: String
      let message: String
    }

    let router = OneOf {
      Route(AppRoute.home)

      Route(AppRoute.contactUs) {
        Path(FromUTF8View { "contact-us".utf8 })
      }

      Route(AppRoute.episodes) {
        Path(FromUTF8View { "episodes".utf8 })

        OneOf {
          Route(Episodes.index)

          Route(Episodes.episode) {
            Path(Int.parser())

            OneOf {
              Route(Episode.show)

              Route(Episode.comments) {
                Path(FromUTF8View { "comments".utf8 })

                OneOf {
                  Route(Comments.post) {
                    Method.post
                    Body {
                      JSON(Comment.self)
                    }
                  }

                  Route(Comments.show) {
                    Query("count", Int.parser(), default: 10)
                  }
                }
              }
            }
          }
        }
      }
    }

    var request = URLRequestData(string: "episodes/hello")!
    try router.parse(&request)
  }
}

struct URLRequestData {
  var body: ArraySlice<UInt8>?
  var headers: [String: Substring]
  var method: String?
  var path: ArraySlice<Substring>
  var query: [String: ArraySlice<Substring?>]

  init(
    method: String? = nil,
    path: ArraySlice<Substring> = [],
    query: [String: ArraySlice<Substring?>] = [:],
    headers: [String: Substring] = [:],
    body: ArraySlice<UInt8>? = nil
  ) {
    self.method = method
    self.path = path
    self.query = query
    self.headers = headers
    self.body = body
  }
}

struct Body<Parsers>: Parser
where
  Parsers: Parser,
  Parsers.Input == ArraySlice<UInt8>
{
  let bodyParser: Parsers

  @inlinable
  init(@ParserBuilder _ bodyParser: () -> Parsers) {
    self.bodyParser = bodyParser()
  }

  @inlinable
  func parse(_ input: inout URLRequestData) throws -> Parsers.Output {
    guard var body = input.body
    else {
      throw ParsingError(expect: "HTTP body to be present")
    }

    let output = try self.bodyParser.parse(&body)

    guard body.isEmpty else {
      throw ParsingError(
        expect: """
          HTTP body to have been fully parsed (\(body.count) bytes remaining)
          """
      )
    }

    input.body = nil
    return output
  }
}

struct JSON<Value: Decodable>: Parser {
  let decoder: JSONDecoder

  @inlinable
  init(
    _ type: Value.Type,
    decoder: JSONDecoder = .init()
  ) {
    self.decoder = decoder
  }

  @inlinable
  func parse(_ input: inout ArraySlice<UInt8>) throws -> Value {
    let output = try decoder.decode(Value.self, from: Data(input))
    input = []
    return output
  }
}

struct Method: Parser {
  let name: String

  static let get = Self("GET")
  static let post = Self("POST")
  static let put = Self("PUT")
  static let patch = Self("PATCH")
  static let delete = Self("DELETE")

  @inlinable
  init(_ name: String) {
    self.name = name.uppercased()
  }

  @inlinable
  func parse(_ input: inout URLRequestData) throws {
    guard input.method?.uppercased() == self.name
    else {
      throw ParsingError(expect: "Method \(self.name)")
    }
    input.method = nil
    return ()
  }
}

struct Path<Component>: Parser
where
  Component: Parser,
  Component.Input == Substring
{
  let componentParser: Component

  @inlinable
  init(_ component: Component) {
    self.componentParser = component
  }

  @inlinable
  func parse(_ input: inout URLRequestData) throws -> Component.Output {
    guard var component = input.path.first
    else {
      throw ParsingError(expect: "another path component")
    }

    let output = try self.componentParser.parse(&component)

    guard component.isEmpty
    else {
      throw ParsingError(
        expect: """
          to have fully consumed "\(input.path.first!)" from path; remaining: "\(component)"
          """
      )
    }

    input.path.removeFirst()
    return output
  }
}

struct PathEnd: Parser {
  @inlinable
  init() {}

  @inlinable
  func parse(_ input: inout URLRequestData) throws {
    guard input.path.isEmpty
    else { throw ParsingError(expect: "path to be empty") }
    return ()
  }
}

struct Query<Value>: Parser
where
  Value: Parser,
  Value.Input == Substring
{
  let defaultValue: Value.Output?
  let name: String
  let valueParser: Value

  @inlinable
  init(
    _ name: String,
    _ value: Value,
    default defaultValue: Value.Output? = nil
  ) {
    self.defaultValue = defaultValue
    self.name = name
    self.valueParser = value
  }

  @inlinable
  init(
    _ name: String,
    default defaultValue: Value.Output? = nil
  ) where Value == Rest<Substring> {
    self.init(
      name,
      Rest(),
      default: defaultValue
    )
  }

  @inlinable
  func parse(_ input: inout URLRequestData) throws -> Value.Output {
    func defaultOrError(_ error: Error) throws -> Value.Output {
      guard let defaultValue = self.defaultValue
      else {
        throw error
      }
      return defaultValue
    }

    guard
      let wrapped = input.query[self.name]?.first,
      var value = wrapped
    else {
      return try defaultOrError(ParsingError(expect: "query item named \"\(self.name)\""))
    }

    let output: Value.Output
    do {
      output = try self.valueParser.parse(&value)
    } catch {
      return try defaultOrError(error)
    }

    guard value.isEmpty
    else {
      return try defaultOrError(
        ParsingError(
          expect: """
            to have fully consumed "\(input.query[self.name]!.first!!)" from query item named \
            "\(self.name)"; remaining: "\(value)"
            """
        )
      )
    }

    input.query[self.name]?.removeFirst()
    if input.query[self.name]?.isEmpty ?? true {
      input.query[self.name] = nil
    }
    return output
  }
}

struct Route<Parsers>: Parser
where
  Parsers: Parser,
  Parsers.Input == URLRequestData
{
  let parsers: Parsers

  @inlinable
  init<Upstream, Route>(
    _ transform: @escaping (Upstream.Output) -> Route,
    @ParserBuilder with parsers: () -> Upstream
  ) where Upstream.Input == URLRequestData, Parsers == Parsing.Parsers.Map<Upstream, Route> {
    self.parsers = parsers().map(transform)
  }

  @inlinable
  init<Upstream, Route>(
    _ route: Route,
    @ParserBuilder with parsers: () -> Upstream
  )
  where
    Upstream.Input == URLRequestData,
    Upstream.Output == Void,
    Parsers == Parsing.Parsers.Map<Upstream, Route>
  {
    self.parsers = parsers().map { route }
  }

  @inlinable
  init<Route>(_ route: Route) where Parsers == Always<URLRequestData, Route> {
    self.parsers = Always<URLRequestData, Route>(route)
  }

  @inlinable
  func parse(_ input: inout URLRequestData) throws -> Parsers.Output {
    let original = input

    let output = try self.parsers.parse(&input)

    guard
      input.method == nil || (try? Method.get.parse(&input)) != nil,
      input.path.isEmpty
    else {
      input = original
      throw ParsingError(
        expect: """
          method and all path components to be consumed from input: \(input)
          """
      )
    }

    return output
  }
}

extension URLRequestData {
  init?(request: URLRequest) {
    guard
      let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }

    self.init(
      method: request.httpMethod,
      path: url.path.split(separator: "/")[...],
      query: components.queryItems?.reduce(into: [:]) { query, item in
        query[item.name, default: []].append(item.value?[...])
      } ?? [:],
      headers: request.allHTTPHeaderFields?.mapValues { $0[...] } ?? [:],
      body: request.httpBody.map { ArraySlice($0) }
    )
  }

  init?(url: URL) {
    self.init(request: URLRequest(url: url))
  }

  init?(string: String) {
    guard let url = URL(string: string)
    else { return nil }
    self.init(url: url)
  }
}
