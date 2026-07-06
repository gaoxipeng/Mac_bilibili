#!/usr/bin/env swift
//
// Simulates mouse-wheel scrolling over the bilibili feed for Instruments profiling.
// Requires Accessibility permission for Terminal / swift (System Settings → Privacy).
//

import AppKit
import CoreGraphics

struct Options {
    var bundleID = "gaoxipeng.bilibili"
    var rounds = 50
    var warmup: Double = 2.5
    var scrollDelta: Int32 = 8
    var stepDelayMicros: useconds_t = 16_000

    static func parse() -> Options {
        var opts = Options()
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--bundle":
                opts.bundleID = args.isEmpty ? opts.bundleID : args.removeFirst()
            case "--rounds":
                opts.rounds = Int(args.isEmpty ? "50" : args.removeFirst()) ?? 50
            case "--warmup":
                opts.warmup = Double(args.isEmpty ? "2.5" : args.removeFirst()) ?? 2.5
            case "--delta":
                opts.scrollDelta = Int32(args.isEmpty ? "8" : args.removeFirst()) ?? 8
            case "--delay-ms":
                let ms = Double(args.isEmpty ? "16" : args.removeFirst()) ?? 16
                opts.stepDelayMicros = useconds_t(ms * 1000)
            case "--help", "-h":
                print("""
                Usage: scroll-simulator.swift [options]
                  --bundle ID     App bundle identifier (default: gaoxipeng.bilibili)
                  --rounds N      Scroll up/down cycles (default: 50)
                  --warmup SEC    Seconds before scrolling (default: 2.5)
                  --delta N       Wheel delta per tick (default: 8)
                  --delay-ms MS   Delay between ticks in ms (default: 16)
                """)
                exit(0)
            default:
                break
            }
        }
        return opts
    }
}

func feedScrollPoint(for pid: pid_t) -> CGPoint? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    var bestArea: CGFloat = 0
    var bestPoint: CGPoint?

    for window in list {
        guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid else { continue }
        guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
        guard let isOnscreen = window[kCGWindowIsOnscreen as String] as? Int, isOnscreen == 1 else { continue }
        guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = boundsDict["X"], let y = boundsDict["Y"],
              let width = boundsDict["Width"], let height = boundsDict["Height"],
              width > 400, height > 300 else { continue }

        let area = width * height
        guard area > bestArea else { continue }
        bestArea = area

        // Feed content sits to the right of the sidebar (~220pt).
        let contentX = x + 220 + (width - 220) * 0.5
        let contentY = y + height * 0.52
        bestPoint = CGPoint(x: contentX, y: contentY)
    }

    return bestPoint
}

func postMouseMove(to point: CGPoint) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
    move?.post(tap: .cghidEventTap)
}

func postScroll(at point: CGPoint, deltaY: Int32) {
    postMouseMove(to: point)
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    let scroll = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)
    scroll?.location = point
    scroll?.post(tap: .cghidEventTap)
}

let options = Options.parse()

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleID).first else {
    fputs("scroll-simulator: app '\(options.bundleID)' is not running\n", stderr)
    exit(1)
}

app.activate()
usleep(useconds_t(options.warmup * 1_000_000))

guard let point = feedScrollPoint(for: app.processIdentifier) else {
    fputs("scroll-simulator: could not locate main window\n", stderr)
    exit(1)
}

print("scroll-simulator: scrolling at (\(Int(point.x)), \(Int(point.y))) rounds=\(options.rounds)")

postMouseMove(to: point)
usleep(100_000)

for round in 0..<options.rounds {
    let direction: Int32 = round.isMultiple(of: 2) ? -options.scrollDelta : options.scrollDelta
    postScroll(at: point, deltaY: direction)
    usleep(options.stepDelayMicros)
}

print("scroll-simulator: done")
