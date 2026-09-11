//
//  Item.swift
//  tiktoksellertool
//
//  Created by Trung Vu on 12/9/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
