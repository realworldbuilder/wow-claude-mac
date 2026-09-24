// macOS counterpart of capture.ps1: screen-captures the top-left corner of the
// WoW client window with ScreenCaptureKit and decodes the WoWClaude pixel strip
// (see Codec.lua in the addon). Prints one JSON line per new message to stdout.
// Started by bridge.js; can also be run by hand. Built by setup.js into
// bridge/bin/wowclaude-capture (see buildCaptureHelper there).
//
//   wowclaude-capture -ProcessName "/Applications/World of Warcraft/_classic_beta_/World of Warcraft Beta.app"
//   wowclaude-capture -TestImage strip.png     decode a PNG once and exit (used by tests)
//   wowclaude-capture ... -DumpImage last.png  also write every captured region to a file (debugging)
//
// Same flags as capture.ps1 (-Cell -Cells -MaxRows -IntervalMs -ProcessName -TestImage),
// same output ({"id","text"} / {"info"} / {"warn"} / {"error"}), same decoder.
//
// Differences from Windows, and why:
// - The window is found through SCShareableContent, and -ProcessName may be an
//   .app path (exact, distinguishes two installs of the same bundle id), a bundle
//   id, or a substring of the app name.
// - The capture uses a display filter that includes only the game window, so a
//   terminal or the Claude app overlapping the corner does not corrupt the strip.
//   (A plain window filter adds a shadow margin of unpredictable size.)
// - The window frame includes the title bar in windowed mode and nothing in
//   borderless mode, and the game may render at half the display's pixel density,
//   so instead of computing the content origin the decoder searches a few rows
//   down for the frame magic and tries 1x and 2x cell sizes. Once found, that
//   offset is tried first on the next frame.
// - Screen Recording permission belongs to the app that launched the bridge
//   (Terminal, iTerm, the Claude app...). Without it the helper exits with code 2
//   and bridge.js backs off instead of retrying every 5 s.

import AppKit
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

struct Options {
  var cell = 4
  var cells = 200
  var maxRows = 48
  var intervalMs = 250
  var processName = WOW_BUNDLE_ID
  var testImage: String? = nil
  var dumpImage: String? = nil
  var verbose = false
}

func parseArgs() -> Options {
  var o = Options()
  let args = Array(CommandLine.arguments.dropFirst())
  var i = 0
  while i < args.count {
    var key = args[i].lowercased()
    while key.hasPrefix("-") { key.removeFirst() }
    let value = i + 1 < args.count ? args[i + 1] : nil
    func intValue() -> Int? { value.flatMap { Int($0) } }
    switch key {
    case "cell": if let v = intValue() { o.cell = v }; i += 2
    case "cells": if let v = intValue() { o.cells = v }; i += 2
    case "maxrows": if let v = intValue() { o.maxRows = v }; i += 2
    case "intervalms": if let v = intValue() { o.intervalMs = v }; i += 2
    case "processname": if let v = value { o.processName = v }; i += 2
    case "testimage": if let v = value { o.testImage = v }; i += 2
    case "dumpimage": if let v = value { o.dumpImage = v }; i += 2
    case "verbose": o.verbose = true; i += 1
    default:
      FileHandle.standardError.write("unknown argument \(args[i])\n".data(using: .utf8)!)
      i += 1
    }
  }
  return o
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

// One compact JSON object per line, written straight to fd 1 (no stdio buffering).
func emit(_ obj: [String: Any]) {
  guard var data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return }
  data.append(0x0A)
  FileHandle.standardOutput.write(data)
}

func debug(_ opts: Options, _ msg: String) {
  if opts.verbose { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!) }
}

// ---------------------------------------------------------------------------
// Pixels
// ---------------------------------------------------------------------------

// RGBX, 4 bytes per pixel, row 0 at the top, sRGB. Every image (live capture or
// test PNG) is drawn into this one layout so the decoder never sees BGRA,
// premultiplied alpha or Display P3 values.
struct RGBBuffer {
  let width: Int
  let height: Int
  let bytes: [UInt8]

  func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    let o = (y * width + x) * 4
    return (bytes[o], bytes[o + 1], bytes[o + 2])
  }
}

func normalize(_ img: CGImage) -> RGBBuffer? {
  let w = img.width, h = img.height
  guard w > 0, h > 0 else { return nil }
  var buf = [UInt8](repeating: 0, count: w * h * 4)
  let ok: Bool = buf.withUnsafeMutableBytes { p in
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    else { return false }
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  return ok ? RGBBuffer(width: w, height: h, bytes: buf) : nil
}

func loadImage(_ path: String) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
}

func writePNG(_ img: CGImage, _ path: String) {
  guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
  CGImageDestinationAddImage(dest, img, nil)
  CGImageDestinationFinalize(dest)
}

// ---------------------------------------------------------------------------
// Decoder (bit-for-bit the same rules as capture.ps1)
// ---------------------------------------------------------------------------

enum DecodeResult {
  case none                       // no magic at this position
  case rejected(String)           // magic matched, frame invalid: "length" / "truncated" / "checksum"
  case ok(id: Int, text: String)
}

// Each channel is either fully on or off, so anything past mid-grey counts as on.
// Cells outside the image read as black, which fails the magic or the checksum.
@inline(__always)
func cellValue(_ b: RGBBuffer, c: Int, r: Int, x0: Int, y0: Int, cellPx: Int) -> Int {
  let x = x0 + c * cellPx + cellPx / 2
  let y = y0 + r * cellPx + cellPx / 2
  guard x >= 0, y >= 0, x < b.width, y < b.height else { return 0 }
  let (R, G, B) = b.rgb(x, y)
  return (R >= 128 ? 4 : 0) + (G >= 128 ? 2 : 0) + (B >= 128 ? 1 : 0)
}

// The first 6 cells (18 bits) hold the two magic bytes; cheap pre-check before a full decode.
func magicMatches(_ b: RGBBuffer, x0: Int, y0: Int, cellPx: Int, cells: Int) -> Bool {
  var acc = 0
  for c in 0..<6 { acc = (acc << 3) | cellValue(b, c: c, r: 0, x0: x0, y0: y0, cellPx: cellPx) }
  return (acc >> 10) == 0xC7 && ((acc >> 2) & 0xFF) == 0x1A
}

func decode(_ b: RGBBuffer, x0: Int, y0: Int, cellPx: Int, cells: Int, maxRows: Int) -> DecodeResult {
  var acc = 0, nbits = 0
  var bytes: [Int] = []
  bytes.reserveCapacity(64)
  var needed = 6
  let total = cells * maxRows
  var i = 0
  while i < total {
    let v = cellValue(b, c: i % cells, r: i / cells, x0: x0, y0: y0, cellPx: cellPx)
    acc = (acc << 3) | v
    nbits += 3
    var done = false
    while nbits >= 8 {
      bytes.append((acc >> (nbits - 8)) & 0xFF)
      nbits -= 8
      acc &= (1 << nbits) - 1
      if bytes.count == 2 {
        if bytes[0] != 0xC7 || bytes[1] != 0x1A { return .none }
      }
      if bytes.count == 6 {
        let len = bytes[4] * 256 + bytes[5]
        needed = 8 + len
        if needed > total * 3 / 8 { return .rejected("length") }
      }
      if bytes.count >= needed { done = true; break }
    }
    if done { break }
    i += 1
  }
  if bytes.count < needed { return .rejected("truncated") }
  let len = bytes[4] * 256 + bytes[5]
  var s1 = 0, s2 = 0
  for k in 2..<(6 + len) {
    s1 = (s1 + bytes[k]) % 255
    s2 = (s2 + s1) % 255
  }
  if bytes[6 + len] != s1 || bytes[7 + len] != s2 { return .rejected("checksum") }
  let payload = bytes[6..<(6 + len)].map { UInt8($0) }
  return .ok(id: bytes[2] * 256 + bytes[3], text: String(decoding: payload, as: UTF8.self))
}

// Where the strip starts is not known exactly: the window frame may include a
// title bar (28 pt: 56 px at 2x, 28 px at 1x), and the game may render at half
// the display density so a 4 px cell shows as 8 px. Try the likely spots first,
// then every row down to yScan, at 1x and 2x cell size. A candidate costs six
// pixel reads unless the magic matches; a full decode only runs on a match.
struct Lock { let y0: Int; let cellPx: Int }

let Y_SCAN = 120  // rows (in captured pixels) to search below the top of the window

func findStrip(_ b: RGBBuffer, opts: Options, lock: inout Lock?) -> DecodeResult {
  var candidates: [(Int, Int)] = []
  if let l = lock { candidates.append((l.y0, l.cellPx)) }
  for (y, m) in [(0, 1), (56, 1), (28, 1), (0, 2), (56, 2), (28, 2)] { candidates.append((y, opts.cell * m)) }
  for y in 0...Y_SCAN { for m in [1, 2] { candidates.append((y, opts.cell * m)) } }
  var seen = Set<Int>()
  var firstReject: String? = nil
  for (y0, cellPx) in candidates {
    if !seen.insert(y0 * 1024 + cellPx).inserted { continue }
    if !magicMatches(b, x0: 0, y0: y0, cellPx: cellPx, cells: opts.cells) { continue }
    switch decode(b, x0: 0, y0: y0, cellPx: cellPx, cells: opts.cells, maxRows: opts.maxRows) {
    case .ok(let id, let text):
      if lock == nil || lock!.y0 != y0 || lock!.cellPx != cellPx {
        lock = Lock(y0: y0, cellPx: cellPx)
        debug(opts, "strip locked at y=\(y0) cell=\(cellPx)px")
      }
      return .ok(id: id, text: text)
    case .rejected(let why):
      if firstReject == nil { firstReject = why }
    case .none:
      break
    }
  }
  if let why = firstReject { return .rejected(why) }
  return .none
}

// ---------------------------------------------------------------------------
// Window discovery and capture (ScreenCaptureKit)
// ---------------------------------------------------------------------------

let SC_ERROR_DOMAIN = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
let SC_USER_DECLINED = -3801

func isPermissionError(_ e: Error) -> Bool {
  let ns = e as NSError
  return ns.domain == SC_ERROR_DOMAIN && ns.code == SC_USER_DECLINED
}

func shareableContent(timeout: TimeInterval) -> Result<SCShareableContent, Error> {
  var result: Result<SCShareableContent, Error> = .failure(NSError(domain: "wowclaude", code: 1, userInfo: [NSLocalizedDescriptionKey: "window list timed out"]))
  let sem = DispatchSemaphore(value: 0)
  SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
    if let c = content { result = .success(c) } else if let e = error { result = .failure(e) }
    sem.signal()
  }
  _ = sem.wait(timeout: .now() + timeout)
  return result
}

// -ProcessName: an .app path (prefix match on the bundle path), a bundle id, or a
// substring of the app name. The Forever client calls itself just "Wow", so any
// value that mentions wow or warcraft (a Windows "WowB", "World of Warcraft")
// also accepts Blizzard's bundle id; a copied config keeps working.
let WOW_BUNDLE_ID = "com.blizzard.worldofwarcraft"

func appMatches(_ app: SCRunningApplication, _ spec: String) -> Bool {
  if spec.contains("/") {
    guard let ra = NSRunningApplication(processIdentifier: app.processID), let p = ra.bundleURL?.path else { return false }
    let a = (p.hasSuffix("/") ? p : p + "/").lowercased()
    let s = (spec.hasSuffix("/") ? spec : spec + "/").lowercased()
    return a.hasPrefix(s)
  }
  if spec.contains(".") { return app.bundleIdentifier == spec }
  if app.applicationName.localizedCaseInsensitiveContains(spec) { return true }
  let s = spec.lowercased()
  return (s.contains("wow") || s.contains("warcraft")) && app.bundleIdentifier == WOW_BUNDLE_ID
}

struct Target {
  let window: SCWindow
  let display: SCDisplay
  let pid: pid_t
  let scale: CGFloat
}

func findGameWindow(_ content: SCShareableContent, _ opts: Options) -> Target? {
  let pids = Set(content.applications.filter { appMatches($0, opts.processName) }.map { $0.processID })
  if pids.isEmpty { return nil }
  let wins = content.windows.filter {
    guard let app = $0.owningApplication, pids.contains(app.processID) else { return false }
    return $0.windowLayer == 0 && $0.frame.width >= 320 && $0.frame.height >= 200
  }
  // Prefer a visible window; among those, the largest.
  guard let win = wins.max(by: { a, b in
    if a.isOnScreen != b.isOnScreen { return !a.isOnScreen }
    return a.frame.width * a.frame.height < b.frame.width * b.frame.height
  }) else { return nil }
  let mid = CGPoint(x: win.frame.midX, y: win.frame.midY)
  let display = content.displays.first { $0.frame.contains(mid) }
    ?? content.displays.max { $0.frame.intersection(win.frame).area < $1.frame.intersection(win.frame).area }
  guard let disp = display else { return nil }
  let scale = CGFloat(SCContentFilter(display: disp, including: [win]).pointPixelScale)
  return Target(window: win, display: disp, pid: win.owningApplication!.processID, scale: scale)
}

extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

// Captures the top-left of the window: regionPx wide and tall in device pixels,
// clamped to the window and its display. Only the game window is rendered, so
// anything on top of it is left out of the image.
func capture(_ t: Target, regionPx: (w: Int, h: Int), timeout: TimeInterval) -> Result<CGImage, Error> {
  let filter = SCContentFilter(display: t.display, including: [t.window])
  let scale = CGFloat(filter.pointPixelScale)
  let f = t.window.frame, d = t.display.frame
  // Window origin in the display's own coordinate space (its origin can be negative on a second display).
  let x = max(0, f.minX - d.minX), y = max(0, f.minY - d.minY)
  let wPt = min(CGFloat(regionPx.w) / scale, f.maxX - d.minX - x, d.width - x)
  let hPt = min(CGFloat(regionPx.h) / scale, f.maxY - d.minY - y, d.height - y)
  guard wPt >= 8, hPt >= 8 else {
    return .failure(NSError(domain: "wowclaude", code: 2, userInfo: [NSLocalizedDescriptionKey: "window is off screen"]))
  }
  let cfg = SCStreamConfiguration()
  cfg.sourceRect = CGRect(x: x, y: y, width: wPt, height: hPt)
  cfg.width = Int((wPt * scale).rounded())
  cfg.height = Int((hPt * scale).rounded())
  cfg.scalesToFit = false
  cfg.showsCursor = false
  cfg.captureResolution = .best
  cfg.pixelFormat = kCVPixelFormatType_32BGRA
  cfg.colorSpaceName = CGColorSpace.sRGB
  cfg.includeChildWindows = false
  var result: Result<CGImage, Error> = .failure(NSError(domain: "wowclaude", code: 3, userInfo: [NSLocalizedDescriptionKey: "capture timed out"]))
  let sem = DispatchSemaphore(value: 0)
  SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { image, error in
    if let i = image { result = .success(i) } else if let e = error { result = .failure(e) }
    sem.signal()
  }
  _ = sem.wait(timeout: .now() + timeout)
  return result
}

// ---------------------------------------------------------------------------
// Permission
// ---------------------------------------------------------------------------

func parentPid(of pid: pid_t) -> pid_t {
  var info = proc_bsdinfo()
  let size = Int32(MemoryLayout<proc_bsdinfo>.size)
  let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
  return n == size ? pid_t(info.pbi_ppid) : 0
}

// Screen Recording is granted to the nearest ancestor that is an app bundle
// (Terminal, iTerm, the Claude app...), not to this helper. Name it in the message.
func responsibleAppName() -> String {
  var pid = getppid()
  var hops = 0
  while pid > 1 && hops < 16 {
    if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil, let name = app.localizedName {
      return name
    }
    pid = parentPid(of: pid)
    hops += 1
  }
  return "the terminal app you started the bridge from"
}

func failPermission() -> Never {
  let app = responsibleAppName()
  emit(["error": "screen recording permission missing: allow '\(app)' under System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen \(app) and start the bridge again"])
  exit(2)
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

func mainLoop(_ opts: Options) -> Never {
  // Wide and tall enough for 2x cells plus the rows searched for the title bar.
  let regionPx = (w: opts.cells * opts.cell * 2, h: (opts.maxRows * opts.cell + Y_SCAN) * 2)
  var target: Target? = nil
  var lastRefresh = Date.distantPast
  var lastKey = ""
  var lastWarn = Date.distantPast
  var lock: Lock? = nil
  var failures = 0
  let interval = Double(opts.intervalMs) / 1000

  while true {
    if getppid() == 1 { exit(0) }  // bridge.js is gone; do not poll the screen forever
    let gone = target.map { NSRunningApplication(processIdentifier: $0.pid)?.isTerminated ?? true } ?? false
    if target == nil || gone || Date().timeIntervalSince(lastRefresh) > 3 {
      switch shareableContent(timeout: 5) {
      case .failure(let e):
        if isPermissionError(e) { failPermission() }
        emit(["warn": "window list failed: \(e.localizedDescription)"])
        Thread.sleep(forTimeInterval: 3)
        continue
      case .success(let content):
        lastRefresh = Date()
        if let t = findGameWindow(content, opts) {
          if target == nil || gone || target!.pid != t.pid || target!.window.windowID != t.window.windowID {
            let f = t.window.frame
            emit(["info": "attached to '\(t.window.title ?? t.window.owningApplication?.applicationName ?? "?")' (pid \(t.pid), window \(t.window.windowID), \(Int(f.width))x\(Int(f.height)) pt at \(Int(f.minX)),\(Int(f.minY)), display \(t.display.displayID), \(t.scale)x)"])
            lock = nil
          }
          target = t
        } else {
          target = nil
          emit(["info": "waiting for \(opts.processName) window"])
          Thread.sleep(forTimeInterval: 3)
          continue
        }
      }
    }
    guard let t = target else { continue }
    if !t.window.isOnScreen {  // minimized or hidden: like IsIconic on Windows
      Thread.sleep(forTimeInterval: 1)
      continue
    }
    switch capture(t, regionPx: regionPx, timeout: 2) {
    case .failure(let e):
      if isPermissionError(e) { failPermission() }
      failures += 1
      if failures >= 20 { emit(["error": "capture keeps failing: \(e.localizedDescription)"]); exit(3) }
      if failures % 3 == 0 { target = nil }  // window may have changed; look again
      if Date().timeIntervalSince(lastWarn) >= 5 {
        lastWarn = Date()
        emit(["warn": "capture failed: \(e.localizedDescription)"])
      }
    case .success(let img):
      failures = 0
      if let dump = opts.dumpImage { writePNG(img, dump) }
      if let buf = normalize(img) {
        switch findStrip(buf, opts: opts, lock: &lock) {
        case .ok(let id, let text):
          let key = "\(id):\(text)"
          if key != lastKey {
            lastKey = key
            emit(["id": id, "text": text])
          }
        case .rejected(let why):
          // Magic matched but the frame didn't validate: say so, at most every 5 s.
          if Date().timeIntervalSince(lastWarn) >= 5 {
            lastWarn = Date()
            emit(["warn": "strip seen but rejected: \(why)"])
          }
        case .none:
          break
        }
      }
    }
    Thread.sleep(forTimeInterval: interval)
  }
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

let opts = parseArgs()
signal(SIGPIPE, SIG_DFL)  // die quietly if bridge.js goes away mid-write

if let file = opts.testImage {
  guard let img = loadImage(file), let buf = normalize(img) else {
    emit(["error": "cannot read image \(file)"])
    exit(1)
  }
  var lock: Lock? = nil
  switch findStrip(buf, opts: opts, lock: &lock) {
  case .ok(let id, let text): emit(["id": id, "text": text])
  case .rejected(let why): emit(["error": why])
  case .none: emit(["error": "no valid strip in image"])
  }
  exit(0)
}

_ = NSApplication.shared  // connects to the window server; SCContentFilter asserts without it
if !CGPreflightScreenCaptureAccess() {
  _ = CGRequestScreenCaptureAccess()  // shows the system prompt once; the grant needs an app relaunch
  failPermission()
}
mainLoop(opts)
