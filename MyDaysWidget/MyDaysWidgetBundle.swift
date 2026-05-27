//
//  MyDaysWidgetBundle.swift
//  MyDaysWidget
//
//  Created by DioMini on 5/26/26.
//

import WidgetKit
import SwiftUI

@main
struct MyDaysWidgetBundle: WidgetBundle {
    var body: some Widget {
        MyDaysWidget()
        MyDaysNTDLockWidget()
        MyDaysNTDLockCircleWidget()
    }
}
