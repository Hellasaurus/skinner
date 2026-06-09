import Foundation
import projectM
import CrashGuard

// Top-level @convention(c) trampoline: passes the projectm_handle stored in ctx
// to projectm_opengl_render_frame.  Cannot be a closure — C function pointers
// cannot capture Swift context.
private func _renderFrameC(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    projectm_opengl_render_frame(OpaquePointer(ctx))
}

/// Swift wrapper around the projectM C API.
/// All methods must be called with the owning OpenGL context active (caller's responsibility).
final class ProjectMBridge {
    private var handle:   projectm_handle?
    private var playlist: projectm_playlist_handle?
    // Serializes renderFrame (CVDisplayLink thread) against preset/resize calls (main thread).
    private let lock = NSLock()

    init(presetPath: URL?) {
        crashGuard_install()
        handle = projectm_create()
        guard let h = handle else { return }

        projectm_set_beat_sensitivity(h, 1.0)
        projectm_set_preset_duration(h, 15.0)
        projectm_set_hard_cut_enabled(h, true)
        projectm_set_hard_cut_duration(h, 8.0)
        projectm_set_soft_cut_duration(h, 3.0)
        projectm_set_aspect_correction(h, true)

        let pl = projectm_playlist_create(h)
        playlist = pl
        if let path = presetPath {
            print("[ProjectM] Loading presets from: \(path.path)")
            let count = projectm_playlist_add_path(pl, path.path, true, false)
            print("[ProjectM] Loaded \(count) presets")
            projectm_playlist_set_shuffle(pl, true)
        } else {
            print("[ProjectM] No preset path found — playlist will be empty")
        }
    }

    deinit {
        if let pl = playlist { projectm_playlist_destroy(pl) }
        if let h  = handle   { projectm_destroy(h) }
    }

    func resize(width: Int, height: Int) {
        guard let h = handle, width > 0, height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        projectm_set_window_size(h, size_t(width), size_t(height))
    }

    func addPCM(_ samples: [Float]) {
        guard let h = handle else { return }
        samples.withUnsafeBufferPointer {
            projectm_pcm_add_float(h, $0.baseAddress!, UInt32(samples.count), PROJECTM_MONO)
        }
    }

    /// Must be called with the OpenGL context active on the calling thread.
    func renderFrame() {
        guard let h = handle else { return }
        // Acquire lock manually (no defer) so unlock is guaranteed even when
        // crashGuard_execute catches a SIGSEGV/SIGBUS inside projectM and
        // returns false instead of unwinding past a defer.
        lock.lock()
        let success = crashGuard_execute(_renderFrameC, UnsafeMutableRawPointer(h))
        lock.unlock()
        if !success {
            print("[ProjectM] render crash caught for preset '\(currentPresetName)' — skipping")
            nextPreset()
        }
    }

    func nextPreset() {
        guard let pl = playlist else { print("[ProjectM] nextPreset: no playlist"); return }
        lock.lock()
        projectm_playlist_play_next(pl, false)
        lock.unlock()
        print("[ProjectM] → next preset: \(currentPresetName)")
    }

    func previousPreset() {
        guard let pl = playlist else { print("[ProjectM] previousPreset: no playlist"); return }
        lock.lock()
        projectm_playlist_play_previous(pl, false)
        lock.unlock()
        print("[ProjectM] ← previous preset: \(currentPresetName)")
    }

    var currentPresetName: String {
        guard let pl = playlist else { return "" }
        lock.lock()
        defer { lock.unlock() }
        let pos = projectm_playlist_get_position(pl)
        guard let cstr = projectm_playlist_item(pl, pos) else { return "" }
        defer { projectm_playlist_free_string(cstr) }
        return URL(fileURLWithPath: String(cString: cstr))
            .deletingPathExtension().lastPathComponent
    }
}
