import { useState } from 'react';
import { socialService } from '../../services/socialService';
import './PostComposer.css';

function PostComposer({ onPost, onClose }) {
    const [content, setContent] = useState('');
    const [imageUrl, setImageUrl] = useState('');
    const [isPosting, setIsPosting] = useState(false);

    const handleSubmit = async (e) => {
        e.preventDefault();
        if (!content.trim()) return;

        setIsPosting(true);
        try {
            const post = await socialService.createPost(content, imageUrl || null);
            onPost(post);
            setContent('');
            setImageUrl('');
        } catch (error) {
            console.error('Error posting:', error);
            alert('Failed to post. Please try again.');
        }
        setIsPosting(false);
    };

    return (
        <div className="composer-modal" onClick={onClose}>
            <div className="composer-content glass-card" onClick={(e) => e.stopPropagation()}>
                <div className="composer-header">
                    <h3>Create Post</h3>
                    <button className="btn-icon close-btn" onClick={onClose}>
                        ✕
                    </button>
                </div>

                <form onSubmit={handleSubmit} className="composer-form">
                    <textarea
                        className="composer-textarea"
                        placeholder="What's on your mind?"
                        value={content}
                        onChange={(e) => setContent(e.target.value)}
                        maxLength={500}
                        rows={6}
                        autoFocus
                    />

                    <div className="char-count">
                        {content.length} / 500
                    </div>

                    <div className="composer-options">
                        <div className="option-group">
                            <label className="option-label">
                                🖼️ Image URL (optional)
                            </label>
                            <input
                                type="url"
                                className="input-field"
                                placeholder="https://example.com/image.jpg"
                                value={imageUrl}
                                onChange={(e) => setImageUrl(e.target.value)}
                            />
                        </div>
                    </div>

                    {imageUrl && (
                        <div className="image-preview">
                            <img src={imageUrl} alt="Preview" onError={(e) => e.target.style.display = 'none'} />
                        </div>
                    )}

                    <div className="composer-actions">
                        <button type="button" className="btn btn-secondary" onClick={onClose}>
                            Cancel
                        </button>
                        <button
                            type="submit"
                            className="btn btn-primary"
                            disabled={!content.trim() || isPosting}
                        >
                            {isPosting ? 'Posting...' : 'Post'}
                        </button>
                    </div>
                </form>
            </div>
        </div>
    );
}

export default PostComposer;
