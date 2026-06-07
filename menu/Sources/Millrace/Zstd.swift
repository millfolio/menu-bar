import Foundation
import CZstd

/// In-process zstd decompression via the vendored, statically-linked decoder
/// (Sources/CZstd) — so unpacking a `.conda`'s `*.tar.zst` payloads needs no
/// system `zstd` binary or `libzstd.dylib` (macOS ships neither). We then hand
/// the plain (uncompressed) `.tar` to `/usr/bin/tar`, whose libarchive always
/// handles uncompressed tar with no optional filter.
enum Zstd {
    enum Failure: Error, CustomStringConvertible {
        case decode(String)
        var description: String { switch self { case .decode(let m): return "zstd decode: \(m)" } }
    }

    /// Stream-decompress `input` (a `.zst` file) to `output`, bounding memory to
    /// the compressed input plus one output chunk rather than the full payload.
    static func decompressFile(_ input: URL, to output: URL) throws {
        let comp = try Data(contentsOf: input)

        guard let ds = ZSTD_createDStream() else { throw Failure.decode("createDStream failed") }
        defer { ZSTD_freeDStream(ds) }
        _ = ZSTD_initDStream(ds)

        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: output.path) else {
            throw Failure.decode("cannot open \(output.lastPathComponent) for writing")
        }
        defer { try? fh.close() }

        let outCap = ZSTD_DStreamOutSize()
        var outChunk = Data(count: outCap)

        try comp.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }   // empty input
            var inBuf = ZSTD_inBuffer(src: base, size: raw.count, pos: 0)

            while inBuf.pos < inBuf.size {
                let produced = try outChunk.withUnsafeMutableBytes { (ob: UnsafeMutableRawBufferPointer) -> Int in
                    var outBuf = ZSTD_outBuffer(dst: ob.baseAddress, size: ob.count, pos: 0)
                    let ret = ZSTD_decompressStream(ds, &outBuf, &inBuf)
                    if ZSTD_isError(ret) != 0 {
                        throw Failure.decode(String(cString: ZSTD_getErrorName(ret)))
                    }
                    return outBuf.pos
                }
                if produced > 0 {
                    fh.write(outChunk.prefix(produced))
                } else if inBuf.pos < inBuf.size {
                    // No progress with input remaining → malformed frame; bail
                    // rather than spin forever.
                    throw Failure.decode("stalled before end of stream")
                }
            }
        }
    }
}
