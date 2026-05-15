import SwiftUI

/// بکگراند اختصاصی چتهای RAVEN (شامل پترنهای وکتور و هالههای نوری برند)
struct RavenChatWallpaper: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // ۱. رنگ سالیدِ پایه پسزمینه
            Color(colorScheme == .dark ? UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1) : UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1))
                .ignoresSafeArea()
            
            // ۲. هالهها و رگههای نوری بنفش/آبی ملایم در بکگراند (Liquid Glass Feel)
            GeometryReader { geo in
                ZStack {
                    // هاله بنفش در بالا چپ
                    Circle()
                        .fill(Color.purple.opacity(colorScheme == .dark ? 0.15 : 0.08))
                        .frame(width: geo.size.width * 0.8)
                        .blur(radius: 70)
                        .offset(x: -geo.size.width * 0.2, y: -geo.size.height * 0.1)
                    
                    // هاله آبی ملایم در پایین راست
                    Circle()
                        .fill(Color.blue.opacity(colorScheme == .dark ? 0.12 : 0.05))
                        .frame(width: geo.size.width * 0.9)
                        .blur(radius: 90)
                        .offset(x: geo.size.width * 0.3, y: geo.size.height * 0.4)
                }
            }
            .ignoresSafeArea()
            
            // ۳. پترن وکتور بامزه — UIColor(patternImage:) avoids SwiftUI GPU tiling bug
            if let patternImage = UIImage(named: "chat_pattern") {
                Rectangle()
                    .fill(Color(uiColor: UIColor(patternImage: patternImage)))
                    .opacity(0.8)
                    .ignoresSafeArea()
                    .id(colorScheme)
            }
        }
    }
}
