import Foundation
import WebRTC
import Combine

class WebRTCManager: ObservableObject {
    private let webRTCClient: WebRTCClient
    private let signalingClient: SignalingClient
    
    @Published var connectionState: String = "Idle"
    
    private var sessionId: String?
    private var isCaller: Bool = false
    private var hasReceivedOffer: Bool = false
    
    // BUFFER: Stores candidates that arrive too early
    private var remoteCandidateQueue: [RTCIceCandidate] = []
    private var hasSetRemoteDescription: Bool = false
    
    init() {
        self.webRTCClient = WebRTCClient()
        self.signalingClient = SignalingClient()
        self.webRTCClient.delegate = self
    }
    
    // MARK: - User Actions
    
    func toggleMute(isMuted: Bool) {
        self.webRTCClient.muteAudio(isMuted)
    }
    
    func disconnect() {
        if let sessionId = sessionId {
            self.signalingClient.deleteCall(sessionId: sessionId)
        }
        self.webRTCClient.close()
        self.resetState()
    }
    
    func startMatchmaking() {
        self.resetState()
        DispatchQueue.main.async { self.connectionState = "Searching..." }
        
        signalingClient.findOrCreateSession { [weak self] sessionId, isCaller in
            guard let self = self else { return }
            self.sessionId = sessionId
            self.isCaller = isCaller
            
            DispatchQueue.main.async {
                self.connectionState = isCaller ? "Waiting for partner..." : "Connecting..."
            }
            
            if isCaller {
                self.startAsCaller()
            } else {
                self.startAsCallee(sessionId: sessionId)
            }
            
            // Start Listening for Candidates
            self.signalingClient.listenForRemoteCandidates(sessionId: sessionId, isCaller: isCaller) { [weak self] candidate in
                self?.handleRemoteCandidate(candidate)
            }
        }
    }
    
    // MARK: - Internal Logic
    
    private func resetState() {
        self.signalingClient.cancelListeners() // KILL ZOMBIE LISTENERS
        self.sessionId = nil
        self.hasReceivedOffer = false
        self.isCaller = false
        self.hasSetRemoteDescription = false
        self.remoteCandidateQueue.removeAll()
        DispatchQueue.main.async { self.connectionState = "Disconnected" }
    }
    
    private func handleRemoteCandidate(_ candidate: RTCIceCandidate) {
        if self.hasSetRemoteDescription {
            self.webRTCClient.set(remoteCandidate: candidate) { _ in }
        } else {
            // Buffer if not ready
            print("⏳ Buffering Candidate")
            self.remoteCandidateQueue.append(candidate)
        }
    }
    
    private func drainBufferedCandidates() {
        print("💧 Draining Queue (\(remoteCandidateQueue.count))")
        for candidate in remoteCandidateQueue {
            self.webRTCClient.set(remoteCandidate: candidate) { _ in }
        }
        remoteCandidateQueue.removeAll()
        self.hasSetRemoteDescription = true
    }
    
    private func startAsCaller() {
        self.webRTCClient.offer { [weak self] sdp in
            guard let self = self, let sessionId = self.sessionId else { return }
            self.signalingClient.send(sdp: sdp, sessionId: sessionId)
            
            self.signalingClient.listenForRemoteSdp(sessionId: sessionId) { [weak self] remoteSdp in
                guard let self = self, let remoteSdp = remoteSdp else {
                    self?.disconnect()
                    return
                }
                
                if remoteSdp.type == .answer {
                    print("✅ Received Answer")
                    self.webRTCClient.set(remoteSdp: remoteSdp) { _ in
                        self.drainBufferedCandidates()
                    }
                }
            }
        }
    }
    
    private func startAsCallee(sessionId: String) {
        self.signalingClient.listenForRemoteSdp(sessionId: sessionId) { [weak self] remoteSdp in
            guard let self = self, let remoteSdp = remoteSdp else {
                self?.disconnect()
                return
            }
            
            if remoteSdp.type == .offer && !self.hasReceivedOffer {
                self.hasReceivedOffer = true // LOCK LOOP
                print("✅ Received Offer")
                
                self.webRTCClient.set(remoteSdp: remoteSdp) { _ in
                    self.drainBufferedCandidates()
                    self.webRTCClient.answer { [weak self] localSdp in
                        guard let self = self else { return }
                        self.signalingClient.send(sdp: localSdp, sessionId: sessionId)
                    }
                }
            }
        }
    }
}

extension WebRTCManager: WebRTCClientDelegate {
    func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate) {
        if let sessionId = self.sessionId {
            self.signalingClient.send(candidate: candidate, sessionId: sessionId, isCaller: self.isCaller)
        }
    }
    
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState) {
        print("⚡️ WebRTC State: \(state.rawValue)")
        DispatchQueue.main.async {
            switch state {
            case .connected, .completed: self.connectionState = "Connected"
            case .disconnected, .failed, .closed: self.connectionState = "Disconnected"
            default: break
            }
        }
    }
    
    func webRTCClient(_ client: WebRTCClient, didReceiveData data: Data) {}
}
