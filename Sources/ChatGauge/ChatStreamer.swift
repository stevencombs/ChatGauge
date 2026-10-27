import ChatGaugeCore
import Foundation

/// Streams one /api/chat reply (NDJSON). Callbacks arrive on the main queue. Cancel to stop mid-reply.
final class ChatStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias ChunkHandler = (ChatChunk) -> Void
    typealias FinishHandler = (_ error: String?, _ cancelled: Bool) -> Void

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = NDJSONBuffer()
    private var status = 0
    private var errorBody = Data()
    private var cancelled = false
    private let onChunk: ChunkHandler
    private let onFinish: FinishHandler

    init(request: URLRequest, onChunk: @escaping ChunkHandler, onFinish: @escaping FinishHandler) {
        self.onChunk = onChunk
        self.onFinish = onFinish
        super.init()
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600      // a cold load of a big model can take a while before the first byte
        c.timeoutIntervalForResource = 3600
        c.urlCache = nil
        c.httpCookieStorage = nil
        session = URLSession(configuration: c, delegate: self, delegateQueue: .main)
        task = session?.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        cancelled = true
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if status != 200 {
            errorBody.append(data)
            return
        }
        for c in buffer.append(data) { onChunk(c) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if status == 200 { for c in buffer.finish() { onChunk(c) } }
        if cancelled { onFinish(nil, true); return }
        if let error { onFinish(OllamaError.unreachable(error.localizedDescription).description, false); return }
        if status != 200 {
            let msg = (try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any])?["error"] as? String
            onFinish(msg.map { OllamaError.friendly($0) } ?? OllamaError.http(status, nil).description, false)
            return
        }
        onFinish(nil, false)
    }
}
