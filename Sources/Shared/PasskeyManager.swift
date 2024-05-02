import AuthenticationServices
import Foundation
import os

extension Notification.Name {
  static let PasskeyManagerModalSheetCanceled = Notification.Name(
    "PasskeyManagerModalSheetCanceledNotification")
  static let PasskeyManagerError = Notification.Name("PasskeyManagerErrorNotification")
  static let PasskeyRegistrationCompleted = Notification.Name(
    "PasskeyRegistrationCompletedNotification")
  static let PasskeyRegistrationFailed = Notification.Name("PasskeyRegistrationFailedNotification")
  static let PasskeyRegistrationCanceled = Notification.Name(
    "PasskeyRegistrationCanceledNotification")
  static let PasskeyAssertionCompleted = Notification.Name(
    "PasskeyAssertionCompletedNotification")
}

public struct Attestation {
  public let credentialId: String
  public let clientDataJson: String
  public let attestationObject: String
}

public struct PasskeyRegistrationResult {
  public let challenge: String
  public let attestation: Attestation
}

public enum PasskeyRegistrationError: Error {
  case missingRPID
  case unexpectedCredentialType
  case invalidClientDataJSON
  case registrationFailed(Error)
  case invalidAttestation
}

public enum PasskeyManagerError: Error {
  case unknownAuthorizationType
  case authorizationFailed(Error)
}

public class PasskeyManager: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  private let rpId: String
  private var presentationAnchor: ASPresentationAnchor?
  private var isPerformingModalRequest = false

  // Initialize with rpId and presentationAnchor
  public init(rpId: String, presentationAnchor: ASPresentationAnchor) {
    self.rpId = rpId
    self.presentationAnchor = presentationAnchor
  }

  public func registerPasskey(email: String) {

    let challenge = generateRandomBuffer()
    let userID = Data(UUID().uuidString.utf8)

    let publicKeyCredentialProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: rpId)

    let registrationRequest = publicKeyCredentialProvider.createCredentialRegistrationRequest(
      challenge: challenge,
      name: email.components(separatedBy: "@").first ?? "",
      userID: userID
    )

    let authorizationController = ASAuthorizationController(authorizationRequests: [
      registrationRequest
    ])
    authorizationController.delegate = self
    authorizationController.presentationContextProvider = self
    authorizationController.performRequests()

    isPerformingModalRequest = true
  }

  public func assertPasskey(challenge: Data) {
    let publicKeyCredentialProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: rpId)

    let assertionRequest = publicKeyCredentialProvider.createCredentialAssertionRequest(
      challenge: challenge)

    let authController = ASAuthorizationController(authorizationRequests: [assertionRequest])
    authController.delegate = self
    authController.presentationContextProvider = self
    authController.performRequests()

    isPerformingModalRequest = true
  }

  private func generateRandomBuffer() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes)
  }

  private func base64URLEncode(_ data: Data) -> String {
    let base64 = data.base64EncodedString()
    return
      base64
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  // MARK: - ASAuthorizationControllerDelegate

  public func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {

    let logger = Logger()
    switch authorization.credential {

    case let credentialRegistration as ASAuthorizationPlatformPublicKeyCredentialRegistration:

      guard let rawAttestationObject = credentialRegistration.rawAttestationObject else {
        notifyRegistrationFailed(error: PasskeyRegistrationError.invalidAttestation)
        return
      }

      guard
        let clientDataJSON = try? JSONDecoder().decode(
          ClientDataJSON.self, from: credentialRegistration.rawClientDataJSON)
      else {
        notifyRegistrationFailed(error: PasskeyRegistrationError.invalidClientDataJSON)
        return
      }

      let challenge = clientDataJSON.challenge

      let attestationObject = rawAttestationObject.base64URLEncodedString()
      let clientDataJson = credentialRegistration.rawClientDataJSON.base64URLEncodedString()
      let credentialId = credentialRegistration.credentialID.base64URLEncodedString()
        
        

      let attestation = Attestation(
        credentialId: credentialId, clientDataJson: clientDataJson, attestationObject: attestationObject)

      let registrationResult = PasskeyRegistrationResult(
        challenge: challenge, attestation: attestation)

      notifyRegistrationCompleted(result: registrationResult)
      return
    //        credentialRegistration.rawAttestationObject?.base64URLEncodedString()
    //
    //
    //      guard
    //        let clientDataJSON = try? JSONDecoder().decode(
    //          ClientDataJSON.self, from: credentialRegistration.rawClientDataJSON)
    //      else {
    //        notifyRegistrationFailed(error: PasskeyRegistrationError.invalidClientDataJSON)
    //        return
    //      }
    //
    //      guard let rawAttestationData = credentialRegistration.rawAttestationObject else {
    //        notifyRegistrationFailed(error: PasskeyRegistrationError.invalidAttestation)
    //        return
    //      }

    //    guard
    //      let attestation = try? JSONDecoder().decode(
    //        ClientDataJSON.self, from: rawAttestationData)
    //    else {
    //      notifyRegistrationFailed(error: PasskeyRegistrationError.invalidClientDataJSON)
    //      return
    //    }

    //        do {
    //            guard let jsonData = try JSONSerialization.data(withJSONObject: rawAttestationData, options: [])
    //            else {
    //                notifyRegistrationFailed(error: PasskeyRegistrationError.invalidAttestation)
    //                return
    //            }
    //
    //            guard let jsonString = String(data: jsonData, encoding: .utf8)  else {
    //                notifyRegistrationFailed(error: PasskeyRegistrationError.invalidAttestation)
    //                return
    //            }
    //        }
    //        catch {
    //
    //        }

    //      let attestation =
    //        String(data: attestationData, encoding: .utf8) ?? "Invalid attestation encoding"
    //
    //      let challenge = clientDataJSON.challenge

    //      let registrationResult = PasskeyRegistrationResult(
    //        challenge: challenge, attestation: attestation)
    //
    //      notifyRegistrationCompleted(result: registrationResult)

    case let credentialAssertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
      logger.log("A passkey was used to sign in: \(credentialAssertion)")
      notifyPasskeyAssertionCompleted(result: credentialAssertion)
    default:
      notifyPasskeyManagerError(error: PasskeyManagerError.unknownAuthorizationType)
    }

    isPerformingModalRequest = false
  }

  public func authorizationController(
    controller: ASAuthorizationController, didCompleteWithError error: Error
  ) {
    let logger = Logger()
    guard let authorizationError = error as? ASAuthorizationError else {
      isPerformingModalRequest = false
      logger.error("Unexpected authorization error: \(error.localizedDescription)")
      notifyPasskeyManagerError(error: PasskeyManagerError.authorizationFailed(error))
      return
    }

    if authorizationError.code == .canceled {
      if isPerformingModalRequest {
        notifyModalSheetCanceled()
      }
    } else {
      logger.error("Error: \((error as NSError).userInfo)")
      notifyPasskeyManagerError(error: PasskeyManagerError.authorizationFailed(error))
    }

    isPerformingModalRequest = false
  }

  struct ClientDataJSON: Codable {
    let challenge: String
  }

  // MARK: - ASAuthorizationControllerPresentationContextProviding

  public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor
  {
    return presentationAnchor!
  }

  // MARK: - Notification

  private func notifyRegistrationCompleted(result: PasskeyRegistrationResult) {
    NotificationCenter.default.post(
      name: .PasskeyRegistrationCompleted, object: self, userInfo: ["result": result])
  }

  private func notifyRegistrationFailed(error: PasskeyRegistrationError) {
    NotificationCenter.default.post(
      name: .PasskeyRegistrationFailed, object: self, userInfo: ["error": error])
  }

  private func notifyRegistrationCanceled() {
    NotificationCenter.default.post(name: .PasskeyRegistrationCanceled, object: self)
  }

  private func notifyModalSheetCanceled() {
    NotificationCenter.default.post(name: .PasskeyManagerModalSheetCanceled, object: self)
  }

  private func notifyPasskeyManagerError(error: PasskeyManagerError) {
    NotificationCenter.default.post(
      name: .PasskeyManagerError, object: self, userInfo: ["error": error])
  }

  private func notifyPasskeyAssertionCompleted(
    result: ASAuthorizationPlatformPublicKeyCredentialAssertion
  ) {
    NotificationCenter.default.post(
      name: .PasskeyAssertionCompleted, object: self, userInfo: ["result": result])
  }
}
