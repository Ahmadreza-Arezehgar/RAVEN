//
//  RavenWidgetsBundle.swift
//  RavenWidgets
//
//  Created by AHMD on 22/2/26.
//

import WidgetKit
import SwiftUI

@main
struct RavenWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RavenWidgets()
        RavenWidgetsControl()
        RavenWidgetsLiveActivity()
        AudioRoomLiveActivity()
    }
}
