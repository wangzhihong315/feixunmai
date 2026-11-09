import Foundation

/// 一条闪念胶囊在 Mac 侧的落盘记录。音频是手机录好的 WAV（16 kHz 单声道），
/// 元数据和转写文本放在同名 json 里，方便 MCP 直接读目录。
struct CapsuleMeta: Codable {
    let id: String
    let createdAt: Int64          // 毫秒时间戳
    let durationMs: Int64
    let fileName: String
    let sizeBytes: Int
    var text: String?
    var transcribedAt: Int64?
    /// 自动转写失败次数：同一段录音最多自动试 3 次，避免反复抢焦点。
    var attempts: Int?
}

/// 手机 BEGIN 帧里的元数据。
private struct CapsuleUpload: Codable {
    let id: String
    let createdAt: Int64
    let durationMs: Int64
    let size: Int
    let name: String?
}

final class CapsuleStoreMac {
    static let shared = CapsuleStoreMac()
    /// 新胶囊落盘后广播，转写队列据此决定什么时候开始工作。
    static let storedNotification = Notification.Name("VibeDeckCapsuleStored")

    private let fm = FileManager.default
    private let io = DispatchQueue(label: "vibedeck.capsules.io")

    private init() {}

    var rootURL: URL {
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("VibeDeck", isDirectory: true)
            .appendingPathComponent("capsules", isDirectory: true)
    }

    func prepare() {
        do {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            FileLog.write("capsules dir \(rootURL.path)")
        } catch {
            FileLog.write("capsules dir failed: \(error.localizedDescription)")
        }
        cleanupStaleParts()
    }

    func audioURL(_ id: String) -> URL {
        rootURL.appendingPathComponent("\(id).wav")
    }

    private func metaURL(_ id: String) -> URL {
        rootURL.appendingPathComponent("\(id).json")
    }

    func save(_ meta: CapsuleMeta, audio: Data, completion: @escaping (Bool) -> Void) {
        io.async {
            do {
                try audio.write(to: self.audioURL(meta.id), options: .atomic)
                let encoded = try JSONEncoder().encode(meta)
                try encoded.write(to: self.metaURL(meta.id), options: .atomic)
                FileLog.write(
                    "capsule stored \(meta.id) \(audio.count)B \(meta.durationMs)ms"
                )
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Self.storedNotification,
                        object: meta
                    )
                }
                completion(true)
            } catch {
                FileLog.write("capsule store failed \(meta.id): \(error.localizedDescription)")
                completion(false)
            }
        }
    }

    func all() -> [CapsuleMeta] {
        guard let names = try? fm.contentsOfDirectory(atPath: rootURL.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> CapsuleMeta? in
                let url = rootURL.appendingPathComponent(name)
                guard let data = fm.contents(atPath: url.path) else { return nil }
                return try? JSONDecoder().decode(CapsuleMeta.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func meta(id: String) -> CapsuleMeta? {
        guard let data = fm.contents(atPath: metaURL(id).path) else { return nil }
        return try? JSONDecoder().decode(CapsuleMeta.self, from: data)
    }

    func text(for id: String) -> String? {
        guard let meta = meta(id: id), let text = meta.text, !text.isEmpty else {
            return nil
        }
        return text
    }

    @discardableResult
    func setText(_ text: String, for id: String) -> Bool {
        guard var meta = meta(id: id) else { return false }
        meta.text = text
        meta.transcribedAt = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let data = try JSONEncoder().encode(meta)
            try data.write(to: metaURL(id), options: .atomic)
            FileLog.write("capsule text saved \(id) \(text.count)字")
            return true
        } catch {
            FileLog.write("capsule text save failed \(id): \(error.localizedDescription)")
            return false
        }
    }

    /// 还没转写的胶囊，按时间从旧到新排。
    /// 自动队列跳过已经失败 3 次的；手动"立即转写"可以 includeExhausted。
    func pendingTranscription(includeExhausted: Bool = false) -> [CapsuleMeta] {
        all()
            .filter { ($0.text ?? "").isEmpty }
            .filter { includeExhausted || ($0.attempts ?? 0) < 3 }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func incrementAttempts(for id: String) -> Int {
        guard var meta = meta(id: id) else { return 0 }
        let next = (meta.attempts ?? 0) + 1
        meta.attempts = next
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL(id), options: .atomic)
        }
        return next
    }

    func resetAttempts(for id: String) {
        guard var meta = meta(id: id) else { return }
        meta.attempts = 0
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL(id), options: .atomic)
        }
    }

    private func cleanupStaleParts() {
        guard let names = try? fm.contentsOfDirectory(atPath: rootURL.path) else {
            return
        }
        for name in names where name.hasSuffix(".part") {
            try? fm.removeItem(at: rootURL.appendingPathComponent(name))
        }
    }
}

/// 一次上传会话：BEGIN 记元数据，DATA 追加字节，END 校验长度后落盘。
/// 同一时刻只处理一个文件（手机也是顺序上传）。
final class CapsuleReceiver {
    static let shared = CapsuleReceiver()

    private var upload: CapsuleUpload?
    private var meta: CapsuleMeta?
    private var data = Data()
    private var active = false

    private init() {}

    @discardableResult
    func begin(_ json: Data) -> CapsuleMeta? {
        guard let upload = try? JSONDecoder().decode(CapsuleUpload.self, from: json),
              upload.size > 0,
              upload.size <= 32 * 1024 * 1024,
              !upload.id.isEmpty else {
            FileLog.write("capsule begin rejected (bad meta)")
            return nil
        }
        self.upload = upload
        let meta = CapsuleMeta(
            id: upload.id,
            createdAt: upload.createdAt,
            durationMs: upload.durationMs,
            fileName: "\(upload.id).wav",
            sizeBytes: upload.size,
            text: nil,
            transcribedAt: nil,
            attempts: nil
        )
        self.meta = meta
        data.removeAll(keepingCapacity: true)
        data.reserveCapacity(upload.size)
        active = true
        FileLog.write("capsule begin \(upload.id) expect=\(upload.size)B")
        return meta
    }

    func append(_ chunk: Data) {
        guard active else { return }
        data.append(chunk)
    }

    /// 长度对上才落盘；返回 nil 表示这次上传失败。
    func end(completion: @escaping (CapsuleMeta?) -> Void) {
        guard active, let meta, let upload else {
            reset()
            completion(nil)
            return
        }
        let received = data.count
        let audio = data
        reset()
        guard received == upload.size else {
            FileLog.write(
                "capsule end size mismatch \(meta.id) got=\(received) want=\(upload.size)"
            )
            completion(nil)
            return
        }
        CapsuleStoreMac.shared.save(meta, audio: audio) { ok in
            completion(ok ? meta : nil)
        }
    }

    func reset() {
        active = false
        upload = nil
        meta = nil
        data.removeAll()
    }
}
