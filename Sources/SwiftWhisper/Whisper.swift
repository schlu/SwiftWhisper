import Foundation
import whisper_cpp

public class Whisper {
    private let whisperContext: OpaquePointer

    public var delegate: WhisperDelegate?
    public var params: WhisperParams
    public private(set) var inProgress = false

    internal var frameCount: Int? // For progress calculation (value not in `whisper_state` yet)
    internal var cancelCallback: (() -> Void)?

    public init(fromFileURL fileURL: URL, withParams params: WhisperParams = .default) {
        self.whisperContext = fileURL.relativePath.withCString { whisper_init_from_file($0) }
        self.params = params

        prepareCallbacks()
    }

    public init(fromData data: Data, withParams params: WhisperParams = .default) {
        var copy = data // Need to copy memory so we can gaurentee exclusive ownership over pointer

        self.whisperContext = copy.withUnsafeMutableBytes { whisper_init_from_buffer($0.baseAddress!, data.count) }
        self.params = params

        prepareCallbacks()
    }

    deinit {
        whisper_free(whisperContext)
    }

    private func prepareCallbacks() {
        /*
         C-style callbacks can't capture any references in swift, so we'll convert `self`
         to a pointer which whisper passes back as the `user_data` argument.

         We can unwrap that and obtain a copy of self inside the callback.
         */
        params.new_segment_callback_user_data = Unmanaged.passRetained(self).toOpaque()
        params.encoder_begin_callback_user_data = Unmanaged.passRetained(self).toOpaque()

        // swiftlint:disable line_length
        params.new_segment_callback = { (ctx: OpaquePointer?, _: OpaquePointer?, newSegmentCount: Int32, userData: UnsafeMutableRawPointer?) in
        // swiftlint:enable line_length
            guard let ctx, let userData else { return }
            let whisper = Unmanaged<Whisper>.fromOpaque(userData).takeUnretainedValue()
            guard let delegate = whisper.delegate else { return }

            let segmentCount = whisper_full_n_segments(ctx)
            var newSegments: [Segment] = []
            newSegments.reserveCapacity(Int(newSegmentCount))

            let startIndex = segmentCount - newSegmentCount

            for index in startIndex..<segmentCount {
                guard let text = whisper_full_get_segment_text(ctx, index) else { continue }
                let startTime = whisper_full_get_segment_t0(ctx, index)
                let endTime = whisper_full_get_segment_t1(ctx, index)

                newSegments.append(.init(
                    startTime: Int(startTime) * 10, // Time is given in ms/10, so correct for that
                    endTime: Int(endTime) * 10,
                    text: String(Substring(cString: text))
                ))
            }

            if let frameCount = whisper.frameCount,
               let lastSegmentTime = newSegments.last?.endTime {

                let fileLength = Double(frameCount * 1000) / Double(WHISPER_SAMPLE_RATE)
                let progress = Double(lastSegmentTime) / Double(fileLength)

                DispatchQueue.main.async {
                    delegate.whisper(whisper, didUpdateProgress: progress)
                }
            }

            DispatchQueue.main.async {
                delegate.whisper(whisper, didProcessNewSegments: newSegments, atIndex: Int(startIndex))
            }
        }

        params.encoder_begin_callback = { (_: OpaquePointer?, _: OpaquePointer?, userData: UnsafeMutableRawPointer?) in
            guard let userData else { return true }
            let whisper = Unmanaged<Whisper>.fromOpaque(userData).takeUnretainedValue()

            if whisper.cancelCallback != nil {
                return false
            }

            return true
        }
    }

    public func transcribe(audioFrames: [Float], completionHandler: @escaping (Result<[Segment], Error>) -> Void) {
        guard !inProgress else {
            completionHandler(.failure(WhisperError.instanceBusy))
            return
        }
        guard audioFrames.count > 0 else {
            completionHandler(.failure(WhisperError.invalidFrames))
            return
        }

        inProgress = true
        frameCount = audioFrames.count

        DispatchQueue.global(qos: .userInitiated).async { [unowned self] in

            whisper_full(whisperContext, params.whisperParams, audioFrames, Int32(audioFrames.count))

            let segmentCount = whisper_full_n_segments(whisperContext)

            var segments: [Segment] = []
            segments.reserveCapacity(Int(segmentCount))

            for index in 0..<segmentCount {
                guard let text = whisper_full_get_segment_text(whisperContext, index) else { continue }
                let startTime = whisper_full_get_segment_t0(whisperContext, index)
                let endTime = whisper_full_get_segment_t1(whisperContext, index)

                segments.append(
                    .init(
                        startTime: Int(startTime) * 10, // Correct for ms/10
                        endTime: Int(endTime) * 10,
                        text: String(Substring(cString: text))
                    )
                )
            }

            if let cancelCallback {
                DispatchQueue.main.async {
                    // Should cancel callback be called after delegate and completionHandler?
                    cancelCallback()

                    let error = WhisperError.cancelled

                    self.delegate?.whisper(self, didErrorWith: error)
                    completionHandler(.failure(error))
                }
            } else {
                DispatchQueue.main.async {
                    self.delegate?.whisper(self, didCompleteWithSegments: segments)
                    completionHandler(.success(segments))
                }
            }

            self.frameCount = nil
            self.cancelCallback = nil
            self.inProgress = false
        }
    }

    public func cancel(completionHandler: @escaping () -> Void) throws {
        guard inProgress else { throw WhisperError.cancellationError(.notInProgress) }
        guard cancelCallback == nil else { throw WhisperError.cancellationError(.pendingCancellation)}

        cancelCallback = completionHandler
    }

    @available(iOS 13, macOS 10.15, *)
    public func transcribe(audioFrames: [Float]) async throws -> [Segment] {
        return try await withCheckedThrowingContinuation { cont in
            self.transcribe(audioFrames: audioFrames) { result in
                switch result {
                case .success(let segments):
                    cont.resume(returning: segments)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }

    @available(iOS 13, macOS 10.15, *)
    public func cancel() async throws {
        return try await withCheckedThrowingContinuation { cont in
            do {
                try self.cancel {
                    cont.resume()
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
