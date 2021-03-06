//
//  MockNetworkManager+PricingRequestable.swift
//  DropBitTests
//
//  Created by Ben Winters on 10/9/18.
//  Copyright © 2018 Coin Ninja, LLC. All rights reserved.
//

@testable import DropBit
import PromiseKit

extension MockNetworkManager: PricingRequestable {

  func fetchDayAveragePrice(for txid: String) -> Promise<PriceTransactionResponse> {
    return Promise { _ in }
  }

}
