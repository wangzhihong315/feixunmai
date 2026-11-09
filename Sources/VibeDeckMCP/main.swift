import Foundation

/// VibeDeck 的闪念胶囊 MCP 服务器（只读）。
///
/// 通过 stdio 走 JSON-RPC 2.0，向 Agent 暴露三个工具：
///   - list_capsules     最近的胶囊（可按未转写过滤）
///   - search_capsules   在转写文本里搜关键词
///   - get_capsule       按 id 取完整文本与音频路径
///
/// 数据目录与主 App 一致：
///   ~/Library/Application Support/VibeDeck/capsules/
/// 可用环境变量 VIBEDECK_CAPSULES_DIR 覆盖（方便测试）。

private struct CapsuleRecord: Decodable {
    let id: String
    let createdAt: Int64
    let durationMs: Int64
    let fileName: String
    let sizeBytes: Int?
    let text: String?
    let transcribedAt: Int64?
}

private struct ToolError: Error {
    let message: String
}

// MARK: - Storage

private func capsulesDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["VIBEDECK_CAPSULES_DIR"],
       !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let base = (try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    )) ?? URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support")
    return base
        .appendingPathComponent("VibeDeck", isDirectory: true)
        .appendingPathComponent("capsules", isDirectory: true)
}

private func loadCapsules() -> [CapsuleRecord] {
    let directory = capsulesDirectory()
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
        return []
    }
    let decoder = JSONDecoder()
    return names
        .filter { $0.hasSuffix(".json") }
        .compactMap { name -> CapsuleRecord? in
            let url = directory.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: url.path) else {
                return nil
            }
            return try? decoder.decode(CapsuleRecord.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
}

// MARK: - Formatting

private func isoString(_ milliseconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func durationSeconds(_ milliseconds: Int64) -> NSDecimalNumber {
    // 用 Decimal 输出，避免 6.2999999… 这种二进制浮点尾巴。
    NSDecimalNumber(string: String(format: "%.1f", Double(milliseconds) / 1000))
}

private func payload(_ record: CapsuleRecord, includeText: Bool = true) -> [String: Any] {
    let text = (record.text ?? "").isEmpty ? nil : record.text
    var object: [String: Any] = [
        "id": record.id,
        "createdAt": isoString(record.createdAt),
        "createdAtMs": record.createdAt,
        "durationSec": durationSeconds(record.durationMs),
        "transcribed": text != nil,
        "audioPath": capsulesDirectory().appendingPathComponent(record.fileName).path
    ]
    if includeText {
        object["text"] = text ?? NSNull()
    }
    if let transcribedAt = record.transcribedAt {
        object["transcribedAt"] = isoString(transcribedAt)
    }
    if let size = record.sizeBytes {
        object["sizeBytes"] = size
    }
    return object
}

private func snippet(_ text: String, query: String, radius: Int = 26) -> String {
    let lowered = text.lowercased()
    guard let range = lowered.range(of: query.lowercased()) else {
        return String(text.prefix(80))
    }
    let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
        ?? text.startIndex
    let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex)
        ?? text.endIndex
    var result = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    if start > text.startIndex { result = "…" + result }
    if end < text.endIndex { result += "…" }
    return result
}

private func encoded(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ) else {
        return "{}"
    }
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - Tools

private let tools: [[String: Any]] = [
    [
        "name": "list_capsules",
        "description": "列出最近的闪念胶囊（手机录下、Mac 已同步的语音笔记）。默认按时间倒序，最多 20 条。",
        "inputSchema": [
            "type": "object",
            "properties": [
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 200,
                    "description": "最多返回多少条，默认 20"
                ],
                "pending_only": [
                    "type": "boolean",
                    "description": "true = 只看还没转写的胶囊"
                ]
            ]
        ]
    ],
    [
        "name": "search_capsules",
        "description": "在所有胶囊的转写文本里按关键词搜索（忽略大小写），返回命中片段。",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "关键词或短语"
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100,
                    "description": "最多返回多少条，默认 20"
                ]
            ],
            "required": ["query"]
        ]
    ],
    [
        "name": "get_capsule",
        "description": "按 id 取一条胶囊：完整转写文本、录制时间、时长、音频文件路径。",
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": [
                    "type": "string",
                    "description": "胶囊 id，例如 cap_1794236354384"
                ]
            ],
            "required": ["id"]
        ]
    ]
]

private func runTool(_ name: String, arguments: [String: Any]) throws -> String {
    switch name {
    case "list_capsules":
        let limit = min(max(arguments["limit"] as? Int ?? 20, 1), 200)
        let pendingOnly = arguments["pending_only"] as? Bool ?? false
        let all = loadCapsules()
        let filtered = pendingOnly
            ? all.filter { ($0.text ?? "").isEmpty }
            : all
        let list = filtered.prefix(limit).map { payload($0) }
        let result: [String: Any] = [
            "total": all.count,
            "pending": all.filter { ($0.text ?? "").isEmpty }.count,
            "count": list.count,
            "capsules": Array(list)
        ]
        return encoded(result)

    case "search_capsules":
        guard let query = (arguments["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !query.isEmpty else {
            throw ToolError(message: "query 不能为空")
        }
        let limit = min(max(arguments["limit"] as? Int ?? 20, 1), 100)
        let lowered = query.lowercased()
        let matches = loadCapsules().compactMap { record -> [String: Any]? in
            guard let text = record.text, !text.isEmpty,
                  text.lowercased().contains(lowered) else {
                return nil
            }
            var object = payload(record)
            object["snippet"] = snippet(text, query: query)
            return object
        }
        let selected = Array(matches.prefix(limit))
        return encoded([
            "query": query,
            "count": selected.count,
            "matches": selected
        ])

    case "get_capsule":
        guard let id = (arguments["id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty else {
            throw ToolError(message: "id 不能为空")
        }
        guard let record = loadCapsules().first(where: { $0.id == id }) else {
            throw ToolError(message: "找不到胶囊 id=\(id)")
        }
        return encoded(payload(record))

    default:
        throw ToolError(message: "未知工具：\(name)")
    }
}

// MARK: - JSON-RPC

private func response(id: Any?, result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
}

private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
}

private func handle(_ request: [String: Any]) -> [String: Any]? {
    guard let method = request["method"] as? String else { return nil }
    let id = request["id"]
    let isNotification = id == nil

    switch method {
    case "initialize":
        return response(id: id, result: [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [String: Any](),
                "prompts": [String: Any]()
            ],
            "serverInfo": [
                "name": "vibedeck-capsules",
                "version": "0.1.0"
            ]
        ])

    case "notifications/initialized":
        return nil

    case "ping":
        return response(id: id, result: [:])

    case "tools/list":
        return response(id: id, result: ["tools": tools])

    case "prompts/list":
        return response(id: id, result: ["prompts": [
            [
                "name": "organize_inspirations",
                "title": "整理闪念胶囊里的灵感",
                "description": "读取最近的胶囊，按主题归纳用户的灵感，并询问下一步要推进什么、需要做哪些工作。",
                "arguments": []
            ]
        ]])

    case "prompts/get":
        let params = request["params"] as? [String: Any] ?? [:]
        guard params["name"] as? String == "organize_inspirations" else {
            return errorResponse(id: id, code: -32602, message: "Unknown prompt")
        }
        let prompt = """
        请先调用 list_capsules（limit 20）读取我最近的闪念胶囊。这些是我随手录下的灵感，不是待办清单。

        请按下面的方式帮我整理：
        1. 按主题归纳成 3–5 组，不要把每条录音逐条复述；
        2. 每组用一句话说清我想要什么、在担心什么或在期待什么，并引用 1–2 句我的原话和时间；
        3. 指出重复、矛盾或值得合并的想法；
        4. 最后问我：这些灵感里哪些是我现在真正想推进的？需要你围绕它做哪些工作（调研、方案、原型、写代码、拆任务），先做哪一个、交付物是什么？

        在我确认之前，不要直接开始执行，也不要把我的想法改写成你的结论。
        """
        return response(id: id, result: [
            "description": "整理灵感并追问下一步工作",
            "messages": [
                [
                    "role": "user",
                    "content": ["type": "text", "text": prompt]
                ]
            ]
        ])

    case "tools/call":
        let params = request["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text = try runTool(name, arguments: arguments)
            return response(id: id, result: [
                "content": [["type": "text", "text": text]],
                "isError": false
            ])
        } catch let error as ToolError {
            return response(id: id, result: [
                "content": [["type": "text", "text": "错误：\(error.message)"]],
                "isError": true
            ])
        } catch {
            return response(id: id, result: [
                "content": [["type": "text", "text": "错误：\(error.localizedDescription)"]],
                "isError": true
            ])
        }

    default:
        if isNotification { return nil }
        return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
    }
}

private func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

// MARK: - Main

FileHandle.standardError.write(
    Data("[VibeDeckMCP] reading \(capsulesDirectory().path)\n".utf8)
)

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        continue
    }
    if let reply = handle(object) {
        send(reply)
    }
}
