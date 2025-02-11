//
//  DeeplinkClient.swift
//  metamask-ios-sdk
//

import UIKit
import Foundation


public class DeeplinkClient: CommClient {
    
    private let session: SessionManager
    private var channelId: String = ""
    private let dappScheme: String
    
    public var appMetadata: AppMetadata?
    public var trackEvent: ((Event, [String : Any]) -> Void)?
    public var handleResponse: (([String: Any]) -> Void)?
    
    private let keyExchange: KeyExchange
    private let deeplinkManager: DeeplinkManager
    
    public var sessionDuration: TimeInterval {
        get {
            session.sessionDuration
        } set {
            session.sessionDuration = newValue
        }
    }
    
    var requestJobs: [RequestJob] = []
    
    init(session: SessionManager,
         keyExchange: KeyExchange,
         deeplinkManager: DeeplinkManager,
         dappScheme: String
    ) {
        self.session = session
        self.keyExchange = keyExchange
        self.deeplinkManager = deeplinkManager
        self.dappScheme = dappScheme
        setupClient()
        setupCallbacks()
    }
    
    private func setupCallbacks() {
        self.deeplinkManager.onReceiveMessage = handleMessage
        self.deeplinkManager.decryptMessage = keyExchange.decryptMessage
    }
    
    private func setupClient() {
        let sessionInfo = session.fetchSessionConfig()
        channelId = sessionInfo.0.sessionId
    }
    
    public func clearSession() {
        track(event: .disconnected)
        session.clear()
        setupClient()
    }
    
    private func sendMessage(_ message: String) {
        let deeplink = "metamask://\(message)"
        guard
            let urlString = deeplink.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: urlString)
        else { return }

        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }
    
    public func handleUrl(_ url: URL) {
        deeplinkManager.handleUrl(url)
    }
    
    func sendMessage(_ deeplink: Deeplink) {
        switch deeplink {
        case .connect(_, let channelId, let request):
            let originatorInfo = originatorInfo().toJsonString()?.base64Encode() ?? ""
            var message = "connect?scheme=\(dappScheme)&channelId=\(channelId)&comm=deeplinking&originatorInfo=\(originatorInfo)"
            if let request = request {
                message.append("&request=\(request)")
            }
            sendMessage(message)
        case .mmsdk(let message, _, let channelId):
            let message = "mmsdk?scheme=\(dappScheme)&message=\(message)&channelId=\(channelId ?? "")"
            Logging.log("DeeplinkClient:: Sending message \(message)")
            sendMessage(message)
        }
    }
    
    public func connect(with request: String? = nil) {
        track(event: .connectionRequest)
        
        sendMessage(.connect(
            pubkey: nil,
            channelId: channelId,
            request: request
        ))
    }
    
    public func track(event: Event) {
        let id = channelId
        var parameters: [String: Any] = ["id": id]

        switch event {
        case .connected,
                .disconnected,
                .reconnectionRequest,
                .connectionAuthorised,
                .connectionRejected,
                .sdkRpcRequestDone:
            break
        case .connectionRequest, .sdkRpcRequest:
            let additionalParams: [String: Any] = [
                "commLayer": "deeplinking",
                "sdkVersion": SDKInfo.version,
                "url": appMetadata?.url ?? "",
                "title": appMetadata?.name ?? "",
                "platform": SDKInfo.platform
            ]
            parameters.merge(additionalParams) { current, _ in current }
        }
        
        trackEvent?(event, parameters)
    }
}

extension DeeplinkClient {
    public func disconnect() {
        track(event: .disconnected)
    }
    
    public func terminateConnection() {
        track(event: .disconnected)
    }
    
    public func addRequest(_ job: @escaping RequestJob) {
        requestJobs.append(job)
    }
    
    func runQueuedJobs() {
        while !requestJobs.isEmpty {
            let job = requestJobs.popLast()
            job?()
        }
    }
    
    public func sendMessage(_ message: String, encrypt: Bool) {
        let base64Encoded = message.base64Encode() ?? ""
        
        let deeplink: Deeplink = .mmsdk(
            message: base64Encoded,
            pubkey: nil,
            channelId: channelId
        )
        sendMessage(deeplink)
    }
    
    public func handleMessage(_ message: String) {
        do {
            guard let data = message.data(using: .utf8) else {
                Logging.error("DeeplinkClient:: Cannot convert message to data: \(message)")
                return
            }
            
            let json: [String: Any] = try JSONSerialization.jsonObject(
                with: data,
                options: []
            )
                as? [String: Any] ?? [:]
            
            if json["type"] as? String == "terminate" {
                disconnect()
                Logging.log("Connection terminated")
            } else if json["type"] as? String == "ready" {
                Logging.log("DeeplinkClient:: Connection is ready")
                runQueuedJobs()
                return
            }
            
            guard let data = json["data"] as? [String: Any] else {
                Logging.log("DeeplinkClient:: Ignoring response \(json)")
                return
            }
            handleResponse?(data)
        } catch {
            Logging.error("DeeplinkClient:: Could not convert message to json. Message: \(message)\nError: \(error)")
        }
    }
}

