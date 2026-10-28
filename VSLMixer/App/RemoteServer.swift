import Foundation
import Network

/// Lets phones control the mixer.  The control page (Remote/ in the app
/// bundle) is served over plain HTTP on `port`, and phones talk to the mixer
/// over a WebSocket on `port + 1`.  Traffic is tiny (fader moves and meters),
/// so everything runs on the main queue.
///
/// Protocol, all JSON text messages:
///   phone → mixer
///     {"t":"hello","role":"viewer"}                  just wants names
///     {"t":"hello","role":"aux","mix":N}             a musician's own mix
///     {"t":"hello","role":"board","code":"1234"}     whole board
///     {"t":"send","mix":M,"ch":C,"pos":P}            fader position 0…1
///     {"t":"master","mix":M,"pos":P}
///     {"t":"pan","mix":M,"ch":C,"pan":P}             −1 left … 1 right
///     {"t":"mute","ch":C,"on":B}                     board only
///     {"t":"channel","ch":C,"set":{"midDb":3,...}}   board only; see ChannelSettings.limits
///     {"t":"reset","ch":C,"what":"eq"|"comp"}        board only
///   mixer → phone
///     {"t":"state",...}   everything a page draws; sent on connect and on every change.
///                         Mix M drives out M+1, or with "stereo" outs M+1
///                         and M+2; each mix's "use" is "main", "aux" (a
///                         musician can take it) or "none" (the odd out of
///                         a linked pair).  "pans" only matter while stereo.
///     {"t":"m",...}       meters, 15 times a second
///     {"t":"denied"}      wrong passcode
@MainActor
final class RemoteServer {
    enum Role: Equatable {
        case pending, viewer, aux(Int), board
    }

    enum Status: Equatable {
        case off, starting
        case running(port: UInt16)
        case failed(String)
    }

    // Only ever touched on the main queue (every callback hops there first).
    private final class Client: @unchecked Sendable {
        let conn: NWConnection
        var role = Role.pending
        var inFlight = 0
        init(_ conn: NWConnection) { self.conn = conn }
    }

    private unowned let app: AppState
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var port: UInt16 = 0
    private var readyListeners = 0
    private var clients: [ObjectIdentifier: Client] = [:]
    private var flushScheduled = false

    private static let firstPort: UInt16 = 8080
    private static let files = [
        "index.html": "text/html; charset=utf-8",
        "remote.js": "text/javascript; charset=utf-8",
        "remote.css": "text/css; charset=utf-8",
    ]

    init(app: AppState) { self.app = app }

    /// Roles of connected phones that have said hello.
    var roles: [Role] { clients.values.map(\.role).filter { $0 != .pending && $0 != .viewer } }

    func start() {
        guard httpListener == nil else { return }
        listen(on: Self.firstPort)
    }

    func stop() {
        httpListener?.cancel(); wsListener?.cancel()
        httpListener = nil; wsListener = nil
        for c in clients.values { c.conn.cancel() }
        clients.removeAll()
        app.remoteStatus = .off
        app.remoteClientsChanged()
    }

    // MARK: listening

    private func listen(on p: UInt16) {
        guard p < Self.firstPort + 40 else {
            app.remoteStatus = .failed("No free network port")
            return
        }
        do {
            let http = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: p)!)
            let wsParams = NWParameters.tcp
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            wsParams.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            let ws = try NWListener(using: wsParams, on: NWEndpoint.Port(rawValue: p + 1)!)

            httpListener = http
            wsListener = ws
            port = p
            app.remoteStatus = .starting
            readyListeners = 0
            let onState: @Sendable (NWListener.State) -> Void = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.port == p else { return }
                    switch state {
                    case .ready:
                        self.readyListeners += 1
                        if self.readyListeners == 2 { self.app.remoteStatus = .running(port: p) }
                    case .failed:
                        // Almost always "address in use": try the next pair of ports.
                        self.httpListener?.cancel(); self.wsListener?.cancel()
                        self.httpListener = nil; self.wsListener = nil
                        self.port = 0
                        self.listen(on: p + 2)
                    default:
                        break
                    }
                }
            }
            // Advertising is also what makes macOS ask for Local Network
            // access.  Without that permission, replies to phones are
            // silently dropped even though the Mac itself can load the page.
            http.service = NWListener.Service(name: "VSL Mixer", type: "_http._tcp")
            http.stateUpdateHandler = onState
            ws.stateUpdateHandler = onState
            http.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.serveHTTP(conn) }
            }
            ws.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(conn) }
            }
            http.start(queue: .main)
            ws.start(queue: .main)
        } catch {
            listen(on: p + 2)
        }
    }

    private func serveHTTP(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            MainActor.assumeIsolated {
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                var path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
                let name = path == "/" ? "index.html" : String(path.dropFirst())

                var head: String
                var body: Data
                if let type = Self.files[name],
                   let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Remote"),
                   let contents = try? Data(contentsOf: url) {
                    head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nCache-Control: no-cache\r\n"
                    body = contents
                } else {
                    head = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
                    body = Data("Not found".utf8)
                }
                head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    // MARK: phones

    private func accept(_ conn: NWConnection) {
        let c = Client(conn)
        clients[ObjectIdentifier(c)] = c
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.drop(c)
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receive(c)
    }

    private func receive(_ c: Client) {
        c.conn.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, self.clients[ObjectIdentifier(c)] != nil else { return }
                if error != nil { self.drop(c); return }
                if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata, meta.opcode == .close {
                    self.drop(c); return
                }
                if let data, !data.isEmpty,
                   let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    self.handle(msg, from: c)
                }
                self.receive(c)
            }
        }
    }

    private func drop(_ c: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        c.conn.cancel()
        app.remoteClientsChanged()
    }

    private func send(_ obj: [String: Any], to c: Client, droppable: Bool = false) {
        if droppable && c.inFlight > 2 { return }   // a slow phone skips meter frames
        if c.inFlight > 200 { drop(c); return }       // and a stuck one gets dropped
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [meta])
        c.inFlight += 1
        c.conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                c.inFlight -= 1
                if error != nil { self?.drop(c) }
            }
        })
    }

    private func allowed(_ c: Client, mix: Int) -> Bool {
        switch c.role {
        case .board: return true
        case .aux(let m): return m == mix && app.session.isAux(m)
        default: return false
        }
    }

    private func handle(_ msg: [String: Any], from c: Client) {
        guard let type = msg["t"] as? String else { return }
        let num = { (key: String) -> Double? in (msg[key] as? NSNumber)?.doubleValue }
        let int = { (key: String) -> Int? in (msg[key] as? NSNumber)?.intValue }
        let clamp = { (v: Double) in min(1, max(0, v)) }

        switch type {
        case "hello":
            switch msg["role"] as? String {
            case "board":
                guard let code = msg["code"] as? String, code == app.session.remoteCode else {
                    c.role = .viewer
                    send(["t": "denied"], to: c)
                    send(stateMessage(board: false), to: c)
                    app.remoteClientsChanged()
                    return
                }
                c.role = .board
            case "aux":
                guard let m = int("mix"), app.session.isAux(m) else { c.role = .viewer; break }
                c.role = .aux(m)
            default:
                c.role = .viewer
            }
            send(stateMessage(board: c.role == .board), to: c)
            app.remoteClientsChanged()

        case "send":
            guard let m = int("mix"), let ch = int("ch"), let pos = num("pos"),
                  (0..<mixCount).contains(m), (0..<channelCount).contains(ch), allowed(c, mix: m) else { return }
            app.session.mixes[m].sends[ch] = clamp(pos)

        case "master":
            guard let m = int("mix"), let pos = num("pos"), (0..<mixCount).contains(m), allowed(c, mix: m) else { return }
            app.session.mixes[m].master = clamp(pos)

        case "pan":
            guard let m = int("mix"), let ch = int("ch"), let pan = num("pan"), pan.isFinite,
                  (0..<mixCount).contains(m), (0..<channelCount).contains(ch), allowed(c, mix: m) else { return }
            app.session.mixes[m].pans[ch] = min(1, max(-1, pan))

        case "mute":
            guard c.role == .board, let ch = int("ch"), (0..<channelCount).contains(ch),
                  let on = msg["on"] as? Bool else { return }
            app.session.channels[ch].muted = on

        case "channel":
            guard c.role == .board, let ch = int("ch"), (0..<channelCount).contains(ch),
                  let changes = msg["set"] as? [String: Any] else { return }
            var s = app.session.channels[ch]
            for (key, value) in changes {
                guard let (path, range) = ChannelSettings.limits[key],
                      let v = (value as? NSNumber)?.doubleValue, v.isFinite else { continue }
                s[keyPath: path] = min(range.upperBound, max(range.lowerBound, v))
            }
            app.session.channels[ch] = s

        case "reset":
            guard c.role == .board, let ch = int("ch"), (0..<channelCount).contains(ch) else { return }
            switch msg["what"] as? String {
            case "eq": app.session.channels[ch].flattenEQ()
            case "comp": app.session.channels[ch].linearComp()
            default: break
            }

        default:
            break
        }
    }

    // MARK: broadcasting

    /// Call on every session change; phones get one update per ~40 ms at most.
    func markDirty() {
        guard !flushScheduled, !clients.isEmpty else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushScheduled = false
                let viewer = self.stateMessage(board: false), board = self.stateMessage(board: true)
                for c in self.clients.values where c.role != .pending {
                    self.send(c.role == .board ? board : viewer, to: c)
                }
            }
        }
    }

    /// The passcode changed: phones showing the whole board must re-enter it.
    func revokeBoard() {
        for c in clients.values where c.role == .board {
            c.role = .viewer
            send(["t": "denied"], to: c)
            send(stateMessage(board: false), to: c)
        }
        app.remoteClientsChanged()
    }

    func broadcastMeters(_ meters: Meters) {
        guard clients.values.contains(where: { $0.role != .pending && $0.role != .viewer }) else { return }
        let r = { (v: Double) in (max(-120, v) * 10).rounded() / 10 }
        let msg: [String: Any] = [
            "t": "m",
            "in": meters.input.map(r),
            "mix": meters.mix.map(r),
            "gr": meters.gainReduction.map(r),
        ]
        for c in clients.values where c.role != .pending && c.role != .viewer {
            send(msg, to: c, droppable: true)
        }
    }

    private func stateMessage(board: Bool) -> [String: Any] {
        let s = app.session
        let r4 = { (v: Double) in (v * 10000).rounded() / 10000 }
        let hex = { (v: UInt32) in String(format: "#%06X", v) }
        let inputs: [[String: Any]] = s.channels.map { ch in
            var d: [String: Any] = ["name": ch.name, "muted": ch.muted]
            if board {
                var fx: [String: Double] = [:]
                for (key, (path, _)) in ChannelSettings.limits { fx[key] = ch[keyPath: path] }
                d["fx"] = fx
            }
            return d
        }
        let mixes: [[String: Any]] = s.mixes.enumerated().map { m, mix in
            ["name": mix.name, "outs": s.jacks(ofMix: m),
             "use": !s.shownMixes.contains(m) ? "none" : s.isAux(m) ? "aux" : "main",
             "stereo": s.isStereo(m),
             "sends": mix.sends.map(r4), "pans": mix.pans.map(r4), "master": r4(mix.master),
             "ground": hex(Theme.mixHex[m].ground), "ink": hex(Theme.mixHex[m].ink)]
        }
        return [
            "t": "state",
            "board": board,
            "inputs": inputs,
            "mixes": mixes,
            "taper": FaderScale.points.map { [$0.p, $0.db] },
        ]
    }

    // MARK: addresses

    /// IPv4 addresses phones could reach us on, best guess first: the Mac's
    /// own hotspot (Internet Sharing uses bridge interfaces), then Wi-Fi and
    /// Ethernet.
    static func localAddresses() -> [String] {
        var found: [(rank: Int, ip: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host), name = String(cString: ifa.ifa_name)
            if ip.hasPrefix("169.254.") { continue }   // link-local, not useful
            let rank = name.hasPrefix("bridge") ? 0 : name.hasPrefix("en") ? 1 : 2
            found.append((rank, ip))
        }
        return found.sorted { $0.rank < $1.rank }.map(\.ip)
    }
}
