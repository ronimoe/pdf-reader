import Compression
import Foundation

/// Decodes the stream filters the writer needs to read structure: cross-reference streams and
/// object streams. Only `/FlateDecode` (with PNG or TIFF predictors) is supported; content
/// streams are never decoded because the writer never touches them.
enum StreamDecoder {
    static func decode(_ stream: PDFStream) throws(PDFSaveError) -> [UInt8] {
        var filters: [PDFName] = []
        var parms: [PDFDictionary?] = []
        switch stream.dictionary["Filter"] {
        case nil, .null?: break
        case .name(let n)?:
            filters = [n]
            parms = [stream.dictionary["DecodeParms"]?.dictionaryValue]
        case .array(let items)?:
            filters = items.compactMap(\.nameValue)
            guard filters.count == items.count else { throw .malformed("bad /Filter array") }
            let p = stream.dictionary["DecodeParms"]?.arrayValue ?? []
            parms = filters.indices.map { $0 < p.count ? p[$0].dictionaryValue : nil }
        default:
            throw .malformed("bad /Filter")
        }
        var data = stream.rawData
        for (filter, parm) in zip(filters, parms) {
            switch filter.string {
            case "FlateDecode", "Fl":
                data = try inflate(data)
                data = try unpredict(data, parms: parm)
            default:
                throw .unsupported("stream filter /\(filter.string) in a structural stream")
            }
        }
        return data
    }

    /// zlib-wrapped DEFLATE. Apple's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951), so the two-byte
    /// zlib header is skipped and the Adler-32 trailer is ignored.
    static func inflate(_ input: [UInt8]) throws(PDFSaveError) -> [UInt8] {
        guard input.count >= 2 else { throw .malformed("Flate stream too short") }
        let cmf = input[0], flg = input[1]
        let hasHeader = cmf & 0x0F == 8 && (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0
        let body = hasHeader ? Array(input[2...]) : input
        if hasHeader, flg & 0x20 != 0 { throw .unsupported("Flate stream with preset dictionary") }
        let limit = outputLimit(forInput: input.count)

        var output: [UInt8] = []
        var exceeded = false
        let ok: Bool = body.withUnsafeBufferPointer { src in
            let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { streamPointer.deallocate() }
            guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return false }
            defer { compression_stream_destroy(streamPointer) }
            let chunk = 64 * 1024
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { dst.deallocate() }
            guard let base = src.baseAddress else { return false }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = src.count
            while true {
                streamPointer.pointee.dst_ptr = dst
                streamPointer.pointee.dst_size = chunk
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - streamPointer.pointee.dst_size
                output.append(contentsOf: UnsafeBufferPointer(start: dst, count: produced))
                if output.count > limit { exceeded = true; return false }
                switch status {
                case COMPRESSION_STATUS_END: return true
                case COMPRESSION_STATUS_OK:
                    // No progress and no input left means a truncated stream.
                    if produced == 0, streamPointer.pointee.src_size == 0 { return false }
                default: return false
                }
            }
        }
        if exceeded { throw .malformed("Flate stream inflates past \(limit) bytes") }
        guard ok else { throw .malformed("corrupt Flate stream") }
        return output
    }

    /// Structural streams (cross-reference and object streams) never need much expansion; a
    /// bigger ratio is a decompression bomb. 64× the input with a 1 MB floor, at most 256 MB.
    static func outputLimit(forInput count: Int) -> Int {
        let ceiling = 256 << 20
        let (scaled, overflow) = count.multipliedReportingOverflow(by: 64)
        return overflow ? ceiling : min(ceiling, max(scaled, 1 << 20))
    }

    static func unpredict(_ data: [UInt8], parms: PDFDictionary?) throws(PDFSaveError) -> [UInt8] {
        guard let parms, let predictor = parms["Predictor"]?.intValue, predictor > 1 else { return data }
        let colors = parms["Colors"]?.intValue ?? 1
        let bpc = parms["BitsPerComponent"]?.intValue ?? 8
        let columns = parms["Columns"]?.intValue ?? 1
        guard [1, 2, 4, 8, 16].contains(bpc), (1...32).contains(colors), (1...(1 << 20)).contains(columns) else {
            throw .malformed("bad predictor parameters /Colors \(colors) /BitsPerComponent \(bpc) /Columns \(columns)")
        }
        let bpp = max(1, colors * bpc / 8)
        let (bits, o1) = (colors * bpc).multipliedReportingOverflow(by: columns)
        let (padded, o2) = bits.addingReportingOverflow(7)
        guard !o1, !o2 else { throw .malformed("predictor row length overflows") }
        let rowLength = padded / 8
        guard rowLength <= data.count || data.isEmpty else {
            throw .malformed("predictor row of \(rowLength) bytes is longer than the data")
        }

        if predictor == 2 {
            guard bpc == 8 else { throw .unsupported("TIFF predictor with \(bpc) bits per component") }
            var out = data
            var row = 0
            while row + rowLength <= out.count {
                for i in bpp..<rowLength { out[row + i] = out[row + i] &+ out[row + i - bpp] }
                row += rowLength
            }
            return out
        }
        guard predictor >= 10 else { throw .unsupported("predictor \(predictor)") }

        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var previous = [UInt8](repeating: 0, count: rowLength)
        var i = 0
        while i < data.count {
            let filter = data[i]
            i += 1
            guard i + rowLength <= data.count else {
                // A short final row is tolerated only if it is padding.
                break
            }
            var row = Array(data[i..<i + rowLength])
            i += rowLength
            for x in 0..<rowLength {
                let left: Int = x >= bpp ? Int(row[x - bpp]) : 0
                let up = Int(previous[x])
                let upLeft: Int = x >= bpp ? Int(previous[x - bpp]) : 0
                let add: Int
                switch filter {
                case 0: add = 0
                case 1: add = left
                case 2: add = up
                case 3: add = (left + up) / 2
                case 4:
                    let p = left + up - upLeft
                    let pa = abs(p - left), pb = abs(p - up), pc = abs(p - upLeft)
                    add = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft)
                default:
                    throw .malformed("bad PNG predictor row filter \(filter)")
                }
                row[x] = UInt8(truncatingIfNeeded: Int(row[x]) + add)
            }
            out += row
            previous = row
        }
        return out
    }
}
