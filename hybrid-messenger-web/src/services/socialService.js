import axios from 'axios';
import { authService } from './authService';

const API_BASE_URL = import.meta.env.VITE_API_URL || 'https://hybrid-messenger-api-516053629173.us-central1.run.app';

class SocialService {
    constructor() {
        this.posts = [];
        this.postHandlers = [];
    }

    /**
     * Get feed posts
     */
    async getFeed(limit = 50) {
        try {
            const response = await axios.get(
                `${API_BASE_URL}/api/posts/feed`,
                {
                    params: { limit },
                    headers: authService.getHeaders()
                }
            );

            this.posts = response.data.posts || [];
            return this.posts;
        } catch (error) {
            console.error('Error fetching feed:', error);
            return [];
        }
    }

    /**
     * Create a post
     */
    async createPost(content, imageUrl = null) {
        try {
            const response = await axios.post(
                `${API_BASE_URL}/api/posts/create`,
                {
                    content,
                    image_url: imageUrl,
                    timestamp: Date.now()
                },
                {
                    headers: authService.getHeaders()
                }
            );

            const newPost = response.data;
            this.posts.unshift(newPost); // Add to beginning
            this.notifyHandlers(newPost);

            return newPost;
        } catch (error) {
            console.error('Error creating post:', error);
            throw error;
        }
    }

    /**
     * Like a post
     */
    async likePost(postId) {
        try {
            await axios.post(
                `${API_BASE_URL}/api/posts/${postId}/like`,
                {},
                {
                    headers: authService.getHeaders()
                }
            );

            // Update local post
            const post = this.posts.find(p => p.id === postId);
            if (post) {
                post.is_liked = true;
                post.like_count = (post.like_count || 0) + 1;
            }
        } catch (error) {
            console.error('Error liking post:', error);
            throw error;
        }
    }

    /**
     * Unlike a post
     */
    async unlikePost(postId) {
        try {
            await axios.delete(
                `${API_BASE_URL}/api/posts/${postId}/like`,
                {
                    headers: authService.getHeaders()
                }
            );

            // Update local post
            const post = this.posts.find(p => p.id === postId);
            if (post) {
                post.is_liked = false;
                post.like_count = Math.max((post.like_count || 0) - 1, 0);
            }
        } catch (error) {
            console.error('Error unliking post:', error);
            throw error;
        }
    }

    /**
     * Repost
     */
    async repost(postId) {
        try {
            const response = await axios.post(
                `${API_BASE_URL}/api/posts/${postId}/repost`,
                {},
                {
                    headers: authService.getHeaders()
                }
            );

            // Update local post
            const post = this.posts.find(p => p.id === postId);
            if (post) {
                post.is_reposted = true;
                post.repost_count = (post.repost_count || 0) + 1;
            }

            return response.data;
        } catch (error) {
            console.error('Error reposting:', error);
            throw error;
        }
    }

    /**
     * Add comment
     */
    async addComment(postId, content) {
        try {
            const response = await axios.post(
                `${API_BASE_URL}/api/posts/${postId}/comments`,
                { content },
                {
                    headers: authService.getHeaders()
                }
            );

            // Update local post
            const post = this.posts.find(p => p.id === postId);
            if (post) {
                post.comment_count = (post.comment_count || 0) + 1;
            }

            return response.data;
        } catch (error) {
            console.error('Error adding comment:', error);
            throw error;
        }
    }

    /**
     * Get comments for a post
     */
    async getComments(postId) {
        try {
            const response = await axios.get(
                `${API_BASE_URL}/api/posts/${postId}/comments`,
                {
                    headers: authService.getHeaders()
                }
            );

            return response.data.comments || [];
        } catch (error) {
            console.error('Error fetching comments:', error);
            return [];
        }
    }

    /**
     * Delete post
     */
    async deletePost(postId) {
        try {
            await axios.delete(
                `${API_BASE_URL}/api/posts/${postId}`,
                {
                    headers: authService.getHeaders()
                }
            );

            // Remove from local posts
            this.posts = this.posts.filter(p => p.id !== postId);
        } catch (error) {
            console.error('Error deleting post:', error);
            throw error;
        }
    }

    /**
     * Get user's posts
     */
    async getUserPosts(userId) {
        try {
            const response = await axios.get(
                `${API_BASE_URL}/api/posts/user/${userId}`,
                {
                    headers: authService.getHeaders()
                }
            );

            return response.data.posts || [];
        } catch (error) {
            console.error('Error fetching user posts:', error);
            return [];
        }
    }

    /**
     * Register a post handler
     */
    onNewPost(handler) {
        this.postHandlers.push(handler);

        return () => {
            const index = this.postHandlers.indexOf(handler);
            if (index > -1) {
                this.postHandlers.splice(index, 1);
            }
        };
    }

    /**
     * Notify handlers of new post
     */
    notifyHandlers(post) {
        this.postHandlers.forEach(handler => handler(post));
    }

    /**
     * Clear cached posts
     */
    clear() {
        this.posts = [];
    }
}

export const socialService = new SocialService();
export default socialService;
