import Parsing
import XCTest

final class PrefixUpToTests: XCTestCase {
  func testSuccess() {
    var input = "Hello,world, 42!"[...]
    XCTAssertEqual("Hello,world", try PrefixUpTo(", ").parse(&input))
    XCTAssertEqual(", 42!", input)
  }

  func testSuccessIsEmpty() {
    var input = "Hello, world!"[...]
    XCTAssertEqual("", try PrefixUpTo("").parse(&input))
    XCTAssertEqual("Hello, world!", input)
  }

  func testFailureIsEmpty() {
    var input = ""[...]
    XCTAssertThrowsError(try PrefixUpTo(", ").parse(&input))
    XCTAssertEqual("", input)
  }

  func testFailureNoMatch() {
    var input = "Hello world!"[...]
    XCTAssertThrowsError(try PrefixUpTo(", ").parse(&input))
    XCTAssertEqual("Hello world!", input)
  }

  func testUTF8() {
    var input = "Hello,world, 42!"[...].utf8
    XCTAssertEqual("Hello,world", Substring(try PrefixUpTo(", ".utf8).parse(&input)))
    XCTAssertEqual(", 42!", Substring(input))
  }
}
