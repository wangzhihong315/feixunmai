import Foundation
import Network

/// Local-network transport shared by two kinds of phone traffic:
///
///  - **voice**   — 16 kHz PCM stream while VibePad's voice link is Wi-Fi;
///  - **capsule** — flash-note WAV uploads and transcription text, available
///    over the LAN even when the voice link is Bluetooth.
///
/// One Bonjour service / one port serves both; a connection's role is decided
/// by the type of its first frame, so voice and capsule sync can run at the
/// same time without interfering.
///
/// Frame layout (little endian):
///   [version=1][type][seq][flags][len lo][len hi][payload…]
///   type 1 = PCM16 mono 16 kHz, 2 = control, 5 = capsule upload,
///   6 = capsule ack, 7 = capsule transcription text.
final class VoiceTCPServer {
    static let shared = VoiceTCPServer()

    static let port: UInt16 = 59321

    private final class Link {
        enum Role { case unknown, voice, capsule }
        let connection: NWConnection
        var buffer = Data()
        var role: Role = .unknown
        var lastRx = Date()
        var seq: UInt8 = 0

        init(_ connection: NWConnection) {
            self.connection = connection
        }
    }

    private var listener: NWListener?
    private var links: [ObjectIdentifier: Link] = [:]
    private var voiceLink: Link?
    private var heartbeat: Timer?
    private var lastStatusFlags: UInt8?

    private init() {}

    var isConnected: Bool {
        voiceLink?.connection.state == .ready
    }

    var statusText: String {
        isConnected ? "Wi-Fi 已连接" : "Wi-Fi 未连接"
    }

    func start() {
        guard listener == nil else { return }
        CapsuleStoreMac.shared.prepare()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let port = NWEndpoint.Port(rawValue: Self.port)!
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(
                name: "VibeDeck",
                type: "_vibedeck._tcp"
            )
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    FileLog.write("wifi listening on \(Self.port) (_vibedeck._tcp)")
                case .failed(let error):
                    FileLog.write("wifi listener failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            FileLog.write("wifi listener start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        for link in links.values {
            link.connection.cancel()
        }
        links.removeAll()
        voiceLink = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection

    private func accept(_ connection: NWConnection) {
        let link = Link(connection)
        links[ObjectIdentifier(connection)] = link
        FileLog.write("tcp link connecting")
        // 回调绑定到自己这条连接：旧连接 cancel 时的异步 .cancelled 不能
        // 影响刚建好的新连接（曾经导致 connect → ready → dropped 死循环）。
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection,
                  let link = self.links[ObjectIdentifier(connection)] else { return }
            switch state {
            case .ready:
                link.lastRx = Date()
                FileLog.write("tcp link ready (role pending)")
            case .failed(let error):
                FileLog.write("tcp link failed: \(error.localizedDescription)")
                self.drop(link)
            case .cancelled:
                self.drop(link)
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(link)
        startHeartbeat()
    }

    private func receive(_ link: Link) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, isComplete, error in
            guard let self, self.links[ObjectIdentifier(link.connection)] != nil else {
                return
            }
            if let data, !data.isEmpty {
                link.buffer.append(data)
                self.parse(link)
            }
            if isComplete || error != nil {
                self.drop(link)
                return
            }
            self.receive(link)
        }
    }

    private func drop(_ link: Link) {
        let key = ObjectIdentifier(link.connection)
        guard links.removeValue(forKey: key) != nil else { return }
        link.connection.cancel()
        if voiceLink === link {
            voiceLink = nil
            PhoneVoiceSession.shared.end(force: true, from: .wifi)
            PhoneAudioBridge.shared.resumeAfterWifi()
            FileLog.write("voice link dropped")
        } else {
            if link.role == .capsule {
                CapsuleReceiver.shared.reset()
            }
            FileLog.write("tcp link dropped (\(link.role))")
        }
    }

    private func parse(_ link: Link) {
        while link.buffer.count >= 6 {
            let header = [UInt8](link.buffer.prefix(6))
            guard header[0] == PhoneProtocol.version else {
                FileLog.write("tcp bad version \(header[0]) — resync")
                link.buffer.removeAll()
                return
            }
            let type = header[1]
            let length = Int(header[4]) | (Int(header[5]) << 8)
            guard length <= 65535 else {
                link.buffer.removeAll()
                return
            }
            guard link.buffer.count >= 6 + length else { return }
            // Data 的 startIndex 会随 removeFirst 前移，必须用 prefix 取相对区间，
            // 否则 subdata(in:) 的绝对下标会越界（EXC_BREAKPOINT）。
            let payload = Data(link.buffer.prefix(6 + length).dropFirst(6))
            link.buffer.removeFirst(6 + length)
            link.lastRx = Date()

            switch type {
            case PhoneProtocol.typeAudio, PhoneProtocol.typeControl:
                if link.role == .unknown { attachVoice(link) }
                guard link.role == .voice else { continue }
                if type == PhoneProtocol.typeAudio {
                    PhoneVoiceSession.shared.ingest(pcm16(payload), from: .wifi)
                } else if let op = payload.first {
                    handleControl(op)
                }
            case PhoneProtocol.typeCapsule:
                if link.role == .unknown { attachCapsule(link) }
                guard link.role == .capsule else { continue }
                handleCapsule(link, payload)
            default:
                break
            }
        }
    }

    private func attachVoice(_ link: Link) {
        if let old = voiceLink, old !== link {
            drop(old)
        }
        link.role = .voice
        voiceLink = link
        FileLog.write("voice link attached")
        PhoneAudioBridge.shared.suspendForWifi()
        send(link, type: PhoneProtocol.typeControl, payload: Data([PhoneProtocol.opReady]))
        sendStatus(force: true)
    }

    private func attachCapsule(_ link: Link) {
        link.role = .capsule
        FileLog.write("capsule link attached")
    }

    private func handleControl(_ op: UInt8) {
        FileLog.write(String(format: "wifi control op=0x%02x", op))
        switch op {
        case PhoneProtocol.opStart:
            PhoneVoiceSession.shared.begin(from: .wifi)
        case PhoneProtocol.opStop:
            PhoneVoiceSession.shared.end(force: false, from: .wifi)
        case PhoneProtocol.opHeartbeat:
            PhoneVoiceSession.shared.noteLinkActive(from: .wifi)
        default:
            break
        }
    }

    // MARK: - Capsules

    private func handleCapsule(_ link: Link, _ payload: Data) {
        guard let op = payload.first else { return }
        let body = Data(payload.dropFirst())
        switch op {
        case PhoneProtocol.capBegin:
            if CapsuleReceiver.shared.begin(body) == nil {
                sendAck(link, id: "", ok: false)
            }
        case PhoneProtocol.capData:
            CapsuleReceiver.shared.append(body)
        case PhoneProtocol.capEnd:
            CapsuleReceiver.shared.end { [weak self, weak link] meta in
                guard let self, let link else { return }
                self.sendAck(link, id: meta?.id ?? "", ok: meta != nil)
            }
        case PhoneProtocol.capQuery:
            guard let ids = try? JSONDecoder().decode([String].self, from: body) else {
                return
            }
            var sent = 0
            for id in ids {
                if let text = CapsuleStoreMac.shared.text(for: id) {
                    send(link, type: PhoneProtocol.typeCapsuleText, payload: textPayload(id, text))
                    sent += 1
                }
            }
            FileLog.write("capsule query \(ids.count) ids, \(sent) texts returned")
        default:
            break
        }
    }

    private func sendAck(_ link: Link, id: String, ok: Bool) {
        let dict: [String: Any] = ["id": id, "ok": ok]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        send(link, type: PhoneProtocol.typeCapsuleAck, payload: data)
        FileLog.write("capsule ack \(id) ok=\(ok ? 1 : 0)")
    }

    /// 转写完成后把文本推给在线的手机会话；手机不在线也没关系，
    /// 下次连上会用 capQuery 把文本补回去。
    func broadcastCapsuleText(id: String, text: String) {
        let payload = textPayload(id, text)
        for link in links.values where link.role == .capsule {
            send(link, type: PhoneProtocol.typeCapsuleText, payload: payload)
        }
    }

    private func textPayload(_ id: String, _ text: String) -> Data {
        let dict: [String: Any] = ["id": id, "text": text]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    // MARK: - Send

    private func send(_ link: Link, type: UInt8, payload: Data) {
        guard link.connection.state == .ready else { return }
        var frame = Data([
            PhoneProtocol.version,
            type,
            link.seq,
            0,
            UInt8(payload.count & 0xFF),
            UInt8((payload.count >> 8) & 0xFF)
        ])
        link.seq &+= 1
        frame.append(payload)
        link.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func sendControl(_ op: UInt8) {
        guard let link = voiceLink else { return }
        send(link, type: PhoneProtocol.typeControl, payload: Data([op]))
    }

    func sendStatus(force: Bool = false) {
        guard let link = voiceLink, isConnected else { return }
        let flags: UInt8 =
            (BridgeModel.shared.accessibilityGranted ? 0x01 : 0) |
            (KeyInterceptor.shared.tapActive ? 0x02 : 0)
        guard force || flags != lastStatusFlags else { return }
        lastStatusFlags = flags
        send(link, type: PhoneProtocol.typeControl, payload: Data([PhoneProtocol.opStatus, flags]))
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let voice = self.voiceLink {
                if Date().timeIntervalSince(voice.lastRx) > 6 {
                    FileLog.write("wifi heartbeat lost")
                    self.drop(voice)
                } else {
                    self.sendStatus()
                }
            }
            // 胶囊连接是短连：传完就该断，长时间没动静就回收。
            for link in self.links.values where link.role == .capsule {
                if Date().timeIntervalSince(link.lastRx) > 60 {
                    self.drop(link)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func pcm16(_ data: Data) -> [Int16] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var out = [Int16](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: UInt16.self)
            for index in 0..<count {
                out[index] = Int16(bitPattern: UInt16(littleEndian: pointer[index]))
            }
        }
        return out
    }
}
