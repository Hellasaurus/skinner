import AppKit
import SkinnerCore

/// Reads debug commands from stdin, one per line, so the app can be driven without
/// `cliclick` and its on-screen state can be dumped for inspection.
///
/// Enabled only when `SKINNER_DEBUG_STDIN` is set in the environment.
///
/// Commands (whitespace-separated; first token is the verb). Each prints `OK` or
/// `ERR <message>` to stdout:
///   click X Y [VIEWID]      — synthetic left click at (X, Y) in view coords
///   move X Y [VIEWID]       — synthetic mouse-moved at (X, Y), updates hover state
///   drag X1 Y1 X2 Y2 [STEPS] [VIEWID] — synthetic mouseDown+N mouseDragged+mouseUp from (X1,Y1) to (X2,Y2)
///   dump [DIR]               — write frame/mask/mapData/mask PNGs to DIR (default /tmp/skinner-debug)
///   screenshot PATH [VIEWID] — write the current frame to PATH
/// `@unchecked Sendable`: the background read loop only ever touches `self` via
/// `DispatchQueue.main.async`, which serializes all AppKit access onto the main thread.
final class DebugStdinController: @unchecked Sendable {
    private let mainCanvas: () -> SkinCanvasView?
    private let secondaryCanvas: (String) -> SkinCanvasView?

    init(mainCanvas: @escaping () -> SkinCanvasView?,
         secondaryCanvas: @escaping (String) -> SkinCanvasView?) {
        self.mainCanvas = mainCanvas
        self.secondaryCanvas = secondaryCanvas

        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let self else { return }
                Task { @MainActor in self.handle(trimmed) }
            }
        }
    }

    @MainActor
    private func canvas(forViewId viewId: String?) -> SkinCanvasView? {
        guard let viewId else { return mainCanvas() }
        return secondaryCanvas(viewId)
    }

    @MainActor
    private func handle(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return ack(.failure("empty command")) }
        let args = Array(parts.dropFirst())

        switch verb {
        case "click", "move":
            guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else {
                return ack(.failure("usage: \(verb) X Y [VIEWID]"))
            }
            guard let canvas = canvas(forViewId: args.count > 2 ? args[2] : nil) else {
                return ack(.failure("no such view"))
            }
            let pt = CGPoint(x: x, y: y)
            if verb == "click" { canvas.debugClick(atViewPoint: pt) }
            else                { canvas.debugMove(atViewPoint: pt) }
            ack(.success)

        case "drag":
            guard args.count >= 4,
                  let x1 = Double(args[0]), let y1 = Double(args[1]),
                  let x2 = Double(args[2]), let y2 = Double(args[3])
            else { return ack(.failure("usage: drag X1 Y1 X2 Y2 [STEPS] [VIEWID]")) }
            let steps = args.count > 4 ? (Int(args[4]) ?? 20) : 20
            let viewId = args.count > 5 ? args[5] : nil
            guard let canvas = canvas(forViewId: viewId) else { return ack(.failure("no such view")) }
            canvas.debugDrag(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2), steps: steps)
            ack(.success)

        case "dump":
            let dir = args.first ?? "/tmp/skinner-debug"
            guard let canvas = mainCanvas() else { return ack(.failure("no main view")) }
            do {
                try canvas.dumpDebugBuffers(to: URL(fileURLWithPath: dir))
                ack(.success)
            } catch {
                ack(.failure("\(error)"))
            }

        case "screenshot":
            guard let path = args.first else { return ack(.failure("usage: screenshot PATH [VIEWID]")) }
            guard let canvas = canvas(forViewId: args.count > 1 ? args[1] : nil) else {
                return ack(.failure("no such view"))
            }
            do {
                try canvas.snapshotPNG(to: URL(fileURLWithPath: path))
                ack(.success)
            } catch {
                ack(.failure("\(error)"))
            }

        default:
            ack(.failure("unknown command: \(verb)"))
        }
    }

    private enum Result {
        case success
        case failure(String)
    }

    private func ack(_ result: Result) {
        switch result {
        case .success:
            print("OK")
        case .failure(let message):
            print("ERR \(message)")
        }
        fflush(stdout)
    }
}
