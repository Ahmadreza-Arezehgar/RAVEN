//
//  RavenWidgetsBundle.swift
//  RavenWidgets
//
//  Created by AHMD on 22/2/26.
//x 

import WidgetKit
import SwiftUI

@main
struct RavenWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RavenWidgets()
        if #available(iOS 18.0, *) {
            RavenWidgetsControl()
        }
        RavenWidgetsLiveActivity()
        AudioRoomLiveActivity()
    }
}
