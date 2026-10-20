// Agent Grove — macOS app: กระท่อมในป่าที่แสดงสถานะ AI agent ในเครื่องเป็นสัตว์
// - agent โปรเจกต์เดียวกันอยู่บ้านเดียวกัน ทำงานที่โต๊ะเดียวกัน
// - ฉากวาดด้วย Core Animation (render server วาดเอง → แอปแทบไม่ใช้ CPU), ส่วนรายละเอียดเป็น SwiftUI
import SwiftUI
import AppKit

// MARK: - ข้อมูล

enum AgentState: String { case working, blocked, waiting, idle }

struct Agent: Identifiable, Equatable {
    var id: String { subId.map { cwd + "#" + $0 } ?? cwd }
    var name: String
    var cwd: String
    var project: String
    var state: AgentState
    var tool: String?
    var prompt: String?
    var since: Double?   // ms
    var alive: Bool
    var subId: String? = nil   // ไม่ nil = subagent ที่ agent หลัก (cwd เดียวกัน) เรียกขึ้นมา
}

struct Project: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var name: String
    var agents: [Agent]
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let claudeSessions = home + "/.claude/sessions"
let orcaStatus = home + "/Library/Application Support/orca/agent-hooks/last-status.json"

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func pidAlive(_ pid: Any?) -> Bool {
    guard let n = pid as? Int, n > 0 else { return false }
    return kill(pid_t(n), 0) == 0
}

func basename(_ p: String) -> String { (p as NSString).lastPathComponent }

/// ชื่อโปรเจกต์: git worktree (.git เป็นไฟล์ "gitdir: <repo>/.git/worktrees/x") → ชื่อ repo หลัก, ไม่งั้นชื่อโฟลเดอร์
var projectCache: [String: String] = [:]
func projectName(_ cwd: String) -> String {
    if let p = projectCache[cwd] { return p }
    var name = basename(cwd)
    if let s = try? String(contentsOfFile: cwd + "/.git", encoding: .utf8), let r = s.range(of: "gitdir:") {
        let gitdir = s[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if let w = gitdir.range(of: "/.git/worktrees/") { name = basename(String(gitdir[..<w.lowerBound])) }
    }
    projectCache[cwd] = name
    return name
}

func collect() -> [Agent] {
    var agents: [String: Agent] = [:]  // key = cwd

    var sessions: [(cwd: String, id: String)] = []
    let files = (try? FileManager.default.contentsOfDirectory(atPath: claudeSessions)) ?? []
    for f in files where f.hasSuffix(".json") {
        guard let d = readJSON(claudeSessions + "/" + f), pidAlive(d["pid"]) else { continue }
        let cwd = d["cwd"] as? String ?? ""
        if let sid = d["sessionId"] as? String { sessions.append((cwd, sid)) }
        agents[cwd] = Agent(name: d["name"] as? String ?? basename(cwd), cwd: cwd, project: projectName(cwd),
                            state: (d["status"] as? String) == "busy" ? .working : .idle,
                            since: d["statusUpdatedAt"] as? Double, alive: true)
    }

    let entries = (readJSON(orcaStatus)?["entries"] as? [String: [String: Any]]) ?? [:]
    let nowMs = Date().timeIntervalSince1970 * 1000
    for e in entries.values {
        let cwd = (e["worktreeId"] as? String ?? "").components(separatedBy: "::").last ?? ""
        let p = e["payload"] as? [String: Any] ?? [:]
        var a: Agent
        if let existing = agents[cwd] {
            a = existing
        } else {
            // มีแค่ใน Orca (เช่น codex) — แสดงเฉพาะที่ไม่เก่าเกิน 30 นาที
            if nowMs - ((e["receivedAt"] as? Double) ?? 0) > 30 * 60 * 1000 { continue }
            a = Agent(name: basename(cwd).isEmpty ? "agent" : basename(cwd), cwd: cwd, project: projectName(cwd),
                      state: .idle, alive: false)
        }
        let state = p["state"] as? String
        // Claude session เป็นตัวจริงเรื่อง busy/idle; Orca ใช้เติม blocked/waiting + ชื่อ tool
        if state == "blocked" || state == "waiting" {
            a.state = AgentState(rawValue: state!)!
        } else if !a.alive, let s = state {
            a.state = s == "working" ? .working : .idle
        }
        a.tool = p["toolName"] as? String
        let prompt = (p["prompt"] as? String ?? "")
            .replacingOccurrences(of: "<[^>]+>", with: "…", options: .regularExpression)
        a.prompt = prompt.isEmpty ? nil : String(prompt.prefix(140))
        if let s = e["stateStartedAt"] as? Double { a.since = s }
        agents[cwd] = a
    }

    // agent หลักเรียงตามชื่อ แต่ละตัวตามด้วย subagent ของมัน
    var out: [Agent] = []
    for a in agents.values.sorted(by: { $0.name < $1.name }) {
        out.append(a)
        for s in sessions where s.cwd == a.cwd { out += runningSubagents(cwd: s.cwd, sessionId: s.id, project: a.project) }
    }
    return out
}

/// subagent ที่กำลังทำงาน: ~/.claude/projects/<cwd เข้ารหัส>/<session>/subagents/**/agent-*.meta.json
/// ยังไม่มี "finished": true และ transcript ถูกเขียนภายใน 3 นาที (บาง meta ไม่เคยถูกตั้ง finished)
func runningSubagents(cwd: String, sessionId: String, project: String) -> [Agent] {
    let enc = String(cwd.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    let dir = home + "/.claude/projects/\(enc)/\(sessionId)/subagents"
    guard let walker = FileManager.default.enumerator(atPath: dir) else { return [] }
    let now = Date()
    var subs: [Agent] = []
    while let rel = walker.nextObject() as? String {
        guard rel.hasSuffix(".meta.json") else { continue }
        let log = dir + "/" + rel.dropLast(".meta.json".count) + ".jsonl"
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: log))?[.modificationDate] as? Date,
              now.timeIntervalSince(mtime) < 180,
              let meta = readJSON(dir + "/" + rel), (meta["finished"] as? Bool) != true else { continue }
        let agentId = basename(String(rel.dropLast(".meta.json".count))).replacingOccurrences(of: "agent-", with: "")
        subs.append(Agent(name: meta["description"] as? String ?? meta["agentType"] as? String ?? "subagent",
                          cwd: cwd, project: project, state: .working, tool: lastTool(log),
                          prompt: meta["agentType"] as? String, since: mtime.timeIntervalSince1970 * 1000,
                          alive: true, subId: agentId))
    }
    return subs.sorted { $0.subId! < $1.subId! }
}

/// ชื่อ tool ล่าสุดใน transcript — อ่านแค่ท้ายไฟล์ 16KB (ไฟล์อาจใหญ่หลาย MB)
func lastTool(_ path: String) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    try? fh.seek(toOffset: size > 16384 ? size - 16384 : 0)
    guard let data = try? fh.readToEnd() else { return nil }
    let tail = String(decoding: data, as: UTF8.self)
    let re = try! NSRegularExpression(pattern: #""type":"tool_use","id":"[^"]+","name":"([^"]+)""#)
    guard let m = re.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last,
          let r = Range(m.range(at: 1), in: tail) else { return nil }
    return String(tail[r])
}

func group(_ agents: [Agent]) -> [Project] {
    Dictionary(grouping: agents) { $0.project.lowercased() }
        .map { Project(key: $0.key, name: $0.value[0].project, agents: $0.value) }
        .sorted { $0.key < $1.key }
}

// MARK: - Model

final class Zoo: ObservableObject {
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var now = Date()
    @Published var windowVisible = true
    @Published var mode = AnimalMode.saved {
        didSet {
            guard mode != oldValue else { return }
            AnimalMode.saved = mode
            (critters, babies) = loadCritters(mode); borrowed = [:]; critterOf = [:]
        }
    }
    private var timer: Timer?

    private let io = DispatchQueue(label: "agentzoo.io", qos: .utility)
    private var loading = false

    init() {
        refresh()
        // อ่านไฟล์ทุก 2 วิ; tolerance ให้ระบบรวบ wake-up ประหยัดไฟ
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 1
    }

    /// อ่านไฟล์นอก main thread: ถ้า macOS ถามสิทธิ์เข้าถึงข้อมูลแอปอื่น (Orca) หน้าต่างจะไม่ค้าง
    func refresh() {
        guard !loading else { return }
        loading = true
        io.async {
            let next = collect()
            DispatchQueue.main.async { [self] in
                loading = false
                if next != agents { releaseCritters(keeping: next); agents = next; projects = group(next) }  // publish เฉพาะตอนเปลี่ยน
                if windowVisible { now = Date() }  // ตัวเลข "x นาที" อัปเดตเฉพาะตอนหน้าต่างแสดงอยู่
            }
        }
    }

    /// นับเฉพาะ agent หลัก (subagent นับแยกเป็น "ผู้ช่วย")
    func count(_ s: AgentState) -> Int { agents.filter { $0.subId == nil && $0.state == s }.count }
    var mainCount: Int { agents.filter { $0.subId == nil }.count }
    var helperCount: Int { agents.count - mainCount }

    var menuTitle: String {
        var t = "🐾 \(count(.working))"
        if helperCount > 0 { t += "+\(helperCount)" }
        if count(.blocked) > 0 { t += " ❗\(count(.blocked))" }
        if count(.waiting) > 0 { t += " ❓\(count(.waiting))" }
        return t
    }
}

// MARK: - Sprites

struct Critter {
    let name: String
    var stand: String { name + "_stand" }
    var walk: String?, walk2: String?, alert: String?, sleep: String?, sit: String?
}

/// สัตว์ทั้งหมด = ทุกไฟล์ Sprites/<ชื่อ>_stand.png — เพิ่มสัตว์ใหม่แค่วางไฟล์แล้ว build
/// ท่าอื่นใช้ชื่อไฟล์ตามแบบเดียวกัน (ไม่มี → ใช้ท่ายืน):
///   <ชื่อ>_walk, <ชื่อ>_walk2  ก้าวเท้าสลับตอนเดิน
///   <ชื่อ>_alert               ตกใจ (รออนุญาต)
///   <ชื่อ>_sleep / <ชื่อ>_sit  พักผ่อน (ใช้ sleep ก่อน)
///   baby_<ชื่อ>_stand  ตัวเล็ก ใช้เป็น subagent
/// โหมดตัวละคร: สัตว์รวม (Sprites/) หรือสุนัขหลายสายพันธุ์ (Sprites/dogs/)
/// ฉาก เฟอร์นิเจอร์ และของในมือใช้ Sprites/ ร่วมกันทุกโหมด
enum AnimalMode: String, CaseIterable, Identifiable {
    case all, dogs
    var id: String { rawValue }
    var label: String { self == .all ? "🐾 สัตว์รวม" : "🐕 สุนัข" }
    var folder: String { self == .all ? "Sprites" : "Sprites/dogs" }
    static var saved: AnimalMode {
        get { AnimalMode(rawValue: UserDefaults.standard.string(forKey: "animalMode") ?? "") ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "animalMode") }
    }
}

/// อ่านสัตว์ทั้งหมดในโฟลเดอร์ของโหมด (ชื่อ Critter = "<โฟลเดอร์>/<ชื่อ>" เพื่อให้ sprite() หาไฟล์ถูกโฟลเดอร์)
func loadCritters(_ mode: AnimalMode) -> ([Critter], [Critter]) {
    let dir = Bundle.main.resourcePath.map { $0 + "/" + mode.folder } ?? ""
    let files = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) })
    let prefix = mode == .all ? "" : "dogs/"
    func has(_ n: String) -> String? { files.contains(n) ? prefix + n : nil }
    let all = files.filter { $0.hasSuffix("_stand") }.map { String($0.dropLast(6)) }.sorted().map {
        Critter(name: prefix + $0, walk: has($0 + "_walk"), walk2: has($0 + "_walk2"), alert: has($0 + "_alert"),
                sleep: has($0 + "_sleep"), sit: has($0 + "_sit"))
    }
    let adults = all.filter { !$0.name.contains("baby_") }, kids = all.filter { $0.name.contains("baby_") }
    if adults.isEmpty && mode == .dogs {
        // ยังไม่มีภาพชุดสุนัข → ใช้หมา/หมาป่าจากชุดรวมไปก่อน
        let base = loadCritters(.all)
        let dogs = base.0.filter { ["dog", "wolf"].contains($0.name) }
        return (dogs.isEmpty ? base.0 : dogs, base.1)
    }
    return (adults.isEmpty ? [Critter(name: "cat")] : adults, kids.isEmpty ? adults : kids)
}

var (critters, babies) = loadCritters(AnimalMode.saved)

func hashKey(_ s: String) -> Int { Int(s.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value } % 9973) }

/// สัตว์ประจำ agent: เรียงต่อกันภายในโปรเจกต์ → บ้านเดียวกันไม่ได้สัตว์ซ้ำ
/// ทะเบียนสัตว์ของ agent หลัก (key = cwd): ไม่ซ้ำชนิดกันทั้งหมู่บ้าน, ได้ตัวเดิมตลอดจน session ปิด
var critterOf: [String: Int] = [:]

/// คืนชนิดสัตว์ให้ทะเบียนเมื่อ agent ปิดไป (เรียกทุกครั้งที่รายชื่อเปลี่ยน)
func releaseCritters(keeping agents: [Agent]) {
    let alive = Set(agents.filter { $0.subId == nil }.map(\.cwd))
    critterOf = critterOf.filter { alive.contains($0.key) }
}

/// สัตว์ที่ agent ยืมไปทำงานอยู่ตอนนี้ (VillageLayerView ตั้งค่า) — ใช้แสดงในรายชื่อ
var borrowed: [String: Critter] = [:]

func critter(for agent: Agent, in project: Project) -> Critter {
    if let c = borrowed[agent.id] { return c }
    let idx: Int
    if let i = critterOf[agent.cwd] { idx = i } else {
        // เริ่มจาก hash ของ cwd (ตัวเดิมทุกครั้งที่เปิดแอป ถ้าว่าง) แล้วไล่หาชนิดที่ยังไม่มีใครใช้
        let used = Set(critterOf.values), start = hashKey(agent.cwd) % critters.count
        idx = (0..<critters.count).map { (start + $0) % critters.count }.first { !used.contains($0) } ?? start
        critterOf[agent.cwd] = idx
    }
    guard let sub = agent.subId else { return critters[idx] }
    return babies[(idx + hashKey(sub)) % babies.count]   // subagent = ตัวเล็ก
}

var imageCache: [String: CGImage] = [:]
func sprite(_ name: String) -> CGImage? {
    if let img = imageCache[name] { return img }
    // name อาจมีโฟลเดอร์ย่อย เช่น "dogs/shiba_stand" → Sprites/dogs/shiba_stand.png
    let sub = (name as NSString).deletingLastPathComponent, file = (name as NSString).lastPathComponent
    guard let url = Bundle.main.url(forResource: file, withExtension: "png", subdirectory: sub.isEmpty ? "Sprites" : "Sprites/" + sub),
          let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    imageCache[name] = img
    return img
}

/// emoji → CGImage สำหรับ ❗ ❓ 💤
func emojiImage(_ s: String, _ size: CGFloat) -> CGImage? {
    let key = "emoji:\(s)@\(size)"
    if let img = imageCache[key] { return img }
    let text = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size)])
    let box = text.size(), scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width * scale), pixelsHigh: Int(box.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = box
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    text.draw(at: .zero)
    NSGraphicsContext.restoreGraphicsState()
    imageCache[key] = rep.cgImage
    return rep.cgImage
}

/// ของในมือตามเครื่องมือที่ agent ใช้อยู่ (Sprites/item_*.png)
func toolProp(_ t: String?) -> String? {
    guard let t else { return nil }
    switch t {
    case "Bash": return "item_terminal"
    case "Read": return "item_book"
    case "Grep": return "item_magnifier"
    case "Glob": return "item_folder"
    case "Edit", "MultiEdit": return "item_toolbox"
    case "Write", "NotebookEdit": return "item_pencil"
    case "TodoWrite": return "item_clipboard"
    case "WebSearch", "WebFetch": return "item_globe"
    case "Agent", "Task": return "item_robot"
    default: return t.hasPrefix("mcp__") ? "item_plug" : "item_bulb"
    }
}

// MARK: - หมู่บ้าน (Core Animation)
//
// อาคารเดียว แบ่งจอ ซ้าย-ขวา:
//   🛋️ ห้องนั่งเล่น (ซ้าย) — ตัวที่พัก/รอคำสั่ง นั่งบนโซฟา (คนโปรเจกต์เดียวกันนั่งติดกัน)
//   ┃ ทางเดินกลาง ┃      — ประตูห้องนั่งเล่นอยู่ผนังขวา, ประตูห้องทำงานอยู่ผนังซ้าย
//   🏢 ห้องทำงาน (ขวา)   — โต๊ะประชุมยาวใช้ร่วมกันทุกโปรเจกต์ (ท็อปไม้ แถบขาว ขาเหล็ก เก้าอี้ตาข่าย)
// ตัวละครเดิน: ที่นั่ง → ทางเดินในห้อง → ประตู → ทางเดินกลาง → ประตูอีกห้อง → ที่นั่ง
// พิกัดในโค้ดเป็นแบบบน-ลง (top) แล้วแปลงเป็น y ของ CALayer ด้วย Y()

struct VillageLayout {
    static let roomTop: CGFloat = 76, corridorW: CGFloat = 40, side: CGFloat = 36, forestBottom: CGFloat = 64  // ขอบป่ารอบอาคาร

    let width: CGFloat, lounging: Int, seated: Int
    var corridorX: CGFloat { (width * 0.4).rounded() }
    private var rawLounge: Lounge { Lounge(left: Self.side, right: corridorX - Self.corridorW / 2, top: Self.roomTop, count: lounging) }
    private var rawHall: Hall { Hall(left: corridorX + Self.corridorW / 2, right: width - Self.side, top: Self.roomTop, seated: seated) }
    // สองห้องสูงเท่ากัน: ห้องที่เตี้ยกว่ายืดผนังหน้าลงมาเท่าห้องที่สูงกว่า
    var lounge: Lounge { var l = rawLounge; l.extra = max(0, rawHall.bottom - l.bottom); return l }
    var hall: Hall { var h = rawHall; h.extra = max(0, rawLounge.bottom - h.bottom); return h }
    var height: CGFloat { max(lounge.bottom, hall.bottom) + Self.forestBottom }
}

/// ห้องนั่งเล่น: ผนังหลัง (ทีวี/หน้าต่าง) → แถวโซฟา × n → ผนังหน้า; ประตูที่ผนังขวาระดับทางเดินแถวสุดท้าย
struct Lounge {
    static let pitch: CGFloat = 56, rowGap: CGFloat = 100
    let left: CGFloat, right: CGFloat, top: CGFloat, count: Int
    var extra: CGFloat = 0   // ยืดให้สูงเท่าห้องข้างๆ
    var perRow: Int { max(1, Int((right - left - 60) / Self.pitch)) }
    var rows: Int { max(1, (count + perRow - 1) / perRow) }
    func seatY(_ r: Int) -> CGFloat { top + 80 + extra / 2 + CGFloat(r) * Self.rowGap }
    func walkY(_ r: Int) -> CGFloat { seatY(r) + 34 }   // ใต้ป้ายชื่อกลุ่ม
    var doorY: CGFloat { walkY(rows - 1) }
    var bottom: CGFloat { top + 80 + CGFloat(rows - 1) * Self.rowGap + 34 + 20 + extra }
    var aisle: CGFloat { right - 22 }
    func seat(_ k: Int) -> (p: CGPoint, row: Int) {
        let r = k / perRow, i = k % perRow
        let pad = ((right - left - 40) - CGFloat(perRow) * Self.pitch) / 2
        return (CGPoint(x: left + 20 + pad + Self.pitch * (CGFloat(i) + 0.5), y: seatY(r)), r)
    }
    func contains(_ p: CGPoint) -> Bool { p.x > left && p.x < right && p.y > top && p.y < bottom }
    func row(of p: CGPoint) -> Int { (0..<rows).min { abs(seatY($0) - p.y) < abs(seatY($1) - p.y) } ?? 0 }
    /// ที่นั่ง → ทางเดินหน้าแถว → ทางเดินข้างขวา → ประตู (ผนังขวา)
    func exit(_ p: CGPoint) -> [CGPoint] {
        let r = row(of: p)
        var pts = [p, CGPoint(x: p.x, y: walkY(r))]
        if r < rows - 1 { pts += [CGPoint(x: aisle, y: walkY(r)), CGPoint(x: aisle, y: doorY)] }
        return pts + [CGPoint(x: right, y: doorY)]
    }
}

/// ห้องทำงาน: ผนังหลัง → [แถวหลัง → โต๊ะยาว → แถวหน้า] × จำนวนโต๊ะ → ผนังหน้า; ประตูที่ผนังซ้าย
/// ห้องทำงาน: โต๊ะเล็ก 2 ฝั่ง (ซ้าย/ขวา) ต่อแถว มีทางเดินคั่นกลาง; ต่อโต๊ะ = แถวหลัง + แถวหน้า; ประตูที่ผนังซ้าย
/// โต๊ะลำดับ t: แถว t/2, ฝั่ง t%2 (0 = ซ้าย, 1 = ขวา)
struct Hall {
    static let pitch: CGFloat = 40, tableGap: CGFloat = 120, midGap: CGFloat = 80
    let left: CGFloat, right: CGFloat, top: CGFloat, seated: Int
    var extra: CGFloat = 0   // ยืดให้สูงเท่าห้องข้างๆ
    private var span: CGFloat { (right - left - 92 - Self.midGap) / 2 }    // ความยาวโต๊ะหนึ่งฝั่ง
    func tableLeft(_ t: Int) -> CGFloat { left + 46 + (t % 2 == 0 ? 0 : span + Self.midGap) }
    func tableRight(_ t: Int) -> CGFloat { tableLeft(t) + span }
    var perSide: Int { max(1, Int((span - 16) / Self.pitch)) }
    var tables: Int { max(2, (seated + 2 * perSide - 1) / (2 * perSide)) }   // อย่างน้อย 1 แถว (2 ฝั่ง)
    var rows: Int { (tables + 1) / 2 }
    var midX: CGFloat { (tableRight(0) + tableLeft(1)) / 2 }               // ทางเดินกลางห้อง
    func tableBase(_ t: Int) -> CGFloat { top + 100 + extra / 2 + CGFloat(t / 2) * Self.tableGap }   // ห้องยืด → โต๊ะอยู่กึ่งกลาง
    func walkY(_ t: Int) -> CGFloat { tableBase(t) + 64 }   // ทางเดินหน้าแถวหน้า (ใต้ป้ายชื่อกลุ่ม)
    var doorY: CGFloat { walkY(tables - 1) }
    var bottom: CGFloat { top + 100 + CGFloat(rows - 1) * Self.tableGap + 64 + 20 + extra }
    var aisle: CGFloat { left + 24 }
    func seat(_ k: Int) -> (p: CGPoint, front: Bool, table: Int) {
        let t = k / (2 * perSide), r = k % (2 * perSide), front = r < perSide, i = r % perSide
        let pad = (span - CGFloat(perSide) * Self.pitch) / 2
        let x = tableLeft(t) + pad + Self.pitch * (CGFloat(i) + 0.5)
        return (CGPoint(x: x, y: front ? tableBase(t) + 28 : tableBase(t) - 28), front, t)  // แถวหลัง: โต๊ะบังแค่ช่วงล่าง
    }
    func contains(_ p: CGPoint) -> Bool { p.x > left && p.x < right && p.y > top && p.y < bottom }
    /// โต๊ะที่ใกล้จุดนี้ที่สุด (แถวตาม y, ฝั่งตาม x)
    func table(of p: CGPoint) -> Int {
        let row = (0..<rows).min { abs(tableBase($0 * 2) - p.y) < abs(tableBase($1 * 2) - p.y) } ?? 0
        return row * 2 + (p.x < midX ? 0 : 1)
    }
    /// ที่นั่ง → (แถวหลังอ้อมหัวโต๊ะฝั่งที่ใกล้) → ทางเดินหน้าแถว → ทางเดินข้างซ้าย → ประตู (ผนังซ้าย)
    func exit(_ p: CGPoint) -> [CGPoint] {
        let t = table(of: p)
        var pts = [p]
        if p.y < tableBase(t) {
            let ends = [tableLeft(t) - 22, tableRight(t) + 22]
            let ax = ends.min { abs($0 - p.x) < abs($1 - p.x) }!
            pts += [CGPoint(x: ax, y: p.y), CGPoint(x: ax, y: walkY(t))]
        } else { pts += [CGPoint(x: p.x, y: walkY(t))] }
        return pts + [CGPoint(x: aisle, y: walkY(t)), CGPoint(x: aisle, y: doorY), CGPoint(x: left, y: doorY)]
    }
}

enum Village {
    static let animalH: CGFloat = 46, walkSpeed: CGFloat = 110  // pt/วินาที
    static func height(_ width: CGFloat, _ projects: [Project]) -> CGFloat { layout(width, projects).height }
    /// ขนาดห้องคิดจากจำนวน agent ทั้งหมด (ไม่ใช่จำนวนที่อยู่ในห้องตอนนี้) → ที่นั่งไม่เลื่อนเมื่อมีคนเข้า-ออก
    static func layout(_ width: CGFloat, _ projects: [Project]) -> VillageLayout {
        let total = projects.reduce(0) { $0 + $1.agents.count }
        let mains = projects.reduce(0) { $0 + $1.agents.filter { $0.subId == nil }.count }   // subagent ไม่เคยเข้าห้องนั่งเล่น
        _ = mains
        return VillageLayout(width: width, lounging: 12, seated: total)   // ห้องนั่งเล่นขนาดคงที่ 12 ที่ — เต็มแล้วตัวที่กลับมาเดินออกไปเลย
    }
    /// สีประจำโปรเจกต์ (พรมใต้เท้า + ป้ายกลุ่ม)
    static let colors: [NSColor] = [
        NSColor(red: 0.29, green: 0.5, blue: 0.82, alpha: 1), NSColor(red: 0.85, green: 0.42, blue: 0.24, alpha: 1),
        NSColor(red: 0.3, green: 0.65, blue: 0.38, alpha: 1), NSColor(red: 0.62, green: 0.38, blue: 0.78, alpha: 1),
        NSColor(red: 0.8, green: 0.6, blue: 0.15, alpha: 1), NSColor(red: 0.2, green: 0.62, blue: 0.66, alpha: 1),
        NSColor(red: 0.8, green: 0.33, blue: 0.5, alpha: 1), NSColor(red: 0.45, green: 0.5, blue: 0.58, alpha: 1),
    ]
}

struct VillageView: NSViewRepresentable {
    let projects: [Project]
    let animate: Bool
    var mode = AnimalMode.saved
    func makeNSView(context: Context) -> VillageLayerView { VillageLayerView() }
    func updateNSView(_ v: VillageLayerView, context: Context) { v.update(projects, animate: animate, mode: mode) }
}

/// emoji วาดเล็กๆ แล้วขยายแบบ nearest → ได้ลุค pixel art เข้ากับ sprite
func pixelEmoji(_ s: String, _ px: Int) -> CGImage? {
    let key = "pixel:\(s)@\(px)"
    if let img = imageCache[key] { return img }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let text = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(px) * 0.8)])
    let t = text.size()
    text.draw(at: NSPoint(x: (CGFloat(px) - t.width) / 2, y: (CGFloat(px) - t.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    imageCache[key] = rep.cgImage
    return rep.cgImage
}

func spriteLayer(_ img: CGImage?, height h: CGFloat) -> CALayer {
    let l = CALayer()
    l.anchorPoint = CGPoint(x: 0.5, y: 0)  // วางที่ "เท้า"
    l.contentsGravity = .resizeAspect
    l.magnificationFilter = .nearest
    if let img {
        l.contents = img
        l.bounds = CGRect(x: 0, y: 0, width: CGFloat(img.width) * h / CGFloat(img.height), height: h)
    }
    return l
}

/// ป้ายไม้แบบเกม
func signLayer(fontSize: CGFloat = 11) -> CATextLayer {
    let s = CATextLayer()
    s.fontSize = fontSize; s.alignmentMode = .center; s.truncationMode = .end
    s.contentsScale = 2; s.cornerRadius = 5; s.anchorPoint = CGPoint(x: 0.5, y: 1)
    s.foregroundColor = NSColor.white.cgColor
    s.backgroundColor = NSColor(red: 0.36, green: 0.23, blue: 0.13, alpha: 0.92).cgColor
    s.borderColor = NSColor(red: 0.2, green: 0.12, blue: 0.06, alpha: 1).cgColor; s.borderWidth = 1.5
    return s
}

func setSign(_ s: CATextLayer, _ text: String, maxWidth: CGFloat) {
    s.string = " \(text) "
    let w = (" \(text) " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: s.fontSize)]).width + 10
    s.bounds = CGRect(x: 0, y: 0, width: min(maxWidth, w), height: s.fontSize + 5)
}

/// อิริยาบถตอนพัก: นอน / นั่งทำกิจกรรม (ไอคอนลอยข้างตัว) / ยืนบิดขี้เกียจ-มองรอบๆ
enum RestPose: Equatable {
    case sleep, sit(String), stretch
    static let activities = ["📖", "🎮", "☕", "🎧", "📱", "🍪"]
    static func random() -> RestPose {
        switch Int.random(in: 0..<10) {
        case 0..<4: return .sleep
        case 4..<8: return .sit(activities.randomElement()!)
        default: return .stretch
        }
    }
}

/// ตัวละคร 1 ตัว: root = ตำแหน่ง, body = ภาพ + ท่าวน, badge = 💤/❗/❓/ของในมือ
final class AgentLayer {
    let root = CALayer(), body = CALayer(), badge = CALayer()
    var critter: Critter
    var state: AgentState?
    var spot: CGPoint?, tool: String?, looping = false   // ค่าล่าสุดที่วาง — ไม่เปลี่ยน = ไม่แตะ animation
    var rest = RestPose.random(), shownRest: RestPose?    // ท่าพักในห้องนั่งเล่น (สุ่มเปลี่ยนเป็นระยะ)
    var agent: Agent?

    init(_ c: Critter) {
        critter = c
        root.anchorPoint = CGPoint(x: 0.5, y: 0)
        for l in [body, badge] {
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
            l.contentsGravity = .resizeAspect
            l.magnificationFilter = .nearest  // pixel art คมๆ
            root.addSublayer(l)
        }
    }

    var small = false   // subagent = ตัวเล็กกว่า
    var scale: CGFloat {
        guard let img = sprite(critter.stand) else { return 0.5 }
        return Village.animalH / CGFloat(img.height) * (small ? 0.72 : 1)
    }

    func show(_ name: String) {
        guard let img = sprite(name) else { return }
        body.contents = img
        body.bounds = CGRect(x: 0, y: 0, width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
        body.position = .zero
    }

    func setBadge(_ img: CGImage?, height: CGFloat) {
        badge.contents = img
        guard let img else { badge.bounds = .zero; return }
        badge.bounds = CGRect(x: 0, y: 0, width: CGFloat(img.width) * height / CGFloat(img.height), height: height)
        badge.position = CGPoint(x: 10, y: body.bounds.height + 2)
    }
}

final class VillageLayerView: NSView {
    private var agents: [String: AgentLayer] = [:]
    private var scenery: [CALayer] = []   // ห้อง เฟอร์นิเจอร์ — วาดใหม่เมื่อขนาด/จำนวนแถวเปลี่ยน
    private var sceneryKey = ""
    private var marks: [CALayer] = []     // พรมสีโปรเจกต์ + ป้ายกลุ่ม — วาดใหม่ทุกครั้งที่ที่นั่งเปลี่ยน
    private var projects: [Project] = []
    private var animate = false
    private var L = VillageLayout(width: 0, lounging: 0, seated: 0)

    private var restTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        // ทุก 20 วิ: ตัวที่พักอยู่ ~1 ใน 3 เปลี่ยนอิริยาบถ (ไม่เปลี่ยนพร้อมกันทั้งห้อง)
        restTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.shuffleRest() }
        restTimer?.tolerance = 5
    }

    private func shuffleRest() {
        guard animate else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let cap = L.lounge.rows * L.lounge.perRow
        // บางรอบ: ตัวว่างหนึ่งตัวเดินออกไป แล้วมีสัตว์ชนิดใหม่เดินเข้ามาแทน
        if Int.random(in: 0..<3) == 0, let out = poolIds.filter({ seats[$0]?.hall == false }).randomElement() {
            sendAway(out); place(walking: true)
        }
        for (id, al) in agents where al.state == .idle && !leaving.contains(id) && Int.random(in: 0..<3) == 0 {
            guard let a = al.agent, var spot = al.spot else { continue }
            var next = RestPose.random()
            while next == al.rest { next = .random() }
            al.rest = next
            // 1 ใน 3 ของตัวที่ขยับ: ลุกเดินไปนั่งโซฟาว่างตัวอื่น
            var walk = false
            if Int.random(in: 0..<3) == 0 {
                let taken = Set(seats.values.filter { !$0.hall }.map(\.k))
                if let k = (0..<cap).filter({ !taken.contains($0) }).randomElement() {
                    seats[id] = (false, k); spot = L.lounge.seat(k).p; walk = true
                }
            }
            apply(a, al, spot: spot, walking: walk)
        }
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var mode = AnimalMode.saved

    func update(_ projects: [Project], animate: Bool, mode: AnimalMode = AnimalMode.saved) {
        let motion = animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if mode != self.mode {   // เปลี่ยนโหมด → ล้างสัตว์ทั้งหมดแล้ววางชุดใหม่ทันที
            self.mode = mode
            agents.values.forEach { $0.root.removeFromSuperlayer() }
            agents = [:]; seats = [:]; owner = [:]; animalOf = [:]; leaving = []
            self.projects = projects; self.animate = motion
            place(walking: false); return
        }
        guard projects != self.projects || motion != self.animate else { return }
        self.projects = projects; self.animate = motion
        place(walking: motion)
    }

    private var lastSize = CGSize.zero
    // SwiftUI เรียก layout บ่อย (ทุกครั้งที่หน้ารีเฟรช) — จัดใหม่เฉพาะตอนขนาดเปลี่ยนจริง ไม่งั้นท่าเดินจะถูกตัด
    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        for al in agents.values { al.spot = nil }   // ขนาดเปลี่ยน → วางใหม่ทุกตัว (ไม่เดิน)
        place(walking: false)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); place(walking: false) }
    override func viewDidChangeEffectiveAppearance() { sceneryKey = ""; place(walking: false) }

    private func Y(_ top: CGFloat) -> CGFloat { bounds.height - top }
    private func P(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: Y(p.y)) }
    /// ของที่อยู่ล่างกว่า (ใกล้จอ) บังของที่อยู่บน
    private func depth(_ top: CGFloat) -> CGFloat { top / 10 }
    private var isNight: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: ฉาก

    private func drawScenery() {
        let lo = L.lounge, h = L.hall
        let key = "\(bounds.width)x\(bounds.height):\(lo.rows):\(h.tables):\(isNight):\(animate)"
        guard key != sceneryKey, let root = layer else { return }
        sceneryKey = key
        scenery.forEach { $0.removeFromSuperlayer() }; scenery = []
        func add(_ l: CALayer, z: CGFloat) { l.zPosition = z; root.addSublayer(l); scenery.append(l) }
        @discardableResult
        func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ hh: CGFloat, _ c: NSColor, z: CGFloat = -1, radius: CGFloat = 0) -> CALayer {
            let l = CALayer(); l.anchorPoint = CGPoint(x: 0, y: 1); l.cornerRadius = radius
            l.bounds = CGRect(x: 0, y: 0, width: w, height: hh); l.position = CGPoint(x: x, y: Y(top))
            l.backgroundColor = c.cgColor; add(l, z: z); return l
        }
        func deco(_ s: String, px: Int, h: CGFloat, x: CGFloat, top: CGFloat, z: CGFloat? = nil) {
            // วาด emoji ที่ 2 เท่าของขนาดบนจอ (Retina) → คมชัด ไม่แตกเป็นก้อน; px เดิมไม่ใช้แล้ว
            let l = spriteLayer(pixelEmoji(s, Int((h * 2.4).rounded())), height: h); l.position = CGPoint(x: x, y: Y(top)); add(l, z: z ?? depth(top))
            l.magnificationFilter = .linear
        }
        let n = isNight
        func c(_ day: (CGFloat, CGFloat, CGFloat), _ night: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            let v = n ? night : day; return NSColor(red: v.0, green: v.1, blue: v.2, alpha: 1)
        }
        // 🌲 ธีมป่า: พื้นหญ้า + ทางดิน + กระท่อมไม้ซุง (โหมดมืด = ป่ากลางคืน + หิ่งห้อย)
        root.backgroundColor = c((0.42, 0.6, 0.32), (0.1, 0.19, 0.13)).cgColor
        let corridor = c((0.62, 0.48, 0.32), (0.27, 0.21, 0.15))                               // ทางดิน
        let wall = c((0.55, 0.37, 0.21), (0.3, 0.2, 0.12)), wallTop = c((0.4, 0.25, 0.13), (0.22, 0.14, 0.08))   // ไม้ซุง
        var rng = UInt32(4242)
        func rand(_ k: Int) -> Int { rng = rng &* 1103515245 &+ 12345; return Int((rng >> 16) % UInt32(max(1, k))) }

        // ลายหญ้า: จุดเขียวเข้ม/อ่อนกระจายทั้งพื้น
        for _ in 0..<Int(bounds.width * L.height / 900) {
            let shade = rand(2) == 0 ? c((0.36, 0.53, 0.27), (0.08, 0.16, 0.1)) : c((0.5, 0.68, 0.38), (0.13, 0.23, 0.15))
            rect(CGFloat(rand(Int(bounds.width))), CGFloat(rand(Int(L.height))), 3 + CGFloat(rand(4)), 2, shade, z: -2)
        }

        // ┃ ทางเดินกลาง: ทางดิน + หินวางเป็นทางก้าว
        let cw = VillageLayout.corridorW
        rect(L.corridorX - cw / 2 + 4, L.lounge.top - 20, cw - 8, L.height - L.lounge.top, corridor, radius: 8)
        var ty = L.lounge.top
        while ty < L.height - 30 {
            rect(L.corridorX - 9 + CGFloat(rand(8)) - 4, ty, 18, 9, c((0.7, 0.68, 0.62), (0.32, 0.31, 0.3)), z: -0.9, radius: 4)
            ty += 34
        }

        // แนวป่า: ต้นไม้แถวบน (หลังอาคาร), แถวล่าง, ด้านข้าง + ของเล็กๆ บนพื้น
        let trees = ["🌲", "🌳", "🌲", "🌲", "🌳"]
        var tx: CGFloat = -10
        while tx < bounds.width + 10 {   // แถวบน 2 ชั้น
            deco(trees[rand(5)], px: 18, h: 46 + CGFloat(rand(14)), x: tx, top: 34 + CGFloat(rand(8)), z: -1.5)
            deco(trees[rand(5)], px: 18, h: 40 + CGFloat(rand(12)), x: tx + 22, top: 50 + CGFloat(rand(8)), z: -1.4)
            tx += 40 + CGFloat(rand(12))
        }
        tx = -6
        while tx < bounds.width + 10 {   // แถวล่าง
            let t = L.height - 8 - CGFloat(rand(10))
            deco(trees[rand(5)], px: 18, h: 44 + CGFloat(rand(16)), x: tx, top: t, z: depth(t) + 50)
            tx += 36 + CGFloat(rand(14))
        }
        var sy = L.lounge.top + 30
        while sy < L.height - 40 {        // ด้านข้าง
            for x in [CGFloat(14), bounds.width - 14] {
                deco(trees[rand(5)], px: 18, h: 40 + CGFloat(rand(10)), x: x + CGFloat(rand(8)) - 4, top: sy + CGFloat(rand(12)), z: depth(sy) + 40)
            }
            sy += 52
        }
        for _ in 0..<Int(bounds.width / 40) {   // เห็ด/ดอกไม้/หิน ข้างทางเดินและขอบป่า
            let side = VillageLayout.side
            let x = [L.corridorX - cw / 2 - 2, L.corridorX + cw / 2 + 2, CGFloat(rand(Int(side))), bounds.width - CGFloat(rand(Int(side)))][rand(4)]
            let t = [L.lounge.top + CGFloat(rand(Int(L.height - L.lounge.top - 20))), L.lounge.top - 6 - CGFloat(rand(8)), L.height - 30 - CGFloat(rand(10))][rand(3)]
            deco(["🍄", "🌼", "🌿", "🪨", "🌸", "🍀"][rand(6)], px: 10, h: 14, x: x, top: t, z: depth(t) + 45)
        }
        // หิ่งห้อยตอนกลางคืน: กะพริบช้าๆ (Core Animation วาดเอง)
        if n && animate {
            for k in 0..<10 {
                let f = CALayer(); f.bounds = CGRect(x: 0, y: 0, width: 3, height: 3); f.cornerRadius = 1.5
                f.backgroundColor = NSColor(red: 1, green: 0.95, blue: 0.5, alpha: 1).cgColor
                f.shadowColor = f.backgroundColor; f.shadowOpacity = 1; f.shadowRadius = 3; f.shadowOffset = .zero
                let fx = CGFloat(rand(Int(bounds.width))), fy = [CGFloat(20 + rand(50)), L.height - CGFloat(10 + rand(50))][k % 2]
                f.position = CGPoint(x: fx, y: Y(fy))
                let blink = CABasicAnimation(keyPath: "opacity"); blink.fromValue = 0; blink.toValue = 1
                let drift = CABasicAnimation(keyPath: "position"); drift.isAdditive = true
                drift.fromValue = NSValue(point: .zero); drift.toValue = NSValue(point: CGPoint(x: CGFloat(rand(30)) - 15, y: CGFloat(rand(20)) - 10))
                let g = CAAnimationGroup(); g.animations = [blink, drift]; g.duration = 2.5 + Double(rand(20)) / 10
                g.autoreverses = true; g.repeatCount = .infinity; g.beginTime = CACurrentMediaTime() + Double(rand(30)) / 10
                f.add(g, forKey: "glow"); add(f, z: 95)
            }
        }

        /// ห้อง: พื้น + ผนังหลัง + ผนังข้าง/หน้า (เว้นประตูที่ด้าน doorSide)
        func room(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat, floor: NSColor, doorY: CGFloat, doorOnRight: Bool) {
            let w = right - left, hh = bottom - top, zFront = depth(bottom) + 1
            rect(left, top, w, hh, floor, z: -0.6)
            var py = top + 24
            while py < bottom { rect(left, py, w, 1, floor.blended(withFraction: 0.18, of: .black)!, z: -0.59); py += 14 }   // แผ่นไม้กระดาน
            rect(left, top, w, 24, wall, z: -0.5); rect(left, top, w, 4, wallTop, z: -0.45)
            for ly in [top + 10, top + 17] { rect(left, ly, w, 1, wallTop, z: -0.44) }                 // ร่องไม้ซุง
            rect(left, bottom - 5, w, 5, wallTop, z: zFront)                                   // ผนังหน้า
            for (x, hasDoor) in [(left, !doorOnRight), (right - 5, doorOnRight)] {
                if hasDoor {   // เว้นช่องประตูกว้าง 34pt
                    rect(x, top, 5, doorY - 26 - top, wallTop, z: zFront)
                    rect(x, doorY + 8, 5, bottom - doorY - 8, wallTop, z: zFront)
                    rect(doorOnRight ? x : x - 4, doorY - 26, 9, 34, corridor, z: -0.55)        // ธรณีประตู
                } else { rect(x, top, 5, hh, wallTop, z: zFront) }
            }
        }

        // 🛋️ ห้องนั่งเล่น
        room(left: lo.left, right: lo.right, top: lo.top, bottom: lo.bottom, floor: c((0.8, 0.62, 0.42), (0.33, 0.25, 0.17)),
             doorY: lo.doorY, doorOnRight: true)
        /// วางภาพ (ยืนบนพื้นที่ top) สูง hh; z ตามความลึกถ้าไม่ระบุ
        @discardableResult
        func put(_ name: String, x: CGFloat, top: CGFloat, h hh: CGFloat, z: CGFloat? = nil) -> CALayer {
            let l = spriteLayer(sprite(name), height: hh); l.position = CGPoint(x: x, y: Y(top)); add(l, z: z ?? depth(top)); return l
        }
        let lw = lo.right - lo.left
        // พรมทอสี่เหลี่ยม (ธีมกระท่อมป่า): ขอบสองชั้น + ลายตารางกลาง + พู่ปลายสองด้าน — วาดเอง ไม่ยืดภาพ
        do {
            let rx = lo.left + 30, rw = lw - 60, rt = lo.top + 64, rh = lo.bottom - lo.top - 92, z: CGFloat = -0.55
            let base = c((0.45, 0.55, 0.38), (0.2, 0.27, 0.18)), cream = c((0.93, 0.87, 0.72), (0.42, 0.39, 0.32))
            let accent = c((0.74, 0.42, 0.28), (0.36, 0.2, 0.14)), dark = base.blended(withFraction: 0.3, of: .black)!
            for fx in stride(from: rx + 4, to: rx + rw - 2, by: 6) {              // พู่ซ้าย-ขวา (บน/ล่าง)
                rect(fx, rt - 5, 2, 5, cream, z: z); rect(fx, rt + rh, 2, 5, cream, z: z)
            }
            rect(rx, rt, rw, rh, dark, z: z, radius: 4)
            rect(rx + 4, rt + 4, rw - 8, rh - 8, cream, z: z + 0.001, radius: 3)
            rect(rx + 8, rt + 8, rw - 16, rh - 16, accent, z: z + 0.002, radius: 2)
            rect(rx + 12, rt + 12, rw - 24, rh - 24, base, z: z + 0.003, radius: 2)
            // ลายตารางจุดครีม
            var gy = rt + 24
            while gy < rt + rh - 18 {
                var gx = rx + 24 + (Int((gy - rt) / 20) % 2 == 0 ? 0 : 10)
                while gx < rx + rw - 22 { rect(gx, gy, 6, 6, cream.withAlphaComponent(0.55), z: z + 0.004, radius: 1); gx += 20 }
                gy += 20
            }
        }
        put("window", x: lo.left + lw * 0.22, top: lo.top + 44, h: 40, z: -0.4)
        put("picture", x: lo.left + lw * 0.78, top: lo.top + 30, h: 22, z: -0.4)
        put("tv_cabinet", x: lo.left + lw * 0.5, top: lo.top + 58, h: 40, z: -0.35)
        put("bookshelf", x: lo.left + 28, top: lo.top + 66, h: 50, z: -0.3)
        put("lamp", x: lo.right - 22, top: lo.top + 70, h: 48, z: -0.3)
        put("plant_big", x: lo.left + 22, top: lo.bottom - 6, h: 44)
        put("console", x: lo.left + lw * 0.5 + 34, top: lo.top + 66, h: 14, z: -0.3)
        // ที่นั่ง: โซฟาส้ม/โซฟาฟ้า/บีนแบ็ก สลับกัน — ตัวละครนั่งทับเบาะ (โซฟาอยู่ข้างหลัง)
        for k in 0..<(lo.rows * lo.perRow) {
            let s = lo.seat(k)
            put(["sofa_orange", "sofa_blue", "beanbag"][k % 3], x: s.p.x, top: s.p.y + 10, h: k % 3 == 2 ? 36 : 44, z: depth(s.p.y) - 0.3)
        }

        // 🏢 ห้องทำงาน
        room(left: h.left, right: h.right, top: h.top, bottom: h.bottom, floor: c((0.86, 0.74, 0.55), (0.36, 0.3, 0.22)),
             doorY: h.doorY, doorOnRight: false)
        put("tv", x: (h.left + h.right) / 2, top: h.top + 26, h: 26, z: -0.4)
        var wx = h.left + 60, wi = 0
        while wx < h.right - 40 {
            if abs(wx - (h.left + h.right) / 2) > 50 { deco(["🗓️", "🕒"][wi % 2], px: 12, h: 16, x: wx, top: h.top + 20, z: -0.4) }
            wx += 120; wi += 1
        }
        put("whiteboard", x: h.right - 34, top: h.top + 70, h: 52, z: -0.3)
        put("plant_office", x: h.left + 18, top: h.top + 62, h: 40, z: -0.3)
        put("watercooler", x: h.right - 22, top: h.bottom - 8, h: 44)

        // โต๊ะประชุมยาว: ชิ้นซ้าย + ชิ้นกลาง (ยืดตามความยาว) + ชิ้นขวา
        let TH: CGFloat = 60
        func tablePiece(_ name: String, x: CGFloat, width: CGFloat? = nil, slice: CGRect? = nil, base: CGFloat) {
            guard let img = sprite(name) else { return }
            let l = CALayer(); l.contents = img; l.magnificationFilter = .nearest; l.anchorPoint = .zero
            if let slice { l.contentsRect = slice }
            let w = width ?? CGFloat(img.width) * TH / CGFloat(img.height)
            l.bounds = CGRect(x: 0, y: 0, width: w, height: TH); l.position = CGPoint(x: x, y: Y(base))
            add(l, z: depth(base - 12))
        }
        for t in 0..<h.tables {
            let tb = h.tableBase(t), base = tb + 12
            let wl = sprite("table_left").map { CGFloat($0.width) * TH / CGFloat($0.height) } ?? 50
            let wr = sprite("table_right").map { CGFloat($0.width) * TH / CGFloat($0.height) } ?? 50
            let tl = h.tableLeft(t), tr = h.tableRight(t)
            tablePiece("table_left", x: tl, base: base)
            tablePiece("table_mid", x: tl + wl - 1, width: max(0, tr - tl - wl - wr + 2),
                       slice: CGRect(x: 0.35, y: 0, width: 0.3, height: 1), base: base)
            tablePiece("table_right", x: tr - wr, base: base)
            // ของบนโต๊ะ
            var px = tl + 34 + CGFloat(t % 2) * 20, pi = t
            while px < tr - 26 {
                put(["laptop", "papers", "mug"][pi % 3], x: px, top: tb - 22, h: [16, 12, 11][pi % 3], z: depth(tb) + 0.02)
                px += 74; pi += 1
            }
            // เก้าอี้: แถวหลังเห็นด้านหน้าเก้าอี้, แถวหน้าเห็นพนักพิง — อยู่หลังตัวละคร; หัวโต๊ะ 2 ตัว
            for k in 0..<(2 * h.perSide) {
                let s = h.seat(t * 2 * h.perSide + k)
                put(s.front ? "chair_back" : "chair_front", x: s.p.x, top: s.p.y + (s.front ? 4 : -2), h: 40, z: depth(s.p.y) - 0.2)
            }
            for x in [tl - 20, tr + 20] { put("chair_front", x: x, top: tb + 4, h: 40, z: depth(tb) - 0.1) }
        }

    }

    // MARK: วางตัวละคร

    // สัตว์ในฉาก (key = animal id) ไม่ได้ผูกกับ agent ตายตัว:
    //  - ตัวว่าง = นั่งเล่นในห้องนั่งเล่น (มีตัวใหม่เดินเข้า-ตัวเก่าเดินออกสลับกันเป็นระยะ)
    //  - agent เริ่มทำงาน → สุ่มตัวว่างในห้องนั่งเล่นลุกไปทำงานแทน; เลิกงาน → เดินกลับมาเป็นตัวว่าง
    //  - subagent → ลูกสัตว์ตัวใหม่เดินเข้ามา แล้วเดินออกไปเมื่องานจบ
    private var seats: [String: (hall: Bool, k: Int)] = [:]   // animal id → ที่นั่ง (จองจนเปลี่ยนห้อง)
    private var owner: [String: String] = [:]                  // animal id → agent id ที่ยืมไปทำงาน
    private var animalOf: [String: String] = [:]               // agent id → animal id
    private var leaving = Set<String>()
    private var nextAnimal = 0

    /// ที่นั่งข้างๆ (แถว/ฝั่งเดียวกัน)
    private func neighbors(_ k: Int, hall: Bool) -> [Int] {
        let seg = hall ? L.hall.perSide : L.lounge.perRow
        return [k - 1, k + 1].filter { $0 >= 0 && $0 / seg == k / seg }
    }

    private var entrance: CGPoint { CGPoint(x: L.corridorX, y: 8) }                 // ปลายทางเดินด้านบน (ในป่า)
    private var exitPoint: CGPoint { CGPoint(x: L.corridorX, y: L.height + 50) }   // ออกไปทางป่าด้านล่าง

    /// สร้างสัตว์ตัวใหม่ (ชนิดที่ยังไม่มีในฉาก); fromEntrance = เดินเข้ามาจากป่า
    private func spawn(baby: Bool, fromEntrance: Bool) -> String {
        let id = "animal-\(nextAnimal)"; nextAnimal += 1
        let used = Set(agents.filter { !leaving.contains($0.key) }.map { $0.value.critter.name })
        let pool = baby ? babies : critters
        let c = pool.filter { !used.contains($0.name) }.randomElement() ?? pool.randomElement()!
        let al = AgentLayer(c); al.small = baby
        layer?.addSublayer(al.root); agents[id] = al
        if fromEntrance { al.spot = entrance; al.root.position = P(entrance) }
        return id
    }

    /// ส่งสัตว์เดินออกไปทางป่า แล้วลบทิ้ง
    private func sendAway(_ id: String) {
        guard let al = agents[id], !leaving.contains(id) else { return }
        leaving.insert(id); seats[id] = nil
        if let ag = owner.removeValue(forKey: id) { animalOf[ag] = nil }
        let bye = Agent(name: "", cwd: id, project: "", state: .waiting, alive: true)
        apply(bye, al, spot: exitPoint, walking: animate && al.spot != nil)
        al.setBadge(nil, height: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + (animate ? 7.5 : 0)) { [weak self] in
            al.root.removeFromSuperlayer(); self?.agents[id] = nil; self?.leaving.remove(id)
        }
    }

    /// จำนวนตัวว่างที่อยากให้มีในห้องนั่งเล่น
    private func poolTarget() -> Int {
        let idleMains = projects.flatMap(\.agents).filter { $0.subId == nil && $0.state == .idle }.count
        return max(3, min(idleMains + 2, L.lounge.rows * L.lounge.perRow - 2))
    }

    private var poolIds: [String] { agents.keys.filter { owner[$0] == nil && !leaving.contains($0) }.sorted() }

    /// walking = ให้ตัวละครเดินไปตำแหน่งใหม่ (ไม่งั้นวางทันที)
    private func place(walking: Bool) {
        guard layer != nil, bounds.width > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        L = Village.layout(bounds.width, projects)
        drawScenery()
        marks.forEach { $0.removeFromSuperlayer() }; marks = []
        let cap = (lounge: L.lounge.rows * L.lounge.perRow, hall: L.hall.tables * 2 * L.hall.perSide)

        let flat = projects.flatMap { p in p.agents.map { (p, $0) } }
        // ตัวที่ต้องมีตัวละครในห้องทำงาน: agent หลักที่ไม่ได้พัก (ทำงาน/รออนุญาต/รอคำสั่ง) + subagent
        let active = flat.filter { $0.1.subId != nil || $0.1.state != .idle }
        let mains = active.filter { $0.1.subId == nil }, subs = active.filter { $0.1.subId != nil }
        let activeIds = Set(active.map(\.1.id))
        let agentById = Dictionary(active.map { ($0.1.id, $0) }) { a, _ in a }

        // 1) เลิกงาน: agent หลัก → สัตว์เดินกลับห้องนั่งเล่น; subagent → ลูกสัตว์เดินออกไป
        for (aid, ag) in owner where !activeIds.contains(ag) {
            let loungeFull = seats.values.filter { !$0.hall }.count >= cap.lounge - 1   // เผื่อ 1 ที่ไว้ลุกสลับ
            if agents[aid]?.small == true || loungeFull { sendAway(aid) }               // ไม่มีที่นั่ง → เดินออกไปเลย
            else { owner[aid] = nil; animalOf[ag] = nil; seats[aid] = nil }
        }
        // 2) เริ่มงาน: สุ่มตัวว่างในห้องนั่งเล่นออกไปทำ (ไม่มีตัวว่าง → ตัวใหม่เดินเข้ามา)
        for (_, a) in mains + subs where animalOf[a.id] == nil {
            let aid: String
            if a.subId == nil, let pick = poolIds.filter({ seats[$0]?.hall == false }).randomElement() ?? poolIds.randomElement() {
                aid = pick
            } else { aid = spawn(baby: a.subId != nil, fromEntrance: walking) }
            owner[aid] = a.id; animalOf[a.id] = aid; seats[aid] = nil
            borrowed[a.id] = agents[aid]?.critter
        }
        // 3) รักษาจำนวนตัวว่างในห้องนั่งเล่น
        let target = poolTarget()
        var pool = poolIds
        while pool.count < target { pool.append(spawn(baby: false, fromEntrance: walking)) }
        if pool.count > target + 1, let extra = pool.filter({ seats[$0]?.hall == false }).randomElement() ?? pool.last {
            sendAway(extra)
        }

        // 4) ที่นั่ง: คืนที่ที่เปลี่ยนห้อง/เกินความจุ แล้วจัดที่ให้ตัวที่ยังไม่มี
        let projectOf = Dictionary(owner.compactMap { aid, ag in agentById[ag].map { (aid, $0.0.key) } }) { a, _ in a }
        let inHall = { (aid: String) in self.owner[aid] != nil }
        seats = seats.filter { aid, s in agents[aid] != nil && !leaving.contains(aid) && inHall(aid) == s.hall
                               && s.k < (s.hall ? cap.hall : cap.lounge) }
        let order = poolIds + mains.compactMap { animalOf[$0.1.id] } + subs.compactMap { animalOf[$0.1.id] }   // ตัวหลักเลือกก่อนลูก
        for aid in order where seats[aid] == nil {
            let hall = inHall(aid)
            let taken = Set(seats.values.filter { $0.hall == hall }.map(\.k))
            var near: [Int] = [], isFront = { (_: Int) in true }
            if hall, let ag = owner[aid], let (p, a) = agentById[ag] {
                let mates = seats.filter { projectOf[$0.key] == p.key && $0.value.hall }.map(\.value.k)
                // subagent ตัวเล็ก → นั่งแถวหน้าเท่านั้น (แถวหลังโต๊ะบังมิด): ตรงข้าม/ข้างตัวหลักก่อน
                let side = L.hall.perSide
                func front(_ k: Int) -> Int { k / (2 * side) * 2 * side + k % side }
                let byParent: [Int] = a.subId == nil ? [] : animalOf[a.cwd].flatMap { seats[$0] }.map { s in
                    let f = front(s.k); return s.k == f ? neighbors(f, hall: true) : [f] + neighbors(f, hall: true)
                } ?? []
                if a.subId != nil { isFront = { $0 % (2 * side) < side } }
                near = (byParent.contains { !taken.contains($0) } ? byParent : mates.flatMap { neighbors($0, hall: true) })
                    .filter { !taken.contains($0) && isFront($0) }
            }
            let free = (0..<(hall ? cap.hall : cap.lounge)).filter { !taken.contains($0) && isFront($0) }
            if let k = near.randomElement() ?? free.randomElement() { seats[aid] = (hall, k) }
        }

        // 5) วาง/เดิน
        let colorOf = Dictionary(projects.enumerated().map { ($0.element.key, (Village.colors[$0.offset % Village.colors.count], $0.element.name)) }) { a, _ in a }
        for (aid, al) in agents where !leaving.contains(aid) {
            guard let s = seats[aid] else {                                   // ห้องเต็ม
                if owner[aid] == nil { sendAway(aid) } else { al.root.opacity = 0 }
                continue
            }
            al.root.opacity = 1
            let a = owner[aid].flatMap { agentById[$0]?.1 } ?? Agent(name: "", cwd: aid, project: "", state: .idle, alive: true)
            let spot: CGPoint
            if s.hall {
                let d = L.hall.seat(s.k); spot = d.p
                if let key = projectOf[aid], let (color, _) = colorOf[key] {
                    mark(x: d.p.x, top: d.front ? d.p.y - 1 : L.hall.tableBase(d.table) - 44, w: Hall.pitch - 6,
                         z: d.front ? depth(d.p.y) : depth(L.hall.tableBase(d.table)) + 0.05, color: color)
                }
            } else { spot = L.lounge.seat(s.k).p }
            apply(a, al, spot: spot, walking: walking && al.spot != nil)
        }

        // ป้ายชื่อ (ห้องทำงานเท่านั้น): หนึ่งป้ายต่อโปรเจกต์ต่อแถวที่นั่ง (โต๊ะ + ฝั่งหน้า/หลัง)
        // วางเป็นเลน: ถ้าชนป้ายข้างๆ ในแถวเดียวกัน → ลงเลนถัดไป (แถวหน้าเลื่อนลง, แถวหลังเลื่อนขึ้น)
        var lines: [String: [(name: String, color: NSColor, xs: [CGFloat], d: (p: CGPoint, front: Bool, table: Int))]] = [:]
        for (aid, s) in seats where s.hall {
            guard let key = projectOf[aid], let (color, name) = colorOf[key] else { continue }
            let d = L.hall.seat(s.k), line = "\(d.table)-\(d.front)"
            if let i = lines[line]?.firstIndex(where: { $0.name == name }) { lines[line]![i].xs.append(d.p.x) }
            else { lines[line, default: []].append((name, color, [d.p.x], d)) }
        }
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        for groups in lines.values {
            var laneRight: [CGFloat] = []
            for g in groups.sorted(by: { $0.xs.min()! < $1.xs.min()! }) {
                let cx = (g.xs.min()! + g.xs.max()!) / 2
                let w = min(130, (" \(g.name) " as NSString).size(withAttributes: [.font: font]).width + 12)
                let lane = laneRight.firstIndex { $0 + 4 <= cx - w / 2 } ?? laneRight.count
                if lane == laneRight.count { laneRight.append(-.infinity) }
                laneRight[lane] = cx + w / 2
                let d = g.d, step: CGFloat = 16
                let top = d.front ? d.p.y + 6 + CGFloat(lane) * step                     // ใต้เท้าแถวหน้า
                                  : L.hall.tableBase(d.table) - 44 - CGFloat(lane) * step  // บนโต๊ะ (แถวหลัง)
                tag(g.name, color: g.color, x: cx, width: w, top: top)
            }
        }
    }

    private func mark(x: CGFloat, top: CGFloat, w: CGFloat, z: CGFloat, color: NSColor) {
        let m = CALayer(); m.cornerRadius = 3
        m.bounds = CGRect(x: 0, y: 0, width: w, height: 7)
        m.backgroundColor = color.withAlphaComponent(0.9).cgColor
        m.position = P(CGPoint(x: x, y: top)); m.zPosition = z
        layer?.addSublayer(m); marks.append(m)
    }

    private func tag(_ name: String, color: NSColor, x: CGFloat, width: CGFloat, top: CGFloat) {
        let t = signLayer(fontSize: 10); t.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        t.string = " \(name) "; t.bounds = CGRect(x: 0, y: 0, width: width, height: 15)
        t.backgroundColor = color.blended(withFraction: 0.3, of: .black)!.cgColor
        t.borderWidth = 1; t.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        t.shadowOpacity = 0.35; t.shadowRadius = 1.5; t.shadowOffset = CGSize(width: 0, height: -1)
        t.position = P(CGPoint(x: x, y: top)); t.zPosition = 85
        layer?.addSublayer(t); marks.append(t)
    }

    /// เส้นทาง (พิกัด top): ออกจากห้องต้นทาง → ทางเดินกลาง → เข้าห้องปลายทาง
    private func route(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        let lo = L.lounge, h = L.hall, cx = L.corridorX
        func exit(_ p: CGPoint) -> [CGPoint]? {
            if lo.contains(p) { return lo.exit(p) + [CGPoint(x: cx, y: lo.doorY)] }
            if h.contains(p) { return h.exit(p) + [CGPoint(x: cx, y: h.doorY)] }
            return [p, CGPoint(x: cx, y: p.y)]   // อยู่บนทางเดินกลาง/ในป่า
        }
        guard let ea = exit(a), let eb = exit(b) else { return [a, b] }
        let sameRoom = (lo.contains(a) && lo.contains(b)) || (h.contains(a) && h.contains(b))
        if sameRoom {   // ย้ายที่นั่ง: แถวเดียวกันเดินตรง ไม่งั้นผ่านทางเดินในห้อง (ไม่ออกประตู)
            return abs(a.y - b.y) < 2 ? [a, b] : Array(ea.dropLast(2)) + eb.dropLast(2).reversed()
        }
        return ea + eb.reversed()
    }

    private func apply(_ a: Agent, _ al: AgentLayer, spot: CGPoint, walking: Bool) {
        if al.state == a.state && al.spot == spot && al.tool == a.tool && al.looping == animate
            && (a.state != .idle || al.shownRest == al.rest) { return }
        if a.state == .idle && al.state != .idle { al.rest = .random() }   // เพิ่งกลับมาพัก → สุ่มท่าใหม่
        al.agent = a; al.shownRest = a.state == .idle ? al.rest : nil
        let moved = al.spot.map { $0 != spot } ?? false
        al.spot = spot; al.tool = a.tool; al.looping = animate
        let c = al.critter
        let fromLayer = al.root.presentation()?.position ?? al.root.position
        let from = CGPoint(x: fromLayer.x, y: bounds.height - fromLayer.y)
        let target = P(spot)
        al.state = a.state

        // ท่า + ป้ายประจำสถานะ
        switch a.state {
        case .working: al.show(c.stand)
        case .blocked: al.show(c.alert ?? c.stand)
        case .waiting: al.show(c.stand)
        case .idle:
            switch al.rest {
            case .sleep: al.show(c.sleep ?? c.sit ?? c.stand)
            case .sit: al.show(c.sit ?? c.stand)
            case .stretch: al.show(c.stand)
            }
        }
        switch a.state {
        case .blocked where c.alert == nil: al.setBadge(emojiImage("❗", 16), height: 20)
        case .waiting: al.setBadge(emojiImage("❓", 16), height: 20)
        case .idle:
            switch al.rest {
            case .sleep: al.setBadge(emojiImage("💤", 14), height: 16)
            case .sit(let icon): al.setBadge(pixelEmoji(icon, 44), height: 18)
            case .stretch: al.setBadge(nil, height: 0)
            }
        case .working: al.setBadge(toolProp(a.tool).flatMap { sprite($0) }, height: 20)
        default: al.setBadge(nil, height: 0)
        }

        al.root.position = target
        al.root.zPosition = depth(spot.y) + 0.5
        al.root.removeAllAnimations()
        al.body.removeAllAnimations(); al.badge.removeAllAnimations()   // รวม "look" ของท่ายืนบิดขี้เกียจ

        var delay: CFTimeInterval = 0
        if walking && moved && hypot(from.x - spot.x, from.y - spot.y) > 2 {
            var pts: [CGPoint] = []
            for p in route(from, spot) where pts.last.map({ hypot($0.x - p.x, $0.y - p.y) > 1 }) ?? true { pts.append(p) }
            if pts.count < 2 { pts.append(spot) }
            var dist: [CGFloat] = [0]
            for k in 1..<pts.count { dist.append(dist[k - 1] + hypot(pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y)) }
            let total = max(dist.last!, 1)
            delay = min(7, max(0.8, Double(total / Village.walkSpeed)))
            let times = dist.map { NSNumber(value: Double($0 / total)) }

            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = pts.map { NSValue(point: P($0)) }; move.keyTimes = times; move.duration = delay
            al.root.add(move, forKey: "move")
            // ตอนเดินอยู่หน้าสุดเสมอ (ไม่โดนโต๊ะ/โซฟาบัง)
            let z = CABasicAnimation(keyPath: "zPosition"); z.fromValue = 90; z.toValue = 90; z.duration = delay
            al.root.add(z, forKey: "z")
            // ระหว่างเดิน: ท่ายืน/ก้าว สลับ + เด้งเบาๆ + หันหน้าตามทิศของแต่ละช่วง; ซ่อนป้ายไว้ก่อน
            let steps = CAKeyframeAnimation(keyPath: "contents")
            steps.values = [sprite(c.walk ?? c.stand) as Any, sprite(c.walk2 ?? c.stand) as Any]
            steps.calculationMode = .discrete; steps.duration = 0.36; steps.repeatDuration = delay
            al.body.add(steps, forKey: "steps")
            // กรอบต้องเปลี่ยนตามเฟรมเดินด้วย ไม่งั้นภาพเดินถูกบีบลงกรอบของท่าปลายทาง (นั่ง/นอน) → ตัวเล็กลง
            let frameBounds = [c.walk ?? c.stand, c.walk2 ?? c.stand].map { name -> NSValue in
                let img = sprite(name)
                return NSValue(rect: CGRect(x: 0, y: 0, width: CGFloat(img?.width ?? 1) * al.scale, height: CGFloat(img?.height ?? 1) * al.scale))
            }
            let size = CAKeyframeAnimation(keyPath: "bounds")
            size.values = frameBounds; size.calculationMode = .discrete; size.duration = 0.36; size.repeatDuration = delay
            al.body.add(size, forKey: "size")
            let hop = CABasicAnimation(keyPath: "transform.translation.y")
            hop.fromValue = 0; hop.toValue = 3; hop.duration = 0.18; hop.autoreverses = true; hop.repeatDuration = delay
            al.body.add(hop, forKey: "hop")
            var faces: [NSNumber] = [], last: CGFloat = 1
            for k in 0..<(pts.count - 1) {
                let dx = pts[k + 1].x - pts[k].x
                if abs(dx) > 1 { last = dx < 0 ? -1 : 1 }
                faces.append(NSNumber(value: Double(last)))
            }
            faces.append(faces.last ?? 1)
            let face = CAKeyframeAnimation(keyPath: "transform.scale.x")
            face.values = faces; face.keyTimes = times; face.calculationMode = .discrete; face.duration = delay
            al.body.add(face, forKey: "face")
            let hide = CABasicAnimation(keyPath: "opacity"); hide.fromValue = 0; hide.toValue = 0; hide.duration = delay
            al.badge.add(hide, forKey: "hide")
        }
        guard animate else { return }

        // ท่าวนหลังถึงที่หมาย
        let start = CACurrentMediaTime() + delay
        func add(_ l: CALayer, _ anim: CAAnimation) { anim.beginTime = start; l.add(anim, forKey: "loop") }
        switch a.state {
        case .working:
            add(al.body, loop([basic("transform.translation.y", 0, 3)], 0.45))
            add(al.badge, loop([basic("transform.translation.y", 0, 4)], 0.6))
        case .blocked:
            add(al.body, loop([basic("transform.translation.x", -2, 2)], 0.1, ease: .linear))
            add(al.badge, loop([basic("transform.translation.y", 0, 5)], 0.25))
        case .waiting:
            let look = CAKeyframeAnimation(keyPath: "transform.scale.x")
            look.values = [1, -1]; look.calculationMode = .discrete; look.duration = 2.4; look.repeatCount = .infinity
            add(al.body, look)
        case .idle:
            switch al.rest {
            case .sleep:   // หายใจช้าๆ + 💤 ลอยขึ้นแล้วจาง
                let breathe = CABasicAnimation(keyPath: "transform.scale.y"); breathe.fromValue = 1; breathe.toValue = 0.94
                add(al.body, loop([breathe], 1.6))
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
                add(al.badge, loop([fade, basic("transform.translation.y", 0, 14), basic("transform.translation.x", 0, 8)], 2.4,
                                   reverse: false, ease: .easeOut))
            case .sit:     // โยกตัวเบาๆ + ไอคอนกิจกรรมขยับขึ้นลง
                add(al.body, loop([basic("transform.rotation.z", -0.03, 0.03)], 1.8))
                add(al.badge, loop([basic("transform.translation.y", 0, 3)], 1.2))
            case .stretch: // ยืดตัวขึ้นช้าๆ แล้วหันมองซ้ายขวา
                let up = CABasicAnimation(keyPath: "transform.scale.y"); up.fromValue = 1; up.toValue = 1.07
                add(al.body, loop([up], 1.4))
                let look = CAKeyframeAnimation(keyPath: "transform.scale.x")
                look.values = [1, -1]; look.calculationMode = .discrete; look.duration = 3.2; look.repeatCount = .infinity
                look.beginTime = start; al.root.add(look, forKey: "look")
            }
        }
    }

    private func basic(_ key: String, _ from: CGFloat, _ to: CGFloat) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key); a.fromValue = from; a.toValue = to; a.isAdditive = true; return a
    }
    private func loop(_ items: [CAAnimation], _ d: CFTimeInterval, reverse: Bool = true,
                      ease: CAMediaTimingFunctionName = .easeInEaseOut) -> CAAnimationGroup {
        let g = CAAnimationGroup(); g.animations = items; g.duration = d; g.autoreverses = reverse
        g.repeatCount = .infinity; g.timingFunction = CAMediaTimingFunction(name: ease); return g
    }
}

// MARK: - SwiftUI

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let sky = Color(light: NSColor(red: 0.87, green: 0.95, blue: 1, alpha: 1), dark: NSColor(red: 0.08, green: 0.13, blue: 0.23, alpha: 1))
    static let card = Color(light: NSColor.white.withAlphaComponent(0.8), dark: NSColor(red: 0.11, green: 0.14, blue: 0.2, alpha: 0.8))
}

extension AgentState {
    var label: String { ["working": "กำลังทำงาน", "blocked": "รออนุญาต!", "waiting": "รอคำสั่ง", "idle": "พักผ่อน"][rawValue]! }
    var color: Color { switch self { case .working: .green; case .blocked: .red; case .waiting: .orange; case .idle: .gray } }
}

func ago(_ ms: Double?, _ now: Date) -> String {
    guard let ms else { return "" }
    let s = max(0, Int(now.timeIntervalSince1970 - ms / 1000))
    return s < 60 ? "\(s) วิ" : s < 3600 ? "\(s / 60) นาที" : "\(s / 3600) ชม."
}

var thumbCache: [String: NSImage] = [:]
func thumb(_ name: String) -> NSImage? {
    if let t = thumbCache[name] { return t }
    guard let img = sprite(name) else { return nil }
    let t = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) * 22 / CGFloat(img.height), height: 22))
    thumbCache[name] = t
    return t
}

struct AgentRow: View {
    let agent: Agent
    let critter: Critter
    let now: Date
    var body: some View {
        HStack(spacing: 8) {
            if agent.subId != nil { Text("↳").foregroundStyle(.secondary).padding(.leading, 14) }
            if let t = thumb(critter.stand) { Image(nsImage: t).interpolation(.none).scaleEffect(agent.subId != nil ? 0.8 : 1) }
            Text(agent.name).fontWeight(agent.subId != nil ? .regular : .medium).lineLimit(1).help(agent.cwd)
            Text(agent.state.label).foregroundStyle(agent.state.color).fontWeight(.semibold)
            if agent.state == .working, let t = agent.tool { Text(t).foregroundStyle(.secondary).lineLimit(1) }
            Text(agent.prompt.map { "“\($0)”" } ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(ago(agent.since, now)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

struct ZooView: View {
    @EnvironmentObject var zoo: Zoo

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("🌿 Agent Grove").font(.system(size: 20, weight: .bold))
                        if !zoo.agents.isEmpty {
                            Text(LocalizedStringKey("**\(zoo.projects.count)** โปรเจกต์ · **\(zoo.mainCount)** ตัว\(zoo.helperCount > 0 ? " + ผู้ช่วย **\(zoo.helperCount)**" : "") · ทำงาน **\(zoo.count(.working))** · รออนุญาต **\(zoo.count(.blocked))** · รอคำสั่ง **\(zoo.count(.waiting))** · พัก **\(zoo.count(.idle))**"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding([.horizontal, .top], 20)
                    .overlay(alignment: .topTrailing) {
                        Picker("", selection: $zoo.mode) {
                            ForEach(AnimalMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .padding([.trailing, .top], 16)
                    }

                    if zoo.agents.isEmpty {
                        Text("ไม่มี agent ทำงานอยู่ — หมู่บ้านเงียบ 🌱").foregroundStyle(.secondary).padding(20)
                    } else {
                        VillageView(projects: zoo.projects, animate: zoo.windowVisible, mode: zoo.mode)
                            .frame(height: Village.height(geo.size.width - 24, zoo.projects))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 12).padding(.vertical, 10)

                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(zoo.projects) { p in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("📁 \(p.name)").font(.system(size: 13, weight: .semibold))
                                    ForEach(p.agents) { AgentRow(agent: $0, critter: critter(for: $0, in: p), now: zoo.now) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 20).padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(Color.sky)
        // หยุด animation เมื่อหน้าต่างถูกปิด/ย่อ/บังมิด → แทบไม่กิน CPU
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { n in
            guard let w = n.object as? NSWindow, w.identifier?.rawValue.hasPrefix("zoo") == true else { return }
            zoo.windowVisible = w.occlusionState.contains(.visible)
        }
        .onDisappear { zoo.windowVisible = false }
        .onAppear { zoo.windowVisible = true }
    }
}

// MARK: - App

@main
struct AgentGroveApp: App {
    @StateObject private var zoo = Zoo()

    init() {
        // AGENT_GROVE_SNAPSHOT=out.png → เรนเดอร์ฉากหมู่บ้านเป็นรูป (ไว้ตรวจหน้าตา) แล้วออก
        if let out = ProcessInfo.processInfo.environment["AGENT_GROVE_SNAPSHOT"] {
            MainActor.assumeIsolated {
                var agents = collect()
                if ProcessInfo.processInfo.environment["AGENT_GROVE_DEMO"] != nil {  // จำลองครบทุกสถานะ + หลายแถว
                    let states: [AgentState] = [.working, .idle, .blocked, .waiting, .working, .working]
                    agents = (0..<24).map { k in Agent(name: "agent-\(k)", cwd: "/demo/\(k)", project: "proj-\(k / 3)",
                                                       state: states[k % states.count], tool: ["Read", "Bash", "Grep", "Edit"][k % 4], alive: true) }
                }
                let mode = AnimalMode(rawValue: ProcessInfo.processInfo.environment["AGENT_GROVE_MODE"] ?? "") ?? AnimalMode.saved
                (critters, babies) = loadCritters(mode)
                let projects = group(agents), w: CGFloat = 900, h = Village.height(w, projects)
                let v = VillageLayerView(frame: NSRect(x: 0, y: 0, width: w, height: h))
                v.layer!.backgroundColor = NSColor(red: 0.87, green: 0.95, blue: 1, alpha: 1).cgColor
                v.update(projects, animate: false, mode: mode)
                v.layer!.sublayers = v.layer!.sublayers?.sorted { $0.zPosition < $1.zPosition }  // render(in:) ไม่สน zPosition
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * 2), pixelsHigh: Int(h * 2), bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = NSSize(width: w, height: h)
                let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
                v.layer!.render(in: ctx)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("Agent Grove", id: "zoo") {
            ZooView().environmentObject(zoo)
        }
        .defaultSize(width: 900, height: 600)
        .defaultLaunchBehavior(.presented)  // เปิดแอปแล้วหน้าต่างขึ้นเสมอ (ไม่จำว่าปิดไว้)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuContent().environmentObject(zoo)
        } label: {
            Text(zoo.menuTitle)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var zoo: Zoo
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("ทำงาน \(zoo.count(.working)) · รออนุญาต \(zoo.count(.blocked)) · รอคำสั่ง \(zoo.count(.waiting)) · ทั้งหมด \(zoo.agents.count)")
        Divider()
        Picker("ตัวละคร", selection: $zoo.mode) {
            ForEach(AnimalMode.allCases) { Text($0.label).tag($0) }
        }
        Divider()
        Button("เปิด Agent Grove") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "zoo")
        }.keyboardShortcut("o")
        Button("ออก") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
