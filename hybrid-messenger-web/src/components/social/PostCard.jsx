import { useState } from 'react';
import { socialService } from '../../services/socialService';
import './PostCard.css';

function PostCard({ post, currentUser, onLike, onRepost, onComment, onDelete }) {
    const [showComments, setShowComments] = useState(false);
    const [commentText, setCommentText] = useState('');
    const [comments, setComments] = useState([]);
    const [isLoadingComments, setIsLoadingComments] = useState(false);

    const isOwnPost = post.user_id === currentUser?.id;

    const loadComments = async () => {
        if (comments.length > 0) {
            setShowComments(!showComments);
            return;
        }

        setIsLoadingComments(true);
        const postComments = await socialService.getComments(post.id);
        setComments(postComments);
        setShowComments(true);
        setIsLoadingComments(false);
    };

    const handleCommentSubmit = async (e) => {
        e.preventDefault();
        if (!commentText.trim()) return;

        await onComment(post.id, commentText);
        setCommentText('');

        // Reload comments
        const postComments = await socialService.getComments(post.id);
        setComments(postComments);
    };

    const formatTime = (timestamp) => {
        const date = new Date(timestamp);
        const now = new Date();
        const diff = now - date;

        if (diff < 60000) return 'now';
        if (diff < 3600000) return `${Math.floor(diff / 60000)}m`;
        if (diff < 86400000) return `${Math.floor(diff / 3600000)}h`;
        return `${Math.floor(diff / 86400000)}d`;
    };

    return (
        <div className="post-card glass-card">
            {/* Post Header */}
            <div className="post-header">
                <div className="post-avatar">
                    {post.username?.charAt(0).toUpperCase() || '?'}
                </div>
                <div className="post-author">
                    <div className="post-username">{post.username || 'Unknown'}</div>
                    <div className="post-time">{formatTime(post.timestamp)}</div>
                </div>
                {isOwnPost && (
                    <button
                        className="btn-icon delete-btn"
                        onClick={() => onDelete(post.id)}
                        title="Delete"
                    >
                        🗑️
                    </button>
                )}
            </div>

            {/* Post Content */}
            <div className="post-content">
                <p>{post.content}</p>
                {post.image_url && (
                    <img src={post.image_url} alt="Post" className="post-image" />
                )}
            </div>

            {/* Post Actions */}
            <div className="post-actions">
                <button
                    className={`action-btn ${showComments ? 'active' : ''}`}
                    onClick={loadComments}
                >
                    💬 {post.comment_count || 0}
                </button>

                <button
                    className={`action-btn ${post.is_reposted ? 'active' : ''}`}
                    onClick={() => onRepost(post.id)}
                >
                    🔄 {post.repost_count || 0}
                </button>

                <button
                    className={`action-btn like-btn ${post.is_liked ? 'active liked' : ''}`}
                    onClick={() => onLike(post.id)}
                >
                    {post.is_liked ? '❤️' : '🤍'} {post.like_count || 0}
                </button>
            </div>

            {/* Comments Section */}
            {showComments && (
                <div className="comments-section">
                    <form onSubmit={handleCommentSubmit} className="comment-form">
                        <input
                            type="text"
                            className="input-field"
                            placeholder="Write a comment..."
                            value={commentText}
                            onChange={(e) => setCommentText(e.target.value)}
                        />
                        <button type="submit" className="btn btn-primary btn-sm">
                            Post
                        </button>
                    </form>

                    {isLoadingComments ? (
                        <div className="loading-comments">Loading...</div>
                    ) : (
                        <div className="comments-list">
                            {comments.map(comment => (
                                <div key={comment.id} className="comment-item">
                                    <div className="comment-avatar">
                                        {comment.username?.charAt(0).toUpperCase() || '?'}
                                    </div>
                                    <div className="comment-content">
                                        <div className="comment-header">
                                            <span className="comment-username">{comment.username}</span>
                                            <span className="comment-time">{formatTime(comment.timestamp)}</span>
                                        </div>
                                        <p>{comment.content}</p>
                                    </div>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            )}
        </div>
    );
}

export default PostCard;
