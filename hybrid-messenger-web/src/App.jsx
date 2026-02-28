import { BrowserRouter as Router, Routes, Route, Navigate } from 'react-router-dom';
import { useState, useEffect } from 'react';
import './App.css';

// Pages
import LoginPage from './pages/LoginPage';
import SignUpPage from './pages/SignUpPage';
import MessagesPage from './pages/MessagesPage';
import BluetoothPage from './pages/BluetoothPage';
import HomePage from './pages/HomePage';
import { SearchPage, AccountPage } from './pages/PlaceholderPages';

// Services
import { authService } from './services/authService';

function App() {
    const [isAuthenticated, setIsAuthenticated] = useState(false);
    const [isLoading, setIsLoading] = useState(true);

    useEffect(() => {
        // Check if user is already logged in
        const checkAuth = async () => {
            const token = localStorage.getItem('token');
            if (token) {
                try {
                    await authService.validateToken(token);
                    setIsAuthenticated(true);
                } catch (error) {
                    console.error('Token validation failed:', error);
                    localStorage.removeItem('token');
                }
            }
            setIsLoading(false);
        };

        checkAuth();
    }, []);

    if (isLoading) {
        return (
            <div className="loading-container">
                <div className="loading-spinner"></div>
                <p>Loading RAVEN...</p>
            </div>
        );
    }

    return (
        <Router>
            <div className="app">
                <Routes>
                    {/* Public routes */}
                    <Route
                        path="/login"
                        element={
                            isAuthenticated ?
                                <Navigate to="/home" replace /> :
                                <LoginPage onLogin={() => setIsAuthenticated(true)} />
                        }
                    />
                    <Route
                        path="/signup"
                        element={
                            isAuthenticated ?
                                <Navigate to="/home" replace /> :
                                <SignUpPage onSignUp={() => setIsAuthenticated(true)} />
                        }
                    />

                    {/* Protected routes */}
                    <Route
                        path="/home"
                        element={
                            isAuthenticated ?
                                <HomePage /> :
                                <Navigate to="/login" replace />
                        }
                    />
                    <Route
                        path="/messages"
                        element={
                            isAuthenticated ?
                                <MessagesPage /> :
                                <Navigate to="/login" replace />
                        }
                    />
                    <Route
                        path="/search"
                        element={
                            isAuthenticated ?
                                <SearchPage /> :
                                <Navigate to="/login" replace />
                        }
                    />
                    <Route
                        path="/account"
                        element={
                            isAuthenticated ?
                                <AccountPage onLogout={() => setIsAuthenticated(false)} /> :
                                <Navigate to="/login" replace />
                        }
                    />

                    {/* Default redirect */}
                    <Route
                        path="/"
                        element={
                            <Navigate to={isAuthenticated ? "/home" : "/login"} replace />
                        }
                    />
                </Routes>
            </div>
        </Router>
    );
}

export default App;
