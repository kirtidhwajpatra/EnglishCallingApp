import SwiftUI
import AVFoundation

// MARK: - App State
enum AppPhase {
    case home
    case searching
    case inCall
}

// MARK: - Main Controller
struct ContentView: View {
    @State private var currentPhase: AppPhase = .home
    @StateObject private var webRTCManager = WebRTCManager()

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()

            Group {
                switch currentPhase {
                case .home:
                    HomeView(currentPhase: $currentPhase, webRTCManager: webRTCManager)
                        .transition(.move(edge: .leading))
                    
                case .searching:
                    SearchingView(currentPhase: $currentPhase, webRTCManager: webRTCManager)
                        .transition(.opacity)
                    
                case .inCall:
                    CallInProgressView(currentPhase: $currentPhase, webRTCManager: webRTCManager)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeInOut(duration: 0.4), value: currentPhase)
        }
        // Listener to react to WebRTC state changes
        .onChange(of: webRTCManager.connectionState) { newState in
            print("UI Received State Update: \(newState)")
            
            if newState == "Connected" {
                currentPhase = .inCall
            }
            else if newState == "Disconnected" || newState == "Failed" {
                currentPhase = .home
            }
        }
    }
}

// MARK: - Views

struct HomeView: View {
    @Binding var currentPhase: AppPhase
    @ObservedObject var webRTCManager: WebRTCManager
    @ObservedObject var authManager = AuthManager.shared

    var body: some View {
        VStack(spacing: 30) {
            // Sign Out
            HStack {
                Spacer()
                Button("Sign Out") { authManager.signOut() }
                    .foregroundColor(.red)
                    .padding()
            }
            Spacer()
            
            // Title
            VStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .resizable().frame(width: 80, height: 80).foregroundColor(.blue)
                Text("English Talk").font(.largeTitle).fontWeight(.bold)
                Text("Practice speaking with learners worldwide.")
                    .font(.subheadline).foregroundColor(.gray)
            }
            Spacer()
            
            // Connect Button
            Button(action: {
                // 1. Move UI to Searching IMMEDIATELY
                currentPhase = .searching
                // 2. Trigger Logic
                // We do this in the SearchingView .onAppear, but we can also trigger it here to be safe
            }) {
                Text("Connect Now")
                    .font(.title3).fontWeight(.semibold).foregroundColor(.white)
                    .padding().frame(maxWidth: .infinity)
                    .background(Color.blue).cornerRadius(50)
            }
            .padding(.horizontal, 40)
            Spacer().frame(height: 50)
        }
    }
}

struct SearchingView: View {
    @Binding var currentPhase: AppPhase
    @ObservedObject var webRTCManager: WebRTCManager
    
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            ZStack {
                Circle().stroke(Color.blue.opacity(0.3), lineWidth: 4).frame(width: 150, height: 150)
                ProgressView().scaleEffect(2).tint(.blue)
            }
            
            // Show Status
            Text(webRTCManager.connectionState)
                .font(.headline).foregroundColor(.secondary)
            
            Spacer()
            Button("Cancel Search") {
                webRTCManager.disconnect() // Stop the search logic
                currentPhase = .home
            }
            .foregroundColor(.red).padding(.bottom, 50)
        }
        .padding()
        .onAppear {
            // Trigger logic when view appears
            if webRTCManager.connectionState == "Idle" || webRTCManager.connectionState == "Disconnected" {
                webRTCManager.startMatchmaking()
            }
        }
    }
}

struct CallInProgressView: View {
    @Binding var currentPhase: AppPhase
    @ObservedObject var webRTCManager: WebRTCManager
    
    @State private var isMuted = false
    @State private var callDurationSeconds = 0
    @State private var timer: Timer? = nil

    var body: some View {
        VStack {
            Spacer().frame(height: 60)
            VStack(spacing: 20) {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().frame(width: 120, height: 120)
                    .foregroundColor(.gray.opacity(0.5))
                Text("Connected").font(.headline).foregroundColor(.green)
                Text(formattedDuration).font(.title2).monospacedDigit().foregroundColor(.gray)
            }
            Spacer()
            HStack(spacing: 40) {
                Button(action: {
                    isMuted.toggle()
                    webRTCManager.toggleMute(isMuted: isMuted)
                }) {
                    VStack {
                        Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.title2).foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(isMuted ? Color.orange : Color.gray.opacity(0.3))
                            .clipShape(Circle())
                        Text("Mute").font(.caption).foregroundColor(.gray)
                    }
                }
                
                Button(action: endCall) {
                    Image(systemName: "phone.down.fill")
                        .font(.title).foregroundColor(.white)
                        .padding(25).background(Color.red)
                        .clipShape(Circle())
                }
            }
            .padding(.bottom, 50)
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    var formattedDuration: String {
        let minutes = callDurationSeconds / 60
        let seconds = callDurationSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.callDurationSeconds += 1
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func endCall() {
        stopTimer()
        webRTCManager.disconnect()
        // The View will automatically transition to .home via the .onChange listener
    }
}
