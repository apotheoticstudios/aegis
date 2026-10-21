import Foundation

/// Failures while extracting a counted string from a Messages typedstream.
public enum TypedStreamError: Error, Sendable, Equatable {
    /// The first 16 bytes do not contain the typedstream signature.
    case notTypedStream
    /// The stream does not contain an NSString class marker.
    case missingNSString
    /// No counted-byte payload marker follows the NSString marker.
    case missingStringPayload
    /// The payload marker has no following length byte.
    case truncatedStream
    /// The length encoding is unsupported or incomplete.
    case invalidStringLength
    /// The declared string length exceeds the remaining bytes.
    case stringOutOfBounds
}

/// Extracts plain text from the common Messages NSArchiver typedstream layout.
public enum TypedStream {
    /// Returns the first NSString payload, replacing invalid UTF-8 with U+FFFD.
    /// Throws a typed error if the signature, markers, or counted bytes are malformed.
    public static func text(fromAttributedBody data: Data) throws(TypedStreamError) -> String {
        let headerEnd = data.index(data.startIndex, offsetBy: min(16, data.count))
        guard data.range(of: Data("streamtyped".utf8), in: data.startIndex ..< headerEnd) != nil else {
            throw .notTypedStream
        }
        guard let classRange = data.range(of: Data("NSString".utf8)) else {
            throw .missingNSString
        }
        guard let payloadRange = data.range(of: Data([0x84, 0x01, 0x2B]), in: classRange.lowerBound ..< data.endIndex) else {
            throw .missingStringPayload
        }
        var position = payloadRange.upperBound
        let count = try readLength(in: data, position: &position)
        guard UInt64(count) <= UInt64(data.endIndex - position) else {
            throw .stringOutOfBounds
        }
        // Replacement decoding is required by the Python reader, rather than failing on invalid UTF-8.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data[position ..< position + Int(count)], as: UTF8.self)
    }

    private static func readLength(in data: Data, position: inout Data.Index) throws(TypedStreamError) -> UInt32 {
        guard position < data.endIndex else {
            throw .truncatedStream
        }
        let first = data[position]
        position += 1
        if first < 0x80 {
            return UInt32(first)
        }
        let width: Int
        switch first {
        case 0x81: width = 2
        case 0x82: width = 4
        default: throw .invalidStringLength
        }
        guard width <= data.endIndex - position else {
            throw .invalidStringLength
        }
        var length: UInt32 = 0
        for offset in 0 ..< width {
            length |= UInt32(data[position + offset]) << (8 * offset)
        }
        position += width
        return length
    }
}
