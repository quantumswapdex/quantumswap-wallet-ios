// KeychainWrapSidecar.swift (KeyMaterial layer 5)
// Placeholder for the biometric-unlock sidecar.
// The strongbox slot file (`StrongboxFileCodec`) carries
// `wrap.passwordWrap` only; it is byte-identical to the
// Android slot format at the wrap layer, and the codec
// rejects any extraneous `wrap.*` keys on read.
// If/when a biometric-unlock UI is added, its per-device
// wrap-key state (the AES envelope sealing `mainKey` under a
// device-bound key) must live in a sibling sidecar file
// rather than inside the strongbox envelope, so the slot file
// remains portable byte-for-byte across iOS and Android. The
// device-bound key itself must be stored in the Keychain with
// `kSecAttrAccessControl = biometryCurrentSet` so a coerced
// enrollment immediately invalidates the wrap.
// This file is intentionally a stub. It exists so the
// architectural placement is documented at the layer that
// would own it; do NOT add fields to the strongbox slot file
// for this purpose.
import Foundation

public enum KeychainWrapSidecar {
    /// Suggested sidecar file name (sibling of the strongbox
    /// slot files in the same Application Support directory).
    /// Reserved: no current writer creates this file.
    public static let sidecarFileName = "strongbox.wrap.sidecar.json"

    /// Returns `true` if a biometric sidecar exists on disk.
    /// Always `false` in the current build; reserved for a
    /// future biometric-unlock implementation.
    public static func exists(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent(sidecarFileName)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
