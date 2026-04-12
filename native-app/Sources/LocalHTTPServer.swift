import Foundation
import Network

// MARK: - LocalHTTPServer — Local HTTP Server
// Provides valid HTTP Referer header for YouTube embeds

class LocalHTTPServer {
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var isReady = false

    func start(completion: @escaping (UInt16) -> Void) {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: .any)
        } catch {
            NSLog("[FloatVideo] HTTP server failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener?.port?.rawValue {
                    self?.port = port
                    self?.isReady = true
                    NSLog("[FloatVideo] HTTP server ready on port \(port)")
                    completion(port)
                }
            case .failed(let error):
                NSLog("[FloatVideo] HTTP server failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isReady = false
        NSLog("[FloatVideo] HTTP server stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        // Read HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let data = data, error == nil else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            self?.processRequest(request, connection: connection)
        }
    }

    private func processRequest(_ request: String, connection: NWConnection) {
        // Parse request line: GET /play?v=VIDEO_ID HTTP/1.1
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(connection: connection, code: 400, message: "Bad Request")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(connection: connection, code: 400, message: "Bad Request")
            return
        }

        let path = parts[1]

        if path.hasPrefix("/play") {
            handlePlayRequest(path: path, connection: connection)
        } else if path == "/health" {
            sendResponse(connection: connection, body: "OK", contentType: "text/plain")
        } else {
            sendErrorResponse(connection: connection, code: 404, message: "Not Found")
        }
    }

    // MARK: - Play Request Handler

    private func handlePlayRequest(path: String, connection: NWConnection) {
        // Parse query parameters
        guard let urlComponents = URLComponents(string: "http://localhost\(path)") else {
            sendErrorResponse(connection: connection, code: 400, message: "Invalid URL")
            return
        }

        let queryItems = urlComponents.queryItems ?? []
        let videoId = queryItems.first(where: { $0.name == "v" })?.value ?? ""
        let site = queryItems.first(where: { $0.name == "site" })?.value ?? "youtube"
        let startTime = queryItems.first(where: { $0.name == "t" })?.value ?? "0"

        if videoId.isEmpty {
            sendErrorResponse(connection: connection, code: 400, message: "Missing video ID")
            return
        }

        let html: String
        switch site {
        case "youtube":
            html = buildYouTubePlayerHTML(videoId: videoId, startTime: startTime)
        default:
            html = buildGenericEmbedHTML(videoId: videoId)
        }

        sendResponse(connection: connection, body: html, contentType: "text/html; charset=utf-8")
    }

    // MARK: - YouTube Player HTML

    private func buildYouTubePlayerHTML(videoId: String, startTime: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Float Video</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
                .wrap {
                    position: fixed; top: 0; left: 0;
                    width: 960px; height: 540px;
                    transform-origin: top left;
                    transform: scale(1);
                }
                iframe {
                    width: 100%; height: 100%;
                    border: none; display: block;
                }
            </style>
        </head>
        <body>
            <div class="wrap">
                <iframe id="ytplayer"
                    src="https://www.youtube.com/embed/\(videoId)?autoplay=1&enablejsapi=1&controls=0&rel=0&modestbranding=1&start=\(startTime)&playsinline=1"
                    allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                    referrerpolicy="strict-origin-when-cross-origin"
                    allowfullscreen>
                </iframe>
            </div>
            <script>
            // Scale-to-fit: render YouTube iframe at 960x540 internally (a clean
            // size for YouTube's player layout) and use CSS transform:scale() to
            // visually shrink to fit when the window is smaller. Prevents YouTube's
            // internal layout from reflowing and leaving a black bar at small sizes.
            (function() {
                var BASE_W = 960, BASE_H = 540;
                function fit() {
                    var vw = window.innerWidth, vh = window.innerHeight;
                    var wrap = document.querySelector('.wrap');
                    if (!wrap) return;
                    if (vw < BASE_W || vh < BASE_H) {
                        wrap.style.width = BASE_W + 'px';
                        wrap.style.height = BASE_H + 'px';
                        var s = Math.min(vw / BASE_W, vh / BASE_H);
                        wrap.style.transform = 'scale(' + s + ')';
                    } else {
                        wrap.style.width = vw + 'px';
                        wrap.style.height = vh + 'px';
                        wrap.style.transform = 'scale(1)';
                    }
                }
                window.addEventListener('resize', fit);
                fit();
            })();
            var tag = document.createElement('script');
            tag.src = 'https://www.youtube.com/iframe_api';
            document.head.appendChild(tag);
            var player;
            function onYouTubeIframeAPIReady() {
                player = new YT.Player('ytplayer', {
                    events: { 'onReady': function(){} }
                });
            }
            window.getPlayerState = function() {
                if (!player || !player.getCurrentTime) return null;
                try {
                    return {
                        ct: player.getCurrentTime(),
                        dur: player.getDuration(),
                        vol: player.getVolume() / 100,
                        muted: player.isMuted(),
                        paused: player.getPlayerState() === 2
                    };
                } catch(e) { return null; }
            };
            window.playerCommand = function(cmd, val) {
                if (!player) return;
                try {
                    if (cmd === 'play') player.playVideo();
                    if (cmd === 'pause') player.pauseVideo();
                    if (cmd === 'seek') player.seekTo(val, true);
                    if (cmd === 'volume') player.setVolume(val * 100);
                    if (cmd === 'mute') player.mute();
                    if (cmd === 'unmute') player.unMute();
                } catch(e) {}
            };
            </script>
        </body>
        </html>
        """
    }

    private func buildGenericEmbedHTML(videoId: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                * { margin: 0; padding: 0; }
                html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
                iframe { width: 100%; height: 100%; border: none; }
            </style>
        </head>
        <body>
            <iframe src="\(videoId)" allow="autoplay; encrypted-media" allowfullscreen></iframe>
        </body>
        </html>
        """
    }

    // MARK: - HTTP Response

    private func sendResponse(connection: NWConnection, body: String, contentType: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r

        """.data(using: .utf8)! + bodyData

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendErrorResponse(connection: NWConnection, code: Int, message: String) {
        let body = "<h1>\(code) \(message)</h1>"
        let bodyData = body.data(using: .utf8) ?? Data()
        let response = """
        HTTP/1.1 \(code) \(message)\r
        Content-Type: text/html\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """.data(using: .utf8)! + bodyData

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
