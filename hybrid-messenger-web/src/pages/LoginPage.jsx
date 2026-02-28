import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { authService } from '../services/authService';
import './LoginPage.css';

function LoginPage({ onLogin }) {
    const [username, setUsername] = useState('');
    const [password, setPassword] = useState('');
    const [error, setError] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const navigate = useNavigate();

    const handleSubmit = async (e) => {
        e.preventDefault();
        setError('');
        setIsLoading(true);

        const result = await authService.login(username, password);

        if (result.success) {
            onLogin();
            navigate('/home');
        } else {
            setError(result.error);
        }

        setIsLoading(false);
    };

    return (
        <div className="login-page">
            <div className="login-container">
                <div className="login-card glass-card">
                    <div className="login-header">
                        <div className="logo">⚡</div>
                        <h1>RAVEN</h1>
                        <p>Stay connected anywhere</p>
                    </div>

                    <form onSubmit={handleSubmit} className="login-form">
                        {error && (
                            <div className="error-message">
                                {error}
                            </div>
                        )}

                        <div className="form-group">
                            <label htmlFor="username">Username</label>
                            <input
                                id="username"
                                type="text"
                                className="input-field"
                                placeholder="Enter your username"
                                value={username}
                                onChange={(e) => setUsername(e.target.value)}
                                required
                                autoComplete="username"
                            />
                        </div>

                        <div className="form-group">
                            <label htmlFor="password">Password</label>
                            <input
                                id="password"
                                type="password"
                                className="input-field"
                                placeholder="Enter your password"
                                value={password}
                                onChange={(e) => setPassword(e.target.value)}
                                required
                                autoComplete="current-password"
                            />
                        </div>

                        <button
                            type="submit"
                            className="btn btn-primary btn-full"
                            disabled={isLoading}
                        >
                            {isLoading ? 'Logging in...' : 'Login'}
                        </button>
                    </form>

                    <div className="login-footer">
                        <p>Don't have an account? <Link to="/signup">Sign Up</Link></p>
                    </div>

                    {/* Social login placeholder for future */}
                    <div className="social-login">
                        <div className="divider">
                            <span>or</span>
                        </div>
                        <button className="btn btn-secondary btn-full social-btn" disabled>
                            <span>🔐</span>
                            Sign in with Google (Coming Soon)
                        </button>
                    </div>
                </div>

                <div className="browser-notice">
                    <p>💡 For full offline mesh networking, use Chrome or Edge</p>
                </div>
            </div>
        </div>
    );
}

export default LoginPage;
