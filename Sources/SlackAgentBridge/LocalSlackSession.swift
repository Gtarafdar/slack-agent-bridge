import Foundation
import Security
import CommonCrypto
import SQLite3

/// Reads the Slack session that already exists on this Mac from the **Slack
/// desktop app** — no login window, no admin approval. It extracts:
///   - the `xoxc-` API token from the app's Local Storage (leveldb), and
///   - the `d` cookie from the app's Cookies database, decrypting it with the
///     "Slack Safe Storage" key from the macOS Keychain (Chromium scheme).
///
/// The first decryption triggers a one-time macOS Keychain "Allow" prompt; that
/// is a local permission, not a Slack login and not workspace admin approval.
enum LocalSlackSession {
    enum ExtractError: LocalizedError {
        case slackNotFound
        case tokenNotFound
        case cookieNotFound
        case keychainKeyNotFound
        case decryptFailed

        var errorDescription: String? {
            switch self {
            case .slackNotFound:
                return "Slack desktop app data not found. Install Slack and sign in."
            case .tokenNotFound:
                return "Couldn't find a Slack token. Open the Slack app and sign in, then retry."
            case .cookieNotFound:
                return "Couldn't find the Slack 'd' cookie. Make sure you're signed in to the Slack app."
            case .keychainKeyNotFound:
                return "Couldn't read the Slack Safe Storage key from Keychain. If macOS showed a Keychain prompt, click Always Allow and try Connect again."
            case .decryptFailed:
                return "Couldn't decrypt the Slack cookie."
            }
        }
    }

    /// Base directory of the Slack desktop app's data.
    private static var slackDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Slack", isDirectory: true)
    }

    static func isSlackInstalled() -> Bool {
        FileManager.default.fileExists(atPath: slackDir.path)
    }

    /// A workspace as stored locally by the Slack desktop app.
    struct LocalTeam {
        let id: String
        let name: String
        let url: String?
        let token: String
    }

    /// Reads the local Slack desktop session: the shared `d` cookie and every
    /// workspace (id, name, url, token) the Slack app has signed in. Everything
    /// comes from the app's own `localConfig_v2` — no network, no enumeration.
    ///
    /// Pass `reuseCookie` to skip decrypting Slack's Keychain cookie (avoids repeated
    /// "Slack Safe Storage" prompts during token-only refreshes).
    static func readSession(reuseCookie: String? = nil) throws -> (cookieHeader: String, teams: [LocalTeam]) {
        guard isSlackInstalled() else { throw ExtractError.slackNotFound }

        // Parse workspaces first (no Keychain needed) so this works fully offline.
        var teams = (try? readTeamsFromLocalConfig()) ?? []
        if teams.isEmpty {
            // Fallback: scan for raw tokens (identity resolved later via auth.test).
            teams = (try? readAllTokens())?.map {
                LocalTeam(id: $0, name: "", url: nil, token: $0)
            } ?? []
        }
        Log.info("localConfig parsed \(teams.count) team(s)")
        Log.debug("teams: \(teams.map { $0.name })")
        guard !teams.isEmpty else { throw ExtractError.tokenNotFound }

        let cookieHeader: String
        if let reuseCookie, !reuseCookie.isEmpty {
            cookieHeader = reuseCookie
        } else {
            cookieHeader = try readCookieHeader()
        }
        return (cookieHeader, teams)
    }

    // MARK: - Workspaces (from Local Storage leveldb `localConfig_v2`)

    /// Parses the Slack app's `localConfig_v2` blob out of its LevelDB store,
    /// decompressing Snappy-compressed SSTable blocks as needed, and returns
    /// every workspace with its token. This is the same data the Slack app uses
    /// to populate its workspace switcher.
    private static func readTeamsFromLocalConfig() throws -> [LocalTeam] {
        let leveldbDir = slackDir.appendingPathComponent("Local Storage/leveldb", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: leveldbDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var best: [LocalTeam] = []
        for file in entries {
            let ext = file.pathExtension
            guard let data = boundedData(at: file) else { continue }
            let bytes = [UInt8](data)

            // Collect candidate value buffers that hold the localConfig blob.
            var candidateValues: [[UInt8]] = []
            if ext == "ldb" || ext == "sst" {
                for block in sstableDataBlocks(bytes) {
                    for (key, value) in blockEntries(block)
                    where keyContains(key, "localConfig_v2") {
                        candidateValues.append(value)
                    }
                }
            }
            // WAL (.log) and any missed cases: scan raw bytes for the JSON blob.
            if ext == "log" || (candidateValues.isEmpty && (ext == "ldb" || ext == "sst")) {
                if let raw = extractLocalConfigRaw(bytes) { candidateValues.append(raw) }
            }

            for value in candidateValues {
                if let obj = parseJSONObject(value),
                   let teams = teamsFrom(obj), teams.count > best.count {
                    best = teams
                }
            }
        }
        return best
    }

    /// Builds `LocalTeam`s from a parsed localConfig object's `teams` map.
    private static func teamsFrom(_ obj: [String: Any]) -> [LocalTeam]? {
        guard let teams = obj["teams"] as? [String: Any] else { return nil }
        var result: [LocalTeam] = []
        for (tid, any) in teams {
            guard let t = any as? [String: Any],
                  let token = t["token"] as? String,
                  token.hasPrefix("xoxc") else { continue }
            let id = (t["id"] as? String) ?? tid
            let name = (t["name"] as? String) ?? ""
            let url: String?
            if let u = t["url"] as? String {
                url = u
            } else if let d = t["domain"] as? String {
                url = "https://\(d).slack.com/"
            } else {
                url = nil
            }
            result.append(LocalTeam(id: id, name: name, url: url, token: token))
        }
        return result.isEmpty ? nil : result
    }

    /// Decodes a Chrome localStorage value (0x00 => UTF-16LE, 0x01 => UTF-8)
    /// and parses the embedded JSON object.
    private static func parseJSONObject(_ value: [UInt8]) -> [String: Any]? {
        var jsonBytes: [UInt8]
        if let first = value.first, first == 0x00 {
            let count = (value.count - 1) / 2
            var units = [UInt16](); units.reserveCapacity(count)
            var i = 1
            while i + 1 < value.count {
                units.append(UInt16(value[i]) | (UInt16(value[i + 1]) << 8))
                i += 2
            }
            jsonBytes = Array(String(utf16CodeUnits: units, count: units.count).utf8)
        } else if let first = value.first, first == 0x01 {
            jsonBytes = Array(value.dropFirst())
        } else {
            jsonBytes = value
        }
        guard let brace = jsonBytes.firstIndex(of: 0x7B) else { return nil } // '{'
        let slice = Array(jsonBytes[brace...])
        return (try? JSONSerialization.jsonObject(with: Data(slice))) as? [String: Any]
    }

    /// Raw fallback: locate `localConfig_v2`, then extract the following balanced
    /// `{ ... }` JSON object directly from the byte buffer.
    private static func extractLocalConfigRaw(_ bytes: [UInt8]) -> [UInt8]? {
        let marker = Array("localConfig_v2".utf8)
        guard let mIdx = indexOf(bytes, marker) else { return nil }
        guard let brace = bytes[(mIdx + marker.count)...].firstIndex(of: 0x7B) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = brace
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if escaped { escaped = false }
                else if b == 0x5C { escaped = true }      // backslash
                else if b == 0x22 { inString = false }    // quote
            } else {
                if b == 0x22 { inString = true }
                else if b == 0x7B { depth += 1 }          // {
                else if b == 0x7D {                       // }
                    depth -= 1
                    if depth == 0 { return Array(bytes[brace...i]) }
                }
            }
            i += 1
        }
        return nil
    }

    private static func keyContains(_ key: [UInt8], _ needle: String) -> Bool {
        indexOf(key, Array(needle.utf8)) != nil
    }

    private static func indexOf(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let first = needle[0]
        var i = 0
        let limit = haystack.count - needle.count
        while i <= limit {
            if haystack[i] == first {
                var match = true
                var j = 1
                while j < needle.count {
                    if haystack[i + j] != needle[j] { match = false; break }
                    j += 1
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Minimal LevelDB SSTable reader (+ Snappy)

    private static let sstMagic: UInt64 = 0xdb47_7524_8b80_fb57

    /// Safety caps for parsing local files (defense-in-depth against malformed
    /// or oversized input; real Slack localConfig files are well under these).
    private static let maxFileBytes = 256 * 1024 * 1024
    private static let maxDecompressedBytes = 256 * 1024 * 1024

    /// Loads a file's bytes, skipping anything implausibly large.
    private static func boundedData(at url: URL) -> Data? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Returns the decompressed data blocks of a LevelDB `.ldb`/`.sst` file.
    private static func sstableDataBlocks(_ data: [UInt8]) -> [[UInt8]] {
        guard data.count >= 48 else { return [] }
        let footer = Array(data[(data.count - 48)...])
        var magic: UInt64 = 0
        for i in 0..<8 { magic |= UInt64(footer[40 + i]) << (8 * i) }
        guard magic == sstMagic else { return [] }

        var pos = 0
        guard varint(footer, &pos) != nil, varint(footer, &pos) != nil,   // metaindex handle
              let idxOff = varint(footer, &pos), let idxSize = varint(footer, &pos),
              let indexBlock = readBlock(data, offset: Int(idxOff), size: Int(idxSize))
        else { return [] }

        var blocks: [[UInt8]] = []
        for (_, handle) in blockEntries(indexBlock) {
            var hp = 0
            guard let off = varint(handle, &hp), let size = varint(handle, &hp),
                  let block = readBlock(data, offset: Int(off), size: Int(size)) else { continue }
            blocks.append(block)
        }
        return blocks
    }

    /// Reads a block (`size` bytes + 1 type byte + 4 CRC) and decompresses it.
    private static func readBlock(_ data: [UInt8], offset: Int, size: Int) -> [UInt8]? {
        // Overflow-safe bounds: need `size` bytes + 1 trailing type byte, so
        // both `offset` and `size` must individually fit before `data.count`.
        guard offset >= 0, size >= 0,
              offset < data.count, size < data.count - offset else { return nil }
        let raw = Array(data[offset..<offset + size])
        let type = data[offset + size]
        switch type {
        case 0: return raw                                   // uncompressed
        case 1: return snappyDecompress(raw)                 // snappy
        default: return nil                                  // zstd/other: skip
        }
    }

    /// Iterates the (key, value) entries of a LevelDB block (prefix-compressed).
    private static func blockEntries(_ block: [UInt8]) -> [(key: [UInt8], value: [UInt8])] {
        guard block.count >= 4 else { return [] }
        let numRestarts = Int(block[block.count - 4]) | (Int(block[block.count - 3]) << 8)
            | (Int(block[block.count - 2]) << 16) | (Int(block[block.count - 1]) << 24)
        let trailer = numRestarts * 4 + 4
        guard trailer <= block.count else { return [] }
        let body = Array(block[0..<(block.count - trailer)])

        var entries: [(key: [UInt8], value: [UInt8])] = []
        var idx = 0
        var key: [UInt8] = []
        while idx < body.count {
            guard let shared = varint(body, &idx),
                  let nonShared = varint(body, &idx),
                  let valueLen = varint(body, &idx) else { break }
            let sh = Int(shared), ns = Int(nonShared), vl = Int(valueLen)
            guard idx + ns <= body.count, sh <= key.count else { break }
            let delta = Array(body[idx..<idx + ns]); idx += ns
            key = Array(key[0..<sh]) + delta
            guard idx + vl <= body.count else { break }
            let value = Array(body[idx..<idx + vl]); idx += vl
            entries.append((key, value))
        }
        return entries
    }

    /// LEB128 varint decode.
    private static func varint(_ data: [UInt8], _ idx: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while idx < data.count {
            let b = data[idx]; idx += 1
            result |= UInt64(b & 0x7f) << shift
            if (b & 0x80) == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// Pure-Swift Snappy block decompression (no framing).
    private static func snappyDecompress(_ data: [UInt8]) -> [UInt8]? {
        var idx = 0
        // Declared uncompressed length; used as a hard cap so malformed input
        // can't make us allocate unbounded memory.
        guard let declared = varint(data, &idx) else { return nil }
        let maxOut = Int(min(declared, UInt64(maxDecompressedBytes)))
        var out: [UInt8] = []
        out.reserveCapacity(maxOut)
        let n = data.count
        while idx < n {
            let tag = data[idx]; idx += 1
            switch tag & 0x03 {
            case 0:
                var len = Int(tag >> 2)
                if len >= 60 {
                    let extra = len - 59
                    guard idx + extra <= n else { return nil }
                    var v = 0
                    for i in 0..<extra { v |= Int(data[idx + i]) << (8 * i) }
                    idx += extra
                    len = v
                }
                len += 1
                guard len >= 0, idx + len <= n, out.count + len <= maxOut else { return nil }
                out.append(contentsOf: data[idx..<idx + len])
                idx += len
            default:
                let t = tag & 0x03
                var copyLen = 0
                var offset = 0
                if t == 1 {
                    copyLen = Int((tag >> 2) & 0x07) + 4
                    guard idx < n else { return nil }
                    offset = (Int(tag >> 5) << 8) | Int(data[idx]); idx += 1
                } else if t == 2 {
                    copyLen = Int(tag >> 2) + 1
                    guard idx + 2 <= n else { return nil }
                    offset = Int(data[idx]) | (Int(data[idx + 1]) << 8); idx += 2
                } else {
                    copyLen = Int(tag >> 2) + 1
                    guard idx + 4 <= n else { return nil }
                    offset = Int(data[idx]) | (Int(data[idx + 1]) << 8)
                        | (Int(data[idx + 2]) << 16) | (Int(data[idx + 3]) << 24)
                    idx += 4
                }
                let start = out.count - offset
                guard offset > 0, start >= 0, out.count + copyLen <= maxOut else { return nil }
                for i in 0..<copyLen { out.append(out[start + i]) }
            }
        }
        return out
    }

    /// Fallback raw scan for `xoxc` tokens (used only if localConfig is absent).
    private static func readAllTokens() throws -> [String] {
        let leveldbDir = slackDir.appendingPathComponent("Local Storage/leveldb", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: leveldbDir, includingPropertiesForKeys: nil) else {
            throw ExtractError.tokenNotFound
        }
        guard let regex = try? NSRegularExpression(pattern: "xoxc-[0-9A-Za-z-]+") else {
            throw ExtractError.tokenNotFound
        }

        var seen = Set<String>()
        var tokens: [String] = []
        for file in entries where ["ldb", "log"].contains(file.pathExtension) {
            guard let data = boundedData(at: file) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range, in: text) {
                    let token = String(text[r])
                    if token.count > 12, !seen.contains(token) {
                        seen.insert(token)
                        tokens.append(token)
                    }
                }
            }
        }
        guard !tokens.isEmpty else { throw ExtractError.tokenNotFound }
        return tokens
    }

    // MARK: - Cookie (from Cookies SQLite, Chromium-encrypted)

    /// Returns a full Cookie header value, e.g. "d=xoxd-...; d-s=...".
    private static func readCookieHeader() throws -> String {
        let cookiesURL = slackDir.appendingPathComponent("Cookies", isDirectory: false)
        guard FileManager.default.fileExists(atPath: cookiesURL.path) else {
            throw ExtractError.cookieNotFound
        }

        // Copy the DB (+ WAL/SHM) to a temp location so we can read while Slack runs.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slackagent-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tmpDB = tmpDir.appendingPathComponent("Cookies")
        try? FileManager.default.copyItem(at: cookiesURL, to: tmpDB)
        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: cookiesURL.path + suffix)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(
                    at: src, to: URL(fileURLWithPath: tmpDB.path + suffix))
            }
        }

        let key = try safeStorageKey()

        // Slack needs BOTH `d` (the xoxd session) and `d-s` (session signature)
        // for authenticated requests. Read and decrypt whichever are present.
        let encrypted = readEncryptedCookies(dbPath: tmpDB.path, names: ["d", "d-s"])

        guard let dEncrypted = encrypted["d"] else { throw ExtractError.cookieNotFound }
        let dValue = try decryptCookieString(dEncrypted, key: key, expectXoxd: true)
        guard !dValue.isEmpty else { throw ExtractError.decryptFailed }

        var header = "d=\(dValue)"
        if let dsEncrypted = encrypted["d-s"],
           let dsValue = try? decryptCookieString(dsEncrypted, key: key, expectXoxd: false),
           !dsValue.isEmpty {
            header += "; d-s=\(dsValue)"
        }
        return header
    }

    /// Reads the `encrypted_value` BLOBs of the named cookies for a slack.com host.
    private static func readEncryptedCookies(dbPath: String, names: [String]) -> [String: Data] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT host_key, name, encrypted_value FROM cookies WHERE name IN ('d','d-s')"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var result: [String: Data] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            guard names.contains(name), let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 2))
            let data = Data(bytes: blob, count: len)
            // Prefer a slack.com host; otherwise keep the first seen.
            if host.contains("slack.com") || result[name] == nil {
                result[name] = data
            }
        }
        return result
    }

    /// Cached after first successful read so session refresh does not re-prompt.
    private static var cachedSafeStorageKey: Data?
    private static let safeStorageLock = NSLock()

    /// Reads the "Slack Safe Storage" key from the Keychain (one-time prompt per app launch).
    private static func safeStorageKey() throws -> Data {
        safeStorageLock.lock()
        if let cachedSafeStorageKey {
            let key = cachedSafeStorageKey
            safeStorageLock.unlock()
            return key
        }
        safeStorageLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Slack Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ExtractError.keychainKeyNotFound
        }

        safeStorageLock.lock()
        cachedSafeStorageKey = data
        safeStorageLock.unlock()
        return data
    }

    /// Decrypts a Chromium cookie value to a usable string.
    /// `expectXoxd` is true for the `d` cookie (value begins with "xoxd").
    private static func decryptCookieString(_ encrypted: Data, key: Data,
                                            expectXoxd: Bool) throws -> String {
        let plain = try decryptCookieBytes(encrypted, key: key)

        // Newer Chromium prepends a 32-byte SHA-256 domain hash to the plaintext.
        var candidates: [[UInt8]] = [plain]
        if plain.count > 32 { candidates.append(Array(plain.dropFirst(32))) }

        for bytes in candidates {
            let s = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
            if expectXoxd {
                if let range = s.range(of: "xoxd") {
                    return String(s[range.lowerBound...])
                }
            } else if isPrintableCookie(s) {
                return s
            }
        }
        throw ExtractError.decryptFailed
    }

    /// Decrypts a Chromium `v10` cookie value to raw (unpadded) bytes:
    /// PBKDF2(SHA1, salt="saltysalt", rounds=1003, len=16), then AES-128-CBC
    /// with a 16-byte space IV.
    private static func decryptCookieBytes(_ encrypted: Data, key passwordData: Data) throws -> [UInt8] {
        guard encrypted.count > 3 else { throw ExtractError.decryptFailed }
        let prefix = String(decoding: encrypted.prefix(3), as: UTF8.self)
        let payload: Data = prefix.hasPrefix("v") ? encrypted.dropFirst(3) : encrypted

        let salt = Array("saltysalt".utf8)
        var derivedKey = [UInt8](repeating: 0, count: 16)
        let password = [UInt8](passwordData)
        let kdfStatus = password.withUnsafeBufferPointer { pwPtr in
            salt.withUnsafeBufferPointer { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress?.withMemoryRebound(to: Int8.self, capacity: password.count) { $0 },
                    password.count,
                    saltPtr.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    &derivedKey, derivedKey.count
                )
            }
        }
        guard kdfStatus == kCCSuccess else { throw ExtractError.decryptFailed }

        let iv = [UInt8](repeating: 0x20, count: 16)
        let cipher = [UInt8](payload)
        var output = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var outLen = 0
        let cryptStatus = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            derivedKey, derivedKey.count,
            iv,
            cipher, cipher.count,
            &output, output.count,
            &outLen
        )
        guard cryptStatus == kCCSuccess else { throw ExtractError.decryptFailed }
        return Array(output.prefix(outLen))
    }

    private static func isPrintableCookie(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        // Printable ASCII, and never characters that would break/split a Cookie
        // header value: space, ';', ',', '"', and backslash.
        let forbidden: Set<Unicode.Scalar> = [" ", ";", ",", "\"", "\\"]
        return s.unicodeScalars.allSatisfy {
            $0.value >= 0x21 && $0.value < 0x7F && !forbidden.contains($0)
        }
    }
}
