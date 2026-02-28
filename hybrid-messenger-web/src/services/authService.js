import axios from 'axios';

const API_BASE_URL = import.meta.env.VITE_API_URL || 'https://hybrid-messenger-api-516053629173.us-central1.run.app';

class AuthService {
    constructor() {
        this.token = localStorage.getItem('token');
        this.user = JSON.parse(localStorage.getItem('user') || 'null');
    }

    // Get auth headers
    getHeaders() {
        return {
            'Content-Type': 'application/json',
            ...(this.token && { 'Authorization': `Bearer ${this.token}` })
        };
    }

    // Sign up
    async signUp(username, email, password) {
        try {
            const response = await axios.post(`${API_BASE_URL}/api/auth/signup`, {
                username,
                email,
                password
            });

            const { access_token, user } = response.data;
            this.token = access_token;
            this.user = user;

            localStorage.setItem('token', access_token);
            localStorage.setItem('user', JSON.stringify(user));

            return { success: true, user };
        } catch (error) {
            console.error('Sign up error:', error);
            return {
                success: false,
                error: error.response?.data?.detail || 'Sign up failed'
            };
        }
    }

    // Login
    async login(username, password) {
        try {
            const response = await axios.post(`${API_BASE_URL}/api/auth/login`, {
                username,
                password
            });

            const { access_token, user } = response.data;
            this.token = access_token;
            this.user = user;

            localStorage.setItem('token', access_token);
            localStorage.setItem('user', JSON.stringify(user));

            return { success: true, user };
        } catch (error) {
            console.error('Login error:', error);
            return {
                success: false,
                error: error.response?.data?.detail || 'Login failed'
            };
        }
    }

    // Validate token
    async validateToken(token) {
        try {
            const response = await axios.get(`${API_BASE_URL}/api/auth/me`, {
                headers: {
                    'Authorization': `Bearer ${token}`
                }
            });

            this.user = response.data;
            localStorage.setItem('user', JSON.stringify(this.user));
            return true;
        } catch (error) {
            return false;
        }
    }

    // Logout
    logout() {
        this.token = null;
        this.user = null;
        localStorage.removeItem('token');
        localStorage.removeItem('user');
    }

    // Get current user
    getCurrentUser() {
        return this.user;
    }

    // Check if authenticated
    isAuthenticated() {
        return !!this.token;
    }
}

export const authService = new AuthService();
export default authService;
