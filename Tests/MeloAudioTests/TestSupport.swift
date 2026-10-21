import Foundation
import Network

// MARK: - 测试用 WAV 生成

/// 生成合法的 16bit PCM WAV（默认 2 秒单声道 440Hz 正弦波），用于本地文件与 HTTP 流测试。
enum WAVFixture {
    static let sampleRate: UInt32 = 44_100

    static func makeWAVData(seconds: Double,
                            frequency: Double = 440.0,
                            sampleRate: UInt32 = WAVFixture.sampleRate,
                            amplitude: Double = 0.2) -> Data {
        let frameCount = max(1, Int((Double(sampleRate) * seconds).rounded()))
        var pcm = Data(capacity: frameCount * 2)
        for frame in 0..<frameCount {
            let t = Double(frame) / Double(sampleRate)
            let value = sin(2.0 * Double.pi * frequency * t) * amplitude
            let sample = Int16((max(-1.0, min(1.0, value)) * Double(Int16.max)).rounded())
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }

        return makeContainer(pcm: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
    }

    /// 用给定 16bit PCM 采样值生成 WAV（用于静音尾巴、卷积 IR 脉冲等测试信号）。
    static func makeWAVData(samples: [Int16],
                            sampleRate: UInt32 = WAVFixture.sampleRate,
                            channels: UInt16 = 1) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return makeContainer(pcm: pcm, sampleRate: sampleRate, channels: channels, bitsPerSample: 16)
    }

    /// 写一个由给定采样组成的临时 WAV 文件，调用方负责删除。
    static func writeTemporaryWAV(samples: [Int16],
                                  sampleRate: UInt32 = WAVFixture.sampleRate) throws -> URL {
        let data = makeWAVData(samples: samples, sampleRate: sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-audio-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func makeContainer(pcm: Data,
                              sampleRate: UInt32,
                              channels: UInt16,
                              bitsPerSample: UInt16) -> Data {
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        func u16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }

        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        ascii("RIFF")
        u32(UInt32(36 + pcm.count))
        ascii("WAVE")
        ascii("fmt ")
        u32(16)                 // PCM fmt chunk size
        u16(1)                  // PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        ascii("data")
        u32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    /// 写一个临时 WAV 文件，调用方负责删除。
    static func writeTemporaryWAV(seconds: Double = 2.0,
                                  frequency: Double = 440.0) throws -> URL {
        let data = makeWAVData(seconds: seconds, frequency: frequency)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-audio-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - 测试用本地 HTTP 音频服务器

/// 基于 Network.framework 的最小 HTTP/1.1 服务器，只服务一个 WAV 文件，支持 Range 请求。
/// 用于验证 AVPlayer 的远程 URL 流式播放（127.0.0.1，不访问外网）。
final class LocalHTTPServer {
    enum ServerError: Error, CustomStringConvertible {
        case startTimeout
        case listenerFailed(String)
        case invalidPort

        var description: String {
            switch self {
            case .startTimeout: return "本地 HTTP server 启动超时"
            case .listenerFailed(let message): return "本地 HTTP server 启动失败：\(message)"
            case .invalidPort: return "本地 HTTP server 未分配到端口"
            }
        }
    }

    private let payload: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cn.melo.tests.local-http-server")
    private let lock = NSLock()
    private let readySemaphore = DispatchSemaphore(value: 0)

    private(set) var port: UInt16 = 0
    private var connections: [NWConnection] = []
    private var isStopped = false
    private var startupError: Error?

    init(payload: Data) throws {
        self.payload = payload
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        self.listener = try NWListener(using: parameters, on: .any)
    }

    /// 启动并返回监听端口（阻塞等待 ready，最多 5 秒）。
    func start() throws -> UInt16 {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port?.rawValue {
                    self.port = port
                    self.readySemaphore.signal()
                } else {
                    self.startupError = ServerError.invalidPort
                    self.readySemaphore.signal()
                }
            case .failed(let error):
                self.startupError = ServerError.listenerFailed(String(describing: error))
                self.readySemaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        if readySemaphore.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw ServerError.startTimeout
        }
        if let startupError {
            listener.cancel()
            throw startupError
        }
        guard port != 0 else { throw ServerError.invalidPort }
        return port
    }

    func stop() {
        lock.lock()
        isStopped = true
        let pending = connections
        connections = []
        lock.unlock()
        for connection in pending { connection.cancel() }
        listener.cancel()
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        lock.lock()
        if isStopped {
            lock.unlock()
            connection.cancel()
            return
        }
        connections.append(connection)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeAll { $0 === connection }
        lock.unlock()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerRange.lowerBound], as: UTF8.self)
                self.respond(on: connection, requestHeader: header)
            } else if error != nil || isComplete || buffer.count > 128 * 1024 {
                connection.cancel()
                self.remove(connection)
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, requestHeader: String) {
        let lines = requestHeader.components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? "GET"
        let total = payload.count

        var start = 0
        var end = total - 1
        var isPartial = false
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            var spec = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if spec.hasPrefix("bytes=") { spec.removeFirst("bytes=".count) }
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, total > 0 else { continue }
            if let value = Int(parts[0]) { start = min(max(value, 0), total - 1) }
            if !parts[1].isEmpty, let value = Int(parts[1]), value >= start { end = min(value, total - 1) }
            isPartial = true
        }
        let length = end >= start ? end - start + 1 : 0

        var header = "HTTP/1.1 \(isPartial ? 206 : 200) \(isPartial ? "Partial Content" : "OK")\r\n"
        header += "Content-Type: audio/wav\r\n"
        header += "Content-Length: \(length)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Connection: close\r\n"
        if isPartial { header += "Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
        header += "\r\n"

        var response = Data(header.utf8)
        if method != "HEAD", length > 0 {
            response.append(payload.subdata(in: start..<(start + length)))
        }

        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.remove(connection)
        })
    }
}
