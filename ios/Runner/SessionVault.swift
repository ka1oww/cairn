import Flutter
import Foundation
import Security

/// The Keychain-backed half of the `cairn/session_vault` platform edge.
///
/// Dart sends one JSON value containing the anonymous account id and refresh
/// token. Keeping them in one generic-password item makes rotation atomic and
/// `ThisDeviceOnly` keeps the anonymous phone identity off backups and other
/// devices.
enum SessionKeychain {
  static let service = "com.ka1o.cairn.gotrue-session"
  static let account = "anonymous-account"

  static func read(
    service: String = service,
    account: String = account
  ) throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = found as? Data else {
      throw KeychainFailure(status)
    }
    guard let value = String(data: data, encoding: .utf8) else {
      throw KeychainFailure(errSecDecode)
    }
    return value
  }

  static func write(
    _ value: String?,
    service: String = service,
    account: String = account
  ) throws {
    let key: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    guard let value else {
      let status = SecItemDelete(key as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainFailure(status)
      }
      return
    }

    let data = Data(value.utf8)
    let updateStatus = SecItemUpdate(
      key as CFDictionary,
      [kSecValueData: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainFailure(updateStatus)
    }

    var item = key
    item[kSecValueData] = data
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainFailure(addStatus)
    }
  }
}

private struct KeychainFailure: Error {
  let status: OSStatus

  init(_ status: OSStatus) {
    self.status = status
  }
}

enum SessionVaultChannel {
  static let channelName = "cairn/session_vault"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "read":
          result(try SessionKeychain.read())
        case "write":
          guard call.arguments == nil || call.arguments is NSNull || call.arguments is String else {
            result(
              FlutterError(
                code: "invalid_session",
                message: "The session value was not text.",
                details: nil
              )
            )
            return
          }
          try SessionKeychain.write(call.arguments as? String)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch let failure as KeychainFailure {
        result(
          FlutterError(
            code: "keychain_\(failure.status)",
            message: "The session Keychain item could not be accessed.",
            details: nil
          )
        )
      } catch {
        result(
          FlutterError(
            code: "keychain",
            message: "The session Keychain item could not be accessed.",
            details: nil
          )
        )
      }
    }
  }
}
