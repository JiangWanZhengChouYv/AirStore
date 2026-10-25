//
//  LocalGitHubProxy.swift
//  SideStore
//
//  A loopback-only HTTP CONNECT proxy that maps selected GitHub hosts to the IPs published by
//  GitHub520. URLSession keeps doing TLS and certificate validation itself; the proxy only routes
//  the TCP connection to the chosen address, so nothing in /etc/hosts (or the system DNS) changes.
//

import Foundation
import Network

final class LocalGitHubProxy: @unchecked Sendable
{
    static let shared = LocalGitHubProxy()

    private let queue = DispatchQueue(label: "io.airstore.local-github-proxy")
    private var listener: NWListener?
    private var hosts: [String: String] = [:]
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    private var listeningPort: UInt16?

    var log: (@Sendable (String) -> Void)?

    private init() {}

    var port: UInt16? {
        self.queue.sync { self.listeningPort }
    }

    /// The local proxy port to use for a URL, only when that host is in the GitHub520 map.
    func proxyPort(for host: String?) -> UInt16? {
        guard let host = host?.lowercased() else { return nil }
        return self.queue.sync {
            guard let port = self.listeningPort, self.hosts[host] != nil else { return nil }
            return port
        }
    }

    func updateHosts(_ hosts: [String: String]) {
        self.queue.async {
            self.hosts = hosts
            if !hosts.isEmpty {
                self.startLocked()
            }
        }
    }

    func start() {
        self.queue.async { self.startLocked() }
    }

    private func startLocked() {
        guard self.listener == nil, !self.hosts.isEmpty else { return }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        do
        {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state
                {
                case .ready:
                    self.listeningPort = listener.port?.rawValue
                    self.log?("[LocalGitHubProxy] listening on 127.0.0.1:\(self.listeningPort ?? 0) for \(self.hosts.count) GitHub hosts")
                case .failed(let error):
                    self.log?("[LocalGitHubProxy] listener failed: \(error)")
                    self.listener = nil
                    self.listeningPort = nil
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: self.queue)
        }
        catch
        {
            self.log?("[LocalGitHubProxy] could not start: \(error)")
        }
    }

    private func accept(_ connection: NWConnection)
    {
        if case let .hostPort(host, _) = connection.endpoint
        {
            let peer = "\(host)"
            guard ["127.0.0.1", "::1", "localhost"].contains(peer) else {
                connection.cancel()
                return
            }
        }

        let proxyConnection = ProxyConnection(client: connection, queue: self.queue, hosts: self.hosts) { [weak self] identifier in
            self?.connections.removeValue(forKey: identifier)
        } log: { [weak self] message in
            self?.log?(message)
        }
        self.connections[ObjectIdentifier(proxyConnection)] = proxyConnection
        proxyConnection.start()
    }
}

private final class ProxyConnection: @unchecked Sendable
{
    private static let connectTimeout: TimeInterval = 8

    private let client: NWConnection
    private let queue: DispatchQueue
    private let hosts: [String: String]
    private let completion: @Sendable (ObjectIdentifier) -> Void
    private let log: @Sendable (String) -> Void

    private var upstream: NWConnection?
    private var headerBuffer = Data()
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var upstreamIsReady = false
    private var isFinished = false

    init(client: NWConnection,
         queue: DispatchQueue,
         hosts: [String: String],
         completion: @escaping @Sendable (ObjectIdentifier) -> Void,
         log: @escaping @Sendable (String) -> Void)
    {
        self.client = client
        self.queue = queue
        self.hosts = hosts
        self.completion = completion
        self.log = log
    }

    func start()
    {
        self.client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
        }
        self.client.start(queue: self.queue)
        self.receiveHeaders()
    }

    private func receiveHeaders()
    {
        self.client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data
            {
                self.headerBuffer.append(data)
            }

            if let headerEnd = self.headerBuffer.range(of: Data("\r\n\r\n".utf8))
            {
                let headerData = self.headerBuffer[..<headerEnd.upperBound]
                let leftover = Data(self.headerBuffer[headerEnd.upperBound...])
                self.handleConnect(header: String(decoding: headerData, as: UTF8.self), leftover: leftover)
                return
            }

            if isComplete || error != nil || self.headerBuffer.count > 16_384
            {
                self.finish()
                return
            }

            self.receiveHeaders()
        }
    }

    private func handleConnect(header: String, leftover: Data)
    {
        guard let firstLine = header.split(separator: "\r\n").first else {
            self.finish()
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else {
            self.respond("HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        }

        guard let (host, port) = ProxyConnection.parseHostPort(String(parts[1])) else {
            self.respond("HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        }

        let targetHost = self.hosts[host.lowercased()] ?? host
        self.log("[LocalGitHubProxy] CONNECT \(host):\(port) -> \(targetHost)")

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(targetHost),
            port: NWEndpoint.Port(rawValue: port) ?? 443
        )
        let upstream = NWConnection(to: endpoint, using: .tcp)
        self.upstream = upstream

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, !self.upstreamIsReady else { return }
            self.log("[LocalGitHubProxy] \(host) timed out connecting to \(targetHost)")
            self.respond("HTTP/1.1 502 Bad Gateway\r\n\r\n")
        }
        self.connectTimeoutWorkItem = timeoutWorkItem
        self.queue.asyncAfter(deadline: .now() + ProxyConnection.connectTimeout, execute: timeoutWorkItem)

        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state
            {
            case .ready:
                guard !self.isFinished else { return }
                self.upstreamIsReady = true
                self.connectTimeoutWorkItem?.cancel()
                self.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil {
                        self.finish()
                        return
                    }
                    if !leftover.isEmpty {
                        self.sendToUpstream(leftover)
                    }
                    self.relayClientToUpstream()
                    self.relayUpstreamToClient()
                })
            case .failed(let error):
                self.log("[LocalGitHubProxy] upstream \(targetHost) failed: \(error)")
                self.respond("HTTP/1.1 502 Bad Gateway\r\n\r\n")
            default:
                break
            }
        }
        upstream.start(queue: self.queue)
    }

    private func relayClientToUpstream()
    {
        self.client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.sendToUpstream(data)
            }
            if isComplete || error != nil {
                self.finish()
                return
            }
            self.relayClientToUpstream()
        }
    }

    private func relayUpstreamToClient()
    {
        self.upstream?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.sendToClient(data)
            }
            if isComplete || error != nil {
                self.finish()
                return
            }
            self.relayUpstreamToClient()
        }
    }

    private func sendToUpstream(_ data: Data)
    {
        self.upstream?.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finish() }
        })
    }

    private func sendToClient(_ data: Data)
    {
        self.client.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finish() }
        })
    }

    private func respond(_ response: String)
    {
        guard !self.isFinished else { return }
        self.client.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish()
    {
        guard !self.isFinished else { return }
        self.isFinished = true
        self.connectTimeoutWorkItem?.cancel()
        self.client.cancel()
        self.upstream?.cancel()
        self.completion(ObjectIdentifier(self))
    }

    private static func parseHostPort(_ value: String) -> (String, UInt16)?
    {
        if value.hasPrefix("[")
        {
            guard let closing = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<closing])
            let remainder = value[value.index(after: closing)...]
            let port = remainder.hasPrefix(":") ? UInt16(remainder.dropFirst()) : 443
            return port.map { (host, $0) }
        }

        guard let separator = value.lastIndex(of: ":") else {
            return (value, 443)
        }
        let host = String(value[..<separator])
        guard let port = UInt16(value[value.index(after: separator)...]) else { return nil }
        return (host, port)
    }
}
