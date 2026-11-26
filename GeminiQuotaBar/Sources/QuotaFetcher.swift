import Foundation

struct QuotaBucket: Decodable {
    let bucketId: String?
    let displayName: String?
    let window: String?
    let remainingFraction: Double?
    let resetTime: String?
    let description: String?
    let disabled: Bool?

    enum CodingKeys: String, CodingKey {
        case bucketId, bucket_id
        case displayName, display_name
        case window
        case remainingFraction, remaining_fraction
        case resetTime, reset_time
        case description
        case disabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucketId = try container.decodeIfPresent(String.self, forKey: .bucketId) ?? container.decodeIfPresent(String.self, forKey: .bucket_id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? container.decodeIfPresent(String.self, forKey: .display_name)
        window = try container.decodeIfPresent(String.self, forKey: .window)
        
        // remainingFraction can be Double, Float, Int, or String
        if let d = try? container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
            remainingFraction = d
        } else if let d = try? container.decodeIfPresent(Double.self, forKey: .remaining_fraction) {
            remainingFraction = d
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .remainingFraction), let d = Double(s) {
            remainingFraction = d
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .remaining_fraction), let d = Double(s) {
            remainingFraction = d
        } else {
            remainingFraction = nil
        }
        
        resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime) ?? container.decodeIfPresent(String.self, forKey: .reset_time)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
    }
}

struct QuotaGroup: Decodable {
    let displayName: String?
    let description: String?
    let buckets: [QuotaBucket]?

    enum CodingKeys: String, CodingKey {
        case displayName, display_name
        case description
        case buckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? container.decodeIfPresent(String.self, forKey: .display_name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        buckets = try container.decodeIfPresent([QuotaBucket].self, forKey: .buckets)
    }
}

struct QuotaResponseEnvelope: Decodable {
    let response: QuotaResponseData?
    let groups: [QuotaGroup]?
    
    enum CodingKeys: String, CodingKey {
        case response, groups
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        response = try container.decodeIfPresent(QuotaResponseData.self, forKey: .response)
        groups = try container.decodeIfPresent([QuotaGroup].self, forKey: .groups)
    }
}

struct QuotaResponseData: Decodable {
    let groups: [QuotaGroup]?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case groups, description
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decodeIfPresent([QuotaGroup].self, forKey: .groups)
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }
}

struct DaemonHubInfo: Decodable {
    let pid: Int?
    let httpPort: Int?
    let httpsPort: Int?
    let csrfToken: String?
}

struct ModelBucketInfo {
    let id: String
    let displayName: String
    let window: String
    let percent: Int
    let resetTime: String
    let description: String
}

struct ModelGroupInfo {
    let displayName: String
    let description: String
    var buckets: [ModelBucketInfo]
}

struct GeminiQuota {
    // Primary Gemini metrics
    var fiveHourPercent: Int = 100
    var weeklyPercent: Int = 100
    var fiveHourResetTime: String = ""
    var weeklyResetTime: String = ""
    var fiveHourDescription: String = ""
    var weeklyDescription: String = ""
    var lastUpdated: Date = Date()
    
    // Claude & GPT metrics
    var claudeFiveHourPercent: Int?
    var claudeWeeklyPercent: Int?
    var claudeWeeklyDescription: String?
    
    // Gemini 4 Argon metrics
    var argonWeeklyPercent: Int?
    var argonDescription: String?
    var argonResetTime: String?

    // All dynamic groups returned by the server
    var allGroups: [ModelGroupInfo] = []
}

class SelfSignedSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

class QuotaFetcher {
    static let shared = QuotaFetcher()
    
    private var cachedPort: Int?
    private var cachedScheme: String?
    private var cachedToken: String?
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 2.0
        self.session = URLSession(configuration: config, delegate: SelfSignedSessionDelegate(), delegateQueue: nil)
    }
    
    func fetchQuota(completion: @escaping (Result<GeminiQuota, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 1. Try cached credentials first
            if let port = self.cachedPort, let token = self.cachedToken {
                let scheme = self.cachedScheme ?? "http"
                if let quota = self.querySchemePort(scheme: scheme, port: port, token: token) {
                    DispatchQueue.main.async {
                        completion(.success(quota))
                    }
                    return
                }
            }
            
            // 2. Discover via active daemon files in ~/.gemini/antigravity/daemon/hub_*.json (fastest & standard in newer Antigravity)
            let daemonCandidates = self.findDaemonConfigs()
            for candidate in daemonCandidates {
                if let quota = self.querySchemePort(scheme: candidate.scheme, port: candidate.port, token: candidate.token) {
                    self.cachedPort = candidate.port
                    self.cachedScheme = candidate.scheme
                    self.cachedToken = candidate.token
                    DispatchQueue.main.async {
                        completion(.success(quota))
                    }
                    return
                }
            }
            
            // 3. Discover running processes (CLI args or env vars)
            let servers = self.findLanguageServerProcesses()
            for server in servers {
                var candidatePorts: [Int] = []
                if let p = server.port {
                    candidatePorts.append(p)
                }
                
                let lsofPorts = self.findListeningPorts(pid: server.pid)
                for lp in lsofPorts {
                    if !candidatePorts.contains(lp) {
                        candidatePorts.append(lp)
                    }
                }
                
                for port in candidatePorts {
                    for scheme in ["http", "https"] {
                        if let quota = self.querySchemePort(scheme: scheme, port: port, token: server.token) {
                            self.cachedPort = port
                            self.cachedScheme = scheme
                            self.cachedToken = server.token
                            DispatchQueue.main.async {
                                completion(.success(quota))
                            }
                            return
                        }
                    }
                }
            }
            
            DispatchQueue.main.async {
                completion(.failure(NSError(domain: "QuotaFetcher", code: 2, userInfo: [NSLocalizedDescriptionKey: "No se pudo conectar al endpoint de Antigravity"])))
            }
        }
    }
    
    private func querySchemePort(scheme: String, port: Int, token: String) -> GeminiQuota? {
        let endpoints = [
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            "/exa.language_server_pb.PredictionService/RetrieveUserQuotaSummary"
        ]
        
        for path in endpoints {
            guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else { continue }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
            request.httpBody = "{}".data(using: .utf8)
            
            let semaphore = DispatchSemaphore(value: 0)
            var resultQuota: GeminiQuota?
            
            let task = session.dataTask(with: request) { data, response, error in
                defer { semaphore.signal() }
                guard let data = data, error == nil else { return }
                
                do {
                    let decoded = try JSONDecoder().decode(QuotaResponseEnvelope.self, from: data)
                    let groups = decoded.groups ?? decoded.response?.groups
                    
                    if let groups = groups, !groups.isEmpty {
                        var quota = GeminiQuota()
                        var groupInfos: [ModelGroupInfo] = []
                        
                        for group in groups {
                            guard let gName = group.displayName, !gName.isEmpty else { continue }
                            var bucketInfos: [ModelBucketInfo] = []
                            
                            for bucket in group.buckets ?? [] {
                                let fraction = bucket.remainingFraction ?? 1.0
                                let percent = Int(round(fraction * 100))
                                let bId = bucket.bucketId ?? ""
                                let bWindow = bucket.window ?? ""
                                let bReset = bucket.resetTime ?? ""
                                let bDesc = bucket.description ?? ""
                                
                                var defaultName = "Límite"
                                if bWindow == "5h" || bId.contains("5h") || bWindow.contains("session") {
                                    defaultName = "Límite 5 Horas"
                                } else if bWindow == "weekly" || bId.contains("weekly") {
                                    defaultName = "Límite Semanal"
                                }
                                let bDisplayName = (bucket.displayName?.isEmpty == false) ? bucket.displayName! : defaultName
                                
                                let bInfo = ModelBucketInfo(
                                    id: bId,
                                    displayName: bDisplayName,
                                    window: bWindow,
                                    percent: percent,
                                    resetTime: bReset,
                                    description: bDesc
                                )
                                bucketInfos.append(bInfo)
                                
                                // 1. Main Gemini Models
                                if gName.contains("Gemini") && !gName.contains("Argon") {
                                    if bWindow == "5h" || bId.contains("5h") {
                                        quota.fiveHourPercent = percent
                                        quota.fiveHourResetTime = bReset
                                        quota.fiveHourDescription = bDesc
                                    } else if bWindow == "weekly" || bId.contains("weekly") {
                                        quota.weeklyPercent = percent
                                        quota.weeklyResetTime = bReset
                                        quota.weeklyDescription = bDesc
                                    }
                                }
                                // 2. Claude & GPT Models
                                else if gName.contains("Claude") || gName.contains("GPT") {
                                    if bWindow == "weekly" || bId.contains("weekly") {
                                        quota.claudeWeeklyPercent = percent
                                        quota.claudeWeeklyDescription = bDesc
                                    } else if bWindow == "5h" || bId.contains("5h") {
                                        quota.claudeFiveHourPercent = percent
                                    }
                                }
                                // 3. Gemini 4 Argon (when listed as separate group)
                                else if gName.contains("Argon") {
                                    quota.argonWeeklyPercent = percent
                                    quota.argonDescription = bDesc
                                    quota.argonResetTime = bReset
                                }
                            }
                            
                            groupInfos.append(ModelGroupInfo(
                                displayName: gName,
                                description: group.description ?? "",
                                buckets: bucketInfos
                            ))
                        }
                        
                        quota.allGroups = groupInfos
                        quota.lastUpdated = Date()
                        resultQuota = quota
                    }
                } catch {
                    // Ignore parse error on mismatching endpoint
                }
            }
            
            task.resume()
            _ = semaphore.wait(timeout: .now() + 1.5)
            
            if let quota = resultQuota {
                return quota
            }
        }
        
        return nil
    }
    
    private func findDaemonConfigs() -> [(port: Int, scheme: String, token: String)] {
        var candidates: [(port: Int, scheme: String, token: String)] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let daemonDir = home.appendingPathComponent(".gemini/antigravity/daemon")
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: daemonDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else {
            return []
        }
        
        // Sort files by modification date descending (newest first)
        let sortedFiles = files.filter { $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }
            .sorted { (url1, url2) -> Bool in
                let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                return date1 > date2
            }
        
        for fileUrl in sortedFiles {
            guard let data = try? Data(contentsOf: fileUrl),
                  let hub = try? JSONDecoder().decode(DaemonHubInfo.self, from: data),
                  let token = hub.csrfToken, !token.isEmpty else {
                continue
            }
            
            // Prefer httpPort, fallback httpsPort
            if let httpPort = hub.httpPort {
                candidates.append((port: httpPort, scheme: "http", token: token))
            }
            if let httpsPort = hub.httpsPort {
                candidates.append((port: httpsPort, scheme: "https", token: token))
            }
        }
        
        return candidates
    }
    
    private func findEnvCsrfToken(pid: String) -> String? {
        let psTask = Process()
        psTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        psTask.arguments = ["eww", "-p", pid]
        let pipe = Pipe()
        psTask.standardOutput = pipe
        do {
            try psTask.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            psTask.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            if let range = output.range(of: "ANTIGRAVITY_SERVER_CSRF_TOKEN=") {
                let sub = output[range.upperBound...]
                let token = sub.components(separatedBy: CharacterSet.whitespacesAndNewlines).first ?? ""
                if !token.isEmpty { return token }
            }
        } catch {}
        return nil
    }
    
    private func findLanguageServerProcesses() -> [(pid: String, token: String, port: Int?)] {
        var results: [(pid: String, token: String, port: Int?)] = []
        
        // 1. Try pgrep for agy, language_server, or language-server
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-fl", "agy|language_server|language-server"]
        let pipe = Pipe()
        task.standardOutput = pipe
        
        var output = ""
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            output = String(data: data, encoding: .utf8) ?? ""
        } catch {}
        
        // 2. Fallback to ps if pgrep gave nothing
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let psTask = Process()
            psTask.executableURL = URL(fileURLWithPath: "/bin/ps")
            psTask.arguments = ["-axo", "pid,command"]
            let psPipe = Pipe()
            psTask.standardOutput = psPipe
            do {
                try psTask.run()
                let data = psPipe.fileHandleForReading.readDataToEndOfFile()
                psTask.waitUntilExit()
                output = String(data: data, encoding: .utf8) ?? ""
            } catch {}
        }
        
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            // Filter to actual agy / language server processes
            guard trimmed.contains("agy") || trimmed.contains("language_server") || trimmed.contains("language-server") else { continue }
            
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard let first = parts.first, let _ = Int(first) else { continue }
            let pid = String(first)
            
            // Extract Token from CLI args
            var token = ""
            if let tokenRegex = try? NSRegularExpression(pattern: #"--csrf[-_]token[=\s]+([^\s"']+)"#) {
                let nsLine = line as NSString
                if let match = tokenRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
                   match.numberOfRanges > 1 {
                    token = nsLine.substring(with: match.range(at: 1))
                }
            }
            
            if token.isEmpty {
                for key in ["--csrf_token", "--csrf-token"] {
                    if let range = line.range(of: key) {
                        var sub = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                        if sub.hasPrefix("=") {
                            sub = String(sub.dropFirst()).trimmingCharacters(in: .whitespaces)
                        }
                        token = sub.components(separatedBy: " ").first?.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\"'"))) ?? ""
                        if !token.isEmpty { break }
                    }
                }
            }
            
            // If token not in CLI flags, check process environment variables
            if token.isEmpty {
                token = findEnvCsrfToken(pid: pid) ?? ""
            }
            
            guard !token.isEmpty else { continue }
            
            // Extract Port from command line if present (--hub-port=49203, --https_server_port=..., --port=...)
            var cmdPort: Int?
            if let portRegex = try? NSRegularExpression(pattern: #"--(?:hub-port|https_server_port|port)[=\s]+(\d+)"#) {
                let nsLine = line as NSString
                if let match = portRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
                   match.numberOfRanges > 1 {
                    cmdPort = Int(nsLine.substring(with: match.range(at: 1)))
                }
            }
            
            results.append((pid: pid, token: token, port: cmdPort))
        }
        
        return results
    }
    
    private func findListeningPorts(pid: String) -> [Int] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-p", pid, "-iTCP", "-sTCP:LISTEN", "-P", "-n"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            
            var ports: [Int] = []
            guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
            let nsOutput = output as NSString
            let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
            for match in matches {
                if match.numberOfRanges > 1 {
                    let portStr = nsOutput.substring(with: match.range(at: 1))
                    if let p = Int(portStr) {
                        ports.append(p)
                    }
                }
            }
            return ports
        } catch {
            return []
        }
    }
}
