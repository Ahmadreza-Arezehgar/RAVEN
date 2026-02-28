//
//  RavenWidgetsLiveActivity.swift
//  RavenWidgets
//
//  Created by AHMD on 22/2/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct RavenWidgetsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct RavenWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RavenWidgetsAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension RavenWidgetsAttributes {
    fileprivate static var preview: RavenWidgetsAttributes {
        RavenWidgetsAttributes(name: "World")
    }
}

extension RavenWidgetsAttributes.ContentState {
    fileprivate static var smiley: RavenWidgetsAttributes.ContentState {
        RavenWidgetsAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: RavenWidgetsAttributes.ContentState {
         RavenWidgetsAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: RavenWidgetsAttributes.preview) {
   RavenWidgetsLiveActivity()
} contentStates: {
    RavenWidgetsAttributes.ContentState.smiley
    RavenWidgetsAttributes.ContentState.starEyes
}
