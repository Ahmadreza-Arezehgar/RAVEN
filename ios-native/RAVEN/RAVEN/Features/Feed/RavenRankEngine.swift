import Foundation
import CoreLocation

/// RavenRank™ - Enhanced X (Twitter) Algorithm for RAVEN
/// Optimized for Endless Scroll and High-Retention
actor RavenRankEngine {
    static let shared = RavenRankEngine()
    
    private init() {}
    
    // MARK: - Algorithm Weights (X-Style Tuning Parameters)
    private struct Weights {
        // 🔹 Engagement Weights (X Open Source)
        static let like: Double = 0.5
        static let repost: Double = 1.0
        static let comment: Double = 27.0    // X values replies/conversations massively
        
        // 🔹 Base Score (Prevents 0-engagement burial)
        static let baseScore: Double = 1.0
        
        // 🔹 Recency Decay (Half-Life)
        static let timeHalfLifeHours: Double = 6.0 // Score halves every 6 hours
        
        // 🔹 Format Boosts
        static let mediaBoost: Double = 2.0      // Images/Videos get 2x boost
        static let voiceBoost: Double = 2.0      // Voice posts get 2x boost
        static let meshBoost: Double = 1.5
        static let forYouBoost: Double = 1.2
        
        // 🔹 Creator Affinity
        static let ownPostBoost: Double = 50.0  // Huge ego-boost so users see their own posts instantly
        
        // 🔹 Spatial Radius
        static let optimalRadiusMeters: Double = 5000.0
        static let distanceHalfLifeKm: Double = 15.0
    }
    
    // MARK: - Public API
    
    /// Rank Local Feed - Infinite Scroll Ready
    func rankLocalFeed(posts: [Post], userLocation: CLLocation?, currentUserId: String, limit: Int = 1000) -> [Post] {
        let now = Date()
        var scoredPosts: [(post: Post, score: Double)] = []
        
        var seenIds = Set<String>()
        let uniquePosts = posts.filter { seenIds.insert($0.id).inserted }
        
        for post in uniquePosts {
            let score = calculateXStyleScore(post: post, isLocal: true, now: now, userLocation: userLocation, currentUserId: currentUserId, affinity: 1.0)
            scoredPosts.append((post, score))
        }
        
        scoredPosts.sort { $0.score > $1.score }
        return applyAuthorDiversity(scoredPosts, currentUserId: currentUserId).prefix(limit).map { $0.post }
    }
    
    /// Rank Friends Feed - Infinite Scroll Ready
    func rankFriendsFeed(posts: [Post], currentUserId: String, affinities: [String: Double] = [:], limit: Int = 1000) -> [Post] {
        let now = Date()
        var scoredPosts: [(post: Post, score: Double)] = []
        
        var seenIds = Set<String>()
        let uniquePosts = posts.filter { seenIds.insert($0.id).inserted }
        
        for post in uniquePosts {
            let affinity = affinities[post.authorId] ?? 1.0
            let score = calculateXStyleScore(post: post, isLocal: false, now: now, userLocation: nil, currentUserId: currentUserId, affinity: affinity)
            scoredPosts.append((post, score))
        }
        
        scoredPosts.sort { $0.score > $1.score }
        return applyAuthorDiversity(scoredPosts, currentUserId: currentUserId).prefix(limit).map { $0.post }
    }
    
    // MARK: - Core Math (X / Twitter Algorithm)
    
    private func calculateXStyleScore(post: Post, isLocal: Bool, now: Date, userLocation: CLLocation?, currentUserId: String, affinity: Double) -> Double {
        let isOwnPost = post.authorId == currentUserId
        let ageInSeconds = max(now.timeIntervalSince(post.timestamp), 1.0)
        let ageInHours = max(ageInSeconds / 3600.0, 0.1)
        
        // 1. Raw Engagement Score
        let rawEngagement = (Double(post.likes) * Weights.like) +
                            (Double(post.comments) * Weights.comment) +
                            (Double(post.reposts) * Weights.repost)
        
        var qualityScore = Weights.baseScore + rawEngagement
        
        // 2. Format Multipliers
        let hasMedia = post.imageUrl != nil || (post.media?.isEmpty == false)
        if hasMedia { qualityScore *= Weights.mediaBoost }
        if post.isVoicePost || post.voiceUrl != nil { qualityScore *= Weights.voiceBoost }
        
        if post.source == .forYou || post.source == .recommended {
            qualityScore *= Weights.forYouBoost
        }
        if post.meshStatus == "broadcasting" || post.meshStatus == "queued_mesh" || post.initialSend == "mesh" {
            qualityScore *= Weights.meshBoost
        }
        
        // Verified / Premium Boost
        if post.premiumStatus || post.verifiedStatus {
            qualityScore *= 2.0
        }
        
        // 3. Creator Boost (Ensures users see their own content)
        if isOwnPost {
            qualityScore *= Weights.ownPostBoost
        }
        
        // 4. Time Decay (Half-Life - X style)
        var timeDecay = pow(0.5, ageInHours / Weights.timeHalfLifeHours)
        
        // Decay self posts much slower so they stay visible at the top longer
        if isOwnPost {
            timeDecay = pow(0.85, ageInHours / 24.0)
        }
        
        // 5. Spatial Decay (For Local Feed)
        var distanceMultiplier = 1.0
        if isLocal && !isOwnPost {
            var distanceMeters: Double = Weights.optimalRadiusMeters
            if let d = post.distanceM {
                distanceMeters = Double(d)
            } else if let userLoc = userLocation, let lat = post.latitude, let lng = post.longitude {
                distanceMeters = userLoc.distance(from: CLLocation(latitude: lat, longitude: lng))
            }
            
            if distanceMeters > Weights.optimalRadiusMeters {
                let excessDistanceKm = (distanceMeters - Weights.optimalRadiusMeters) / 1000.0
                distanceMultiplier = pow(0.5, excessDistanceKm / Weights.distanceHalfLifeKm)
                distanceMultiplier = max(distanceMultiplier, 0.05) // Floor at 0.05
            }
        }
        
        // 6. Exploration Jitter
        // Boost new posts with low engagement randomly so they get a chance
        var jitter = 1.0
        if post.likes == 0 && post.comments == 0 && ageInHours < 2.0 && !isOwnPost {
            jitter = Double.random(in: 1.0...3.0)
        } else {
            jitter = Double.random(in: 0.95...1.05)
        }
        
        return qualityScore * timeDecay * distanceMultiplier * affinity * jitter
    }
    
    // MARK: - Author Diversity (Anti-Clustering)
    
    /// Prevents 1 user from dominating the feed, BUT does not penalize the current user's own posts
    private func applyAuthorDiversity(_ scoredPosts: [(post: Post, score: Double)], currentUserId: String) -> [(post: Post, score: Double)] {
        var result: [(post: Post, score: Double)] = []
        var authorCount: [String: Int] = [:]
        
        for item in scoredPosts {
            let count = authorCount[item.post.authorId] ?? 0
            var penalizedScore = item.score
            
            // Do not penalize the user's own posts
            if item.post.authorId != currentUserId {
                // Soft penalty (15%) per consecutive post for endless scroll variety
                let diversityMultiplier = pow(0.85, Double(count))
                penalizedScore *= diversityMultiplier
            }
            
            result.append((post: item.post, score: penalizedScore))
            authorCount[item.post.authorId] = count + 1
        }
        
        return result.sorted { $0.score > $1.score }
    }
}
