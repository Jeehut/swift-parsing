/// Declares a type that can parse an `Input` value into an `Output` value.
///
/// A parser attempts to parse a nebulous piece of data, represented by the `Input` associated type,
/// into something more well-structured, represented by the `Output` associated type. The parser
/// implements the ``parse(_:)-4u8o0`` method, which is handed an `inout Input`, and its job is to
/// turn this into an `Output` if possible, or otherwise return `nil` if it cannot, which represents
/// a parsing failure.
///
/// The argument of the ``parse(_:)-4u8o0`` function is `inout` because a parser will usually
/// consume some of the input in order to produce an output. For example, we can use the
/// `Int.parser()` parser to extract an integer from the beginning of a `UTF8View` and consume that
/// portion of the string:
///
/// ```swift
/// var input = "123 Hello world"[...].utf8
/// let output = Int.parser.parse(&input)
/// precondition(output == 123)
/// precondition(input.elementsEqual(" Hello world"[...].utf8))
/// ```
///
/// It is best practice for a parser to _not_ consume any of the input if it fails to produce an
/// output. This allows for "backtracking", which means if a parser fails then another parser can
/// try on the original input.
@rethrows public protocol Parser {
  /// The kind of values this parser receives.
  associatedtype Input

  /// The kind of values parsed by this parser.
  associatedtype Output

  /// Attempts to parse a nebulous piece of data into something more well-structured.
  ///
  /// - Parameter input: A nebulous piece of data to be parsed.
  /// - Returns: A more well-structured value parsed from the given input, or `nil`.
  func parse(_ input: inout Input) throws -> Output
}

@usableFromInline
enum ParsingError<Input>: Error {
  case expectedInput(String, Context)
  case failed(Context)
  case manyFailed([Error], Context)

  @usableFromInline
  static func expectedInput(_ description: String, at remainingInput: Input) -> Self {
    .expectedInput(description, .init(remainingInput: remainingInput, debugDescription: ""))
  }

  @usableFromInline
  static func failed(debugDescription: String, at remainingInput: Input) -> Self {
    .failed(.init(remainingInput: remainingInput, debugDescription: debugDescription))
  }

  @usableFromInline
  static func manyFailed(_ errors: [Error], at remainingInput: Input) -> Self {
    .manyFailed(errors, .init(remainingInput: remainingInput, debugDescription: ""))
  }

  @usableFromInline
  struct Context {
    var debugDescription: String
    var remainingInput: Input
    var underlyingError: Error?

    @usableFromInline
    init(
      remainingInput: Input,
      debugDescription: String,
      underlyingError: Error? = nil
    ) {
      self.remainingInput = remainingInput
      self.debugDescription = debugDescription
      self.underlyingError = underlyingError
    }
  }
}

extension Parser {
  @inlinable
  public func parse<SuperSequence>(
    _ input: SuperSequence
  ) rethrows -> Output
  where
    SuperSequence: Collection,
    SuperSequence.SubSequence == Input
  {
    var input = input[...]
    return try self.parse(&input)
  }

  @inlinable
  public func parse<S: StringProtocol>(_ input: S) rethrows -> Output
  where
    Input == S.SubSequence.UTF8View
  {
    var input = input[...].utf8
    return try self.parse(&input)
  }

  @inlinable
  public func parse<S: StringProtocol>(_ input: S) rethrows -> Output?
  where
    Input == Slice<UnsafeBufferPointer<UTF8.CodeUnit>>
  {
    try input.utf8
      .withContiguousStorageIfAvailable { input -> Output in
        var input = input[...]
        return try self.parse(&input)
      }
  }

  @inlinable
  public func parse<C: Collection>(_ input: C) rethrows -> Output?
  where
    C.Element == UTF8.CodeUnit,
    Input == Slice<UnsafeBufferPointer<C.Element>>
  {
    try input
      .withContiguousStorageIfAvailable { input -> Output in
        var input = input[...]
        return try self.parse(&input)
      }
  }
}
