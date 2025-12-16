import Foundation
import FirebaseFirestore
import WebRTC

final class SignalingClient {
    
    private let db = Firestore.firestore()
    
    // EDGE CASE FIX: Track listeners to cancel them later
    private var sdpListener: ListenerRegistration?
    private var candidateListener: ListenerRegistration?
    
    func cancelListeners() {
        sdpListener?.remove()
        candidateListener?.remove()
        sdpListener = nil
        candidateListener = nil
        print("🛑 Signaling Listeners Cancelled")
    }
    
    func findOrCreateSession(completion: @escaping (_ sessionId: String, _ isCaller: Bool) -> Void) {
        db.collection("calls")
            .whereField("status", isEqualTo: "waiting")
            .getDocuments { (snapshot, error) in
                
                var validSessionId: String?
                
                if let documents = snapshot?.documents {
                    for document in documents {
                        let data = document.data()
                        if let created = data["created"] as? Timestamp {
                            // Check if room is older than 2 minutes
                            if Date().timeIntervalSince(created.dateValue()) > 120 {
                                print("🗑 Deleting stale room: \(document.documentID)")
                                self.db.collection("calls").document(document.documentID).delete()
                            } else {
                                // Found a valid, recent room
                                validSessionId = document.documentID
                                break
                            }
                        } else {
                            // No timestamp? Delete it to be safe
                            self.db.collection("calls").document(document.documentID).delete()
                        }
                    }
                }
                
                if let sessionId = validSessionId {
                    print("✅ Found existing valid room: \(sessionId)")
                    self.db.collection("calls").document(sessionId).updateData(["status": "matched"])
                    completion(sessionId, false)
                } else {
                    // Create new room
                    var ref: DocumentReference? = nil
                    ref = self.db.collection("calls").addDocument(data: [
                        "status": "waiting",
                        "created": FieldValue.serverTimestamp()
                    ]) { err in
                        if let err = err {
                            print("❌ Error creating room: \(err)")
                        } else {
                            print("✅ Created new room: \(ref!.documentID)")
                            completion(ref!.documentID, true)
                        }
                    }
                }
            }
    }
    
    func deleteCall(sessionId: String) {
        db.collection("calls").document(sessionId).delete()
    }
    
    func send(sdp: RTCSessionDescription, sessionId: String) {
        let typeStr = (sdp.type == .offer) ? "offer" : "answer"
        db.collection("calls").document(sessionId).setData([typeStr: ["type": typeStr, "sdp": sdp.sdp]], merge: true)
    }
    
    func send(candidate: RTCIceCandidate, sessionId: String, isCaller: Bool) {
        let collection = isCaller ? "callerCandidates" : "calleeCandidates"
        let data: [String: Any] = ["candidate": candidate.sdp, "sdpMid": candidate.sdpMid ?? "", "sdpMLineIndex": candidate.sdpMLineIndex]
        db.collection("calls").document(sessionId).collection(collection).addDocument(data: data)
    }
    
    func listenForRemoteSdp(sessionId: String, completion: @escaping (RTCSessionDescription?) -> Void) {
        // Cancel old listener if exists
        sdpListener?.remove()
        
        sdpListener = db.collection("calls").document(sessionId).addSnapshotListener { (documentSnapshot, error) in
            guard let document = documentSnapshot, document.exists else {
                print("⚠️ Call Document Deleted (Remote Hangup)")
                completion(nil)
                return
            }
            
            guard let data = document.data() else { return }
            
            if let offerData = data["offer"] as? [String: Any], let sdp = offerData["sdp"] as? String {
                completion(RTCSessionDescription(type: .offer, sdp: sdp))
            }
            
            if let answerData = data["answer"] as? [String: Any], let sdp = answerData["sdp"] as? String {
                completion(RTCSessionDescription(type: .answer, sdp: sdp))
            }
        }
    }
    
    func listenForRemoteCandidates(sessionId: String, isCaller: Bool, completion: @escaping (RTCIceCandidate) -> Void) {
        // Cancel old listener
        candidateListener?.remove()
        
        let collection = isCaller ? "calleeCandidates" : "callerCandidates"
        candidateListener = db.collection("calls").document(sessionId).collection(collection).addSnapshotListener { (querySnapshot, error) in
            guard let snapshot = querySnapshot else { return }
            snapshot.documentChanges.forEach { change in
                if change.type == .added {
                    let data = change.document.data()
                    if let sdp = data["candidate"] as? String, let sdpMid = data["sdpMid"] as? String, let sdpMLineIndex = data["sdpMLineIndex"] as? Int32 {
                        completion(RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid))
                    }
                }
            }
        }
    }
}
