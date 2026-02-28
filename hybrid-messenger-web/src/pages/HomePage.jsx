import { useState, useEffect } from 'react';
import { socialService } from '../../services/socialService';
import { authService } from '../../services/authService';
import PostCard from '../../components/social/PostCard';
import PostComposer from '../../components/social/PostComposer';
import './HomePage.css';

function HomePage() {
    const [posts, setPosts] = useState([]);
    const [isLoading, setIsLoading] = useState(true);
    const [showComposer, setShowComposer] = useState(false);
    const currentUser = authService.getCurrentUser();

    useEffect(() => {
        loadFeed();

        // Auto-refresh every 10 seconds
        const interval = setInterval(loadFeed, 10000);
        return () => clearInterval(interval);
    }, []);

    const loadFeed = async () => {
        try {
            const feed = await socialService.getFeed();
            setPosts(feed);
        } catch (error) {
            console.error('Error loading feed:', error);
        }
        setIsLoading(false);
    };

    const handleNewPost = async (post) => {
        setPosts(prev => [post, ...prev]);
        setShowComposer(false);
    };

    const handleLike = async (postId) => {
        const post = posts.find(p => p.id === postId);
        if (!post) return;

        try {
            if (post.is_liked) {
                await socialService.unlikePost(postId);
            } else {
                await socialService.likePost(postId);
            }

            // Refresh to get updated counts
            await loadFeed();
        } catch (error) {
            console.error('Error toggling like:', error);
        }
    };

    const handleRepost = async (postId) => {
        try {
            await socialService.repost(postId);
            await loadFeed();
        } catch (error) {
            console.error('Error reposting:', error);
        }
    };

    const handleComment = async (postId, content) => {
        try {
            await socialService.addComment(postId, content);
            await loadFeed();
        } catch (error) {
            console.error('Error commenting:', error);
        }
    };

    const handleDelete = async (postId) => {
        if (!confirm('Delete this post?')) return;

        try {
            await socialService.deletePost(postId);
            setPosts(prev => prev.filter(p => p.id !== postId));
        } catch (error) {
            console.error('Error deleting post:', error);
        }
    };

    if (isLoading) {
        return (
            <div className="home-page">
                <div className="loading-container">
                    <div className="loading-spinner"></div>
                    <p>Loading feed...</p>
                </div>
            </div>
        );
    }

    return (
        <div className="home-page">
            {/* Header */}
            <div className="home-header">
                <h1>Home</h1>
                <button
                    className="btn btn-primary compose-btn"
                    onClick={() => setShowComposer(true)}
                >
                    ✍️ New Post
                </button>
            </div>

            {/* Post Composer Modal */}
            {showComposer && (
                <PostComposer
                    onPost={handleNewPost}
                    onClose={() => setShowComposer(false)}
                />
            )}

            {/* Feed */}
            <div className="feed">
                {posts.length === 0 ? (
                    <div className="empty-feed">
                        <div className="empty-icon">📭</div>
                        <h3>No posts yet</h3>
                        <p>Be the first to post something!</p>
                        <button
                            className="btn btn-primary"
                            onClick={() => setShowComposer(true)}
                        >
                            Create First Post
                        </button>
                    </div>
                ) : (
                    posts.map(post => (
                        <PostCard
                            key={post.id}
                            post={post}
                            currentUser={currentUser}
                            onLike={handleLike}
                            onRepost={handleRepost}
                            onComment={handleComment}
                            onDelete={handleDelete}
                        />
                    ))
                )}
            </div>
        </div>
    );
}

export default HomePage;
