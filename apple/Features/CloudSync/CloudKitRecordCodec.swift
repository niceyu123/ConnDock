import CloudKit
import Foundation

enum CloudKitRecordCodec {
  static let recordType = "SSHClientConfigV1"
  static let zoneID = CKRecordZone.ID(
    zoneName: "SSHClientPrivateV1", ownerName: CKCurrentUserDefaultName)

  static func record(from snapshot: SyncRecordSnapshot) throws -> CKRecord {
    let id = CKRecord.ID(recordName: snapshot.document.identity.recordName, zoneID: zoneID)
    let record: CKRecord
    if let fields = snapshot.systemFields {
      let decoder = try NSKeyedUnarchiver(forReadingFrom: fields)
      decoder.requiresSecureCoding = true
      defer { decoder.finishDecoding() }
      guard let cached = CKRecord(coder: decoder), cached.recordID == id,
        cached.recordType == recordType
      else { throw CloudSyncFailure.invalidRecord }
      record = cached
    } else {
      record = CKRecord(recordType: recordType, recordID: id)
    }
    record.encryptedValues["payloadV1"] = try snapshot.document.encoded() as NSData
    return record
  }

  static func snapshot(from record: CKRecord) throws -> SyncRecordSnapshot {
    guard record.recordType == recordType, record.recordID.zoneID == zoneID,
      record.encryptedValues.allKeys().contains("payloadV1"),
      let data = record.encryptedValues["payloadV1"] as? Data
    else { throw CloudSyncFailure.invalidRecord }
    let document = try SyncDocument.decode(data)
    guard document.identity.recordName == record.recordID.recordName else {
      throw CloudSyncFailure.invalidRecord
    }
    let encoder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: encoder)
    encoder.finishEncoding()
    return SyncRecordSnapshot(document: document, systemFields: encoder.encodedData)
  }
}
