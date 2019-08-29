//
//  CKMTransaction+CoreDataClass.swift
//  DropBit
//
//  Created by BJ Miller on 4/25/18.
//  Copyright © 2018 Coin Ninja, LLC. All rights reserved.
//
//

import Foundation
import CoreData
import PhoneNumberKit

@objc(CKMTransaction)
public class CKMTransaction: NSManagedObject {

  public override func awakeFromInsert() {
    super.awakeFromInsert()
    setPrimitiveValue("", forKey: #keyPath(CKMTransaction.txid))
    setPrimitiveValue(false, forKey: #keyPath(CKMTransaction.isSentToSelf))
    setPrimitiveValue(false, forKey: #keyPath(CKMTransaction.broadcastFailed))
  }

  static let confirmationThreshold = 1
  static let fullyConfirmedThreshold = 6

  static let invitationTxidPrefix = "Invitation_"
  static let failedTxidPrefix = "Failed_"

  func configure(
    with txResponse: TransactionResponse,
    in context: NSManagedObjectContext,
    relativeToBlockHeight blockHeight: Int,
    fullSync: Bool
    ) {
    context.performAndWait {
      // configure the tx here
      if let tempSentTx = temporarySentTransaction, txResponse.txid == txid {
        context.delete(tempSentTx)
      }
      txid = txResponse.txid
      blockHash = txResponse.blockHash
      confirmations = (txResponse.blockHash ?? "").isEmpty ? 0 : txResponse.blockheight.map { (blockHeight - $0) + 1 } ?? 0
      date = txResponse.receivedTime ?? txResponse.date
      sortDate = txResponse.sortDate
      network = "btc://main"

      // vins
      let vinArray = txResponse.vinResponses.map { (vinResponse: TransactionVinResponse) -> CKMVin in
        let vin = CKMVin.findOrCreate(with: vinResponse, in: context, fullSync: fullSync)
        vin.transaction = self
        return vin
      }
      self.vins = Set(vinArray)

      // vouts
      let voutArray = txResponse.voutResponses.compactMap { (voutResponse: TransactionVoutResponse) -> CKMVout? in
        let vout = CKMVout.findOrCreate(with: voutResponse, in: context, fullSync: fullSync)
        vout?.transaction = self
        return vout
      }
      self.vouts = Set(voutArray)

      isIncoming = calculateIsIncoming(in: context)

      let atss = CKMAddressTransactionSummary.find(byTxid: txResponse.txid, in: context)
      addressTransactionSummaries = atss.asSet()
      atss.forEach { $0.transaction = self } // just being extra careful to ensure bi-directional integrity

      if !isIncoming {
        self.isSentToSelf = txResponse.isSentToSelf
      }
    }
  }

  func calculateIsSentToSelf(in context: NSManagedObjectContext) -> Bool {
    // any changes to this method should also change TransactionDataWorker's isSentToSelf calculation

    guard invitation == nil else { return false }

    if let temp = temporarySentTransaction {
      return temp.isSentToSelf
    } else {
      // regular transaction
      let allVoutAddresses = vouts.flatMap { $0.addressIDs }
      let ownedVoutAddresses = allVoutAddresses
        .compactMap { CKMAddress.find(withAddress: $0, in: context) }

      let numberOfVinsBelongingToWallet = vins.filter { $0.belongsToWallet }.count

      let sentToSelf = (numberOfVinsBelongingToWallet == vins.count) && (allVoutAddresses.count == ownedVoutAddresses.count)
      return sentToSelf
    }
  }

  func calculateIsIncoming(in context: NSManagedObjectContext) -> Bool {
    if let invitation = self.invitation {
      return invitation.side == .receiver
    }
    let txReceivedFunds = vouts.compactMap { $0.address }.filter { $0.isReceiveAddress }.isNotEmpty
    let txSentFunds = vins.filter { $0.belongsToWallet }.asArray().isNotEmpty
    return txReceivedFunds && !txSentFunds
  }

  /// Configures a newly created Transaction object with an instance of OutgoingTransactionData DTO.
  ///
  /// - Parameters:
  ///   - outgoingTransactionData: The DTO (data transfer object) which accumulates data about the
  ///     outgoing transaction through the send flow. The included SharedPayloadDTO is ignored by this function.
  ///   - phoneNumber: Optional PhoneNumber. If nil, will attempt to find-or-create by phone number string in
  ///     outgoingTransactionData.
  ///   - context: The NSManagedObjectContext within which this operation will be executed.
  ///     The caller of this method should use `perform` or `performAndWait` and call this method inside that block.
  func configure(with outgoingTransactionData: OutgoingTransactionData, phoneNumber: CKMPhoneNumber? = nil, in context: NSManagedObjectContext) {
    // self.txid should remain as an empty string so that the outgoingTransactionData.txid UUID
    // doesn't trigger a 4xx error when sending txids to the server

    context.performAndWait {
      self.sortDate = Date()
      self.date = self.sortDate
      self.isSentToSelf = outgoingTransactionData.sentToSelf
      self.isIncoming = false
      self.memo = outgoingTransactionData.sharedPayloadDTO?.memo

      if outgoingTransactionData.txid.isNotEmpty {
        self.txid = outgoingTransactionData.txid
      }

      if self.txid.starts(with: CKMTransaction.invitationTxidPrefix) {
        self.txid = outgoingTransactionData.txid
      }

      // counterparty address
      counterpartyAddress = CKMCounterpartyAddress.findOrCreate(withAddress: outgoingTransactionData.destinationAddress, in: context)

      // temporary sent transaction
      let tempTx = temporarySentTransaction ?? CKMTemporarySentTransaction(insertInto: context)
      tempTx.amount = outgoingTransactionData.amount
      tempTx.feeAmount = outgoingTransactionData.feeAmount
      tempTx.isSentToSelf = outgoingTransactionData.sentToSelf
      tempTx.transaction = self

      if let number = phoneNumber {
        number.configure(with: outgoingTransactionData, in: context)
        self.phoneNumber = number
      } else {
        switch outgoingTransactionData.dropBitType {
        case .phone(let phoneContact):
          if let inputs = ManagedPhoneNumberInputs(phoneNumber: phoneContact.globalPhoneNumber) {
            let number = CKMPhoneNumber.findOrCreate(withInputs: inputs, phoneNumberHash: phoneContact.phoneNumberHash, in: context)
            number.configure(with: outgoingTransactionData, in: context)
            self.phoneNumber = number
          }
        case .twitter(let twitterContact):
          let managedContact = CKMTwitterContact.findOrCreate(with: twitterContact, in: context)
          self.twitterContact = managedContact
        case .none: break
        }
      }
    }
  }

  /// Returns early if this transaction already has a CKMTransactionSharedPayload attached
  func configureNewSenderSharedPayload(with sharedPayloadDTO: SharedPayloadDTO?, in context: NSManagedObjectContext) {
    guard let dto = sharedPayloadDTO else { return }

    self.memo = dto.memo

    guard self.sharedPayload == nil,
      let amountInfo = dto.amountInfo,
      dto.shouldShare //don't persist if not shared
      else { return }

    self.sharedPayload = CKMTransactionSharedPayload(sharingDesired: dto.sharingDesired,
                                                     fiatAmount: amountInfo.fiatAmount,
                                                     fiatCurrency: amountInfo.fiatCurrencyCode.rawValue,
                                                     receivedPayload: nil,
                                                     insertInto: context)
  }

  static func prefixedTxid(for invitation: CKMInvitation) -> String {
    return CKMTransaction.invitationTxidPrefix + invitation.id
  }

  static let transactionHistorySortDescriptors: [NSSortDescriptor] = [
    NSSortDescriptor(key: #keyPath(CKMTransaction.sortDate), ascending: false)
  ]

  static func findLatest(in context: NSManagedObjectContext) -> CKMTransaction? {
    let fetchRequest: NSFetchRequest<CKMTransaction> = CKMTransaction.fetchRequest()
    fetchRequest.fetchLimit = 1
    fetchRequest.sortDescriptors = transactionHistorySortDescriptors

    do {
      return try context.fetch(fetchRequest).first
    } catch {
      log.error(error, message: "Could not execute fetch request for latest transaction")
      return nil
    }
  }

  var isInvite: Bool {
    return invitation != nil
  }

  var isConfirmed: Bool {
    return confirmations >= CKMTransaction.confirmationThreshold
  }

}

//extension CKMTransaction: CounterpartyRepresentable {
//
//  var counterpartyName: String? {
//    if let twitterCounterparty = invitation?.counterpartyTwitterContact {
//      return twitterCounterparty.formattedScreenName
//    } else if let inviteName = invitation?.counterpartyName {
//      return inviteName
//    } else {
//      let relevantNumber = phoneNumber ?? invitation?.counterpartyPhoneNumber
//      return relevantNumber?.counterparty?.name
//    }
//  }
//
//  func counterpartyConfig(deviceCountryCode: Int) -> TransactionCellCounterpartyConfig? {
//    if let counterpartyTwitterContact = self.twitterContact {
//      return counterpartyTwitterContact.formattedScreenName  // should include @-sign
//    }
//
//    if let relevantPhoneNumber = invitation?.counterpartyPhoneNumber ?? phoneNumber {
//      let globalPhoneNumber = relevantPhoneNumber.asGlobalPhoneNumber
//
//      var format: PhoneNumberFormat = .international
//      if let code = deviceCountryCode {
//        format = (code == globalPhoneNumber.countryCode) ? .national : .international
//      }
//      let formatter = CKPhoneNumberFormatter(format: format)
//
//      return try? formatter.string(from: globalPhoneNumber)
//    }
//
//    return nil
//  }
//
//  var counterpartyAddressId: String? {
//    return counterpartyReceiverAddressId
//  }
//}

extension CKMTransaction {
  static func == (lhs: CKMTransaction, rhs: CKMTransaction) -> Bool {
    return lhs.txid == rhs.txid
  }
}
